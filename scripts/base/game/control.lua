-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local combo_jump_attack = constants.combo_indices.jump_attack
local combo_right_attack = constants.combo_indices.right_attack
local sequence_defend_pressed = constants.combo_states.defend_pressed
local sequence_idle = constants.combo_states.idle
local sequence_second_pressed = constants.combo_states.second_pressed
local facing_left = constants.facings.left
local facing_right = constants.facings.right
local fusion_merged = constants.fusion_states.merged
local input_history_length = constants.input.history_length
local input_press_frames = constants.input.press_frames
local input_run_double_tap_frames = constants.input.run_double_tap_frames
local record_kinds = constants.record_kinds
local character_frames = constants.character_frames
local none = constants.weapon_holder_codes.none
local velocity_encoding = constants.velocity_encoding
local move_cost_encoding = constants.move_cost_encoding
local sounds = require("base/game/sounds")
local control = {}

local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
local function cmod(a, b) return a - cdiv(a, b) * b end

local press_fields = {"attack_press", "jump_press", "defend_press", "right_press", "left_press",
    "up_press", "down_press"}
local function clear_presses(value)
    for _, field in ipairs(press_fields) do value[field] = 0 end
end

function control.enter_frame(match, value, target)
    local turn = false
    if target < 0 then
        target = -target
        turn = true
    end
    if target == constants.frame_selectors.return_to_standing then target = 0 end
    local frame = value.record.frames[target]
    if not frame then return end
    if not match.running then
        value.frame = target
        clear_presses(value)
        return
    end
    local cost = frame.mp
    local mp_cost = cmod(cost, move_cost_encoding.hp_radix)
    local hp_cost = cdiv(cost, move_cost_encoding.hp_radix) * move_cost_encoding.hp_unit
    if value.mp >= mp_cost and value.hp > hp_cost then
        value.hp = value.hp - hp_cost
        value.mp = value.mp - mp_cost
        value.hp_spent = value.hp_spent + hp_cost
        value.mp_spent = value.mp_spent + mp_cost
        value.frame = target
        if turn then value.facing = 1 - value.facing end
        clear_presses(value)
    end
end

local exclusions = {U = "up_press", D = "down_press", L = "left_press", R = "right_press",
    d = "defend_press", j = "jump_press", a = "attack_press"}
local function interrupted(value, expected, advanced)
    for _, field in ipairs(press_fields) do
        if value[field] == input_press_frames and (not advanced or field ~= exclusions[expected]) then return true end
    end
    return false
end

-- Defend, then a direction or jump, then attack or jump. `hit` names the frame field holding
-- the target frame; `facing` is forced for left/right sequences.
local sequences = {
    {"right_press", "R", "attack_press", "a", "Fa", facing_right},
    {"left_press", "L", "attack_press", "a", "Fa", facing_left},
    {"up_press", "U", "attack_press", "a", "Ua"},
    {"down_press", "D", "attack_press", "a", "Da"},
    {"right_press", "R", "jump_press", "j", "Fj", facing_right},
    {"left_press", "L", "jump_press", "j", "Fj", facing_left},
    {"up_press", "U", "jump_press", "j", "Uj"},
    {"down_press", "D", "jump_press", "j", "Dj"},
    {"jump_press", "j", "attack_press", "a", "ja"},
}
-- Whether a chord of defend (d), jump (j) and attack (a) ("da", "dj", "daj") could start
-- a move for `value`'s fighter in its current frame, whatever the direction: D+A is any of the
-- Defend, direction, Attack sequences (hit_Fa, hit_Ua, hit_Da), D+J likewise with Jump (hit_Fj,
-- hit_Uj, hit_Dj), and D+J+A is hit_ja.
local chord_hits = {da = {"Fa", "Ua", "Da"}, dj = {"Fj", "Uj", "Dj"}, daj = {"ja"}}
function control.chord_available(value, chord)
    local fields = value and chord_hits[chord]
    if not fields then return false end
    -- The sequence begins with Defend, which moves the fighter to the frame its hit_d names (the
    -- defend stance): walking and running frames often carry no combo fields themselves.
    local frame = value.record.frame(value.frame)
    local candidates = {frame.hits}
    if frame.hits.d ~= 0 then candidates[2] = value.record.frame(frame.hits.d).hits end
    for _, hits in ipairs(candidates) do
        for _, field in ipairs(fields) do
            if hits[field] ~= 0 and value.weapon ~= record_kinds.heavy_item and (field ~= "ja" or value.transform == -1) then return true end
        end
    end
    return chord == "daj" and value.twin == fusion_merged
end
local completed_sequence = constants.combo_states.complete
local function recognize(match, value, index)
    local spec = sequences[index]
    local state = value.sequences[index]
    local advanced = false
    if state == sequence_idle and value.defend_press == input_press_frames then state, advanced = sequence_defend_pressed, true end
    if state == sequence_defend_pressed then
        if value[spec[1]] == input_press_frames then state, advanced = sequence_second_pressed, true
        elseif interrupted(value, "d", advanced) then state = sequence_idle end
    end
    if state == sequence_second_pressed then
        if value[spec[3]] == input_press_frames then state, advanced = completed_sequence, true
        elseif interrupted(value, spec[2], advanced) then state = sequence_idle end
    end
    if state == completed_sequence then
        local frame = value.record.frame(value.frame)
        local target = frame.hits[spec[5]]
        if index == combo_jump_attack then
            if value.record.id == constants.fighter_ids.louis and target == 300 and value.hp > 177 and not match.free_transform then
                value.sequences[index] = state
                return
            end
            if target ~= 0 and value.transform == -1 and value.weapon ~= record_kinds.heavy_item then
                control.enter_frame(match, value, target)
                value.sequences[index] = sequence_idle
                return
            end
            if value.twin == fusion_merged then
                value.merge_timer = 0
                value.sequences[index] = state
                return
            end
        elseif target ~= 0 and value.weapon ~= record_kinds.heavy_item then
            control.enter_frame(match, value, target)
            if spec[6] then value.facing = spec[6] end
            value.sequences[index] = sequence_idle
            return
        end
        if interrupted(value, spec[4], advanced) then state = sequence_idle end
    end
    value.sequences[index] = state
end

-- Walk/heavy-walk animation phase: frames base, base+1 ... base+3, back down.
local function walk_cycle(value, base)
    local rate = value.record.movement.walking_frame_rate or 1
    value.walk_phase = (value.walk_phase + 1) % (rate * 6)
    if value.walk_phase < rate * 4 then value.frame = cdiv(value.walk_phase, rate) + base
    else value.frame = base + 6 - cdiv(value.walk_phase, rate) end
end

local function spend_mp(match, value, frame_id)
    if not match.running then return end
    local cost = value.record.frame(frame_id).mp
    value.mp = value.mp - cost
    if value.mp < 0 then value.mp = 0 else value.mp_spent = value.mp_spent + cost end
end

-- States 0/1 (standing, walking). `heavy` selects the heavy-weapon variant.
local function walking(match, value, heavy)
    local keys, previous, movement = value.keys, value.previous_keys, value.record.movement
    local base = heavy and character_frames.heavy_walking or character_frames.walking
    local run_frame = heavy and character_frames.heavy_running or character_frames.running
    local speed = (heavy and movement.heavy_walking_speed or movement.walking_speed) or 0
    local speedz = (heavy and movement.heavy_walking_speedz or movement.walking_speedz) or 0
    if value.dash_counter > 0 then value.dash_counter = value.dash_counter - 1 end
    if value.dash_counter < 0 then value.dash_counter = value.dash_counter + 1 end
    if heavy and value.frame < character_frames.heavy_walking then value.frame = character_frames.heavy_walking end
    if keys.right and not keys.left and value.y_int == 0 then
        if value.facing == facing_left then value.dash_counter = 0 end
        value.facing = facing_right
        walk_cycle(value, base)
        value.vx = speed
        -- A second fresh press within ten frames starts running.
        if not previous.right then value.dash_counter = value.dash_counter + input_run_double_tap_frames end
        if value.dash_counter >= input_run_double_tap_frames + 1 then
            value.frame = run_frame
            value.walk_phase, value.dash_counter = 0, 0
        end
    end
    if not keys.right and keys.left and value.y_int == 0 then
        if value.facing == facing_right then value.dash_counter = 0 end
        value.facing = facing_left
        walk_cycle(value, base)
        value.vx = -speed
        if not previous.left then value.dash_counter = value.dash_counter - input_run_double_tap_frames end
        if value.dash_counter <= -(input_run_double_tap_frames + 1) then
            value.frame = run_frame
            value.walk_phase, value.dash_counter = 0, 0
        end
    end
    local sideways = keys.left == keys.right
    if keys.up and not keys.down and value.y_int == 0 then
        if sideways then walk_cycle(value, base) end
        value.vz = -speedz
        value.vx = value.vx / 1.4
    end
    if keys.down and not keys.up and value.y_int == 0 then
        if sideways then walk_cycle(value, base) end
        value.vz = speedz
        value.vx = value.vx / 1.4
    end
    if keys.attack and value.attack_press > 0 then
        value.dash_counter, value.wait_counter = 0, 0
        if heavy then
            value.frame = character_frames.heavy_weapon_throw
        elseif value.weapon == none then
            if value.super_window > 0 then value.frame = character_frames.super_punch
            else
                value.frame = (engine.random(2) + 12) * 5
                spend_mp(match, value, value.frame)
            end
        elseif value.weapon % 100 == 1 then
            if value.weapon == constants.weapon_holder_codes.knife_or_boomerang
               and (keys.right or keys.left or keys.up or keys.down) then
                value.frame = character_frames.light_weapon_throw
            else
                value.frame = (engine.random(2) + 4) * 5
            end
        elseif value.weapon == record_kinds.baseball then value.frame = character_frames.light_weapon_throw
        elseif value.weapon == record_kinds.drink then value.frame = character_frames.drinking end
    end
    if heavy then return end
    if keys.jump and value.jump_press > 0 then
        value.wait_counter, value.dash_counter = 0, 0
        value.frame = character_frames.jump
    end
    if keys.defend and value.defend_lock == 0 and value.defend_press > 0 then
        value.dash_counter, value.wait_counter = 0, 0
        value.frame = character_frames.defend
    end
end

-- State 2 (running), also with a heavy weapon.
local function running(match, value, heavy)
    local keys, movement = value.keys, value.record.movement
    local rate = movement.running_frame_rate or 1
    value.wait_counter = 0
    value.walk_phase = (value.walk_phase + 1) % (rate * 4)
    local first, speed, speedz, brake
    if heavy then first, speed, speedz, brake = 16, movement.heavy_running_speed, movement.heavy_running_speedz, 19
    else first, speed, speedz, brake = 9, movement.running_speed, movement.running_speedz, 218 end
    if value.walk_phase < rate * 3 then value.frame = cdiv(value.walk_phase, rate) + first
    else value.frame = first + 1 end
    speed, speedz = speed or 0, speedz or 0
    if value.facing == facing_right then
        value.vx = speed
        if keys.left then value.frame = brake end
    end
    if value.facing == facing_left then
        value.vx = -speed
        if keys.right then value.frame = brake end
    end
    if keys.up and not keys.down and value.y_int == 0 then
        value.vz = -speedz
        value.vx = value.vx / 1.2
    end
    if not keys.up and keys.down and value.y_int == 0 then
        value.vz = speedz
        value.vx = value.vx / 1.2
    end
    local directions = keys.left or keys.right or keys.up or keys.down
    if keys.attack and value.attack_press > 0 then
        if heavy then value.frame = character_frames.heavy_weapon_throw
        elseif value.weapon == none then
            if not match.running then value.frame = character_frames.run_attack
            elseif value.mp >= value.record.frame(character_frames.run_attack).mp then
                local cost = value.record.frame(character_frames.run_attack).mp
                value.mp = value.mp - cost
                value.mp_spent = value.mp_spent + cost
                value.frame = character_frames.run_attack
            end
        elseif value.weapon % 100 == 1 then value.frame = directions and character_frames.light_weapon_throw or character_frames.run_weapon_attack
        elseif value.weapon == record_kinds.baseball then value.frame = character_frames.light_weapon_throw
        elseif value.weapon == record_kinds.drink then value.frame = directions and character_frames.light_weapon_throw or character_frames.drinking end
    end
    if heavy then return end
    if keys.defend and value.defend_press > 0 then value.frame = character_frames.rowing + 2 end
    if keys.jump and value.jump_press > 0 then
        sounds.effect(match, value.x_int, 7)
        value.dash_counter = 0
        value.frame = character_frames.dash
        value.vx = (1 - 2 * value.facing) * (movement.dash_distance or 0)
        value.vy = movement.dash_height or 0
        if keys.up and not keys.down then value.vz = -(movement.dash_distancez or 0)
        elseif not keys.up and keys.down then value.vz = movement.dash_distancez or 0 end
    end
end

-- State 4 in the air: turn and attack.
local function jumping(match, value)
    local keys = value.keys
    if keys.right and not keys.left then value.facing = facing_right end
    if keys.left and not keys.right then value.facing = facing_left end
    if not keys.attack then return end
    if value.weapon == none then
        value.wait_counter = 0
        value.frame = character_frames.jump_attack
        spend_mp(match, value, 80)
    elseif value.weapon % 100 == 1 then
        value.wait_counter = 0
        local directions = keys.left or keys.right or keys.up or keys.down
        value.frame = directions and character_frames.jump_light_weapon_throw or character_frames.jump_weapon_attack
    elseif value.weapon == record_kinds.baseball or value.weapon == record_kinds.drink then
        value.frame = character_frames.jump_light_weapon_throw
    end
end

-- Frame 215 (landing crouch): defend rolls, jump dashes in the held or moving direction.
local function crouching(match, value)
    local keys, movement = value.keys, value.record.movement
    if keys.defend and value.defend_press > 0 then value.frame = character_frames.rowing + 2 end
    if keys.jump and (keys.right or 0.001 < value.vx) and value.jump_press > 0 then
        sounds.effect(match, value.x_int, 7)
        value.frame = character_frames.dash + value.facing
        value.dash_counter = 0
        value.vx = movement.dash_distance or 0
        value.vy = movement.dash_height or 0
    end
    if keys.jump and (keys.left or -0.001 > value.vx) and value.jump_press > 0 then
        sounds.effect(match, value.x_int, 7)
        value.frame = character_frames.dash + 1 - value.facing
        value.dash_counter = 0
        value.vx = -(movement.dash_distance or 0)
        value.vy = movement.dash_height or 0
    end
    if keys.up and not keys.down then value.vz = -(movement.dash_distancez or 0)
    elseif not keys.up and keys.down then value.vz = movement.dash_distancez or 0 end
end

local function recovering(value)
    local keys, movement = value.keys, value.record.movement
    if not (value.fall_damage >= 0 and keys.jump and value.jump_press > 0 and value.hp > 0) then return end
    if value.facing == facing_right then value.frame = value.vx <= 0.0 and 100 or 108
    else value.frame = value.vx >= 0.0 and 100 or 108 end
    value.wait_counter = 0
    local height, distance = movement.rowing_height or 0, movement.rowing_distance or 0
    if height < value.vy then value.vy = height end
    if value.vx < 1.0 and value.vx > -1.0 then
        value.vx = value.facing == facing_left and distance or -distance
    else
        value.vx = value.vx > 0.0 and distance or -distance
    end
end

-- State 5 (dashing): turning picks the forward/backward dash frame; attacking only forward.
local function dashing(match, value)
    local keys = value.keys
    if keys.right and not keys.left then value.facing = facing_right end
    if value.facing == facing_right and value.frame ~= 217 and value.vx < 0.0 then value.frame = character_frames.dash + 1 end
    if value.facing == facing_right and value.frame ~= 216 and value.vx > 0.0 then value.frame = character_frames.dash end
    if keys.left and not keys.right then value.facing = facing_left end
    if value.facing == facing_left and value.frame ~= 217 and value.vx > 0.0 then value.frame = character_frames.dash + 1 end
    if value.facing == facing_left and value.frame ~= 216 and value.vx < 0.0 then value.frame = character_frames.dash end
    local forward = (value.vx > 0.0 and value.facing == facing_right) or (value.vx < 0.0 and value.facing == facing_left)
    if not forward or not keys.attack then return end
    local weapon = value.weapon
    if weapon == none then
        local cost = value.record.frame(character_frames.dash_attack).mp
        if not match.running then value.frame = character_frames.dash_attack
        elseif value.mp >= cost then
            value.mp = value.mp - cost
            value.mp_spent = value.mp_spent + cost
            value.frame = character_frames.dash_attack
        end
        return
    end
    local directions = keys.left or keys.right or keys.up or keys.down
    if weapon % 100 == 1 or ((weapon == record_kinds.baseball or weapon == record_kinds.drink) and directions) then
        value.frame = (weapon == record_kinds.baseball or weapon == record_kinds.drink) and character_frames.jump_light_weapon_throw or character_frames.dash_weapon_attack
        value.vy = value.vy - 1.0
        value.wait_counter = 0
    end
end

local function frame_velocity(value)
    local frame = value.record.frame(value.frame)
    local dvx = frame.dvx
    if dvx > velocity_encoding.absolute_threshold then value.vx = dvx - velocity_encoding.absolute_offset
    else
        if dvx > 0 and dvx > value.vx and value.facing == facing_right then value.vx = dvx end
        if dvx > 0 and -value.vx < dvx and value.facing == facing_left then value.vx = -dvx end
        if dvx < 0 and dvx < value.vx and value.facing == facing_right then value.vx = dvx end
        if dvx < 0 and -value.vx > dvx and value.facing == facing_left then value.vx = -dvx end
    end
    local dvy = frame.dvy
    if dvy ~= 0 then
        if dvy > velocity_encoding.absolute_threshold then value.vy = dvy - velocity_encoding.absolute_offset else value.vy = dvy + value.vy end
    end
    local dvz = frame.dvz
    if dvz ~= 0 then
        if dvz > velocity_encoding.absolute_threshold then value.vz = dvz - velocity_encoding.absolute_offset
        else
            if value.keys.up and value.up_press >= value.down_press then value.vz = -dvz end
            if value.keys.down and value.up_press <= value.down_press then value.vz = dvz end
        end
    end
end

local key_press = {right = "right_press", left = "left_press", up = "up_press", down = "down_press",
    defend = "defend_press", jump = "jump_press", attack = "attack_press"}
local press_order = {"right", "left", "up", "down", "defend", "jump", "attack"}
local key_codes = constants.key_history_codes

function control.step(match, value)
    for _, field in ipairs(press_fields) do
        if value[field] > 0 then value[field] = value[field] - 1 end
    end
    if value.defend_lock > 0 then value.defend_lock = value.defend_lock - 1 end
    for _, key in ipairs(press_order) do
        if not value.previous_keys[key] and value.keys[key] then
            value[key_press[key]] = input_press_frames
            local history = value.key_history
            table.remove(history, 1)
            history[input_history_length] = key_codes[key]
        end
    end
    for index = combo_right_attack, combo_jump_attack do recognize(match, value, index) end

    -- A frame's hit_a/hit_d/hit_j continue to another frame on the freshest key.
    local frame = value.record.frame(value.frame)
    local hits = frame.hits
    if hits.a ~= 0 and value.attack_press > value.defend_press and value.attack_press > value.jump_press then
        control.enter_frame(match, value, hits.a)
        value.attack_press = 0
    elseif hits.d ~= 0 and value.defend_press > value.attack_press and value.defend_press > value.jump_press then
        control.enter_frame(match, value, hits.d)
        value.defend_press = 0
    elseif hits.j ~= 0 and value.jump_press > value.attack_press and value.jump_press > value.defend_press then
        control.enter_frame(match, value, hits.j)
        value.jump_press = 0
    end
    if value.frame == character_frames.defend then
        if value.keys.right then value.facing = facing_right end
        if value.keys.left then value.facing = facing_left end
    end
    local movement = value.record.movement
    local state = value.record.frame(value.frame).state
    if state == constants.frame_states.deep_dash_sword or state == constants.frame_states.burning_run then
        if value.keys.up and not value.keys.down and value.y_int == 0 then value.vz = -(movement.running_speedz or 0) end
        if value.keys.down and not value.keys.up and value.y_int == 0 then value.vz = movement.running_speedz or 0 end
    end
    if value.weapon ~= record_kinds.heavy_item and (state == constants.frame_states.standing or state == constants.frame_states.walking) then walking(match, value, false) end
    state = value.record.frame(value.frame).state
    if value.weapon == record_kinds.heavy_item and (state == constants.frame_states.standing or state == constants.frame_states.walking) then walking(match, value, true) end
    state = value.record.frame(value.frame).state
    if state == constants.frame_states.jumping and value.y_int < 0 then jumping(match, value) end
    state = value.record.frame(value.frame).state
    if state == constants.frame_states.running and value.weapon ~= record_kinds.heavy_item then running(match, value, false) end
    state = value.record.frame(value.frame).state
    if state == constants.frame_states.running and value.weapon == record_kinds.heavy_item then running(match, value, true) end
    if value.frame == character_frames.crouch then crouching(match, value) end
    if value.frame == 182 or value.frame == 188 then recovering(value) end
    if value.record.frame(value.frame).state == constants.frame_states.dashing then dashing(match, value) end
    frame_velocity(value)
end
return control
