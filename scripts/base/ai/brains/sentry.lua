-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `sentry` (docs/ai-plan.md phase 3): a test brain that stands still and predicts. On each tick it builds the
-- snapshot, updates its senses and asks prediction for the threats to itself. It logs each new or changed prediction
-- (`ev=threat ... impact=TICK`) and each hit that it takes (`ev=hurt`), so tools/ai_prediction_check.py can compare
-- the predicted tick with the tick of the hit. It never presses a key, so the attackers' moves decide everything.
local item = require("base/game/item")
local perception = require("base/ai/perception")
local predict = require("base/ai/predict")
local senses = require("base/ai/senses")
local sentry = {name = "sentry", version = 1}
local attention = 6

function sentry.start(state, index, seed)
    return {version = sentry.version, rng = seed, hp = state.items[index].hp, threat_source = {}, threat_impact = {},
        next_impact = -1, caught_ticks = 100, fall_damage = 0}
end

function sentry.tick(state, index, memory, scan, log)
    local self = state.items[index]
    for _, key in ipairs(item.keys) do
        self.previous_keys[key] = self.keys[key]
        self.keys[key] = false
    end
    local world = perception.world(state, scan)
    local me = world.entries[index]
    -- The hp falls in combat.apply of the previous tick: the hit belongs to that tick.
    -- A grab hurts by the catch rules (base/game/grab), and a throw by the fall damage on landing (base/game/physics),
    -- not by a hit box, so prediction does not see them.
    if self.hp < memory.hp and log then
        local cause = memory.caught_ticks < 3 and "grab" or (memory.fall_damage ~= 0 and "throw" or "hit")
        log(state, index, string.format("ev=hurt hit=%d hp=%d dmg=%d frame=%d cause=%s", world.tick - 1, self.hp,
            memory.hp - self.hp, self.frame, cause))
    end
    memory.hp, memory.fall_damage = self.hp, self.fall_damage
    if me.class == "caught" then memory.caught_ticks = 0 else memory.caught_ticks = memory.caught_ticks + 1 end
    senses.update(memory, state, world, me, attention, perception.hostile)
    local threats = predict.threats(state, world, me, predict.horizon)
    local sources, impacts = {}, {}
    for position, threat in ipairs(threats) do
        local impact = world.tick + threat.ticks
        sources[position], impacts[position] = threat.source, impact
        local known = false
        for old = 1, #memory.threat_source do
            if memory.threat_source[old] == threat.source and memory.threat_impact[old] == impact then known = true end
        end
        if not known and log then
            log(state, index, string.format("ev=threat src=%d move=%d ball=%d impact=%d in=%d dmg=%d fall=%d", threat.source,
                threat.move, threat.ball and 1 or 0, impact, threat.ticks, threat.damage, threat.fall))
        end
    end
    memory.threat_source, memory.threat_impact = sources, impacts
    memory.next_impact = #threats > 0 and threats[1].ticks or -1
end

function sentry.describe(memory)
    return string.format("seen:%d,next:%d", #(memory.seen_index or {}), memory.next_impact)
end
return sentry
