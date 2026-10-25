-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `guard` (docs/ai-plan.md phase 7): a test brain that only defends and dodges with the reflexes
-- (base/ai/reflex), through the delayed view and the actuator. It never attacks and never walks to a target, so the
-- arena can compare the damage that it takes with the damage that a `sentry` takes in the same fights. It logs each
-- answer (`ev=reflex answer=defend src=12 in=4 kind=move`).
local actuator = require("base/ai/actuator")
local reflex = require("base/ai/reflex")
local guard = {name = "guard", version = 1, interface = 2}

function guard.start(state, index, seed)
    local memory = {version = guard.version, rng = seed, reflex_until = -1, answers = 0, hp = state.items[index].hp,
        class = ""}
    actuator.start(memory)
    return memory
end

function guard.tick(context)
    local memory = context.memory
    -- The hits that it takes, with its class on the tick before (a defend, a sidestep or nothing).
    if context.self.hp < memory.hp and context.log then
        context.log(context.state, context.index, string.format("ev=hurt hit=%d dmg=%d class=%s", context.state.frame_number - 1,
            memory.hp - context.self.hp, memory.class))
    end
    memory.hp, memory.class = context.self.hp, context.me.class
    local answer, threat, remaining, source = reflex.decide(context)
    if answer then
        reflex.act(context, answer, threat, remaining, source)
        if answer ~= "hold" then
            memory.answers = memory.answers + 1
            if context.log then
                context.log(context.state, context.index, string.format("ev=reflex answer=%s src=%d in=%d kind=%s dmg=%d delay=%d",
                    answer, threat.source, remaining, threat.kind, threat.damage, context.view.delay or 0))
            end
        end
    elseif (memory.reflex_until or -1) < context.state.frame_number and not actuator.busy(memory) then
        actuator.hold(memory, 0)
    end
    actuator.tick(context.state, context.self, memory, context.row)
end

function guard.describe(memory) return "answers:" .. memory.answers end
return guard
