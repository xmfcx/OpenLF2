-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A client of a networked fight with prediction and rollback (OpenLF2 extension, docs/netcode.md "The rollback engine
-- on the client"). The client runs its fight ahead of the server: its own slots use its own keys, the other slots
-- the newest final keys from the server (the prediction). When a final tick differs from what the client ran, it goes
-- back to its saved state of that tick and runs the ticks again. This module knows no transport; the caller passes
-- the messages in and out.
local match = require("base/game/match")
local sounds = require("base/game/sounds")
local rumble = require("base/game/rumble")
local rollback = require("base/game/rollback")
local ticks = require("base/game/ticks")
local speed_gate = require("base/game/speed_gate")
local client = {}

local tick_ms = ticks.tick_ms
-- The most ticks the client runs ahead of its newest final tick; past it, the client waits. The window covers the
-- round trip and a few ticks more, from 12 to 20 ticks (a rollback of 20 ticks costs about 12 ms in battle mode).
local window_least, window_most = 12, 20
-- Saved states and inputs are kept this many ticks behind the newest final tick (the hash checks need them).
local keep = 40
-- The most ticks a message repeats, and the most new ticks a frame runs (more when the client catches up on final
-- ticks).
local resend_limit, run_limit, catch_up_limit = 32, 2, 8

-- options: id, match, random (its position), owned[slot] = true, owns_functions.
function client.create(options)
    -- delay_behind: a spectator runs only final ticks, this many behind the newest one.
    return {id = options.id, match = options.match, random = options.random, owned = options.owned,
        delay_behind = options.delay_behind,
        owns_functions = options.owns_functions, tick = 0, confirmed = -1, reported = -1, final = {},
        local_inputs = {}, used = {}, saved = {}, results = {}, played = {}, last_known = ticks.empty().slots,
        sample = ticks.empty(), delay = 0, input_acknowledged = -1, server_hashes = {}, hashes_checked = -1, sounds_out = {},
        results_out = {}, new_ticks = 0,
        stats = {rollbacks = 0, rolled_ticks = 0, longest = 0, stalls = 0, hash_checks = 0, hash_failures = 0}}
end

-- This frame's keys of the client's own slots (an input as in base/game/ticks).
function client.sample(state, input)
    state.sample = ticks.sample(state.sample_pending and state.sample, input)
    state.sample_pending = true
end

-- The keys of the client's own slots for `tick`: the newest sample at or before it.
local function local_input(state, tick)
    for earlier = tick, tick - window_most, -1 do
        local input = state.local_inputs[earlier]
        if input then return input end
    end
    return ticks.empty()
end

local function input_for(state, tick)
    local final = state.final[tick]
    if final then return final end
    local own, input = local_input(state, tick), ticks.empty()
    for slot = 0, 7 do
        if state.owned[slot] then input.slots[slot] = own.slots[slot] or ""
        else input.slots[slot] = state.last_known[slot] or "" end
    end
    if state.owns_functions then input.functions, input.function_presses = own.functions, own.function_presses end
    -- The speed and the hold stay as the newest final tick has them.
    input.speed, input.hold = state.last_speed, state.last_hold
    return input
end

-- Runs tick `tick` (the random position must be in place). A sound plays the first time a tick makes it: a tick that
-- runs again plays only the sounds its earlier runs did not.
local function run_tick(state, tick)
    local input = input_for(state, tick)
    state.saved[tick] = rollback.save(state.match)
    local due, held = speed_gate.step(state.match, ticks.held(input))
    state.results[tick] = due and match.step(state.match, held) or nil
    state.used[tick] = input
    local played, counts = state.played[tick] or {}, {}
    state.played[tick] = played
    for _, sound in ipairs(sounds.flush(state.match)) do
        local key = sound.resource
        counts[key] = (counts[key] or 0) + 1
        if counts[key] > (played[key] or 0) then
            played[key] = counts[key]
            state.sounds_out[#state.sounds_out + 1] = sound
        end
    end
    rumble.flush(state.match)
end

-- A message from the server: final ticks, hashes, and the times for the clock.
function client.receive(state, message, now)
    if message.echo then
        local sample = math.max(0, now - message.echo - (message.held or 0))
        if not state.rtt then
            state.rtt, state.jitter = sample, sample / 4
        else
            state.jitter = state.jitter * 0.875 + math.abs(sample - state.rtt) * 0.125
            state.rtt = state.rtt * 0.875 + sample * 0.125
        end
    end
    -- The server's clock now, estimated as its time at sending plus half the round trip.
    local offset = message.server_time + (state.rtt or 0) / 2 - now
    state.offset = state.offset and state.offset * 0.9 + offset * 0.1 or offset
    if message.newest_input and message.newest_input > state.input_acknowledged then
        state.input_acknowledged = message.newest_input
    end
    for tick, input in pairs(message.ticks or {}) do
        if tick > state.confirmed and not state.final[tick] then state.final[tick] = input end
    end
    for tick, hash in pairs(message.hashes or {}) do
        if tick > state.hashes_checked and tick > state.confirmed - keep then state.server_hashes[tick] = hash end
    end
end

-- The input delay in ticks, from the round trip: 0 to 2 (docs/netcode.md "Input from the client").
local function input_delay(state)
    -- The player can fix it in the settings menu (`fixed_delay`, base/game/options `input_delay`).
    if state.fixed_delay then return state.fixed_delay end
    return math.max(0, math.min(2, math.floor((state.rtt or 0) / 2 / tick_ms)))
end

-- One frame: takes the new final ticks (going back where they differ), runs the new ticks of the clock, and checks
-- the server's hashes. Sounds to play and confirmed results collect in sounds_out and results_out.
function client.update(state, now)
    state.new_ticks = 0
    ticks.with_random(state, function()
        local wrong
        while state.final[state.confirmed + 1] do
            local tick = state.confirmed + 1
            state.confirmed = tick
            state.last_known, state.last_speed = state.final[tick].slots, state.final[tick].speed
            state.last_hold = state.final[tick].hold
            if tick < state.tick and not ticks.same(state.final[tick], state.used[tick]) then wrong = wrong or tick end
        end
        if wrong then
            rollback.restore(state.match, state.saved[wrong])
            for tick = wrong, state.tick - 1 do run_tick(state, tick) end
            local length = state.tick - wrong
            state.stats.rollbacks = state.stats.rollbacks + 1
            state.stats.rolled_ticks = state.stats.rolled_ticks + length
            state.stats.longest = math.max(state.stats.longest, length)
        end
        if not (state.offset and state.rtt) then return end
        state.delay = input_delay(state)
        -- Run ahead of the server: half the round trip and a margin for jitter, less what the input delay covers.
        local lead = math.max(state.rtt / 2 + 2 * state.jitter + 8 - state.delay * tick_ms, 4)
        local target = math.floor((now + state.offset + lead) / tick_ms)
        if state.delay_behind then target = math.min(target, state.confirmed - state.delay_behind) end
        -- Far behind (a return or a resumed session runs the ticks so far): more ticks a frame.
        local limit = state.tick <= state.confirmed and (state.confirmed - state.tick > 60 and 4 * catch_up_limit or catch_up_limit)
            or run_limit
        state.window = math.max(window_least, math.min(window_most, math.ceil(state.rtt / tick_ms) + 4))
        while state.tick <= target and state.new_ticks < limit do
            if state.tick - state.confirmed > state.window then
                state.stats.stalls = state.stats.stalls + 1
                break
            end
            local into = state.tick + state.delay
            if not state.local_inputs[into] then
                state.local_inputs[into] = ticks.take(state.sample, state.sample_pending)
                state.sample_pending = false
            end
            run_tick(state, state.tick)
            state.tick = state.tick + 1
            state.new_ticks = state.new_ticks + 1
        end
    end)
    -- Results of final ticks only, so that a prediction cannot end a round that the server does not end.
    local last = math.min(state.confirmed, state.tick - 1)
    for tick = state.reported + 1, last do
        if state.results[tick] then state.results_out[#state.results_out + 1] = {result = state.results[tick], tick = tick} end
    end
    state.reported = math.max(state.reported, last)
    -- The server hashed its state after tick T; the client's state after T is the saved state of T + 1.
    for tick, hash in pairs(state.server_hashes) do
        local saved = state.saved[tick + 1]
        if tick <= state.confirmed and tick + 1 < state.tick and saved then
            state.stats.hash_checks = state.stats.hash_checks + 1
            if rollback.hash_saved(saved) ~= hash then
                state.stats.hash_failures = state.stats.hash_failures + 1
                state.stats.first_hash_failure = state.stats.first_hash_failure or tick
            end
            state.server_hashes[tick] = nil
            state.hashes_checked = math.max(state.hashes_checked, tick)
        elseif tick < state.confirmed - keep then
            state.server_hashes[tick] = nil
        end
    end
    -- Kept: the ticks near the newest final tick, and every tick not run yet (a client that catches up runs far
    -- behind its final ticks).
    local oldest = math.min(state.confirmed, state.tick) - keep
    for _, list in ipairs({state.saved, state.used, state.final, state.local_inputs, state.results, state.played}) do
        for tick in pairs(list) do
            if tick < oldest then list[tick] = nil end
        end
    end
end

-- The message for the server: the client's inputs that the server does not have yet.
function client.message(state, now)
    local inputs = {}
    local first = math.max(state.input_acknowledged + 1, state.confirmed + 1, state.tick + state.delay - resend_limit)
    for tick = first, state.tick + state.delay do
        if state.local_inputs[tick] then inputs[tick] = state.local_inputs[tick] end
    end
    return {from = state.id, sent_at = now, acknowledged = state.confirmed, inputs = inputs}
end

-- The overlays (damage chart, fight effects) read the newest final state, so that they never show a hit that a
-- rollback takes back. The view is one table that points at the fields of that saved state; before the first final
-- tick it is the fight itself.
function client.confirmed_view(state)
    local saved = state.saved[math.min(state.confirmed, state.tick - 1) + 1]
    if not saved then return state.match end
    local view = state.view or {}
    state.view = view
    if view.source ~= saved then
        for key in pairs(view) do view[key] = nil end
        for key, value in pairs(saved.match) do view[key] = value end
        view.source = saved
    end
    return view
end

-- For headless descriptions: the tick, the newest final tick, the rollbacks (count, ticks, longest), the waits, the
-- hash checks (count, failures), the input delay and the round trip.
function client.describe(state)
    local stats = state.stats
    return string.format("tick=%d,final=%d,rollbacks=%d/%d/%d,stalls=%d,hashes=%d/%d,delay=%d,rtt=%.0f", state.tick,
        state.confirmed, stats.rollbacks, stats.rolled_ticks, stats.longest, stats.stalls, stats.hash_checks,
        stats.hash_failures, state.delay, state.rtt or -1)
end

-- Takes the sounds and results collected since the last call (each result with its tick: {result, tick}).
function client.take(state)
    local played, results = state.sounds_out, state.results_out
    state.sounds_out, state.results_out = {}, {}
    return played, results
end

return client
