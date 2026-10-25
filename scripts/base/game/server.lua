-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The server program (OpenLF2 extension, docs/netcode.md and docs/ui-network-architecture.md; `openlf2 --server`).
-- It keeps a lobby of the connected players, starts a fight when the player with the room role asks and everybody is
-- ready, and runs the fight as its authority (base/game/authority): the clients send their keys, the server makes
-- each tick final and sends the final ticks back. It runs without a window, one frame on each 33 ms tick.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local authority = require("base/game/authority")
local wire = require("base/game/wire")
local network = require("base/game/network")
local server = {}

-- The version of these messages; a client with another one cannot join.
server.protocol = 1
local reliable, unreliable = 0, 1
local max_players = 8
-- A fight starts this long after the start command, so that every client has the start message first.
local start_delay_ms = 1000
-- After the last tick of a fight, the server waits this long before it opens the lobby again.
local results_ms = 3000

-- options: the runtime settings (server_port, network_profile).
function server.create(options)
    local listening, problem = engine.messages("listen", "0.0.0.0", options.server_port, 64)
    assert(listening, problem)
    return {profile = options.network_profile, version = network.own_version() or "", players = {}, order = {},
        settings = {background = constants.background_rows.random, difficulty = constants.difficulties.difficult,
            computers = 0},
        phase = "lobby", log = {}}
end

local function log(state, text) state.log[#state.log + 1] = text end
local function send(peer, message, channel)
    engine.messages("send", peer, channel or reliable, wire.encode(message))
end

-- The lobby as every client sees it.
local function lobby_message(state)
    local players = {}
    for position, peer in ipairs(state.order) do
        local player = state.players[peer]
        players[position] = {id = peer, name = player.name, slot = player.slot, fighter = player.fighter,
            team = player.team, ready = player.ready, role = position == 1}
    end
    return {type = "lobby", players = players, settings = state.settings, phase = state.phase}
end
local function broadcast(state, message, channel)
    for _, peer in ipairs(state.order) do send(peer, message, channel) end
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

local function remove(state, peer)
    if not state.players[peer] then return end
    log(state, "left: " .. state.players[peer].name)
    state.players[peer] = nil
    for position, other in ipairs(state.order) do
        if other == peer then table.remove(state.order, position) break end
    end
    if state.phase == "lobby" then broadcast_lobby(state) end
end

-- A fighter for a random pick: one that no other slot has, below the random range end (character_select).
local function pick_fighter(fighters, taken)
    local candidates = {}
    for index, fighter in ipairs(fighters) do
        if fighter.record >= 1 and fighter.id < constants.record_id_ranges.random_fighter_end_exclusive
           and not taken[index] then
            candidates[#candidates + 1] = index
        end
    end
    return candidates[engine.random(#candidates) + 1]
end

-- Starts a fight: resolves the random fighters, fills the computer slots, and sends every client the setup and the
-- random state, so that all of them create the same fight.
local function start_fight(state, now)
    local fighters, taken, slots, owners = catalog.load(), {}, {}, {}
    for _, peer in ipairs(state.order) do
        local player = state.players[peer]
        if player.fighter > 0 then taken[player.fighter] = true end
    end
    for _, peer in ipairs(state.order) do
        local player = state.players[peer]
        local fighter = player.fighter > 0 and player.fighter or pick_fighter(fighters, taken)
        taken[fighter] = true
        slots[player.slot] = {kind = "human", fighter = fighter, team = player.team}
        owners[player.slot] = peer
    end
    local computers = state.settings.computers
    for slot = 0, max_players - 1 do
        if computers > 0 and not slots[slot] then
            local fighter = pick_fighter(fighters, taken)
            taken[fighter] = true
            slots[slot] = {kind = "computer", fighter = fighter, team = constants.teams.independent}
            computers = computers - 1
        end
    end
    local setup = {mode = constants.modes.versus, difficulty = state.settings.difficulty,
        background = state.settings.background, stage_level = 0, slots = slots}
    local table_string = engine.random_state()
    local index, sequence, crt = engine.random_position()
    local options = {mode = setup.mode, difficulty = setup.difficulty, background = setup.background, stage_level = 0,
        fighters = fighters, backgrounds = catalog.backgrounds(), slots = slots}
    local fight = match.create(options)
    fight.capture = require("base/ui/match_screen").make_capture()
    local clients = {}
    for position, peer in ipairs(state.order) do clients[position] = peer end
    state.authority = authority.create({match = fight, random = {engine.random_position()}, owners = owners,
        function_owner = state.order[1], clients = clients})
    state.phase, state.start_at, state.finished_at = "fight", now + start_delay_ms, nil
    broadcast(state, {type = "start", setup = setup, owners = owners, function_owner = state.order[1],
        random = {table = table_string, index = index, sequence = sequence, crt = crt}})
    log(state, "fight started with " .. #state.order .. " players")
end

local handlers = {}
function handlers.hello(state, peer, message, now)
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
    local name = type(message.name) == "string" and message.name:sub(1, constants.text_limits.player_name_bytes) or "?"
    state.players[peer] = {name = name, slot = slot, fighter = 0, team = constants.teams.independent, ready = false}
    state.order[#state.order + 1] = peer
    send(peer, {type = "welcome", id = peer, slot = slot})
    log(state, "joined: " .. name .. " (slot " .. (slot + 1) .. ")")
    broadcast_lobby(state)
end
function handlers.choose(state, peer, message)
    local player = state.players[peer]
    if not player or state.phase ~= "lobby" then return end
    local fighter, team = tonumber(message.fighter), tonumber(message.team)
    if fighter and fighter >= 0 and fighter <= #catalog.load() and fighter == math.floor(fighter) then player.fighter = fighter end
    if team and team >= 0 and team <= constants.teams.player_four and team == math.floor(team) then player.team = team end
    broadcast_lobby(state)
end
function handlers.ready(state, peer, message)
    local player = state.players[peer]
    if not player or state.phase ~= "lobby" then return end
    player.ready = message.value == true
    broadcast_lobby(state)
end
function handlers.settings(state, peer, message)
    if state.order[1] ~= peer or state.phase ~= "lobby" then return end
    local computers = tonumber(message.computers)
    if computers and computers >= 0 and computers <= max_players - #state.order and computers == math.floor(computers) then
        state.settings.computers = computers
    end
    broadcast_lobby(state)
end
function handlers.start(state, peer, message, now)
    if state.order[1] ~= peer or state.phase ~= "lobby" then return end
    for _, other in ipairs(state.order) do
        if not state.players[other].ready then return end
    end
    -- A fight needs two sides: two players, or players and computers.
    if #state.order + state.settings.computers < 2 then return end
    start_fight(state, now)
end
function handlers.input(state, peer, message, now)
    if state.phase ~= "fight" or not state.players[peer] then return end
    message.from = peer
    authority.receive(state.authority, message, now - state.start_at)
end

-- One frame: the messages of the clients, then the fight's due ticks. Returns the lines to log.
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
    if state.phase == "fight" then
        local fight_time = now - state.start_at
        for peer, message in pairs(authority.update(state.authority, fight_time)) do
            message.type = "ticks"
            send(peer, message, unreliable)
        end
        if not state.finished_at then
            for _, result in pairs(state.authority.results) do
                if result == "finished" or result == "leave" then state.finished_at = now end
            end
        end
        -- Everybody left, or the results were shown: back to the lobby.
        if #state.order == 0 or (state.finished_at and now - state.finished_at > results_ms) then
            state.phase, state.authority = "lobby", nil
            for _, player in pairs(state.players) do player.ready = false end
            broadcast(state, {type = "end"})
            broadcast_lobby(state)
            log(state, "fight over")
        end
    end
    local lines = state.log
    state.log = {}
    return lines
end

function server.describe(state)
    return string.format("server phase=%s players=%d", state.phase, #state.order)
end

return server
