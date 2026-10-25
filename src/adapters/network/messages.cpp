// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/messages.hpp"
#include <cstdlib>
#include <map>
#include <utility>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include <enet/enet.h>

namespace openlf2 {
namespace {
// ENet keeps process-wide state (WinSock on Windows); it starts once and ends at exit.
bool start_enet() {
    static const bool started = [] {
        if (enet_initialize() != 0) return false;
        std::atexit(enet_deinitialize);
        return true;
    }();
    return started;
}

// One ENet host; peers get small numbers that stay valid until they disconnect (never ENet pointers).
class EnetTransport final : public MessageTransport {
public:
    ~EnetTransport() override { close(); }

    Result<void> listen(std::string_view address, std::uint16_t port, std::size_t peers) override {
        close();
        ENetAddress bound{};
        if (address == "0.0.0.0") bound.host = ENET_HOST_ANY;
        else if (enet_address_set_host_ip(&bound, std::string(address).c_str()) != 0) {
            return fail(ErrorCode::format, "Invalid server address");
        }
        bound.port = port;
        if (peers < 1 || peers > 4095) return fail(ErrorCode::limit, "A server allows 1 to 4095 clients");
        host_ = enet_host_create(&bound, peers, channels, 0, 0);
        if (!host_) return fail(ErrorCode::io, "Cannot listen on UDP port " + std::to_string(port));
        return {};
    }

    Result<std::uint32_t> connect(std::string_view address, std::uint16_t port) override {
        close();
        ENetAddress target{};
        if (enet_address_set_host_ip(&target, std::string(address).c_str()) != 0) {
            return fail(ErrorCode::format, "Invalid server address");
        }
        target.port = port;
        host_ = enet_host_create(nullptr, 1, channels, 0, 0);
        if (!host_) return fail(ErrorCode::io, "Cannot open a UDP socket");
        ENetPeer* peer = enet_host_connect(host_, &target, channels, 0);
        if (!peer) {
            close();
            return fail(ErrorCode::io, "Cannot start the connection");
        }
        return add(peer);
    }

    Result<void> send(std::uint32_t peer, std::uint8_t channel, std::span<const char> bytes) override {
        const auto found = peers_.find(peer);
        if (!host_ || found == peers_.end()) return fail(ErrorCode::io, "No such connection");
        if (channel >= channels) return fail(ErrorCode::format, "Invalid channel");
        if (bytes.size() > max_message_bytes) return fail(ErrorCode::limit, "Message too large");
        // Channel 1 is unreliable: a lost message is not sent again, and the next one carries its data.
        ENetPacket* packet = enet_packet_create(bytes.data(), bytes.size(), channel == 0 ? ENET_PACKET_FLAG_RELIABLE : 0);
        if (!packet) return fail(ErrorCode::limit, "Out of memory");
        if (enet_peer_send(found->second, channel, packet) != 0) {
            enet_packet_destroy(packet);
            return fail(ErrorCode::io, "Cannot send a message");
        }
        // Sent at once, not at the next service: a message waits a whole frame otherwise (docs/netcode.md, "Clock").
        enet_host_flush(host_);
        return {};
    }

    Result<std::vector<MessageEvent>> service() override {
        std::vector<MessageEvent> events;
        if (!host_) return events;
        ENetEvent event{};
        // A bound on the events of one call keeps a flood from stalling a frame; the rest wait for the next call.
        while (events.size() < 4096) {
            const int serviced = enet_host_service(host_, &event, 0);
            if (serviced < 0) return fail(ErrorCode::io, "Network error");
            if (serviced == 0) break;
            if (event.type == ENET_EVENT_TYPE_CONNECT) {
                auto number = event.peer->data ? id_of(event.peer) : add(event.peer);
                events.push_back({MessageEvent::Kind::connected, number, 0, {}});
            } else if (event.type == ENET_EVENT_TYPE_DISCONNECT) {
                if (event.peer->data) {
                    const auto number = id_of(event.peer);
                    peers_.erase(number);
                    event.peer->data = nullptr;
                    events.push_back({MessageEvent::Kind::disconnected, number, 0, {}});
                }
            } else if (event.type == ENET_EVENT_TYPE_RECEIVE) {
                if (event.peer->data && event.packet->dataLength <= max_message_bytes) {
                    events.push_back({MessageEvent::Kind::received, id_of(event.peer), event.channelID,
                        std::string(reinterpret_cast<const char*>(event.packet->data), event.packet->dataLength)});
                }
                enet_packet_destroy(event.packet);
            }
        }
        enet_host_flush(host_);
        return events;
    }

    void wait(std::uint32_t milliseconds) noexcept override {
        if (!host_) return;
        enet_uint32 condition = ENET_SOCKET_WAIT_RECEIVE | ENET_SOCKET_WAIT_INTERRUPT;
        enet_socket_wait(host_->socket, &condition, milliseconds);
    }

    void disconnect(std::uint32_t peer) noexcept override {
        const auto found = peers_.find(peer);
        if (found == peers_.end()) return;
        enet_peer_disconnect(found->second, 0);
    }

    void close() noexcept override {
        if (!host_) return;
        for (auto& [number, peer] : peers_) {
            enet_peer_disconnect_now(peer, 0);
            peer->data = nullptr;
        }
        peers_.clear();
        enet_host_flush(host_);
        enet_host_destroy(host_);
        host_ = nullptr;
    }

    std::optional<PeerQuality> quality(std::uint32_t peer) const noexcept override {
        const auto found = peers_.find(peer);
        if (found == peers_.end()) return std::nullopt;
        const ENetPeer* native = found->second;
        return PeerQuality{native->roundTripTime, native->roundTripTimeVariance,
            static_cast<std::uint32_t>(static_cast<std::uint64_t>(native->packetLoss) * 1000 / ENET_PEER_PACKET_LOSS_SCALE)};
    }

private:
    // The peer number is kept in ENet's user data field as an integer value.
    static std::uint32_t id_of(const ENetPeer* peer) {
        return static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(peer->data));
    }
    std::uint32_t add(ENetPeer* peer) {
        const auto number = next_++;
        peer->data = reinterpret_cast<void*>(static_cast<std::uintptr_t>(number));
        peers_[number] = peer;
        return number;
    }
    ENetHost* host_ = nullptr;
    std::map<std::uint32_t, ENetPeer*> peers_;
    std::uint32_t next_ = 1;
};
}

Result<std::unique_ptr<MessageTransport>> make_message_transport() {
    if (!start_enet()) return fail(ErrorCode::dependency, "Cannot start ENet");
    return std::unique_ptr<MessageTransport>(std::make_unique<EnetTransport>());
}
}
