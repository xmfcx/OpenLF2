// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include <cstdint>
#include <memory>
#include <string>

namespace openlf2 {
// A port of the home router opened for the server program (OpenLF2 extension, plan.md "Play with the friend"): UPnP
// asks the router to send UDP packets of the port to this computer, and tells the public address that the players
// type to join. The work runs in the background; the mapping goes away with the object.
struct PortMappingStatus {
    enum class State { working, mapped, failed };
    State state = State::working;
    std::string public_address; // the router's public IPv4 address, when mapped
    std::string problem;        // why it failed
};
class PortMapping {
public:
    virtual ~PortMapping() = default;
    [[nodiscard]] virtual PortMappingStatus status() const = 0;
};
// Starts mapping UDP `port`; fails at once on platforms without UPnP (the web build).
Result<std::unique_ptr<PortMapping>> map_udp_port(std::uint16_t port);
}
