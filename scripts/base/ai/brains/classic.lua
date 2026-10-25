-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `classic` (docs/ai.md): the original's routines for computer fighters in base/game/ai, unchanged. It keeps
-- no memory of its own (no `value.ai`), so a fight with classic brains stays the same table, with the same hash and
-- the same replays. With the trace on, it only reads what ai.control changed and writes events.
local ai = require("base/game/ai")
local constants = require("base/game/constants")
local trace = require("base/ai/trace")
local sequence_complete = constants.combo_states.complete
local classic = {name = "classic"}

-- constants.combo_indices order, with the frame field that each sequence enters (base/game/control).
local sequence_inputs = {"D>A dir=right", "D>A dir=left", "D^A", "DvA", "D>J dir=right", "D>J dir=left", "D^J", "DvJ", "DJA"}
local sequence_fields = {"Fa", "Fa", "Ua", "Da", "Fj", "Fj", "Uj", "Dj", "ja"}
local key_letters = {{"up", "u"}, {"down", "d"}, {"left", "l"}, {"right", "r"}, {"attack", "c"}, {"jump", "b"}, {"defend", "f"}}
local summary_ticks = 30
local before = {}

local function held_keys(value)
    local text = ""
    for _, pair in ipairs(key_letters) do
        if value.keys[pair[1]] then text = text .. pair[2] end
    end
    return text == "" and "-" or text
end

function classic.tick(state, index, scan)
    if not trace.active(state, index) then return ai.control(state, index, state.mode, scan) end
    local value = state.items[index]
    local target = value.last_target
    for sequence = 1, #sequence_fields do before[sequence] = value.sequences[sequence] end
    ai.control(state, index, state.mode, scan)
    if value.last_target ~= target then trace.add(state, index, "ev=target to=" .. value.last_target) end
    for sequence = 1, #sequence_fields do
        if value.sequences[sequence] == sequence_complete and before[sequence] ~= sequence_complete then
            -- The move starts from the current frame, or from the defend frame that the sequence passes.
            local frame = value.record.frame(value.frame)
            local goal = frame.hits[sequence_fields[sequence]]
            if goal == 0 and frame.hits.d ~= 0 then goal = value.record.frame(frame.hits.d).hits[sequence_fields[sequence]] end
            if goal == 0 then
                -- The current frame has no move for this input, so the sequence starts nothing.
                trace.add(state, index, string.format("ev=move input=%s frame=none from=%d mp=%d", sequence_inputs[sequence],
                    value.frame, value.mp))
            else
                trace.add(state, index, string.format("ev=move input=%s frame=%d name=%s mp=%d", sequence_inputs[sequence],
                    math.abs(goal), value.record.frame(math.abs(goal)).name, value.mp))
            end
        end
    end
    if state.frame_number % summary_ticks == 0 then
        local other = value.last_target >= 0 and state.items[value.last_target]
        local distance = other and math.abs(other.x_int - value.x_int) + math.abs(other.z_int - value.z_int) or -1
        trace.add(state, index, string.format("ev=sum brain=classic id=%d frame=%d hp=%d mp=%d target=%d dist=%d keys=%s",
            value.record.id, value.frame, value.hp, value.mp, value.last_target, distance, held_keys(value)))
    end
end

classic.held_keys = held_keys
return classic
