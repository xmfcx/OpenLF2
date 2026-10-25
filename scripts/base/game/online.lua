-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A client of the server program (OpenLF2 extension, docs/netcode.md): the connection, the lobby, the chat, and a
-- session, in which the whole game runs on the server's final ticks. The menus run in lockstep on them: each frame
-- takes the next final tick (online.exchange, like the original's exchange of packets). A fight runs with prediction
-- and rollback (base/game/rollback_client) on the same ticks, counted from the fight's start (online.begin_match and
-- online.frame); once its last tick is final, the menus go on from the next tick.
local controls = require("base/ui/controls")
local wire = require("base/game/wire")
local ticks = require("base/game/ticks")
local rollback = require("base/game/rollback")
local rollback_client = require("base/game/rollback_client")
local server = require("base/game/server")
local online = {}

local reliable, unreliable = 0, 1
local tick_ms = ticks.tick_ms
-- Without the server's welcome after this long, the connection failed.
local connect_ms = 10000
-- The most ticks one input message repeats, and the most new ticks one frame gives keys to.
local resend_limit, sample_limit = 32, 8
-- A fight's state hash goes to the server every this many ticks (server.lua compares the clients).
local hash_interval = 30
local chat_kept = 20

-- options: the runtime settings (network_profile). retry_ms: how long to connect again after a failed attempt.
function online.create(options, address, port, retry_ms)
    local state = {phase = "connecting", address = address, port = port, profile = options.network_profile,
        started = engine.network_time(), lobby = nil, events = {}, chat = {}, taunts = {},
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
    if state.peer and state.phase ~= "failed" and state.phase ~= "closed" then
        engine.messages("send", state.peer, channel or reliable, wire.encode(message))
    end
end

function online.close(state)
    if engine.messages then engine.messages("close") end
    state.phase, state.client = "closed", nil
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

-- The round trip, its jitter and the server's clock, from the times in the server's messages.
local function measure(state, message, now)
    if message.echo then
        -- `held`: the time the server kept the echo before its message (newer servers).
        local sample = math.max(0, now - message.echo - (message.held or 0))
        if not state.rtt then
            state.rtt, state.jitter = sample, sample / 4
        else
            state.jitter = state.jitter * 0.875 + math.abs(sample - state.rtt) * 0.125
            state.rtt = state.rtt * 0.875 + sample * 0.125
        end
    end
    local offset = message.server_time + (state.rtt or 0) / 2 - now
    state.offset = state.offset and state.offset * 0.9 + offset * 0.1 or offset
end

-- A message of session ticks as the rollback client sees it: ticks counted from the fight's first tick.
local function fight_message(state, message)
    local first = state.base + 1
    local converted = {server_time = message.server_time - first * tick_ms, echo = message.echo, held = message.held, ticks = {},
        newest_input = message.newest_input and message.newest_input - first}
    for tick, input in pairs(message.ticks or {}) do
        if tick >= first then converted.ticks[tick - first] = input end
    end
    return converted
end

local handlers = {}
function handlers.welcome(state, message)
    state.phase, state.id, state.slot = "lobby", message.id, message.slot
end
function handlers.refused(state, message)
    local reasons = {version = "The server runs another game version (" .. tostring(message.version) .. ")",
        full = "The server is full", playing = "The server is in a game; try again after it"}
    fail(state, reasons[message.reason] or "The server refused the connection")
end
function handlers.lobby(state, message)
    state.lobby = message
end
-- A session starts: the server's random state, the players' names and slots. The flow starts the game.
function handlers.session(state, message)
    local random = message.random
    engine.set_random_state(random.table, random.index)
    engine.set_random_position(random.index, random.sequence, random.crt)
    state.phase, state.session_start = "session", message
    state.names, state.host = message.names, message.role == state.id
    state.finals, state.next_tick, state.local_inputs, state.sent_tick = {}, 0, {}, -1
    state.input_acknowledged, state.frames, state.client, state.base = -1, 0, nil, nil
    state.events[#state.events + 1] = message
end
handlers["end"] = function(state, message)
    state.phase, state.client, state.finals = "lobby", nil, nil
    state.events[#state.events + 1] = message
end
function handlers.difference(state, message)
    state.difference = tonumber(message.tick)
end
-- A chat line; a number from 1 to 42 alone is a taunt, which plays its sound (base/ui/chat).
function handlers.chat(state, message)
    local log = state.chat
    log[#log + 1] = {name = tostring(message.name), text = tostring(message.text), at = engine.network_time()}
    if #log > chat_kept then table.remove(log, 1) end
    local number = tonumber(tostring(message.text):match("^%s*(%d+)%s*$"))
    if number and number >= 1 and number <= 42 then state.taunts[#state.taunts + 1] = number end
end
function handlers.ticks(state, message)
    if state.phase ~= "session" then return end
    local now = engine.network_time()
    measure(state, message, now)
    if message.newest_input and message.newest_input > state.input_acknowledged then
        state.input_acknowledged = message.newest_input
    end
    for tick, input in pairs(message.ticks or {}) do
        if tick >= state.next_tick and not state.finals[tick] then state.finals[tick] = input end
    end
    if state.client then rollback_client.receive(state.client, fight_message(state, message), now) end
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

-- This computer's keys for the session: player 1's keys drive its slot; the function keys go with them.
local function own_input(state, held)
    local input = ticks.empty()
    input.slots[state.slot] = held[0] or ""
    input.functions, input.function_presses = held.functions or "", held.function_presses or ""
    return input
end

-- The combined input of a final tick, as the original's network exchange gives it (base/game/network): every
-- slot's keys, the function keys, no pointer, no unlock words.
local function combined_input(final)
    local combined = ticks.held(final)
    combined.pointer_x, combined.pointer_y, combined.button, combined.network, combined.unlock_bits = 0, 0, false, true, 0
    return combined
end

-- One frame of the menus: sends this computer's keys for the ticks ahead (they reach the server before it makes
-- them final), and returns the next final tick's combined input, or nil while it has not arrived (the frame waits),
-- or nil and a problem when the connection failed.
function online.exchange(state, held)
    online.poll(state)
    if state.phase == "failed" then return nil, state.problem end
    if state.phase ~= "session" then return nil end
    local now = engine.network_time()
    if state.rtt then
        -- Keys sampled now go to the tick that the server makes final after they arrive.
        local lead = state.rtt / 2 + 2 * state.jitter + 10
        local target = math.floor((now + state.offset + lead) / tick_ms)
        -- A frame that waits for the server runs these scripts again with the same keys; merging them changes nothing.
        local sample, given = ticks.sample(state.pending_sample, own_input(state, held)), 0
        state.pending_sample = sample
        while state.sent_tick < target and given < sample_limit do
            state.sent_tick = state.sent_tick + 1
            state.local_inputs[state.sent_tick] = ticks.take(sample, given == 0)
            state.pending_sample = nil
            given = given + 1
        end
    end
    local inputs = {}
    for tick = math.max(state.input_acknowledged + 1, state.next_tick, state.sent_tick - resend_limit), state.sent_tick do
        inputs[tick] = state.local_inputs[tick]
    end
    online.send(state, {type = "input", sent_at = now, acknowledged = state.next_tick - 1, inputs = inputs}, unreliable)
    local final = state.finals[state.next_tick]
    if not final then return nil end
    state.finals[state.next_tick], state.local_inputs[state.next_tick] = nil, nil
    state.next_tick, state.frames = state.next_tick + 1, state.frames + 1
    return combined_input(final)
end

-- A fight starts in the menus' tick that was just taken; its tick 0 is the next session tick. The rollback client
-- starts with the keys this computer already sent for the fight's ticks and the final ticks already here.
function online.begin_match(state, fight)
    state.base = state.next_tick - 1
    local first = state.base + 1
    local client = rollback_client.create({id = state.id, match = fight, random = {engine.random_position()},
        owned = {[state.slot] = true}, owns_functions = true})
    for tick = first, state.sent_tick do
        if state.local_inputs[tick] then client.local_inputs[tick - first] = state.local_inputs[tick] end
    end
    for tick, input in pairs(state.finals) do
        if tick >= first then client.final[tick - first] = input end
    end
    client.rtt, client.jitter = state.rtt, state.jitter
    client.offset = state.offset and state.offset - first * tick_ms
    client.input_acknowledged = state.input_acknowledged - first
    state.client, state.hash_sent = client, -1
    state.fights = (state.fights or 0) + 1
end

-- The end of a fight at its final tick `last`: the fight goes back to its state after that tick (the client may have
-- run further), and the menus go on from the next session tick.
local function end_match(state, last)
    local client = state.client
    local saved = client.saved[last + 1]
    if saved then rollback.restore(client.match, saved) end
    local first = state.base + 1
    state.next_tick = first + last + 1
    state.sent_tick = math.max(state.sent_tick, first + client.tick + client.delay)
    for tick in pairs(state.finals) do
        if tick < state.next_tick then state.finals[tick] = nil end
    end
    state.client = nil
end

-- One frame of a fight: the server's ticks, this computer's keys, the client's ticks and the message to the server.
-- Returns the sounds, the results of final ticks and the number of new ticks.
function online.frame(state, held)
    online.poll(state)
    local client = state.client
    -- The session ended (the flow goes back to the lobby).
    if not client then return {}, {}, 0 end
    rollback_client.sample(client, own_input(state, held))
    local now = engine.network_time()
    rollback_client.update(client, now)
    local first = state.base + 1
    local message = rollback_client.message(client, now)
    local inputs = {}
    for tick, input in pairs(message.inputs) do inputs[tick + first] = input end
    online.send(state, {type = "input", sent_at = now, acknowledged = message.acknowledged + first, inputs = inputs},
        unreliable)
    -- The state after every 30th final tick goes to the server, which compares the clients.
    for tick = state.hash_sent + 1, client.confirmed do
        local saved = client.saved[tick + 1]
        if tick % hash_interval == 0 and saved then
            online.send(state, {type = "hash", tick = tick + first, hash = rollback.hash_saved(saved)})
            state.hashes_sent = (state.hashes_sent or 0) + 1
        end
    end
    state.hash_sent = math.max(state.hash_sent, client.confirmed)
    local played, results = rollback_client.take(client)
    local new_ticks = client.new_ticks
    for _, entry in ipairs(results) do
        if entry.result == "finished" or entry.result == "leave" or entry.result == "replay_error" then
            end_match(state, entry.tick)
            return played, {entry.result}, new_ticks
        end
    end
    return played, {}, new_ticks
end

return online
