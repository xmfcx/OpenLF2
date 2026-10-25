-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The server program (OpenLF2 extension, docs/netcode.md and docs/ui-network-architecture.md; `openlf2 --server`).
-- It keeps a lobby of the connected players. When the player with the room role starts and everybody is ready, a
-- session begins: the whole game (title menu, character selection, fights, results) runs on every client from the
-- same ticks. The server is the authority of these ticks (base/game/authority): the clients send their keys, the
-- server makes each tick final at its deadline, never waiting for a client, and sends the final ticks to everybody.
-- The clients run the menus on final ticks and the fights with rollback. It runs without a window, a frame on each
-- message and at least every 4 ms.
local constants = require("base/game/constants")
local authority = require("base/game/authority")
local wire = require("base/game/wire")
local network = require("base/game/network")
local server = {}

-- The version of these messages; a client with another one cannot join.
server.protocol = 2
local reliable, unreliable = 0, 1
local max_players = 8
-- A session starts this long after the start command, so that every client has the session message first.
local start_delay_ms = 1000
-- Chat: printable text up to 120 characters, at most 5 messages in 5 seconds for each player.
local chat_length, chat_burst, chat_window_ms = 120, 5, 5000

-- options: the runtime settings (server_port, network_profile).
function server.create(options)
    local listening, problem = engine.messages("listen", "0.0.0.0", options.server_port, 64)
    assert(listening, problem)
    return {profile = options.network_profile, version = network.own_version() or "", players = {}, order = {},
        phase = "lobby", log = {}, hashes = {}}
end

local function log(state, text) state.log[#state.log + 1] = text end
local function send(peer, message, channel)
    engine.messages("send", peer, channel or reliable, wire.encode(message))
end
local function broadcast(state, message, channel)
    for _, peer in ipairs(state.order) do send(peer, message, channel) end
end

-- The lobby as every client sees it.
local function lobby_message(state)
    local players = {}
    for position, peer in ipairs(state.order) do
        local player = state.players[peer]
        players[position] = {id = peer, name = player.name, slot = player.slot, ready = player.ready, role = position == 1}
    end
    return {type = "lobby", players = players, phase = state.phase}
end
local function broadcast_lobby(state) broadcast(state, lobby_message(state)) end

local function free_slot(state)
    for slot = 0, max_players - 1 do
        local taken = false
        for _, player in pairs(state.players) do
            if player.slot == slot then taken = true end
        end
        if not taken then return slot end
    end
    return nil
end

local function back_to_lobby(state, reason)
    state.phase, state.authority, state.hashes = "lobby", nil, {}
    for _, player in pairs(state.players) do player.ready = false end
    broadcast(state, {type = "end"})
    broadcast_lobby(state)
    log(state, "session over: " .. reason)
end

local function remove(state, peer)
    if not state.players[peer] then return end
    log(state, "left: " .. state.players[peer].name)
    state.players[peer] = nil
    for position, other in ipairs(state.order) do
        if other == peer then table.remove(state.order, position) break end
    end
    if state.phase == "session" and #state.order == 0 then back_to_lobby(state, "everybody left") end
    broadcast_lobby(state)
end

-- Starts a session: every client gets the player names and slots and the server's random state, so that all of
-- them start the same game. The keys of a player who leaves are predicted as none (authority).
local function start_session(state, now)
    local owners, names, clients = {}, {}, {}
    for position, peer in ipairs(state.order) do
        local player = state.players[peer]
        owners[player.slot] = peer
        names[player.slot + 1] = player.name
        clients[position] = peer
    end
    engine.reset_random_sequence()
    local table_string = engine.random_state()
    local index, sequence, crt = engine.random_position()
    state.authority = authority.create({owners = owners, clients = clients, all_functions = true})
    state.phase, state.start_at, state.hashes = "session", now + start_delay_ms, {}
    broadcast(state, {type = "session", owners = owners, names = names, role = state.order[1],
        random = {table = table_string, index = index, sequence = sequence, crt = crt}})
    log(state, "session started with " .. #state.order .. " players")
end

local handlers = {}
function handlers.hello(state, peer, message)
    if state.players[peer] then return end
    if message.protocol ~= server.protocol or message.profile ~= state.profile then
        send(peer, {type = "refused", reason = "version", version = state.version})
        engine.messages("disconnect", peer)
        return
    end
    local slot = free_slot(state)
    if not slot or state.phase ~= "lobby" then
        send(peer, {type = "refused", reason = slot and "playing" or "full"})
        engine.messages("disconnect", peer)
        return
    end
    local name = type(message.name) == "string" and message.name:gsub("[^\32-\126]", "")
        :sub(1, constants.text_limits.player_name_bytes) or ""
    if name == "" then name = tostring(slot + 1) end
    state.players[peer] = {name = name, slot = slot, ready = false}
    state.order[#state.order + 1] = peer
    send(peer, {type = "welcome", id = peer, slot = slot})
    log(state, "joined: " .. name .. " (slot " .. (slot + 1) .. ")")
    broadcast_lobby(state)
end
function handlers.ready(state, peer, message)
    local player = state.players[peer]
    if not player or state.phase ~= "lobby" then return end
    player.ready = message.value == true
    broadcast_lobby(state)
end
function handlers.start(state, peer, message, now)
    if state.order[1] ~= peer or state.phase ~= "lobby" then return end
    for _, other in ipairs(state.order) do
        if not state.players[other].ready then return end
    end
    start_session(state, now)
end
-- The title's Quit runs on every client on the same tick; the first client that reports it ends the session.
function handlers.lobby_return(state, peer)
    if state.phase == "session" and state.players[peer] then back_to_lobby(state, "quit") end
end
function handlers.chat(state, peer, message, now)
    local player = state.players[peer]
    if not player or type(message.text) ~= "string" then return end
    local text = message.text:gsub("[^\32-\126]", ""):sub(1, chat_length)
    if text:match("^%s*$") then return end
    local recent = {}
    for _, time in ipairs(player.chat_times or {}) do
        if now - time < chat_window_ms then recent[#recent + 1] = time end
    end
    if #recent >= chat_burst then return end
    recent[#recent + 1] = now
    player.chat_times = recent
    broadcast(state, {type = "chat", name = player.name, text = text})
    log(state, player.name .. ": " .. text)
end
function handlers.input(state, peer, message, now)
    if state.phase ~= "session" or not state.players[peer] then return end
    message.from = peer
    authority.receive(state.authority, message, now - state.start_at)
end
-- A client's hash of its game state after a final tick (base/game/online): two different hashes for one tick mean
-- that the clients run different games. The server keeps the first report of each tick and compares the others.
function handlers.hash(state, peer, message)
    if state.phase ~= "session" or not state.players[peer] then return end
    local tick, hash = tonumber(message.tick), message.hash
    if not tick or type(hash) ~= "string" then return end
    local first = state.hashes[tick]
    if not first then
        state.hashes[tick] = {hash = hash, peer = peer}
    elseif first.hash == hash and first.peer ~= peer and not first.agreed then
        first.agreed = true
        state.agreed = (state.agreed or 0) + 1
        if state.agreed == 1 or state.agreed == 10 or state.agreed == 100 then
            log(state, string.format("hashes agree (%d checks, tick %d)", state.agreed, tick))
        end
    elseif first.hash ~= hash and not first.reported then
        first.reported = true
        log(state, string.format("difference at tick %d: %s and %s", tick, state.players[first.peer]
            and state.players[first.peer].name or "?", state.players[peer].name))
        broadcast(state, {type = "difference", tick = tick})
    end
end

-- One frame: the messages of the clients, then the due ticks of a session. Returns the lines to log.
function server.update(state)
    local now = engine.network_time()
    local events = engine.messages("service") or {}
    for _, event in ipairs(events) do
        if event.kind == "disconnected" then
            remove(state, event.peer)
        elseif event.kind == "message" then
            local message = wire.decode(event.data)
            local handler = type(message) == "table" and handlers[message.type]
            if handler then handler(state, event.peer, message, now) end
        end
    end
    if state.phase == "session" then
        -- The program runs a frame on each message and every few milliseconds; the clients hear from the server
        -- when a tick became final (and its message repeats the ticks they did not acknowledge yet).
        local messages = authority.update(state.authority, now - state.start_at)
        if state.authority.tick ~= state.sent_tick then
            state.sent_tick = state.authority.tick
            for peer, message in pairs(messages) do
                message.type = "ticks"
                send(peer, message, unreliable)
            end
        end
        for tick in pairs(state.hashes) do
            if tick < state.authority.tick - 600 then state.hashes[tick] = nil end
        end
    end
    local lines = state.log
    state.log = {}
    return lines
end

function server.describe(state)
    return string.format("server phase=%s players=%d tick=%d", state.phase, #state.order,
        state.authority and state.authority.tick or -1)
end

return server
