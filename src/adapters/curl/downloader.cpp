// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

// libcurl adapter: HTTPS downloads into memory. libcurl types stay inside this file.
#include "openlf2/ports/download.hpp"
#include <array>
#include <filesystem>
#include <fstream>
#include <span>
#include <string>
#include <curl/curl.h>

namespace openlf2 {
namespace {
struct CleanupEasy {
    void operator()(CURL* handle) const noexcept { curl_easy_cleanup(handle); }
};
// curl_global_init() brackets every other libcurl call; the downloader owns this session.
struct CurlSession {
    CurlSession() = default;
    CurlSession(const CurlSession&) = delete;
    CurlSession& operator=(const CurlSession&) = delete;
    ~CurlSession() { curl_global_cleanup(); }
};
// State shared with the callbacks of one transfer. Callbacks never let exceptions reach libcurl.
struct Transfer {
    Bytes bytes;
    std::size_t limit = 0;
    const DownloadProgress& progress;
    bool over_limit = false;
    bool cancelled = false;
};
std::size_t receive(char* data, std::size_t size, std::size_t count, void* opaque) noexcept {
    auto& transfer = *static_cast<Transfer*>(opaque);
    const auto length = size * count;
    if (length > transfer.limit - transfer.bytes.size()) {
        transfer.over_limit = true;
        return 0;
    }
    try {
        const std::span<const char> chunk(data, length);
        transfer.bytes.insert(transfer.bytes.end(), chunk.begin(), chunk.end());
    } catch (...) {
        return 0;
    }
    return length;
}
int report(void* opaque, curl_off_t total, curl_off_t received, curl_off_t, curl_off_t) noexcept {
    auto& transfer = *static_cast<Transfer*>(opaque);
    const auto count = [](curl_off_t value) { return value > 0 ? static_cast<std::uint64_t>(value) : 0; };
    try {
        if (transfer.progress && !transfer.progress(count(received), count(total))) transfer.cancelled = true;
    } catch (...) {
        transfer.cancelled = true;
    }
    return transfer.cancelled ? 1 : 0;
}
template <typename Value> void set(CURL* handle, CURLoption option, Value value, CURLcode& code) {
    if (code == CURLE_OK) code = curl_easy_setopt(handle, option, value);
}
#ifdef __ANDROID__
Result<std::string> android_ca_bundle() {
    constexpr std::array directories{
        "/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"};
    constexpr std::uintmax_t max_certificate = 64 * 1024;
    constexpr std::size_t max_bundle = 8 * 1024 * 1024;
    for (const auto* directory : directories) {
        std::error_code error;
        std::filesystem::directory_iterator entries(directory, error);
        if (error) continue;
        std::string bundle;
        const std::filesystem::directory_iterator end;
        for (; entries != end; entries.increment(error)) {
            if (error) return fail(ErrorCode::io, "download: cannot read Android CA directory");
            const auto& entry = *entries;
            if (!entry.is_regular_file(error) || error) {
                if (error) return fail(ErrorCode::io, "download: cannot read Android CA directory");
                continue;
            }
            const auto size = entry.file_size(error);
            if (error || size > max_certificate || size > max_bundle - bundle.size()) {
                return fail(ErrorCode::limit, "download: Android CA bundle is too large or unreadable");
            }
            std::ifstream file(entry.path(), std::ios::binary);
            if (!file) return fail(ErrorCode::io, "download: cannot open Android CA certificate");
            std::string certificate(static_cast<std::size_t>(size), '\0');
            if (!file.read(certificate.data(), static_cast<std::streamsize>(size))) {
                return fail(ErrorCode::io, "download: cannot read Android CA certificate");
            }
            if (certificate.find("-----BEGIN CERTIFICATE-----") != std::string::npos) {
                bundle += certificate;
                bundle += '\n';
            }
        }
        if (error) return fail(ErrorCode::io, "download: cannot read Android CA directory");
        if (!bundle.empty()) return bundle;
    }
    return fail(ErrorCode::dependency, "download: Android system CA certificates are unavailable");
}
#endif
class CurlDownloader final : public Downloader {
public:
    explicit CurlDownloader(bool verify_server) : verify_server_(verify_server) {}
    Result<Bytes> fetch(std::string_view url, std::size_t limit, const DownloadProgress& progress) const override {
        const std::unique_ptr<CURL, CleanupEasy> handle(curl_easy_init());
        if (!handle) return fail(ErrorCode::dependency, "download: libcurl could not start a transfer");
        const std::string address(url);
        std::array<char, CURL_ERROR_SIZE> message{};
        Transfer transfer{{}, limit, progress};
        CURLcode code = CURLE_OK;
        set(handle.get(), CURLOPT_URL, address.c_str(), code);
        set(handle.get(), CURLOPT_ERRORBUFFER, message.data(), code);
        // Downloads accept HTTPS connections without authenticating the server, unless asked to.
        set(handle.get(), CURLOPT_SSL_VERIFYPEER, verify_server_ ? 1L : 0L, code);
        set(handle.get(), CURLOPT_SSL_VERIFYHOST, verify_server_ ? 2L : 0L, code);
#ifdef __ANDROID__
        // Android names CA files using hashes that need not match the OpenSSL
        // version linked into curl. Load the system PEM certificates as a bundle.
        auto ca_bundle = android_ca_bundle();
        if (!ca_bundle) return std::unexpected(ca_bundle.error());
        curl_blob certificates{ca_bundle->data(), ca_bundle->size(), CURL_BLOB_COPY};
        set(handle.get(), CURLOPT_CAINFO_BLOB, &certificates, code);
#endif
#ifdef __vita__
        // VitaSDK's mbedTLS curl has no installed CA store on the console.
        // The VPK carries the build image's verified system trust bundle.
        set(handle.get(), CURLOPT_CAINFO, "app0:/certs/ca-certificates.crt", code);
#endif
#if (defined(_WIN32) || defined(__APPLE__)) && defined(CURLSSLOPT_NATIVE_CA)
        // Use the OS trust store: OpenSSL's CA paths may be absent on the target device.
        // Apple builds enable SecTrust in libcurl; Schannel already uses native trust.
        set(handle.get(), CURLOPT_SSL_OPTIONS, static_cast<long>(CURLSSLOPT_NATIVE_CA), code);
#endif
#if LIBCURL_VERSION_NUM >= 0x075500
        set(handle.get(), CURLOPT_PROTOCOLS_STR, "https", code);
        set(handle.get(), CURLOPT_REDIR_PROTOCOLS_STR, "https", code);
#else
        set(handle.get(), CURLOPT_PROTOCOLS, CURLPROTO_HTTPS, code);
        set(handle.get(), CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS, code);
#endif
        set(handle.get(), CURLOPT_FOLLOWLOCATION, 1L, code);
        set(handle.get(), CURLOPT_MAXREDIRS, 5L, code);
        set(handle.get(), CURLOPT_FAILONERROR, 1L, code);
        set(handle.get(), CURLOPT_USERAGENT, "OpenLF2", code);
        // Worker threads must not rely on signals for DNS timeouts.
        set(handle.get(), CURLOPT_NOSIGNAL, 1L, code);
        set(handle.get(), CURLOPT_CONNECTTIMEOUT, 30L, code);
        // A stalled connection (under 1 byte/s for a minute) fails instead of hanging.
        set(handle.get(), CURLOPT_LOW_SPEED_LIMIT, 1L, code);
        set(handle.get(), CURLOPT_LOW_SPEED_TIME, 60L, code);
        set(handle.get(), CURLOPT_MAXFILESIZE_LARGE, static_cast<curl_off_t>(limit), code);
        set(handle.get(), CURLOPT_WRITEFUNCTION, &receive, code);
        set(handle.get(), CURLOPT_WRITEDATA, &transfer, code);
        set(handle.get(), CURLOPT_NOPROGRESS, 0L, code);
        set(handle.get(), CURLOPT_XFERINFOFUNCTION, &report, code);
        set(handle.get(), CURLOPT_XFERINFODATA, &transfer, code);
        if (code != CURLE_OK) {
            return fail(ErrorCode::dependency, std::string("download: libcurl option: ") + curl_easy_strerror(code));
        }
        code = curl_easy_perform(handle.get());
        if (transfer.cancelled) return fail(ErrorCode::io, "download cancelled: " + address);
        if (transfer.over_limit || code == CURLE_FILESIZE_EXCEEDED) {
            return fail(ErrorCode::limit, "download: " + address + " is larger than " + std::to_string(limit) + " bytes");
        }
        if (code != CURLE_OK) {
            const std::string reason = message.front() != '\0' ? message.data() : curl_easy_strerror(code);
            return fail(ErrorCode::io, "download: " + address + ": " + reason);
        }
        return std::move(transfer.bytes);
    }

private:
    CurlSession session_;
    bool verify_server_ = false;
};
}
Result<std::unique_ptr<Downloader>> make_downloader(bool verify_server) {
    if (const auto code = curl_global_init(CURL_GLOBAL_DEFAULT); code != CURLE_OK) {
        return fail(ErrorCode::dependency, std::string("download: libcurl: ") + curl_easy_strerror(code));
    }
    return std::unique_ptr<Downloader>(std::make_unique<CurlDownloader>(verify_server));
}
}
