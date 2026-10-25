// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/port_mapping.hpp"

namespace openlf2 {
Result<std::unique_ptr<PortMapping>> map_udp_port(std::uint16_t) {
    return fail(ErrorCode::platform, "UPnP is unavailable in browsers");
}
}
