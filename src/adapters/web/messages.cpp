// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/messages.hpp"

namespace openlf2 {
Result<std::unique_ptr<MessageTransport>> make_message_transport() {
    return fail(ErrorCode::platform, "UDP messages are unavailable in browsers");
}
}
