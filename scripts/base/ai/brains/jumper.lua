-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `jumper` (docs/ai-plan.md phase 12): a scripted test opponent. It stands 180 pixels from its target in the
-- target's depth lane, so that a zoner throws balls at it, and it leaves the lane of every ball that comes (a step in
-- depth, which also works in a corner, where a jump comes too late). It never attacks. The learning test lets a zoner
-- fight it: the zoner must throw fewer balls once it learns that they miss.
local actuator = require("base/ai/actuator")
local perception = require("base/ai/perception")
local predict = require("base/ai/predict")
local jumper = {name = "jumper", version = 1, interface = 2}
local bits = actuator.bits

function jumper.start(state, index, seed)
    local memory = {version = jumper.version, rng = seed, jumps = 0, dodge_until = -1, dodge_mask = 0}
    actuator.start(memory)
    return memory
end

function jumper.tick(context)
    local memory, me, state = context.memory, context.me, context.state
    local target
    for _, other in ipairs(context.world.list) do
        if other.character and other.hp > 0 and perception.enemy(state, me, other) then target = other end
    end
    if target and (me.class == "free" or me.class == "moving") and not actuator.busy(memory) then
        local jump = false
        for _, threat in ipairs(predict.threats(state, context.world, me, 12)) do
            if threat.ball then jump = true end
        end
        if jump and memory.dodge_until < state.frame_number then
            -- Away from the ball's lane, toward the side with room.
            local near = (state.stage.zboundary or {})[1] or 0
            local far = (state.stage.zboundary or {})[2] or 0
            memory.dodge_mask = (me.z - near > far - me.z) and bits.up or bits.down
            memory.dodge_until = state.frame_number + 14
            memory.jumps = memory.jumps + 1
        end
        if memory.dodge_until >= state.frame_number then
            actuator.hold(memory, memory.dodge_mask)
        else
            local side = me.x < target.x and -1 or 1
            local x, z = target.x + side * 180, target.z
            local mask = 0
            if x > me.x + 10 then mask = mask + bits.right elseif x < me.x - 10 then mask = mask + bits.left end
            if z > me.z + 2 then mask = mask + bits.down elseif z < me.z - 2 then mask = mask + bits.up end
            actuator.hold(memory, mask)
        end
    end
    actuator.tick(state, context.self, memory, context.row)
end

function jumper.describe(memory) return "jumps:" .. memory.jumps end
return jumper
