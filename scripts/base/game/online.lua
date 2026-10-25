-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A client of the server program (OpenLF2 extension, docs/netcode.md): the connection, the lobby the server sends,
-- and during a fight the rollback client (base/game/rollback_client) that the final ticks go to.
local constants = require("base/game/constants")
local controls = require("base/ui/controls")
local wire = require("base/game/wire")
local ticks = require("base/game/ticks")
local rollback_client = require("base/game/rollback_client")
local server = require("base/game/server")
local online = {}

local reliable, unreliable = 0, 1
-- Without the server's welcome after this long, the connection failed.
local connect_ms = 10000

-- options: the runtime settings (network_profile). retry_ms: how long to connect again after a failed attempt.
function online.create(options, address, port, retry_ms)
    local state = {phase = "connecting", address = address, port = port, profile = options.network_profile,
        started = engine.network_time(), lobby = nil, events = {},
        retry_until = retry_ms and engine.network_time() + retry_ms or nil}
    if not engine.messages then
        state.phase, state.problem = "failed", "This game version cannot connect to a server"
        return state
    end
    local peer, problem = engine.messages("connect", address, port)
    if not peer then
        state.phase, state.problem = "failed", problem
        return state
    end
    state.peer = peer
    return state
end

function online.send(state, message, channel)
    if state.peer and state.phase ~= "failed" then engine.messages("send", state.peer, channel or reliable, wire.encode(message)) end
end

function online.close(state)
    if engine.messages then engine.messages("close") end
    state.phase = "closed"
end

local function fail(state, problem)
    local connecting = state.phase == "connecting"
    online.close(state)
    -- Not connected yet, and still in the time to try again: a new attempt.
    if connecting and state.retry_until and engine.network_time() < state.retry_until then
        state.phase = "connecting"
        state.peer = engine.messages("connect", state.address, state.port)
        if state.peer then return end
    end
    state.phase, state.problem = "failed", problem
end

-- Messages from the server. "start" and "end" are kept in `events` for the screens.
local handlers = {}
function handlers.welcome(state, message)
    state.phase, state.id, state.slot = "lobby", message.id, message.slot
end
function handlers.refused(state, message)
    local reasons = {version = "The server runs another game version (" .. tostring(message.version) .. ")",
        full = "The server is full", playing = "The server is in a fight; try again after it"}
    fail(state, reasons[message.reason] or "The server refused the connection")
end
function handlers.lobby(state, message)
    state.lobby = message
end
function handlers.start(state, message)
    state.events[#state.events + 1] = message
end
handlers["end"] = function(state, message)
    state.client = nil
    state.events[#state.events + 1] = message
end
function handlers.ticks(state, message)
    if state.client then rollback_client.receive(state.client, message, engine.network_time()) end
end

-- Takes the messages of this frame. Call once per frame, also in the lobby.
function online.poll(state)
    if state.phase == "failed" or state.phase == "closed" then return end
    local events, problem = engine.messages("service")
    if not events then return fail(state, problem) end
    for _, event in ipairs(events) do
        if event.kind == "connected" then
            online.send(state, {type = "hello", protocol = server.protocol, profile = state.profile,
                name = controls.name(0)})
        elseif event.kind == "disconnected" then
            return fail(state, "The server closed the connection")
        elseif event.kind == "message" then
            local message = wire.decode(event.data)
            local handler = type(message) == "table" and handlers[message.type]
            if handler then handler(state, message) end
        end
    end
    if state.phase == "connecting" and engine.network_time() - state.started > connect_ms then
        fail(state, "No answer from the server")
    end
end

function online.take_events(state)
    local events = state.events
    state.events = {}
    return events
end

-- The fight of a start message: sets the server's random state and returns the options for match.create.
function online.fight_options(state, start)
    local random = start.random
    engine.set_random_state(random.table, random.index)
    engine.set_random_position(random.index, random.sequence, random.crt)
    local catalog = require("base/game/catalog")
    local setup = start.setup
    local slots = {}
    for slot = 0, 7 do slots[slot] = setup.slots[slot] end
    return {mode = setup.mode, difficulty = setup.difficulty, background = setup.background,
        stage_level = setup.stage_level, fighters = catalog.load(), backgrounds = catalog.backgrounds(), slots = slots,
        online = true}
end

-- Joins the fight that the match screen just created from fight_options.
function online.begin_fight(state, start, fight)
    local owned = {}
    for slot, owner in pairs(start.owners) do
        if owner == state.id then owned[slot] = true end
    end
    state.client = rollback_client.create({id = state.id, match = fight, random = {engine.random_position()},
        owned = owned, owns_functions = start.function_owner == state.id})
    state.own_slot = state.slot
end

-- One frame of a fight: the server's ticks, this computer's keys (player 1's keys drive this client's slot), the
-- client's ticks and the message to the server. Returns the sounds, the results of final ticks and the new ticks.
function online.frame(state, held)
    online.poll(state)
    local client = state.client
    -- The server ended the fight (everybody else left): the round is over for this computer too.
    if not client then return {}, {"finished"}, 0 end
    local input = ticks.empty()
    for slot in pairs(client.owned) do input.slots[slot] = held[0] or "" end
    if client.owns_functions then input.functions, input.function_presses = held.functions or "", held.function_presses or "" end
    rollback_client.sample(client, input)
    local now = engine.network_time()
    rollback_client.update(client, now)
    local message = rollback_client.message(client, now)
    message.type = "input"
    online.send(state, message, unreliable)
    local played, results = rollback_client.take(client)
    return played, results, client.new_ticks
end

return online
