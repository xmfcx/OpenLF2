-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Perception of the AI (OpenLF2 extension, docs/ai-plan.md "Perception"): one snapshot of the fight for each tick,
-- built before the first brain that asks for it and kept in the tick's scan (ai.prepare), never in the match table.
-- A brain reads the snapshot and must not keep its tables in its memory, because the next tick builds new ones.
--
-- An entry: {index, kind (constants.record_kinds), id, team, x, y, z, vx, vy, vz, facing, frame, state, wait_counter,
--   hp, mp, blink, owner, attack_rest, rest, character, ball, item, book, class, free_in, move, move_tick, bodies,
--   hits, record, holder}. `attack_rest` is the attacker's rest after its last hit (timer_ec), `rest` the item's pair
--   rests by attacker index (base/game/combat), `record` the item's record: read only. `holder` is the index of the
--   character that holds a weapon (state held_item), or nil.
-- `move` and `move_tick` place a character in its move book (the move and the timeline index of this tick). `bodies`
-- and `hits` are the boxes of the current frame in world coordinates: {x0, x1, y0, y1} and, for hits, the fields of
-- a move book hit box. x1 and y1 are exclusive, like base/game/collision.
local constants = require("base/game/constants")
local move_book = require("base/ai/move_book")
local record_kinds = constants.record_kinds
local states = constants.frame_states
local attack_kinds = constants.attack_kinds
local default_zwidth = constants.combat.default_zwidth
local perception = {}

-- Frame states of objects that move on their own and hurt on contact.
local flying = {[states.flying_ball] = true, [states.ball_hiting] = true, [states.rebound_ball] = true,
    [states.flying_missile] = true, [states.vanishing_ball] = true, [states.thrown_item] = true,
    [states.flying_heavy_item] = true}
perception.hurting = {[attack_kinds.plain] = true, [attack_kinds.thrown_body] = true, [attack_kinds.held_item] = true,
    [attack_kinds.super_window] = true, [attack_kinds.whirlwind] = true, [attack_kinds.conditional_whirlwind] = true,
    [attack_kinds.pulling_whirlwind] = true, [attack_kinds.freezing_whirlwind] = true}

-- The world box of `region` (a body or an interaction of the frame) of an item at x, y facing `facing`.
local function world_box(frame, region, x, y, facing)
    local x0
    if facing == constants.facings.left then x0 = frame.center_x + x - region.width - region.x
    else x0 = region.x + x - frame.center_x end
    local y0 = region.y + y - frame.center_y
    return x0, x0 + region.width, y0, y0 + region.height
end
perception.world_box = world_box

local function boxes(value, frame)
    local bodies, hits = {}, {}
    for _, body in ipairs(frame.bodies) do
        local x0, x1, y0, y1 = world_box(frame, body, value.x_int, value.y_int, value.facing)
        bodies[#bodies + 1] = {x0 = x0, x1 = x1, y0 = y0, y1 = y1}
    end
    for _, itr in ipairs(frame.interactions) do
        local x0, x1, y0, y1 = world_box(frame, itr, value.x_int, value.y_int, value.facing)
        hits[#hits + 1] = {x0 = x0, x1 = x1, y0 = y0, y1 = y1, kind = itr.kind, injury = itr.injury, fall = itr.fall,
            bdefend = itr.bdefend, effect = itr.effect, zwidth = itr.zwidth ~= 0 and itr.zwidth or default_zwidth,
            damaging = perception.hurting[itr.kind] == true and itr.effect ~= constants.effects.skip_characters}
    end
    return bodies, hits
end

local function entry_of(state, index, value)
    local frame = value.record.frame(value.frame)
    local kind = value.record.kind
    local entry = {index = index, kind = kind, id = value.record.id, team = value.team, x = value.x_int, y = value.y_int,
        z = value.z_int, vx = value.vx, vy = value.vy, vz = value.vz, facing = value.facing, frame = value.frame,
        state = frame.state, wait_counter = value.wait_counter, hp = value.hp, mp = value.mp, blink = value.blink,
        owner = value.owner, attack_rest = value.timer_ec, rest = value.pair_rest, record = value.record,
        holder = frame.state == states.held_item and value.holder or nil,
        character = kind == record_kinds.character, ball = flying[frame.state] == true,
        item = kind ~= record_kinds.character and not flying[frame.state]}
    entry.bodies, entry.hits = boxes(value, frame)
    if entry.character then
        local book = move_book.get(value.record)
        entry.book = book
        entry.class = book.class[value.frame] or "busy"
        local free = book.free_in[value.frame] or -1
        entry.free_in = free >= 0 and math.max(free - value.wait_counter, 0) or -1
        local at = book.move_at[value.frame]
        if at and entry.class == "attacking" then entry.move, entry.move_tick = at.move, at.tick + value.wait_counter end
    end
    return entry
end

-- The snapshot of the fight on this tick: {tick, entries = {[index] = entry}, list = {entry...} in slot order,
-- by_x = the list sorted by x}.
function perception.world(state, scan)
    local world = scan.world
    if world then return world end
    world = {tick = state.frame_number, entries = {}, list = {}}
    for position = 1, #scan.slots do
        local index = scan.slots[position]
        local value = state.items[index]
        if value then
            local entry = entry_of(state, index, value)
            world.entries[index] = entry
            world.list[#world.list + 1] = entry
        end
    end
    local by_x = {}
    for position, entry in ipairs(world.list) do by_x[position] = entry end
    table.sort(by_x, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.index < b.index
    end)
    world.by_x = by_x
    scan.world = world
    return world
end

-- Whether `other` can hurt `self` (base/game/ai hostile, and different teams for balls and items). Independent
-- fighters have their own team (base/game/match gives each one slot_offset + index).
function perception.hostile(state, self, other)
    if other.index == self.index then return false end
    if other.team == self.team then return false end
    return true
end
return perception
