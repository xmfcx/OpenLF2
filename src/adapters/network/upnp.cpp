// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#include "openlf2/ports/port_mapping.hpp"
#include <array>
#include <mutex>
#include <string>
#include <thread>
#include <miniupnpc.h>
#include <upnpcommands.h>
#include <upnperrors.h>

namespace openlf2 {
namespace {
constexpr int discover_ms = 2000;
// A day: the router drops the mapping by itself when the program ends without removing it (a crash).
constexpr const char* lease_seconds = "86400";

class UpnpMapping final : public PortMapping {
public:
    explicit UpnpMapping(std::uint16_t port) : port_(std::to_string(port)) {
        worker_ = std::thread([this] { run(); });
    }
    ~UpnpMapping() override {
        if (worker_.joinable()) worker_.join();
        if (mapped_) UPNP_DeletePortMapping(urls_.controlURL, data_.first.servicetype, port_.c_str(), "UDP", nullptr);
        if (have_urls_) FreeUPNPUrls(&urls_);
    }
    PortMappingStatus status() const override {
        std::scoped_lock lock(mutex_);
        return status_;
    }

private:
    void finish(PortMappingStatus::State state, std::string address, std::string problem) {
        std::scoped_lock lock(mutex_);
        status_ = {state, std::move(address), std::move(problem)};
    }
    void run() {
        int error = 0;
        UPNPDev* devices = upnpDiscover(discover_ms, nullptr, nullptr, UPNP_LOCAL_PORT_ANY, 0, 2, &error);
        if (!devices) return finish(PortMappingStatus::State::failed, {}, "no UPnP router found");
        std::array<char, 64> local{};
        std::array<char, 64> wan{};
        const int found = UPNP_GetValidIGD(devices, &urls_, &data_, local.data(), local.size(), wan.data(), wan.size());
        freeUPNPDevlist(devices);
        have_urls_ = found != 0;
        if (found != 1) return finish(PortMappingStatus::State::failed, {}, "the router does not offer UPnP port mapping");
        int result = UPNP_AddPortMapping(urls_.controlURL, data_.first.servicetype, port_.c_str(), port_.c_str(),
                                         local.data(), "OpenLF2", "UDP", nullptr, lease_seconds);
        // Some routers take only mappings without an end.
        if (result == 725) {
            result = UPNP_AddPortMapping(urls_.controlURL, data_.first.servicetype, port_.c_str(), port_.c_str(),
                                         local.data(), "OpenLF2", "UDP", nullptr, "0");
        }
        if (result != UPNPCOMMAND_SUCCESS) {
            return finish(PortMappingStatus::State::failed, {}, std::string("the router refused the port: ") + strupnperror(result));
        }
        mapped_ = true;
        std::array<char, 64> address{};
        if (UPNP_GetExternalIPAddress(urls_.controlURL, data_.first.servicetype, address.data()) != UPNPCOMMAND_SUCCESS) {
            address[0] = '\0';
        }
        finish(PortMappingStatus::State::mapped, address.data(), {});
    }
    std::string port_;
    UPNPUrls urls_{};
    IGDdatas data_{};
    bool have_urls_ = false;
    bool mapped_ = false;
    mutable std::mutex mutex_;
    PortMappingStatus status_;
    std::thread worker_;
};
}

Result<std::unique_ptr<PortMapping>> map_udp_port(std::uint16_t port) {
    return std::unique_ptr<PortMapping>(std::make_unique<UpnpMapping>(port));
}
}
