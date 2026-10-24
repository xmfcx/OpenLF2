// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

#pragma once

#include "openlf2/core/result.hpp"
#include "openlf2/core/script_value.hpp"
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace openlf2 {
class Downloader;
class SettingsStore;

// A program to start once the current frame is done, after which this one quits.
struct VersionLaunch {
    std::filesystem::path program;
    std::vector<std::string> arguments;
};

// Game versions (OpenLF2 extension): complete builds installed in the configuration directory (versions/<id>/),
// the published version index they come from, and switching between them. The configuration keeps the chosen
// version ("versions": {"active": id}) and this program's own place ("base", "base_id"), so the program that the
// player starts can open the chosen version. Downloads and unpacking run on a worker thread; poll() reports them.
class VersionStore {
public:
    virtual ~VersionStore() = default;
    // {current, commit, platform, active, base_id, index_url, installed = {version.json of each installed version}}.
    [[nodiscard]] virtual ScriptValue describe() const = 0;
    // Starts reading the version index.
    virtual Result<void> fetch_index() = 0;
    // Starts installing a version of the last index read: download, SHA-256 check and unpacking.
    virtual Result<void> install(std::string_view id) = 0;
    // The running or last task: {state = "idle" | "running" | "done" | "failed", task, progress (0 to 1), message,
    // index (after a done "index" task)}.
    virtual ScriptValue poll() = 0;
    // Deletes an installed version (not the running one).
    virtual Result<void> remove(std::string_view id) = 0;
    // Chooses a version (the base program's id or an installed one) and asks to start it with `extra` arguments.
    virtual Result<void> launch(std::string_view id, std::span<const std::string> extra) = 0;
    virtual std::optional<VersionLaunch> take_launch() = 0;
};

struct VersionSetup {
    std::filesystem::path root;          // versions/ in the configuration directory
    std::filesystem::path program;       // this program
    std::filesystem::path base_program;  // the program the player starts (this one, or the one that started it)
    std::string base_id;                 // its version
    std::string current_id;              // this program's version
    std::string commit;
    std::string platform;                // "windows-x64", "linux-x64" ...
    std::string index_url;
    std::vector<std::string> arguments;  // to pass on to a started version (configuration directory and so on)
};

std::unique_ptr<VersionStore> make_version_store(VersionSetup setup, SettingsStore& settings,
                                                 std::unique_ptr<Downloader> downloader);
// The version the configuration chooses ("versions.active"), or nothing.
std::optional<std::string> chosen_version(const SettingsStore& settings);
// Records this program as the base one in the configuration ("versions.base", "versions.base_id").
Result<void> record_base_program(SettingsStore& settings, const std::filesystem::path& program, std::string_view id);
// The base program the configuration records, if any.
std::optional<std::filesystem::path> recorded_base_program(const SettingsStore& settings, std::string* id);
}
