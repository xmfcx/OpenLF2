-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Prediction of the AI (OpenLF2 extension, docs/ai-plan.md "Prediction"): answers about the next ticks from the
-- snapshot (base/ai/perception) and the move books, with simple motion. It reads, it never writes.
--
-- Tick counts: 0 is the current tick (combat.detect of this tick, after the keys, the control and the physics of the
-- tick), 1 the next tick, and so on. A character in its move moves by the move book's forward distance, a ball by its
-- speed. The defender stays where it is, or moves at its current speed with `moving`.
local constants = require("base/game/constants")
local perception = require("base/ai/perception")
local facing_left = constants.facings.left
local velocity_encoding = constants.velocity_encoding
local gravity = constants.gravity.default
local predict = {}

-- base/game/control frame_velocity in the facing direction: dvx above the threshold sets the speed, a positive dvx
-- is a minimum speed forward, a negative one a minimum speed backward.
local function advance_speed(speed, dvx)
    if dvx > velocity_encoding.absolute_threshold then return dvx - velocity_encoding.absolute_offset end
    if dvx > 0 and dvx > speed then return dvx end
    if dvx < 0 and dvx < speed then return dvx end
    return speed
end
predict.horizon = 30

-- The first tick on which combat lets `attacker` hit `defender` (base/game/combat): the attacker's rest after its
-- last hit (timer_ec, counted down in the frame advance), the pair rest of the defender (aged at the start of each
-- detection) and the defender's blink (counted toward 0 in the frame advance).
local function earliest(attacker, defender)
    local pair = defender.rest and defender.rest[attacker.index] or 0
    return math.max(attacker.attack_rest or 0, pair - 1, math.abs(defender.blink or 0), 0)
end
predict.earliest = earliest

-- Whether a box of the move book or of the snapshot can touch the defender: a falling victim is not touched by weak
-- attacks (base/game/combat record_targets).
local function touches(box, defender)
    return not (defender.state == constants.frame_states.falling and box.fall < 41)
end

-- Whether the defender's bodies, shifted by shift_x, overlap the box.
local function overlaps_body(defender, x0, x1, y0, y1, shift_x)
    for _, body in ipairs(defender.bodies) do
        -- Strict comparisons, like base/game/collision: touching edges do not overlap.
        if body.x0 + shift_x < x1 and x0 < body.x1 + shift_x and body.y0 < y1 and y0 < body.y1 then return true end
    end
    return false
end

-- The first tick on which `move` of `attacker` (a perception entry), from timeline index `from_tick` on this tick and
-- facing `facing`, hits `defender`, within `horizon` ticks. `attacker_x`, `attacker_z` replace the attacker's
-- position (a planned move from another place). Returns ticks, the hit box of the move book and the timeline index,
-- or nil.
function predict.move_hit(attacker, move, from_tick, facing, defender, horizon, moving, attacker_x, attacker_z)
    horizon = horizon or predict.horizon
    local x, az, y = attacker_x or attacker.x, attacker_z or attacker.z, attacker.y
    local direction = facing == facing_left and -1 or 1
    -- The attacker moves like base/game/control frame_velocity and base/game/physics: from its current speed, each
    -- tick takes the frame's dvx and dvy, then moves, then slows by 1 on the ground or falls by gravity in the air.
    -- A planned move (attacker_x given) starts at rest.
    local frames = attacker.record.data.frames
    local speed = attacker_x and 0 or attacker.vx * direction
    local vy = attacker_x and 0 or attacker.vy
    local last = math.min(move.ticks, from_tick + horizon)
    local first = from_tick + earliest(attacker, defender)
    for t = from_tick, last do
        local frame = frames[move.frames[t]]
        if frame then
            speed = advance_speed(speed, frame.dvx)
            local dvy = frame.dvy
            if dvy ~= 0 then
                if dvy > velocity_encoding.absolute_threshold then vy = dvy - velocity_encoding.absolute_offset else vy = vy + dvy end
            end
        end
        local grounded = y >= 0
        x = x + direction * speed
        if grounded then
            if speed > 0.0001 then speed = math.max(speed - 1, 0) elseif speed < -0.0001 then speed = math.min(speed + 1, 0) end
        end
        y = y + vy
        if y < -0.0001 then vy = vy + gravity else y, vy = 0, 0 end
        local list = t >= first and move.hits[t]
        if list then
            local ahead = t - from_tick
            local shift_x = moving and defender.vx * (ahead + 1) or 0
            local depth = az - (defender.z + (moving and defender.vz * (ahead + 1) or 0))
            for _, box in ipairs(list) do
                if perception.hurting[box.kind] and box.effect ~= constants.effects.skip_characters
                   and depth < box.zwidth and depth > -box.zwidth and touches(box, defender) then
                    local x0, x1
                    if direction > 0 then x0, x1 = x + box.x0, x + box.x1 else x0, x1 = x - box.x1, x - box.x0 end
                    if overlaps_body(defender, x0, x1, y + box.y0, y + box.y1, shift_x) then return ahead, box, t end
                end
            end
        end
    end
    return nil
end

-- The first tick on which a flying object (a ball, a thrown weapon) hits `defender` at its current speed, with the
-- hit boxes of its current frame. The physics moves it before combat.detect, so tick k sees it k + 1 steps ahead.
function predict.ball_hit(ball, defender, horizon)
    horizon = horizon or predict.horizon
    for k = earliest(ball, defender), horizon do
        local dx, dz = ball.vx * (k + 1), ball.vz * (k + 1)
        local depth = ball.z + dz - defender.z
        for _, box in ipairs(ball.hits) do
            if box.damaging and depth < box.zwidth and depth > -box.zwidth and touches(box, defender)
               and overlaps_body(defender, box.x0 + dx, box.x1 + dx, box.y0 + ball.vy * (k + 1), box.y1 + ball.vy * (k + 1), 0) then
                return k, box
            end
        end
    end
    return nil
end

-- The first tick on which a held weapon (a perception entry with `holder`) hits `defender` while its holder goes on
-- with its move. The weapon hurts only on the holder's frames whose wpoint `attacking` is above 0, with the weapon's
-- strength entry of that number (base/game/combat weapon_strike), and it follows the holder by base/game/weapons
-- carry.
function predict.weapon_hit(weapon, holder, defender, horizon)
    local move = holder.move
    if not move then return nil end
    horizon = horizon or predict.horizon
    local frames, strengths = holder.record.data.frames, weapon.record.data.strengths or {}
    local direction = holder.facing == facing_left and -1 or 1
    local base = holder.move_tick > 1 and (move.forward[holder.move_tick - 1] or 0) or 0
    local first = earliest(weapon, defender)
    for t = holder.move_tick + first, math.min(move.ticks, holder.move_tick + horizon) do
        local frame = frames[move.frames[t]]
        local point = frame and frame.wpoint
        local strength = point and point.attacking > 0 and strengths[point.attacking]
        local own = strength and weapon.record.frame(point.weaponact)
        if own and #own.interactions > 0 then
            local hx = holder.x + direction * ((move.forward[t] or 0) - base)
            local x, wx
            if direction > 0 then
                x = hx - frame.center_x + point.x
                wx = own.center_x - own.wpoint.x + x
            else
                x = frame.center_x - point.x + hx
                wx = own.wpoint.x - own.center_x + x
            end
            local wy = own.center_y - own.wpoint.y + (holder.y - frame.center_y + point.y)
            local zwidth = (strength.zwidth or 0) ~= 0 and strength.zwidth or constants.combat.default_zwidth
            local depth = holder.z - defender.z
            local fake = {fall = strength.fall or 0}
            if depth < zwidth and depth > -zwidth and touches(fake, defender) then
                for _, itr in ipairs(own.interactions) do
                    if itr.kind == constants.attack_kinds.held_item then
                        local x0, x1, y0, y1 = perception.world_box(own, itr, wx, wy, holder.facing)
                        if overlaps_body(defender, x0, x1, y0, y1, 0) then
                            return t - holder.move_tick, {injury = strength.injury or 0, fall = strength.fall or 0,
                                bdefend = strength.bdefend or 0}
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- The threats to `self` (a perception entry) within `horizon` ticks, the soonest first: {source, ticks, damage,
-- fall, bdefend, ball, move (start frame or 0)}. An attacking character counts with the rest of its move, a flying
-- object with its speed. `known` (optional) filters the sources that the brain has noticed (base/ai/senses).
function predict.threats(state, world, self, horizon, known)
    local result = {}
    if #self.bodies == 0 then return result end
    for _, other in ipairs(world.list) do
        if perception.hostile(state, self, other) and (not known or known(other)) then
            local ticks, box
            if other.character and other.move then
                ticks, box = predict.move_hit(other, other.move, other.move_tick, other.facing, self, horizon)
            elseif other.ball then
                ticks, box = predict.ball_hit(other, self, horizon)
            elseif other.holder then
                local holder = world.entries[other.holder]
                if holder and holder.character and holder.index ~= self.index then
                    ticks, box = predict.weapon_hit(other, holder, self, horizon)
                end
            end
            if ticks then
                result[#result + 1] = {source = other.index, ticks = ticks, damage = box.injury, fall = box.fall,
                    bdefend = box.bdefend, ball = other.ball, move = other.move and other.move.start
                        or (other.holder and world.entries[other.holder] and world.entries[other.holder].move
                            and world.entries[other.holder].move.start) or 0}
            end
        end
    end
    table.sort(result, function(a, b)
        if a.ticks ~= b.ticks then return a.ticks < b.ticks end
        return a.source < b.source
    end)
    return result
end

-- The ticks during which `entry` cannot act: the rest of its hurt, fall, lying or recovery, or of its move. -1 when
-- the frames hold (the engine decides when it gets up), 0 when it is free.
function predict.opening(entry)
    if not entry.character then return 0 end
    local class = entry.class
    if class == "free" or class == "moving" then return 0 end
    if class == "attacking" and entry.move then return math.max(entry.move.ticks - entry.move_tick, 0) end
    return entry.free_in
end

-- If `self` starts `move` on this tick, facing `target`: the tick of the first hit (nil when it misses), whether the
-- hit is sure (the target cannot act before it), and the damage.
function predict.hit_chance(self, move, target, horizon)
    local facing = target.x < self.x and facing_left or constants.facings.right
    local ticks, box = predict.move_hit(self, move, 1, facing, target, horizon or move.ticks, true)
    if not ticks then return nil end
    local opening = predict.opening(target)
    return ticks, opening < 0 or ticks < opening, box.injury
end

-- The punish risk of `move` for `self`: the most damage that a hostile character can do before `self` can act
-- again, if the move misses. An enemy needs the time to run into reach of its fastest close move, and that move's
-- start-up. Returns the damage and the enemy (nil when nobody can punish).
function predict.risk(state, world, self, move)
    local busy = move.ticks
    local worst, who = 0, nil
    for _, other in ipairs(world.list) do
        if other.character and other.hp > 0 and perception.hostile(state, self, other) then
            local delay = predict.opening(other)
            if delay >= 0 then
                local speed = (other.book.movement.running_speed or 9)
                for _, candidate in ipairs(other.book.moves) do
                    if candidate.kind == "basic" and candidate.first_hit and candidate.damage > 0 and candidate.mp == 0 then
                        local gap = math.max(math.abs(other.x - self.x) - candidate.reach, 0)
                        local arrive = delay + math.ceil(gap / speed) + candidate.first_hit
                        if arrive <= busy and math.abs(other.z - self.z) < 40 and candidate.damage > worst then
                            worst, who = candidate.damage, other.index
                        end
                    end
                end
            end
        end
    end
    return worst, who
end
return predict
