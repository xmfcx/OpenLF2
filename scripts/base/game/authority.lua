-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The authority of a networked fight (OpenLF2 extension, docs/netcode.md "The server"): it collects the inputs of the
-- clients, makes each tick final at its deadline, sends the final ticks to every client and runs the fight itself.
-- It never waits for a client: a missing input becomes a prediction (the last final keys of that slot, or no keys
-- after a while). This module knows no transport; the caller passes the messages in and out.
local match = require("base/game/match")
local sounds = require("base/game/sounds")
local rumble = require("base/game/rumble")
local rollback = require("base/game/rollback")
local ticks = require("base/game/ticks")
local authority = {}

-- Without input for this long, a client's slots are predicted with no keys, so that its fighter does not run off.
local neutral_ms = 500
-- The most final ticks one message repeats for a client that has not acknowledged them.
local resend_limit = 32
-- A hash of the true state every this many ticks, for the clients to compare.
authority.hash_interval = 30

-- options: owners[slot] = client id; clients = list of client ids; function_owner = the client whose function keys
-- count, or all_functions = true for the function keys of every client together (a server session, like the
-- original's network game); match = a fight to run on the final ticks and random = its random position, or none (a
-- server session: the clients run the game).
function authority.create(options)
    local state = {match = options.match, random = options.random, owners = options.owners,
        function_owner = options.function_owner, all_functions = options.all_functions, tick = 0, final = {}, last_final = ticks.empty(), clients = {},
        hashes = {}, results = {}, stats = {late = 0, predicted = 0}}
    for _, id in ipairs(options.clients) do
        -- `newest`: the newest tick up to which every input of the client arrived; `heard`: its newest message time
        -- (server clock); `echo`: the client time of its newest message; `acknowledged`: its newest final tick.
        state.clients[id] = {inputs = {}, newest = -1, heard = 0, echo = nil, acknowledged = -1, missed = {}}
    end
    return state
end

function authority.receive(state, message, now)
    local client = state.clients[message.from]
    if not client then return end
    client.heard = now
    if not client.echo or message.sent_at > client.echo then client.echo, client.echo_at = message.sent_at, now end
    if message.acknowledged and message.acknowledged > client.acknowledged then client.acknowledged = message.acknowledged end
    for tick, input in pairs(message.inputs or {}) do
        -- A client may only send keys for its own slots; an input for a tick that is already final is late.
        if tick < state.tick then
            -- Too late: the tick became final with a prediction for this client (counted once).
            if client.missed[tick] then
                client.missed[tick] = nil
                state.stats.late = state.stats.late + 1
            end
        elseif not client.inputs[tick] then
            local own = {slots = {}, functions = "", function_presses = ""}
            for slot = 0, 7 do
                if state.owners[slot] == message.from then own.slots[slot] = input.slots[slot] or "" end
            end
            if state.all_functions or state.function_owner == message.from then
                own.functions, own.function_presses = input.functions or "", input.function_presses or ""
            end
            client.inputs[tick] = own
        end
    end
    while client.inputs[client.newest + 1] do client.newest = client.newest + 1 end
end

-- Makes tick `tick` final and runs it.
local function finalize(state, tick, now)
    local final = ticks.empty()
    for slot = 0, 7 do
        local id = state.owners[slot]
        local client = id and state.clients[id]
        local input = client and client.inputs[tick]
        if input then
            final.slots[slot] = input.slots[slot] or ""
        elseif client then
            state.stats.predicted = state.stats.predicted + 1
            client.missed[tick] = true
            final.slots[slot] = now - client.heard > neutral_ms and "" or state.last_final.slots[slot]
        end
    end
    -- Function keys are not predicted: a missing input has none.
    for id, client in pairs(state.clients) do
        local input = client.inputs[tick]
        if input and (state.all_functions or id == state.function_owner) then
            final.functions = ticks.merge(final.functions, input.functions or "")
            final.function_presses = ticks.merge(final.function_presses, input.function_presses or "")
        end
    end
    state.final[tick], state.last_final = final, final
    -- Inputs for a final tick are not needed anymore, from any client.
    for _, client in pairs(state.clients) do
        client.inputs[tick] = nil
        if client.newest < tick then client.newest = tick end
        while client.inputs[client.newest + 1] do client.newest = client.newest + 1 end
    end
    if not state.match then return end
    local result = ticks.with_random(state, function()
        local stepped = match.step(state.match, ticks.held(final))
        sounds.flush(state.match)
        rumble.flush(state.match)
        if tick % authority.hash_interval == 0 then state.hashes[tick] = rollback.hash(state.match) end
        return stepped
    end)
    if result then state.results[tick] = result end
end

-- Runs the ticks whose deadline passed (tick T at server time (T + 1) * tick_ms) and returns one message per client.
function authority.update(state, now)
    while now >= (state.tick + 1) * ticks.tick_ms do
        finalize(state, state.tick, now)
        state.tick = state.tick + 1
    end
    local messages = {}
    for id, client in pairs(state.clients) do
        local list = {}
        local first = math.max(client.acknowledged + 1, state.tick - resend_limit)
        for tick = first, state.tick - 1 do list[tick] = state.final[tick] end
        local hashes = {}
        for tick, hash in pairs(state.hashes) do
            if tick >= first - authority.hash_interval then hashes[tick] = hash end
        end
        -- `held`: how long the server kept the echo, which the client takes off its round trip.
        messages[id] = {from = "server", server_time = now, echo = client.echo, held = client.echo_at and now - client.echo_at,
            newest_input = client.newest, ticks = list, hashes = hashes}
    end
    -- Final ticks and hashes that every client acknowledged are not needed anymore.
    local oldest = state.tick
    for _, client in pairs(state.clients) do oldest = math.min(oldest, client.acknowledged + 1) end
    for tick in pairs(state.final) do
        if tick < oldest - resend_limit then state.final[tick] = nil end
    end
    for tick in pairs(state.hashes) do
        if tick < oldest - 4 * authority.hash_interval then state.hashes[tick] = nil end
    end
    for _, client in pairs(state.clients) do
        for tick in pairs(client.missed) do
            if tick < state.tick - 4 * resend_limit then client.missed[tick] = nil end
        end
    end
    return messages
end

return authority
