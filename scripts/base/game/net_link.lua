-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- A simulated one-way network link (OpenLF2 extension, docs/netcode.md step 2): each message arrives after a delay
-- plus a random jitter, or is lost, like a UDP packet. Messages can overtake each other. The link has its own random
-- numbers, so that it never moves the game's random streams.
local rollback = require("base/game/rollback")
local link = {}

-- params: delay and jitter in milliseconds, loss in percent; seed: a whole number.
function link.create(params, seed)
    return {delay = params.delay or 0, jitter = params.jitter or 0, loss = params.loss or 0,
        seed = seed % 2147483648, queue = {}, sent = 0, lost = 0}
end

-- A number from 0 to 1 (a 31-bit linear congruential generator, exact in doubles).
local function next_random(state)
    state.seed = (state.seed * 1103515245 + 12345) % 2147483648
    return state.seed / 2147483648
end

function link.send(state, now, message)
    state.sent = state.sent + 1
    if next_random(state) * 100 < state.loss then
        state.lost = state.lost + 1
        return
    end
    local arrival = now + state.delay + next_random(state) * state.jitter
    -- A copy, so that the sender can change its tables after sending.
    state.queue[#state.queue + 1] = {arrival = arrival, order = state.sent, message = rollback.copy_input(message)}
end

-- The messages that arrived by `now`, in the order of their arrival.
function link.receive(state, now)
    local arrived, waiting = {}, {}
    for _, entry in ipairs(state.queue) do
        if entry.arrival <= now then arrived[#arrived + 1] = entry else waiting[#waiting + 1] = entry end
    end
    state.queue = waiting
    table.sort(arrived, function(a, b)
        if a.arrival ~= b.arrival then return a.arrival < b.arrival end
        return a.order < b.order
    end)
    local messages = {}
    for index, entry in ipairs(arrived) do messages[index] = entry.message end
    return messages
end

return link
