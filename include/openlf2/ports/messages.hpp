// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once
#include "openlf2/core/result.hpp"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace openlf2 {
// Messages between a server and many clients over UDP (docs/netcode.md "Transport"). Channel 0 is reliable and
// ordered (lobby, commands), channel 1 is unreliable (inputs and final ticks, which repeat their data). Main-thread
// use; every operation is nonblocking. One transport is either a server (listen) or a client (connect).
struct MessageEvent {
    enum class Kind { connected, disconnected, received };
    Kind kind = Kind::received;
    std::uint32_t peer = 0;
    std::uint8_t channel = 0;
    std::string data;
};
// The transport's own measurement of a connection.
struct PeerQuality {
    std::uint32_t round_trip_ms = 0;
    std::uint32_t round_trip_variance_ms = 0;
    std::uint32_t packet_loss_permille = 0;
};
class MessageTransport {
public:
    static constexpr std::size_t max_message_bytes = 65536;
    static constexpr std::uint8_t channels = 2;
    virtual ~MessageTransport() = default;
    // Numeric IPv4 address, or "0.0.0.0" for every interface; `peers` is the most clients at once.
    virtual Result<void> listen(std::string_view address, std::uint16_t port, std::size_t peers) = 0;
    // Starts a connection; the server's peer number comes back at once, and a connected event follows.
    virtual Result<std::uint32_t> connect(std::string_view address, std::uint16_t port) = 0;
    virtual Result<void> send(std::uint32_t peer, std::uint8_t channel, std::span<const char> bytes) = 0;
    // Sends what is queued and returns what happened since the last call.
    virtual Result<std::vector<MessageEvent>> service() = 0;
    // Waits until a datagram arrives or `milliseconds` pass (a server sleeps here between its frames).
    virtual void wait(std::uint32_t milliseconds) noexcept = 0;
    virtual void disconnect(std::uint32_t peer) noexcept = 0;
    virtual void close() noexcept = 0;
    [[nodiscard]] virtual std::optional<PeerQuality> quality(std::uint32_t peer) const noexcept = 0;
};
// Fails on platforms without UDP (the web build).
Result<std::unique_ptr<MessageTransport>> make_message_transport();
}
