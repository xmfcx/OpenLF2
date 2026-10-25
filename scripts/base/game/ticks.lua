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
    local held = {functions = input.functions or "", function_presses = input.function_presses or "", keys = {}}
    for slot = 0, 7 do held[slot] = input.slots[slot] or "" end
    return held
end

function ticks.same(a, b)
    if (a.functions or "") ~= (b.functions or "") or (a.function_presses or "") ~= (b.function_presses or "") then
        return false
    end
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
