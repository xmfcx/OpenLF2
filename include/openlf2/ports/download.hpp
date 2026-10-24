// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include <cstdint>
#include <functional>
#include <memory>
#include <string_view>

namespace openlf2 {
// Bytes received so far and the size the server announced (0 while unknown). It is called on
// the thread running fetch(); returning false cancels the transfer.
using DownloadProgress = std::function<bool(std::uint64_t received, std::uint64_t total)>;
class Downloader {
public:
    virtual ~Downloader() = default;
    // Downloads an HTTPS `url` into memory, following HTTPS redirects. Transfers larger than
    // `limit` bytes fail. Independent calls may run on worker threads.
    virtual Result<Bytes> fetch(std::string_view url, std::size_t limit,
                                const DownloadProgress& progress) const = 0;
};
// Call it on the main thread. Fails with ErrorCode::dependency when the build has no
// download support. By default the server is not authenticated (the installer is checked
// against known SHA-256 values); `verify_server` authenticates it, for downloads whose
// checksums come from the same server (game versions).
Result<std::unique_ptr<Downloader>> make_downloader(bool verify_server = false);
}
