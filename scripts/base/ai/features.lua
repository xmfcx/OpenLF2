-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The situation of a fighter as ten whole numbers, and its keys as an action (OpenLF2 extension, docs/ai-plan.md
-- "Learning", imitation): what `--ai-log observe` writes for every fighter (base/game/match read_input), what
-- tools/ai-imitate.py learns from, and what the brain `imitator` reads. Left and right become "away" and "toward" its
-- nearest enemy, so a situation and its answer do not depend on the side.
--
-- The features: 1 the distance in x (tens of pixels, at most 40), 2 the depth gap (halves of pixels, -30 to 30, the
-- enemy's depth less its own), 3 it is free, 4 it is in the air, 5 it attacks, 6 the enemy is free, 7 the enemy
-- attacks, 8 the enemy cannot act (hurt, dizzy, falling, lying, recovering), 9 its mp (fifties, at most 10), 10 the
-- enemy faces it. The action: a key mask with up 1, down 2, away 4, toward 8, attack 16, jump 32, defend 64.
local perception = require("base/ai/perception")
local constants = require("base/game/constants")
local features = {count = 10}

local open = {hurt = true, dizzy = true, falling = true, lying = true, recovering = true}

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

-- The nearest enemy of `me` in `world`, or nil.
function features.enemy_of(state, world, me)
    local best, best_distance
    for _, other in ipairs(world.list) do
        if other.character and other.hp > 0 and perception.enemy(state, me, other) then
            local distance = math.abs(other.x - me.x) + 2 * math.abs(other.z - me.z)
            if not best_distance or distance < best_distance then best, best_distance = other, distance end
        end
    end
    return best
end

-- Fills `into` (an array) with the features of `me` against `enemy`.
function features.of(me, enemy, mp, into)
    local facing_me = (enemy.x > me.x and enemy.facing == constants.facings.left)
        or (enemy.x <= me.x and enemy.facing == constants.facings.right)
    into[1] = clamp(math.floor(math.abs(enemy.x - me.x) / 10), 0, 40)
    into[2] = clamp(math.floor((enemy.z - me.z) / 2), -30, 30)
    into[3] = (me.class == "free" or me.class == "moving") and 1 or 0
    into[4] = me.class == "air" and 1 or 0
    into[5] = me.class == "attacking" and 1 or 0
    into[6] = (enemy.class == "free" or enemy.class == "moving") and 1 or 0
    into[7] = enemy.class == "attacking" and 1 or 0
    into[8] = open[enemy.class] and 1 or 0
    into[9] = clamp(math.floor(mp / 50), 0, 10)
    into[10] = facing_me and 1 or 0
    return into
end

-- The action of a fighter's keys against an enemy on the right (`right`) or the left.
function features.action(keys, right)
    local mask = 0
    if keys.up then mask = mask + 1 end
    if keys.down then mask = mask + 2 end
    local toward, away = right and keys.right or (not right and keys.left), right and keys.left or (not right and keys.right)
    if away then mask = mask + 4 end
    if toward then mask = mask + 8 end
    if keys.attack then mask = mask + 16 end
    if keys.jump then mask = mask + 32 end
    if keys.defend then mask = mask + 64 end
    return mask
end

-- The actuator's key mask (base/ai/actuator: left 4, right 8) of an action against an enemy on the right or the left.
function features.keys_of(action, right)
    local away, toward = math.floor(action / 4) % 2 == 1, math.floor(action / 8) % 2 == 1
    local mask = action % 4 + math.floor(action / 16) * 16
    if (toward and right) or (away and not right) then mask = mask + 8 end
    if (toward and not right) or (away and right) then mask = mask + 4 end
    return mask
end

local scratch = {}
-- One `ev=obs` line for each fighter on the ticks where human keys change (`--ai-log observe`).
function features.observe(state, scan, log)
    if state.input_phase ~= 0 then return end
    local world = perception.world(state, scan)
    for _, me in ipairs(world.list) do
        local value = state.items[me.index]
        if me.character and me.hp > 0 and value then
            local enemy = features.enemy_of(state, world, me)
            if enemy then
                features.of(me, enemy, value.mp, scratch)
                log(state, me.index, string.format("ev=obs f=%s a=%d", table.concat(scratch, ","),
                    features.action(value.keys, enemy.x > me.x)))
            end
        end
    end
end
return features
