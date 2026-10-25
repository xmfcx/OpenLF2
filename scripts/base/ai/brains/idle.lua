-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `idle` (docs/ai-plan.md phase 1): a test brain. It walks to the nearest enemy and stands near it, and it
-- waits now and then for a random time. It never attacks. It tests the parts of the framework: the memory in the match
-- table, the AI random stream, the trace and the description, under rollback and in network fights.
local random = require("base/ai/random")
local item = require("base/game/item")
local idle = {name = "idle", version = 1}
local near_x, near_z = 60, 4

function idle.start(state, index, seed)
    return {version = idle.version, rng = seed, target = -1, wait = 0}
end

local function nearest_enemy(state, index, scan)
    local self = state.items[index]
    local best, best_distance = -1, math.huge
    for position = 1, #scan.characters do
        local other_index = scan.characters[position]
        local other = state.items[other_index]
        if other_index ~= index and other and other.hp > 0 and other.team ~= self.team then
            local distance = math.abs(other.x_int - self.x_int) + math.abs(other.z_int - self.z_int)
            if distance < best_distance then best, best_distance = other_index, distance end
        end
    end
    return best
end

-- `log`: nil, or a function(state, index, text) that writes an event to the trace.
function idle.tick(state, index, memory, scan, log)
    local self = state.items[index]
    for _, key in ipairs(item.keys) do
        self.previous_keys[key] = self.keys[key]
        self.keys[key] = false
    end
    if memory.wait > 0 then
        memory.wait = memory.wait - 1
        return
    end
    local target = nearest_enemy(state, index, scan)
    if target ~= memory.target then
        memory.target = target
        if log then log(state, index, "ev=target to=" .. target) end
    end
    if target < 0 then return end
    if random.next(memory, 60) == 0 then
        memory.wait = 10 + random.next(memory, 20)
        if log then log(state, index, "ev=wait ticks=" .. memory.wait) end
        return
    end
    local other = state.items[target]
    local dx, dz = other.x_int - self.x_int, other.z_int - self.z_int
    if dx > near_x then self.keys.right = true elseif dx < -near_x then self.keys.left = true end
    if dz > near_z then self.keys.down = true elseif dz < -near_z then self.keys.up = true end
end

function idle.describe(memory)
    return string.format("target:%d,wait:%d", memory.target, memory.wait)
end
return idle
