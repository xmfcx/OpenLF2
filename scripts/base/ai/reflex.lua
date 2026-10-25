-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The reflexes of a brain (OpenLF2 extension, docs/ai-plan.md "Decisions"): short answers to a threat that arrives too
-- soon to plan. They read the delayed view (base/ai/perception view), so the reaction time of the difficulty applies to
-- them too, and they act through the actuator.
--
-- The answers: defend toward the source (Defend and the direction on one input tick; a defend in base/game/control
-- turns to the held direction), move in depth out of the line of a ball or of an attack that breaks a defense, or jump
-- when there is no time to move. A brain calls reflex.decide on every tick; it returns the chosen answer and the threat.
local actuator = require("base/ai/actuator")
local predict = require("base/ai/predict")
local reflex = {}
local bits = actuator.bits
local defend_window = 6 -- a defend frame lasts long enough to start it this many ticks before the hit
local sidestep_ticks = 8 -- ticks of walking in depth to leave the line of a hit (2.5 pixels a tick, a zwidth of 15)

-- Whether the fighter can answer now: standing, walking, running or already defending.
local function free(me)
    return me.class == "free" or me.class == "moving" or me.class == "defending"
end

-- Chooses an answer for this tick. Returns "defend", "sidestep", "jump", "hold" (a defend that already runs, with
-- the direction toward the source), or nil, and the threat. `memory.reflex_until` keeps an answer from starting
-- again while it runs.
function reflex.decide(context)
    local me, view, memory, now = context.me, context.view, context.memory, context.state.frame_number
    if not me or not free(me) then return nil end
    local threats = predict.threats(context.state, view, me, predict.horizon)
    local delay = view.delay or 0
    local threat
    for _, candidate in ipairs(threats) do
        if candidate.ticks - delay >= 0 then threat = candidate break end
    end
    if not threat then return nil end
    local remaining = threat.ticks - delay
    local source = view.entries[threat.source]
    if not source then return nil end
    if (memory.reflex_until or -1) >= now then
        if me.class == "defending" then return "hold", threat, remaining, source end
        return nil
    end
    -- A defend does not stop a catch or a hit of bdefend 61 or more, and it breaks when the defend points reach 31
    -- (base/game/combat).
    local breaks = threat.kind == "catch" or (threat.bdefend or 0) >= 61 or (me.guard or 0) + (threat.bdefend or 0) >= 31
    if breaks then
        if remaining >= sidestep_ticks then return "sidestep", threat, remaining, source end
        if remaining >= 2 then return "jump", threat, remaining, source end
        return nil
    end
    if threat.ball and remaining >= sidestep_ticks + 2 then return "sidestep", threat, remaining, source end
    if remaining <= defend_window then return "defend", threat, remaining, source end
    return nil
end

-- Starts the answer through the actuator. `upper` is the depth of the stage's near edge (zboundary[1]).
function reflex.act(context, answer, threat, remaining, source)
    local memory, me, now = context.memory, context.me, context.state.frame_number
    local toward = source.x >= me.x and bits.right or bits.left
    if answer == "defend" then
        actuator.program(memory, {bits.defend + toward}, 0)
        memory.reflex_until = now + 12
    elseif answer == "hold" then
        actuator.hold(memory, toward)
    elseif answer == "sidestep" then
        local near = (context.state.stage.zboundary or {})[1] or 0
        local far = (context.state.stage.zboundary or {})[2] or 0
        local down = source.z <= me.z
        if down and me.z > far - 20 then down = false end
        if not down and me.z < near + 20 then down = true end
        actuator.hold(memory, down and bits.down or bits.up)
        memory.reflex_until = now + sidestep_ticks
    elseif answer == "jump" then
        actuator.program(memory, {bits.jump}, 0)
        memory.reflex_until = now + 20
    end
end
return reflex
