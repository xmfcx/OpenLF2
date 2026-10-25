-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The input of one fight tick in the network design (OpenLF2 extension, docs/netcode.md): the keys of each player
-- slot and the function keys, as the fight reads them (base/game/match `held`). The server, the clients and the
-- simulated session share these helpers.
local ticks = {}

-- The original's frame: about 30.3 ticks per second.
ticks.tick_ms = 33

function ticks.empty()
    return {slots = {[0] = "", "", "", "", "", "", "", ""}, functions = "", function_presses = ""}
end

-- The `held` table that match.step reads.
function ticks.held(input)
    local held = {functions = input.functions or "", function_presses = input.function_presses or "", keys = {},
        speed = input.speed, hold = input.hold, commands = input.commands}
    for slot = 0, 7 do held[slot] = input.slots[slot] or "" end
    return held
end

-- The letters of `b` added to `a` (function keys of several clients).
function ticks.merge(a, b)
    for letter in b:gmatch(".") do
        if not a:find(letter, 1, true) then a = a .. letter end
    end
    return a
end

-- The keys of this computer's frames go to the ticks it runs. A frame that runs no tick must not lose its keys (a
-- key or F-key held for one frame): the next frame's sample adds them (`sample`), and a press goes to one tick only
-- (`take`). `pending` is the sample that no tick took yet, or nil.
function ticks.sample(pending, input)
    if not pending then return input end
    local merged = ticks.empty()
    for slot = 0, 7 do merged.slots[slot] = ticks.merge(pending.slots[slot] or "", input.slots[slot] or "") end
    merged.functions = ticks.merge(pending.functions or "", input.functions or "")
    merged.function_presses = ticks.merge(pending.function_presses or "", input.function_presses or "")
    return merged
end
-- The input for one tick from the frame's sample: the first tick takes the presses, later ones the held keys only.
function ticks.take(sample, first)
    if first then return sample end
    local held = {slots = sample.slots, functions = sample.functions, function_presses = ""}
    return held
end

function ticks.same(a, b)
    if (a.functions or "") ~= (b.functions or "") or (a.function_presses or "") ~= (b.function_presses or "") then
        return false
    end
    if (a.speed or 10) ~= (b.speed or 10) or (a.hold or false) ~= (b.hold or false) then return false end
    if #(a.commands or {}) ~= #(b.commands or {}) then return false end
    for slot = 0, 7 do
        if (a.slots[slot] or "") ~= (b.slots[slot] or "") then return false end
    end
    return true
end

-- Several fights can run in one program (the simulated session). They share the engine's random streams, so each
-- owner keeps its own position and puts it in place around its ticks.
function ticks.with_random(owner, run)
    engine.set_random_position(owner.random[1], owner.random[2], owner.random[3])
    local result = run()
    owner.random = {engine.random_position()}
    return result
end

return ticks
