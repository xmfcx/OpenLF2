-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The actuator of the AI (OpenLF2 extension, docs/ai-plan.md "Actions and the actuator"): a brain chooses an action,
-- and the actuator types it as keys over the next ticks, like a player. It is the only writer of a brain's
-- `value.keys` and `value.previous_keys`.
--
-- The keys of a tick are a mask: up 1, down 2, left 4, right 8, attack 16, jump 32, defend 64. A program is a list of
-- masks, one for each sample. A sample is a tick where the keys may change: every second tick (`input_phase` 0, the
-- ticks where human keys change, base/game/match read_input) at the human rate, every tick at the fast rate. After the
-- program, the actuator holds the `hold` mask. The difficulty also limits the key changes a second (a bucket that
-- fills with `keys_per_second` and empties by one change) and delays a program's start by up to `timing_error` ticks.
--
-- The state lives in the brain's memory: act_program (array of masks), act_step, act_hold, act_mask (the mask of the
-- last sample), act_delay, act_budget (thirtieths of a change), act_started (the tick of the program's first key).
local item = require("base/game/item")
local actuator = {}

local keys = item.keys -- up, down, left, right, attack, jump, defend
local bits = {up = 1, down = 2, left = 4, right = 8, attack = 16, jump = 32, defend = 64}
actuator.bits = bits
local burst = 90 -- three key changes at once, in thirtieths

local function has(mask, bit) return math.floor(mask / bit) % 2 == 1 end
actuator.has = has

function actuator.start(memory)
    memory.act_program, memory.act_step, memory.act_hold, memory.act_mask = {}, 1, 0, 0
    memory.act_delay, memory.act_budget, memory.act_started = 0, burst, -1
end

-- Replaces the program. `delay` ticks pass before its first sample (the timing error of the difficulty).
function actuator.program(memory, masks, hold, delay)
    local program = memory.act_program
    for position = #program, 1, -1 do program[position] = nil end
    -- A key that the last sample holds must go up first, or the next press is not fresh.
    local first = masks[1]
    if first and first ~= 0 then
        local overlap = false
        for _, key in ipairs(keys) do
            if has(first, bits[key]) and has(memory.act_mask, bits[key]) then overlap = true end
        end
        if overlap then program[1] = 0 end
    end
    for _, mask in ipairs(masks) do program[#program + 1] = mask end
    memory.act_step, memory.act_hold, memory.act_delay, memory.act_started = 1, hold or 0, delay or 0, -1
end

-- Holds a mask from the next sample on (movement), and drops the program.
function actuator.hold(memory, mask)
    local program = memory.act_program
    for position = #program, 1, -1 do program[position] = nil end
    memory.act_step, memory.act_hold, memory.act_delay = 1, mask, 0
end

function actuator.busy(memory) return memory.act_step <= #memory.act_program end

-- The sequence of base/game/control that an input completes (constants.combo_indices order).
local function sequence_of(input, right)
    if input == "D>A" then return right and 1 or 2 end
    if input == "D>J" then return right and 5 or 6 end
    return ({["D^A"] = 3, DvA = 4, ["D^J"] = 7, DvJ = 8, DJA = 9})[input]
end
actuator.sequence_of = sequence_of

-- The masks that type the input of a move: "D>A", "D^J", "DJA" and the others of base/ai/move_book. `right` chooses the
-- direction of `>`. At the human rate each key has its own sample. At the fast rate the second and third key share one
-- (base/game/control advances a sequence by more than one step in a tick). `progress` is the state of the input's
-- sequence now (value.sequences): the sequences of base/game/control have no timeout, so a sequence can wait at
-- "defend pressed" or "second key pressed" from earlier keys. Then only the missing keys are typed, because a fresh
-- Defend resets a sequence that already waits after Defend.
function actuator.input_masks(input, right, rate, progress)
    local direction = right and bits.right or bits.left
    local second = ({[">"] = direction, ["^"] = bits.up, v = bits.down, J = bits.jump})[input:sub(2, 2)]
    local third = ({A = bits.attack, J = bits.jump})[input:sub(3, 3)]
    if input:sub(1, 1) ~= "D" or not second or not third then return nil end
    progress = progress or 0
    if progress >= 3 then return {} end
    if progress == 2 then return {third} end
    if progress == 1 then
        if rate == "fast" then return {second + third} end
        return {second, third}
    end
    if rate == "fast" then return {bits.defend, second + third} end
    return {bits.defend, second, third}
end

-- Starts typing `input` for `value` (its sequences decide the keys still needed). Returns false for an input that is
-- not a sequence.
function actuator.type_input(memory, value, input, right, rate, delay)
    local index = sequence_of(input, right)
    if not index then return false end
    local masks = actuator.input_masks(input, right, rate, value.sequences[index])
    if not masks then return false end
    actuator.program(memory, masks, 0, delay)
    return true
end

-- Starts a run: a double tap of the direction, then the direction held.
function actuator.run(memory, right, delay)
    local direction = right and bits.right or bits.left
    actuator.program(memory, {direction, 0, direction}, direction, delay)
end

-- One tick: the keys of the fighter from the program. `row` is the difficulty row (rate, keys_per_second).
function actuator.tick(state, value, memory, row)
    -- Like a human fighter (base/game/match read_input): the previous keys follow on every tick.
    for _, key in ipairs(keys) do value.previous_keys[key] = value.keys[key] end
    memory.act_budget = math.min(memory.act_budget + row.keys_per_second, burst)
    if memory.act_delay > 0 then
        memory.act_delay = memory.act_delay - 1
        return
    end
    if row.rate ~= "fast" and state.input_phase ~= 0 then return end
    local mask
    if memory.act_step <= #memory.act_program then mask = memory.act_program[memory.act_step] else mask = memory.act_hold end
    if mask ~= memory.act_mask then
        if memory.act_budget < 30 then return end
        memory.act_budget = memory.act_budget - 30
    end
    if memory.act_step <= #memory.act_program then
        -- The program starts with its first key (a release before it does not count).
        if mask ~= 0 and memory.act_started < 0 then memory.act_started = state.frame_number end
        memory.act_step = memory.act_step + 1
    end
    memory.act_mask = mask
    for _, key in ipairs(keys) do value.keys[key] = has(mask, bits[key]) end
end
return actuator
