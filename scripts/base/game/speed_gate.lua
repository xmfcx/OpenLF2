-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The game speed in a fight of the server program (OpenLF2 extension, docs/pregame-ui-redesign.md "The game speed"):
-- the server's ticks stay 33 ms, and at a speed of N tenths the fight runs on N of every ten ticks, spread evenly.
-- The keys reach it like in a local game (base/ui/flow `fight_due`): each change of a slot's keys is queued, a change
-- one tick after the previous one merges into it, each read takes the oldest state, and more than three waiting
-- states merge the two oldest. Function keys of skipped ticks go to the next tick that runs, and F4 always runs one.
-- The gate keeps its state in the fight (`fight.speed_gate`), so a rollback saves and restores it with the fight, and
-- every client counts the same ticks.
local gate = {}

local key_letters = {"u", "d", "l", "r", "c", "b", "f"}
local merge_ticks, queue_limit = 1, 3

local function key_state(held)
    local letters = {}
    for _, letter in ipairs(key_letters) do
        if held:find(letter, 1, true) then letters[#letters + 1] = letter end
    end
    return table.concat(letters)
end
local function merged(into, from)
    for letter in from:gmatch(".") do
        if not into:find(letter, 1, true) then into = into .. letter end
    end
    return into
end

-- Whether the fight runs on this tick, and the keys it reads then. `held` is the tick's input (base/game/ticks held)
-- with `speed`, the speed in tenths (nil or 10 is the normal speed).
function gate.step(fight, held)
    -- A held tick of a server session (a player dropped): the fight waits, and its keys do not count.
    if held.hold then return false, nil end
    local tenths = held.speed or 10
    if tenths >= 10 then
        -- Keys queued on skipped ticks go to this tick.
        local before = fight.speed_gate
        fight.speed_gate = nil
        if before then
            local out = {functions = merged(before.functions, held.functions or ""),
                function_presses = merged(before.presses, held.function_presses or ""), keys = held.keys, speed = held.speed}
            for slot = 0, 7 do out[slot] = (held[slot] or "") .. (before.commands[slot] or "") end
            return true, out
        end
        return true, held
    end
    local state = fight.speed_gate
    if not state then
        state = {progress = 0, tick = 0, slots = {}, functions = "", presses = "", commands = {}}
        for slot = 0, 7 do state.slots[slot] = {given = key_state(held[slot] or ""), queue = {}} end
        fight.speed_gate = state
    end
    state.progress = state.progress + tenths
    local due = state.progress >= 10 or (held.functions or ""):find("4", 1, true) ~= nil
    state.tick = state.tick + 1
    for slot = 0, 7 do
        local entry, keys = state.slots[slot], held[slot] or ""
        -- The control letters of base/game/match ("A", "P") are not keys: they wait for the next tick that runs.
        for letter in keys:gmatch("[AP]") do state.commands[slot] = merged(state.commands[slot] or "", letter) end
        local queue, now = entry.queue, key_state(keys)
        local tail = queue[#queue]
        if now ~= (tail and tail.keys or entry.given) then
            local before = queue[#queue - 1]
            before = before and before.keys or entry.given
            if tail and state.tick - tail.tick <= merge_ticks and now ~= before then
                tail.keys, tail.tick = now, state.tick
            else
                queue[#queue + 1] = {keys = now, tick = state.tick}
                if #queue > queue_limit then table.remove(queue, 1) end
            end
        end
    end
    state.functions = merged(state.functions, held.functions or "")
    state.presses = merged(state.presses, held.function_presses or "")
    if not due then return false, nil end
    state.progress = math.max(state.progress - 10, 0)
    local reads = (fight.input_phase + 1) % 2 == 0
    local out = {functions = state.functions, function_presses = state.presses, keys = held.keys, speed = tenths}
    for slot = 0, 7 do
        local entry = state.slots[slot]
        if reads and #entry.queue > 0 then entry.given = table.remove(entry.queue, 1).keys end
        out[slot] = entry.given .. (state.commands[slot] or "")
    end
    state.commands = {}
    -- The fight reads function keys on every second tick, and a release clears a key it has not read
    -- (base/game/match "note_function_keys"): on a tick that does not read them, they stay for the next one.
    if reads then state.functions, state.presses = "", "" end
    return true, out
end

return gate
