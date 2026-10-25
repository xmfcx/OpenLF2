// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/versions.hpp"
#include "openlf2/core/files.hpp"
#include "openlf2/core/json.hpp"
#include "openlf2/ports/digest.hpp"
#include "openlf2/ports/download.hpp"
#include "openlf2/ports/settings.hpp"
#include <algorithm>
#include <atomic>
#include <fstream>
#include <mutex>
#include <thread>
#include <zlib.h>

// GCC 13 at -O2 and above reports std::variant members of ScriptField (the integer key) as maybe uninitialized when
// a field is moved into a table; the warning is a known false positive.
#if defined(__GNUC__) && !defined(__clang__)
#pragma GCC diagnostic ignored "-Wmaybe-uninitialized"
#endif

namespace openlf2 {
namespace {
constexpr std::size_t index_limit = 4 * 1024 * 1024;
constexpr std::size_t package_limit = 512 * 1024 * 1024;
constexpr std::size_t unpacked_limit = 1024 * 1024 * 1024;

std::string utf8(const std::filesystem::path& path) {
    const auto text = path.u8string();
    return std::string(text.begin(), text.end());
}
std::filesystem::path from_utf8(std::string_view text) {
    return std::filesystem::path(std::u8string(text.begin(), text.end()));
}
// Version ids name directories: letters, digits and ". _ + -" only, never "." or "..".
bool valid_id(std::string_view id) {
    if (id.empty() || id.size() > 64 || id == "." || id == "..") return false;
    return std::all_of(id.begin(), id.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '.' || c == '_'
            || c == '+' || c == '-';
    });
}
const ScriptValue* field(const ScriptValue& value, std::string_view key) {
    const auto* table = std::get_if<ScriptTable>(&value.value);
    if (!table) return nullptr;
    for (const auto& entry : *table) {
        if (const auto* name = std::get_if<std::string>(&entry.key); name && *name == key) return &entry.value;
    }
    return nullptr;
}
std::string text(const ScriptValue* value) {
    if (!value) return {};
    if (const auto* string = std::get_if<std::string>(&value->value)) return *string;
    return {};
}
ScriptValue string_value(std::string text) { return ScriptValue{std::move(text)}; }
// Replaces or adds `key` in a table value.
void put(ScriptValue& table, std::string_view key, ScriptValue value) {
    auto* entries = std::get_if<ScriptTable>(&table.value);
    if (!entries) {
        table.value = ScriptTable{};
        entries = std::get_if<ScriptTable>(&table.value);
    }
    for (auto& entry : *entries) {
        if (const auto* name = std::get_if<std::string>(&entry.key); name && *name == key) {
            entry.value = std::move(value);
            return;
        }
    }
    set_field(*entries, std::string(key), std::move(value));
}
void erase(ScriptValue& table, std::string_view key) {
    auto* entries = std::get_if<ScriptTable>(&table.value);
    if (!entries) return;
    std::erase_if(*entries, [&](const ScriptField& entry) {
        const auto* name = std::get_if<std::string>(&entry.key);
        return name && *name == key;
    });
}

Result<ScriptValue> load_document(const SettingsStore& settings) {
    auto loaded = settings.load();
    if (!loaded) return std::unexpected(loaded.error());
    if (!*loaded) return ScriptValue{ScriptTable{}};
    auto parsed = parse_json(**loaded);
    if (!parsed) return std::unexpected(parsed.error());
    if (!std::holds_alternative<ScriptTable>(parsed->value)) return ScriptValue{ScriptTable{}};
    return *parsed;
}
// Changes the "versions" member of the configuration and saves it; other members stay as they are.
template <typename Change> Result<void> change_versions(SettingsStore& settings, Change change) {
    auto document = load_document(settings);
    if (!document) return std::unexpected(document.error());
    ScriptValue versions = ScriptValue{ScriptTable{}};
    if (const auto* stored = field(*document, "versions"); stored && std::holds_alternative<ScriptTable>(stored->value)) {
        versions = *stored;
    }
    change(versions);
    put(*document, "versions", std::move(versions));
    auto written = write_json(*document);
    if (!written) return std::unexpected(written.error());
    return settings.save(*written);
}

Result<Bytes> gunzip(std::span<const char> packed) {
    z_stream stream{};
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return fail(ErrorCode::dependency, "zlib could not start");
    Bytes output;
    std::array<char, 1 << 16> buffer{};
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(packed.data()));
    stream.avail_in = static_cast<uInt>(packed.size());
    int status = Z_OK;
    while (status != Z_STREAM_END) {
        stream.next_out = reinterpret_cast<Bytef*>(buffer.data());
        stream.avail_out = static_cast<uInt>(buffer.size());
        status = inflate(&stream, Z_NO_FLUSH);
        if (status != Z_OK && status != Z_STREAM_END) {
            inflateEnd(&stream);
            return fail(ErrorCode::format, "the version package is not a valid .tar.gz");
        }
        output.insert(output.end(), buffer.data(), buffer.data() + (buffer.size() - stream.avail_out));
        if (output.size() > unpacked_limit) {
            inflateEnd(&stream);
            return fail(ErrorCode::limit, "the version package is too large");
        }
    }
    inflateEnd(&stream);
    return output;
}
std::uint64_t octal(std::span<const char> digits) {
    std::uint64_t value = 0;
    for (const char c : digits) {
        if (c >= '0' && c <= '7') value = value * 8 + static_cast<std::uint64_t>(c - '0');
        else if (c != ' ' && c != '\0') break;
    }
    return value;
}
std::string header_text(std::span<const char> bytes) {
    const auto end = std::find(bytes.begin(), bytes.end(), '\0');
    return std::string(bytes.begin(), end);
}
// A path inside the package: relative, forward slashes, no "." or ".." parts.
std::optional<std::filesystem::path> package_path(std::string_view name) {
    if (name.empty() || name.front() == '/' || name.find('\\') != std::string_view::npos
        || name.find(':') != std::string_view::npos) return std::nullopt;
    std::filesystem::path path;
    std::size_t start = 0;
    while (start <= name.size()) {
        const auto end = std::min(name.find('/', start), name.size());
        const auto part = name.substr(start, end - start);
        if (part == "..") return std::nullopt;
        if (!part.empty() && part != ".") path /= from_utf8(part);
        start = end + 1;
    }
    if (path.empty()) return std::nullopt;
    return path;
}
// Unpacks a ustar archive (files, directories, GNU long names; other entries are skipped) into `target`.
Result<void> untar(std::span<const char> archive, const std::filesystem::path& target) {
    std::size_t offset = 0;
    std::string long_name;
    while (offset + 512 <= archive.size()) {
        const auto header = archive.subspan(offset, 512);
        if (std::all_of(header.begin(), header.end(), [](char c) { return c == '\0'; })) break;
        const auto size = octal(header.subspan(124, 12));
        const char type = header[156];
        std::string name = header_text(header.subspan(0, 100));
        if (header_text(header.subspan(257, 5)) == "ustar") {
            const auto prefix = header_text(header.subspan(345, 155));
            if (!prefix.empty()) name = prefix + "/" + name;
        }
        offset += 512;
        if (size > archive.size() - offset) return fail(ErrorCode::format, "the version package is cut short");
        const auto data = archive.subspan(offset, static_cast<std::size_t>(size));
        offset += static_cast<std::size_t>((size + 511) / 512 * 512);
        if (type == 'L') {
            long_name = header_text(data);
            continue;
        }
        if (!long_name.empty()) {
            name = long_name;
            long_name.clear();
        }
        if (type != '0' && type != '\0' && type != '5') continue;
        // The package's own folder ("./", from `tar -C dir .`) is the target itself.
        if (type == '5' && std::all_of(name.begin(), name.end(), [](char c) { return c == '.' || c == '/'; })
            && name.find("..") == std::string::npos) continue;
        const auto relative = package_path(name);
        if (!relative) return fail(ErrorCode::format, "the version package has an unsafe path: " + name);
        const auto path = target / *relative;
        std::error_code error;
        if (type == '5') {
            std::filesystem::create_directories(path, error);
            if (error) return fail(ErrorCode::io, "cannot create " + utf8(path) + ": " + error.message());
            continue;
        }
        std::filesystem::create_directories(path.parent_path(), error);
        if (error) return fail(ErrorCode::io, "cannot create " + utf8(path.parent_path()) + ": " + error.message());
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        file.write(data.data(), static_cast<std::streamsize>(data.size()));
        if (!file) return fail(ErrorCode::io, "cannot write " + utf8(path));
        file.close();
        if (octal(header.subspan(100, 8)) & 0100) {
            std::filesystem::permissions(path, std::filesystem::perms::owner_exec | std::filesystem::perms::group_exec
                | std::filesystem::perms::others_exec, std::filesystem::perm_options::add, error);
        }
    }
    return {};
}

class FileVersionStore final : public VersionStore {
public:
    FileVersionStore(VersionSetup setup, SettingsStore& settings, std::unique_ptr<Downloader> downloader)
        : setup_(std::move(setup)), settings_(settings), downloader_(std::move(downloader)) {}
    ~FileVersionStore() override {
        cancel_ = true;
        if (worker_.joinable()) worker_.join();
    }

    ScriptValue describe() const override {
        ScriptValue result{ScriptTable{}};
        put(result, "current", string_value(setup_.current_id));
        put(result, "commit", string_value(setup_.commit));
        put(result, "platform", string_value(setup_.platform));
        put(result, "base_id", string_value(setup_.base_id));
        put(result, "index_url", string_value(setup_.index_url));
        put(result, "active", string_value(chosen_version(settings_).value_or("")));
        ScriptTable installed;
        std::vector<std::string> ids;
        std::error_code error;
        for (const auto& entry : std::filesystem::directory_iterator(setup_.root, error)) {
            const auto name = utf8(entry.path().filename());
            if (entry.is_directory(error) && valid_id(name) && name.front() != '.') ids.push_back(name);
        }
        std::sort(ids.begin(), ids.end(), std::greater<>());
        std::int32_t position = 1;
        for (const auto& id : ids) {
            ScriptValue version{ScriptTable{}};
            if (auto bytes = read_file(setup_.root / from_utf8(id) / "version.json", 1024 * 1024)) {
                if (auto parsed = parse_json(std::string_view(bytes->data(), bytes->size()));
                    parsed && std::holds_alternative<ScriptTable>(parsed->value)) version = *parsed;
            }
            put(version, "id", string_value(id));
            set_field(installed, position++, std::move(version));
        }
        put(result, "installed", ScriptValue{std::move(installed)});
        return result;
    }

    Result<void> fetch_index() override {
        if (setup_.index_url.empty()) return fail(ErrorCode::unsupported, "this build has no version index address");
        return start("index", [this]() -> Result<void> {
            auto bytes = downloader_->fetch(setup_.index_url, index_limit, progress_callback());
            if (!bytes) return std::unexpected(bytes.error());
            auto parsed = parse_json(std::string_view(bytes->data(), bytes->size()));
            if (!parsed) return std::unexpected(parsed.error());
            std::lock_guard lock(mutex_);
            index_ = std::move(*parsed);
            return {};
        });
    }

    Result<void> install(std::string_view id) override {
        if (!valid_id(id)) return fail(ErrorCode::format, "invalid version id");
        ScriptValue entry;
        {
            std::lock_guard lock(mutex_);
            const auto* versions = index_ ? field(*index_, "versions") : nullptr;
            const auto* list = versions ? std::get_if<ScriptTable>(&versions->value) : nullptr;
            if (!list) return fail(ErrorCode::unsupported, "read the version index first");
            for (const auto& item : *list) {
                if (text(field(item.value, "id")) == id) entry = item.value;
            }
        }
        const auto* files = field(entry, "files");
        const auto* file = files ? field(*files, setup_.platform) : nullptr;
        if (!file) return fail(ErrorCode::unsupported, "version " + std::string(id) + " has no " + setup_.platform + " build");
        const auto url = text(field(*file, "url"));
        const auto digest = text(field(*file, "sha256"));
        if (url.empty() || digest.size() != 64) return fail(ErrorCode::format, "the version index entry is incomplete");
        if (running_from(id)) return fail(ErrorCode::unsupported, "this version is running");
        return start("install", [this, id = std::string(id), entry, url, digest]() -> Result<void> {
            auto bytes = downloader_->fetch(url, package_limit, progress_callback());
            if (!bytes) return std::unexpected(bytes.error());
            auto actual = sha256(*bytes);
            if (!actual) return std::unexpected(actual.error());
            std::string expected = digest;
            std::transform(expected.begin(), expected.end(), expected.begin(), [](unsigned char c) {
                return static_cast<char>(std::tolower(c));
            });
            if (*actual != expected) return fail(ErrorCode::format, "the downloaded version does not match its SHA-256");
            auto archive = gunzip(*bytes);
            if (!archive) return std::unexpected(archive.error());
            const auto partial = setup_.root / from_utf8(".partial-" + id);
            const auto target = setup_.root / from_utf8(id);
            std::error_code error;
            std::filesystem::remove_all(partial, error);
            std::filesystem::create_directories(partial, error);
            if (error) return fail(ErrorCode::io, "cannot create " + utf8(partial) + ": " + error.message());
            if (auto unpacked = untar(*archive, partial); !unpacked) {
                std::filesystem::remove_all(partial, error);
                return unpacked;
            }
            auto metadata = write_json(entry);
            if (!metadata) return std::unexpected(metadata.error());
            if (auto saved = replace_file(partial, "version.json", *metadata); !saved) return saved;
            std::filesystem::remove_all(target, error);
            std::filesystem::rename(partial, target, error);
            if (error) return fail(ErrorCode::io, "cannot install " + utf8(target) + ": " + error.message());
            return {};
        });
    }

    ScriptValue poll() override {
        std::lock_guard lock(mutex_);
        if (worker_.joinable() && finished_) worker_.join();
        ScriptValue result{ScriptTable{}};
        put(result, "state", string_value(state_));
        put(result, "task", string_value(task_));
        put(result, "progress", ScriptValue{progress_.load()});
        put(result, "message", string_value(message_));
        if (task_ == "index" && state_ == "done" && index_) put(result, "index", *index_);
        return result;
    }

    Result<void> remove(std::string_view id) override {
        if (!valid_id(id)) return fail(ErrorCode::format, "invalid version id");
        if (running_from(id)) return fail(ErrorCode::unsupported, "this version is running");
        {
            std::lock_guard lock(mutex_);
            if (state_ == "running") return fail(ErrorCode::unsupported, "wait for the running task");
        }
        std::error_code error;
        std::filesystem::remove_all(setup_.root / from_utf8(id), error);
        if (error) return fail(ErrorCode::io, "cannot delete version " + std::string(id) + ": " + error.message());
        if (chosen_version(settings_) == std::string(id)) {
            return change_versions(settings_, [](ScriptValue& versions) { erase(versions, "active"); });
        }
        return {};
    }

    Result<void> launch(std::string_view id, std::span<const std::string> extra) override {
        std::filesystem::path program;
        const bool base = id.empty() || id == setup_.base_id;
        if (base) program = setup_.base_program;
        else {
            if (!valid_id(id)) return fail(ErrorCode::format, "invalid version id");
            program = setup_.root / from_utf8(id) / setup_.program.filename();
        }
        std::error_code error;
        if (!std::filesystem::is_regular_file(program, error)) {
            return fail(ErrorCode::io, "version " + std::string(id) + " is not installed");
        }
        auto saved = change_versions(settings_, [&](ScriptValue& versions) {
            if (base) erase(versions, "active");
            else put(versions, "active", string_value(std::string(id)));
        });
        if (!saved) return saved;
        VersionLaunch request{program, setup_.arguments};
        request.arguments.insert(request.arguments.end(), extra.begin(), extra.end());
        request.arguments.push_back("--no-redirect");
        std::lock_guard lock(mutex_);
        launch_ = std::move(request);
        return {};
    }

    std::optional<VersionLaunch> take_launch() override {
        std::lock_guard lock(mutex_);
        auto request = std::move(launch_);
        launch_.reset();
        return request;
    }

private:
    bool running_from(std::string_view id) const {
        std::error_code error;
        const auto own = std::filesystem::weakly_canonical(setup_.program.parent_path(), error);
        const auto version = std::filesystem::weakly_canonical(setup_.root / from_utf8(id), error);
        return !error && own == version;
    }
    DownloadProgress progress_callback() {
        return [this](std::uint64_t received, std::uint64_t total) {
            if (total > 0) progress_ = static_cast<double>(received) / static_cast<double>(total);
            return !cancel_.load();
        };
    }
    template <typename Work> Result<void> start(std::string task, Work work) {
        std::lock_guard lock(mutex_);
        if (state_ == "running") return fail(ErrorCode::unsupported, "another version task is running");
        if (worker_.joinable()) worker_.join();
        state_ = "running";
        task_ = std::move(task);
        message_.clear();
        progress_ = 0.0;
        finished_ = false;
        worker_ = std::thread([this, work = std::move(work)]() mutable {
            Result<void> outcome = fail(ErrorCode::io, "version task failed");
            try {
                outcome = work();
            } catch (const std::exception& error) {
                outcome = fail(ErrorCode::io, error.what());
            }
            std::lock_guard done(mutex_);
            state_ = outcome ? "done" : "failed";
            message_ = outcome ? std::string{} : outcome.error().message;
            if (outcome) progress_ = 1.0;
            finished_ = true;
        });
        return {};
    }

    VersionSetup setup_;
    SettingsStore& settings_;
    std::unique_ptr<Downloader> downloader_;
    mutable std::mutex mutex_;
    std::thread worker_;
    std::atomic<bool> cancel_{false};
    std::atomic<double> progress_{0.0};
    bool finished_ = true;
    std::string state_ = "idle", task_, message_;
    std::optional<ScriptValue> index_;
    std::optional<VersionLaunch> launch_;
};
}

std::unique_ptr<VersionStore> make_version_store(VersionSetup setup, SettingsStore& settings,
                                                 std::unique_ptr<Downloader> downloader) {
    return std::make_unique<FileVersionStore>(std::move(setup), settings, std::move(downloader));
}

std::optional<std::string> chosen_version(const SettingsStore& settings) {
    auto document = load_document(settings);
    if (!document) return std::nullopt;
    const auto* versions = field(*document, "versions");
    const auto id = versions ? text(field(*versions, "active")) : std::string{};
    if (!valid_id(id)) return std::nullopt;
    return id;
}

Result<void> record_base_program(SettingsStore& settings, const std::filesystem::path& program, std::string_view id) {
    return change_versions(settings, [&](ScriptValue& versions) {
        put(versions, "base", string_value(utf8(program)));
        put(versions, "base_id", string_value(std::string(id)));
    });
}

std::optional<std::filesystem::path> recorded_base_program(const SettingsStore& settings, std::string* id) {
    auto document = load_document(settings);
    if (!document) return std::nullopt;
    const auto* versions = field(*document, "versions");
    const auto base = versions ? text(field(*versions, "base")) : std::string{};
    if (base.empty()) return std::nullopt;
    if (id) *id = text(field(*versions, "base_id"));
    return from_utf8(base);
}
}
