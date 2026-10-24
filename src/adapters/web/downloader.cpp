// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/download.hpp"

namespace openlf2 {
Result<std::unique_ptr<Downloader>> make_downloader(bool) {
    return fail(ErrorCode::dependency,
                "Browser download is unavailable; select your LF2_v2.0a.exe in the launcher");
}
}
