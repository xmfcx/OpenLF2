-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The random stream of an AI brain (OpenLF2 extension, docs/ai-plan.md "Memory"): a Park-Miller generator whose state
-- is one integer in the brain's memory, so a rollback saves it with the match table. Every step stays exact in a
-- double (48271 * (2^31 - 1) < 2^53). A brain never uses engine.random after its start, so a change to a brain never
-- changes the random items, drops or stages of a fight.
local random = {}
local modulus, multiplier = 2147483647, 48271

-- A start value from one engine.random call (its values stay below 1489) mixed with the slot and the tick, so
-- fighters that start on the same tick get different streams.
function random.seed(match, index, id)
    local mixed = (engine.random(1489) * 7919 + index * 104729 + match.frame_number * 131 + id * 17) % (modulus - 1)
    local memory = {rng = mixed + 1}
    for _ = 1, 3 do random.next(memory, 1) end
    return memory.rng
end

-- A whole number in 0 .. range - 1 from the stream in `memory.rng`.
function random.next(memory, range)
    local state = memory.rng * multiplier % modulus
    memory.rng = state
    if range <= 1 then return 0 end
    return state % range
end
return random
