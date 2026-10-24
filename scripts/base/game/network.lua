-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local controls = require("base/ui/controls")
local recording = require("base/game/recording")
local speed = require("base/game/speed")
local network = {}
local timeout = 30000
-- Script sharing (OpenLF2 extension): when the profiles differ, the host offers its game scripts with this header,
-- 8 decimal digits of size and a newline. The joining player is asked first; on "Y" the host sends the scripts, the
-- joining game answers "D" once it has them all, the host listens again and the joining game swaps in the scripts
-- (engine.replace_scripts: memory only, same sandbox) and joins again.
local profile_prefix = "OpenLF2 TCP 1\n"
local share_header = "OpenLF2 scripts 1 "
local share_header_size = #share_header + 9
local share_limit = 16 * 1024 * 1024
local share_piece = 16384
local ask_timeout = 120000
local operations = {module = true, replace = true, extend = true}
-- After its offer the host also names its game version (base/ui/versions) on a line of its own; joining games
-- before this ignore the line, newer ones can offer to switch to that version.
local version_prefix = "OpenLF2 version "
-- This build's game version, from its label ("OpenLF2 <version> (<commit>)").
function network.own_version()
    return engine.build_label and engine.build_label:match("^OpenLF2 (%S+)") or nil
end
local function take_version_line(state)
    if state.host_version or #state.received < #version_prefix then return end
    if state.received:sub(1, #version_prefix) ~= version_prefix then return end
    local line = state.received:match("^" .. version_prefix .. "([%w%.%_%+%-]+)\n")
    if line then
        state.host_version = line
        state.received = state.received:sub(#version_prefix + #line + 2)
    elseif #state.received > #version_prefix + 65 then
        state.host_version = ""
    end
end
local function failed(state, message)
    engine.network("close")
    state.phase, state.error = "failed", message
    return nil, message
end
local function send(state, bytes)
    local sent, problem = engine.network("send", bytes)
    if not sent then return failed(state, problem) end
    return true
end
local function take(state, count)
    if #state.received < count then return nil end
    local bytes = state.received:sub(1, count)
    state.received = state.received:sub(count + 1)
    return bytes
end
-- Declarations as a count line, then each of their four fields as a length line and the bytes.
local function encode_scripts(declarations)
    local parts = {#declarations .. "\n"}
    for _, declaration in ipairs(declarations) do
        for field = 1, 4 do parts[#parts + 1] = #declaration[field] .. "\n" .. declaration[field] end
    end
    return table.concat(parts)
end
local function decode_scripts(bytes)
    local position = 1
    local function number()
        local digits = bytes:match("^(%d+)\n", position)
        if not digits or #digits > 8 then return nil end
        position = position + #digits + 1
        return tonumber(digits)
    end
    local count = number()
    if not count or count < 1 or count > 4096 then return nil end
    local declarations = {}
    for index = 1, count do
        local declaration = {}
        for field = 1, 4 do
            local size = number()
            if not size or position + size - 1 > #bytes then return nil end
            declaration[field] = bytes:sub(position, position + size - 1)
            position = position + size
        end
        if not operations[declaration[1]] then return nil end
        declarations[index] = declaration
    end
    if position ~= #bytes + 1 then return nil end
    return declarations
end
local function names_packet(host)
    local fields = {host and "11110000" or "00001111", string.rep("0", 24)}
    for index = 1, 4 do
        local name = controls.current().names[index]:sub(1, constants.text_limits.player_name_bytes)
        fields[#fields + 1] = name .. string.rep("_", constants.text_limits.player_name_field_bytes - #name)
    end
    return table.concat(fields) .. "\0"
end
local function read_names(state, bytes)
    local expected = state.host and "00001111" or "11110000"
    if bytes:sub(1, 8) ~= expected or bytes:byte(77) ~= 0 then return failed(state, "Invalid network player assignment") end
    state.names = {}
    for index = 1, 4 do
        local peer = bytes:sub(33 + (index - 1) * constants.text_limits.player_name_field_bytes, 43 + (index - 1) * constants.text_limits.player_name_field_bytes):match("^[^_%z]*")
        local own = controls.current().names[index]:match("^[^_%z]*"):sub(1, constants.text_limits.player_name_bytes)
        state.names[(state.host and 0 or 4) + index] = own
        state.names[(state.host and 4 or 0) + index] = peer
    end
    return true
end
function network.create(options)
    assert(type(options.network_profile) == "string" and #options.network_profile == 64, "missing network profile")
    return {phase = "idle", received = "", sequence = 0, frames = 0,
        version = options.recording_version, profile = "OpenLF2 TCP 1\n" .. options.network_profile,
        port = options.network_port or constants.network.default_port}
end
function network.start(state, host, address)
    network.close(state)
    state.host, state.error, state.received, state.address = host, nil, "", address
    state.share, state.notice = nil, state.host and state.notice or nil
    -- `accepted`: a peer connected to this host; `profiled`: its profile arrived (see ui/network's waiting page).
    state.accepted, state.profiled, state.host_version = false, false, nil
    state.names, state.pending, state.sequence, state.frames = nil, nil, 0, 0
    local started, problem = engine.network(host and "host" or "join", address, state.port)
    if not started then return failed(state, problem) end
    state.phase = "connecting"
    state.deadline = engine.network_time() + timeout
    return true
end
function network.close(state)
    engine.network("close")
    state.phase, state.pending, state.received = "idle", nil, ""
end
-- The transfer of shared scripts: several polls per frame, as each poll moves at most one send and 8 KiB received.
local function share_poll(state)
    local share = state.share
    for _ = 1, 32 do
        if state.phase == "uploading" and share.sent < #share.bundle then
            local piece = share.bundle:sub(share.sent + 1, share.sent + share_piece)
            -- A full send queue refuses the piece; it is offered again after the next poll.
            if engine.network("send", piece) then
                share.sent = share.sent + #piece
                state.deadline = engine.network_time() + timeout
            end
        end
        local bytes, problem = engine.network("poll")
        if not bytes then
            -- The host closes the connection once it has the joining game's "D".
            if state.phase == "finishing" then return network.swap(state) end
            return failed(state, problem)
        end
        if state.phase == "uploading" and #bytes > 0 then
            if bytes ~= "D" then return failed(state, "Invalid network scripts answer") end
            engine.network("close")
            local address = state.address
            state.notice = "Scripts sent. Waiting for the other player to join again"
            if not network.start(state, true, address) then return nil, state.error end
            return false
        elseif state.phase == "downloading" and #bytes > 0 then
            share.chunks[#share.chunks + 1] = bytes
            share.received = share.received + #bytes
            state.deadline = engine.network_time() + timeout
            if share.received > share.size then return failed(state, "Network scripts size mismatch") end
            if share.received == share.size then
                if not send(state, "D") then return nil, state.error end
                state.phase, state.deadline = "finishing", engine.network_time() + 5000
            end
        end
    end
    if state.phase == "uploading" then
        state.notice = string.format("Sending scripts: %d%%", math.floor(share.sent * 100 / #share.bundle))
    elseif state.phase == "downloading" then
        state.notice = string.format("Receiving scripts: %d%%", math.floor(share.received * 100 / share.size))
    end
    if engine.network_time() > state.deadline then
        if state.phase == "finishing" then return network.swap(state) end
        return failed(state, "Network connection timed out")
    end
    return false
end
-- The joining game has the host's scripts: they replace its own, and the new scripts join the host again.
function network.swap(state)
    engine.network("close")
    local declarations = decode_scripts(table.concat(state.share.chunks))
    if not declarations then return failed(state, "Invalid network scripts") end
    local replaced, problem = engine.replace_scripts(declarations, {network_role = "join", network_address = state.address,
        network_port = state.port, network_profile = state.remote_profile, network_retry = true})
    if not replaced then return failed(state, "The host's scripts did not load: " .. tostring(problem)) end
    state.phase = "swapped"
    return false
end
-- The joining player's answer to the host's offer.
function network.answer(state, allow)
    if state.phase ~= "ask" then return end
    if not allow then return failed(state, "You refused the host's scripts") end
    if not send(state, "Y") then return end
    state.phase, state.deadline = "downloading", engine.network_time() + timeout
end
-- Called from the lobby or once per attempted tick. No simulation or RNG draw occurs while
-- waiting. Deadlines measure elapsed real time, never simulation time.
function network.poll(state)
    if state.phase == "failed" then return nil, state.error end
    if state.phase == "swapped" then return false end
    if state.phase == "uploading" or state.phase == "downloading" or state.phase == "finishing" then
        return share_poll(state)
    end
    local bytes, problem = engine.network("poll")
    if not bytes then
        if state.phase == "await_offer" then problem = "Network engine/scripts/mod profile mismatch"
        elseif state.phase == "offered" then problem = "The other player refused the scripts or cannot receive them" end
        return failed(state, problem)
    end
    state.received = state.received .. bytes
    if #state.received > constants.network.max_receive_buffer_bytes then return failed(state, "Network receive buffer exceeded") end
    -- A host waits for a peer until it is cancelled; the time limits start when one connects.
    local listening = state.host and state.phase == "connecting" and not state.accepted
    if state.phase ~= "ready" and not listening and engine.network_time() > state.deadline then
        return failed(state, "Network connection timed out")
    end
    if state.phase == "connecting" and engine.network("status") == "connected" then
        if state.host then state.accepted, state.deadline = true, engine.network_time() + timeout end
        if not send(state, state.profile) then return nil, state.error end
        state.phase = "profile"
    end
    if state.phase == "profile" then
        local profile = take(state, #state.profile)
        if not profile then return false end
        state.profiled = true
        if profile ~= state.profile then
            if state.host and engine.scripts then
                state.share = {bundle = encode_scripts(engine.scripts()), sent = 0}
                if #state.share.bundle > share_limit then return failed(state, "Network engine/scripts/mod profile mismatch") end
                local offer = share_header .. string.format("%08d", #state.share.bundle) .. "\n"
                local version = network.own_version()
                if version then offer = offer .. version_prefix .. version .. "\n" end
                if not send(state, offer) then return nil, state.error end
                state.phase, state.deadline = "offered", engine.network_time() + ask_timeout
            elseif not state.host and profile:sub(1, #profile_prefix) == profile_prefix
                   and profile:sub(#profile_prefix + 1):match("^%x+$") then
                state.remote_profile = profile:sub(#profile_prefix + 1)
                state.phase, state.deadline = "await_offer", engine.network_time() + 5000
            else
                return failed(state, "Network engine/scripts/mod profile mismatch")
            end
        else
            state.checksum = recording.data_checksum() % 65536
            if state.host then
                if not send(state, "u can connect\0") then return nil, state.error end
                state.phase = "players"
            else state.phase = "greeting" end
        end
    end
    if state.phase == "offered" then
        local answer = take(state, 1)
        if not answer then return false end
        if answer ~= "Y" then return failed(state, "Invalid network scripts answer") end
        state.phase, state.deadline = "uploading", engine.network_time() + timeout
        return false
    end
    if state.phase == "await_offer" then
        local header = take(state, share_header_size)
        if not header then return false end
        local digits = header:sub(#share_header + 1, -2)
        local size = header:sub(1, #share_header) == share_header and header:sub(-1) == "\n"
            and digits:match("^%d+$") and tonumber(digits)
        if not size or size < 1 or size > share_limit then return failed(state, "Invalid network scripts offer") end
        state.share = {size = size, chunks = {}, received = 0}
        state.phase, state.deadline = "ask", engine.network_time() + ask_timeout
        take_version_line(state)
        return false
    end
    if state.phase == "ask" then
        take_version_line(state)
        return false
    end
    if state.phase == "greeting" then
        local greeting = take(state, 14)
        if not greeting then return false end
        if greeting ~= "u can connect\0" then return failed(state, "Invalid network greeting") end
        if not send(state, names_packet(false)) then return nil, state.error end
        state.phase = "players"
    end
    if state.phase == "players" then
        local players = take(state, 77)
        if not players then return false end
        if not read_names(state, players) then return nil, state.error end
        if state.host then
            local random_table = engine.random_state()
            engine.set_random_state(random_table, 0)
            engine.reset_random_sequence()
            if not send(state, names_packet(true) .. random_table .. "\0") then return nil, state.error end
            state.phase = "ready"
        else state.phase = "random" end
    end
    if state.phase == "random" then
        local random_table = take(state, constants.random_table_size + 1)
        if not random_table then return false end
        if random_table:byte(constants.random_table_size + 1) ~= 0 or random_table:sub(1, constants.random_table_size):find("\0", 1, true) then
            return failed(state, "Invalid network random table")
        end
        engine.set_random_state(random_table:sub(1, constants.random_table_size), 0)
        engine.reset_random_sequence()
        state.phase = "ready"
    end
    return state.phase == "ready"
end
local function has(value, bit) return math.floor(value / bit) % 2 == 1 end
-- Bytes 17 to 20 (OpenLF2 extension, the original sends 1 1 1 1): a click of this computer's mouse, so that the menus
-- run it on both computers. 1 1 1 1 is no click, else x and y, each as its high byte plus 2 and its low byte.
local function packet_click(packet)
    local high_x, low_x, high_y, low_y = packet:byte(17, 20)
    if high_x == 1 and low_x == 1 and high_y == 1 and low_y == 1 then return nil end
    local x, y = (high_x - 2) * 256 + low_x, (high_y - 2) * 256 + low_y
    if high_x < 2 or high_y < 2 or x >= constants.screen.width or y >= constants.screen.height then return false end
    return {x, y}
end
-- Packet offsets 10 and 12, unlike recording flags. Bit zero starts set in the original.
local function_bits = {{10, 2}, {10, 64}, {12, 2}, {10, 4}, {10, 8}, {10, 16}, {10, 32}, {12, 4}, {10, 128}}
function network.packet(state, input, hp)
    local bytes = {}
    for index = 1, 20 do bytes[index] = 1 end
    bytes[21], bytes[22] = 0, 0
    for index = 0, 3 do
        bytes[(state.host and 0 or 4) + index + 1] = recording.pack_keys(input[index] or "") + 1
    end
    -- Byte 9 (OpenLF2 speed menu, base/ui/speed_menu): the host's fight speed in tenths plus one, 1 from the joining
    -- peer. Both peers run the host's speed, so they skip the same frames.
    bytes[9] = state.host and speed.tenths + 1 or 1
    bytes[10], bytes[12], bytes[14] = state.sequence, state.version, hp % 100 + 1
    bytes[15], bytes[16] = state.checksum % 256, math.floor(state.checksum / 256)
    for key, field in ipairs(function_bits) do
        if input.functions:find(tostring(key), 1, true) then bytes[field[1] + 1] = bytes[field[1] + 1] + field[2] end
    end
    local click = input.click_at
    if click then
        bytes[17], bytes[18] = math.floor(click[1] / 256) + 2, click[1] % 256
        bytes[19], bytes[20] = math.floor(click[2] / 256) + 2, click[2] % 256
    end
    local marks = input.unlock_bits or 0
    if marks % 2 == 1 then bytes[13] = bytes[13] + 8 end
    if math.floor(marks / 2) % 2 == 1 then bytes[13] = bytes[13] + 16 end
    return string.char(unpack(bytes))
end
function network.exchange(state, input, hp)
    if not state.pending then
        state.sequence = (state.sequence + 1) % 50
        state.pending = network.packet(state, input, hp)
        state.sent_click = input.click_at
        state.deadline = engine.network_time() + timeout
        if not send(state, state.pending) then return nil, state.error end
    end
    local ok, problem = network.poll(state)
    if not ok then return nil, problem end
    local remote = take(state, 22)
    if not remote then
        if engine.network_time() > state.deadline then return failed(state, "Network input timed out") end
        return nil
    end
    local own = state.pending
    for _, check in ipairs({{10, "sequence"}, {12, "version"}, {14, "HP synchronization"}, {15, "data"}, {16, "data"}}) do
        if remote:byte(check[1]) ~= own:byte(check[1]) then return failed(state, "Network " .. check[2] .. " mismatch") end
    end
    -- Reject a peer trying to write the other machine's controls or malformed reserved bytes.
    for index = 1, 8 do
        local peer_slot = state.host and index > 4 or not state.host and index <= 4
        if remote:byte(index) % 2 ~= 1 or (not peer_slot and remote:byte(index) ~= 1) then
            return failed(state, "Invalid network input slot")
        end
    end
    if remote:byte(11) % 2 ~= 1 or remote:byte(13) % 2 ~= 1 or remote:byte(13) > 31
       or remote:byte(9) < 1 or remote:byte(9) > (state.host and 1 or 11) or remote:sub(21) ~= "\0\0" or packet_click(remote) == false then
        return failed(state, "Invalid network packet padding")
    end
    local combined = {functions = "", keys = {}, pointer_x = -1, pointer_y = -1, button = false, network = true}
    -- One click a frame, the host's first: a click of the joining computer on the same frame waits for the next
    -- packet (`applied_click` tells the computer whose click ran).
    local host_click, join_click = packet_click(state.host and own or remote), packet_click(state.host and remote or own)
    local click = host_click or join_click
    if click then
        combined.pointer_x, combined.pointer_y, combined.button = click[1], click[2], true
        combined.click_host = host_click ~= nil
        if (host_click and state.host) or (not host_click and not state.host) then combined.applied_click = state.sent_click end
    end
    for slot = 0, 7 do
        local local_slot = state.host and slot < 4 or not state.host and slot >= 4
        combined[slot] = recording.unpack_keys((local_slot and own or remote):byte(slot + 1))
    end
    combined.function_sources = {"", ""}
    for key, field in ipairs(function_bits) do
        if has(own:byte(field[1] + 1), field[2]) or has(remote:byte(field[1] + 1), field[2]) then
            combined.functions = combined.functions .. tostring(key)
        end
        if has(own:byte(field[1] + 1), field[2]) then combined.function_sources[1] = combined.function_sources[1] .. key end
        if has(remote:byte(field[1] + 1), field[2]) then combined.function_sources[2] = combined.function_sources[2] .. key end
    end
    combined.speed_tenths = (state.host and own or remote):byte(9) - 1
    combined.unlock_bits = 0
    for _, mark in ipairs({{8, 1}, {16, 2}}) do
        if has(own:byte(13), mark[1]) or has(remote:byte(13), mark[1]) then
            combined.unlock_bits = combined.unlock_bits + mark[2]
        end
    end
    state.pending, state.frames = nil, state.frames + 1
    return combined
end
return network
