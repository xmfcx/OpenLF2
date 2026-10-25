-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Perception of the AI (OpenLF2 extension, docs/ai-plan.md "Perception and senses"): one snapshot of the fight for
-- each tick, built before the first brain that asks for it and kept in the tick's scan (ai.prepare), never in the
-- match table. The snapshot reuses its tables from tick to tick (a pool), so it makes no new tables in a long fight. A
-- brain reads it and must not keep its tables in its memory, because the next build overwrites them.
--
-- An entry: {index, kind (constants.record_kinds), id, team, x, y, z, vx, vy, vz, facing, frame, state, wait_counter,
--   hp, mp, blink, owner, born, attack_rest, rest, record, holder, character, ball, item, book, class, free_in, move,
--   move_tick, bodies, hits, body_count, hit_count}.
-- `move` and `move_tick` place a character in its move book (the move and the timeline index of this tick). `bodies`
-- and `hits` are the boxes of the current frame in world coordinates: {x0, x1, y0, y1} and, for hits, the fields of a
-- move book hit box. x1 and y1 are exclusive, like base/game/collision. `team` of a held weapon is its holder's team,
-- like base/game/combat. `attack_rest` is the rest after the last hit (timer_ec), `rest` the pair rests by attacker
-- index, `record` the item's record: read only. `holder` is the index of the character that holds a weapon.
local constants = require("base/game/constants")
local move_book = require("base/ai/move_book")
local record_kinds = constants.record_kinds
local states = constants.frame_states
local teams = constants.teams
local attack_kinds = constants.attack_kinds
local default_zwidth = constants.combat.default_zwidth
local perception = {}

-- Frame states of objects that move on their own and hurt on contact.
local flying = {[states.flying_ball] = true, [states.ball_hiting] = true, [states.rebound_ball] = true,
    [states.flying_missile] = true, [states.vanishing_ball] = true, [states.thrown_item] = true,
    [states.flying_heavy_item] = true}
perception.flying = flying
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

-- The pool: the world table and its entries live from tick to tick.
local world = {tick = -1, entries = {}, list = {}, by_x = {}}
local pool = {}

local function fill_boxes(entry, value, frame)
    local bodies, hits = entry.bodies, entry.hits
    local count = 0
    for _, body in ipairs(frame.bodies) do
        count = count + 1
        local box = bodies[count]
        if not box then box = {}; bodies[count] = box end
        box.x0, box.x1, box.y0, box.y1 = world_box(frame, body, value.x_int, value.y_int, value.facing)
    end
    for position = count + 1, #bodies do bodies[position] = nil end
    entry.body_count = count
    count = 0
    for _, itr in ipairs(frame.interactions) do
        count = count + 1
        local box = hits[count]
        if not box then box = {}; hits[count] = box end
        box.x0, box.x1, box.y0, box.y1 = world_box(frame, itr, value.x_int, value.y_int, value.facing)
        box.kind, box.injury, box.fall, box.bdefend, box.effect = itr.kind, itr.injury, itr.fall, itr.bdefend, itr.effect
        box.zwidth = itr.zwidth ~= 0 and itr.zwidth or default_zwidth
        box.damaging = perception.hurting[itr.kind] == true and itr.effect ~= constants.effects.skip_characters
    end
    for position = count + 1, #hits do hits[position] = nil end
    entry.hit_count = count
end

local function fill_entry(entry, state, index, value)
    local frame = value.record.frame(value.frame)
    local kind = value.record.kind
    entry.index, entry.kind, entry.id, entry.team = index, kind, value.record.id, value.team
    entry.x, entry.y, entry.z, entry.vx, entry.vy, entry.vz = value.x_int, value.y_int, value.z_int, value.vx, value.vy, value.vz
    entry.facing, entry.frame, entry.state, entry.wait_counter = value.facing, value.frame, frame.state, value.wait_counter
    entry.hp, entry.mp, entry.blink, entry.owner, entry.born = value.hp, value.mp, value.blink, value.owner, value.born or 0
    entry.attack_rest, entry.rest, entry.record = value.timer_ec, value.pair_rest, value.record
    entry.guard = value.timer_b8 or 0 -- the defend points that the last hits added (a defend breaks at 31)
    -- The stage's edges in x: a fighter that walks into one does not move on (prediction clamps to them).
    entry.x_max = (state.stage_bound or 0) > 0 and state.stage_bound or (state.stage.width or constants.screen.width)
    entry.holder = frame.state == states.held_item and value.holder or nil
    entry.character = kind == record_kinds.character
    entry.ball = flying[frame.state] == true
    entry.item = kind ~= record_kinds.character and not entry.ball
    if entry.holder then
        -- A held weapon spares its holder's team (base/game/combat eligible).
        local holder = state.items[entry.holder]
        entry.team = holder and holder.team or teams.independent
    end
    fill_boxes(entry, value, frame)
    entry.book, entry.class, entry.free_in, entry.move, entry.move_tick = nil, nil, 0, nil, nil
    if entry.character then
        local book = move_book.get(value.record)
        entry.book = book
        entry.class = book.class[value.frame] or "busy"
        local free = book.free_in[value.frame] or -1
        entry.free_in = free >= 0 and math.max(free - value.wait_counter, 0) or -1
        local at = book.move_at[value.frame]
        if at and entry.class == "attacking" then entry.move, entry.move_tick = at.move, at.tick + value.wait_counter end
    end
end

local function by_position(a, b)
    if a.x ~= b.x then return a.x < b.x end
    return a.index < b.index
end

-- The snapshot of the fight on this tick: {tick, entries = {[index] = entry}, list = {entry...} in slot order,
-- by_x = the list sorted by x}. It is rebuilt when the scan is new (a new tick, or a chasing ball that changed the
-- items), from the pool.
function perception.world(state, scan)
    if scan.world then return scan.world end
    local entries, list, by_x = world.entries, world.list, world.by_x
    for position = 1, #list do entries[list[position].index] = nil end
    local count = 0
    for position = 1, #scan.slots do
        local index = scan.slots[position]
        local value = state.items[index]
        if value then
            count = count + 1
            local entry = pool[count]
            if not entry then entry = {bodies = {}, hits = {}}; pool[count] = entry end
            fill_entry(entry, state, index, value)
            entries[index] = entry
            list[count] = entry
            by_x[count] = entry
        end
    end
    for position = count + 1, #list do list[position] = nil end
    for position = count + 1, #by_x do by_x[position] = nil end
    table.sort(by_x, by_position)
    world.tick = state.frame_number
    scan.world = world
    return world
end

-- The past of the fight (docs/ai-plan.md "Perception and senses", the delayed view): the match keeps the last
-- `past_depth` ticks of every character in `state.ai_past` (in the match table, so a rollback restores it), and a
-- brain with a reaction of R ticks sees the characters as they were R ticks ago. Flying objects and weapons stay in
-- the present: the senses delay a brain's notice of them instead. The match records the past only when a brain other
-- than classic plays, so classic fights do not change.
local past_depth, past_fields = 13, 10
perception.past_depth = past_depth

-- Called once per tick before the brains (base/game/match read_input): the state of each character at the start of
-- the tick.
function perception.record_past(state)
    local past = state.ai_past
    if not past then
        past = {slots = {}}
        state.ai_past = past
    end
    local tick = state.frame_number
    past.tick = tick
    local base = (tick % past_depth) * past_fields
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value and value.record.kind == record_kinds.character then
            local ring = past.slots[index]
            if not ring then
                ring = {}
                for position = 1, past_depth * past_fields do ring[position] = 0 end
                ring[past_depth * past_fields + 1] = tick -- the first recorded tick
                past.slots[index] = ring
            end
            ring[base + 1], ring[base + 2], ring[base + 3] = value.x_int, value.y_int, value.z_int
            ring[base + 4], ring[base + 5], ring[base + 6] = value.vx, value.vy, value.vz
            ring[base + 7], ring[base + 8], ring[base + 9], ring[base + 10] = value.frame, value.wait_counter, value.facing, value.hp
        end
    end
end

local views = {} -- by reaction: {world = ..., pool = {...}}

local function fill_from_past(entry, present, ring, base, state)
    for key, value in pairs(present) do
        if key ~= "bodies" and key ~= "hits" then entry[key] = value end
    end
    entry.x, entry.y, entry.z = ring[base + 1], ring[base + 2], ring[base + 3]
    entry.vx, entry.vy, entry.vz = ring[base + 4], ring[base + 5], ring[base + 6]
    entry.frame, entry.wait_counter, entry.facing, entry.hp = ring[base + 7], ring[base + 8], ring[base + 9], ring[base + 10]
    local record = present.record
    local frame = record.frame(entry.frame)
    entry.state = frame.state
    local fake = {x_int = entry.x, y_int = entry.y, facing = entry.facing}
    fill_boxes(entry, fake, frame)
    local book = present.book
    entry.class = book.class[entry.frame] or "busy"
    local free = book.free_in[entry.frame] or -1
    entry.free_in = free >= 0 and math.max(free - entry.wait_counter, 0) or -1
    local at = book.move_at[entry.frame]
    entry.move, entry.move_tick = nil, nil
    if at and entry.class == "attacking" then entry.move, entry.move_tick = at.move, at.tick + entry.wait_counter end
end

-- The world as a brain with a reaction of `reaction` ticks sees it: the characters other than `self_index` as they
-- were then (or as early as the past goes), everything else as now. Built once per tick and reaction, from a pool.
-- `view.delay` is the number of ticks that the view is old: prediction from it counts that many ticks less.
function perception.view(state, scan, reaction, self_index)
    local present = perception.world(state, scan)
    local past = state.ai_past
    if reaction <= 0 or not past then return present end
    scan.views = scan.views or {}
    local key = reaction * 1000 + self_index
    local cached = scan.views[key]
    if cached then return cached end
    local holder = views[key]
    if not holder then
        holder = {world = {entries = {}, list = {}, by_x = {}}, pool = {}}
        views[key] = holder
    end
    local view, pool = holder.world, holder.pool
    for position = 1, #view.list do view.entries[view.list[position].index] = nil end
    local count, delay = 0, 0
    for _, entry in ipairs(present.list) do
        count = count + 1
        local ring = entry.character and entry.index ~= self_index and past.slots[entry.index]
        local copy = pool[count]
        if not copy then copy = {bodies = {}, hits = {}}; pool[count] = copy end
        if ring then
            local first = ring[past_depth * past_fields + 1]
            local tick = math.max(state.frame_number - reaction, first, state.frame_number - past_depth + 1)
            fill_from_past(copy, entry, ring, (tick % past_depth) * past_fields, state)
            delay = math.max(delay, state.frame_number - tick)
        else
            for key_name, value in pairs(entry) do
                if key_name ~= "bodies" and key_name ~= "hits" then copy[key_name] = value end
            end
            local bodies, hits = copy.bodies, copy.hits
            for position = 1, math.max(#bodies, #entry.bodies) do bodies[position] = entry.bodies[position] end
            for position = 1, math.max(#hits, #entry.hits) do hits[position] = entry.hits[position] end
        end
        view.entries[copy.index] = copy
        view.list[count] = copy
        view.by_x[count] = copy
    end
    for position = count + 1, #view.list do view.list[position], view.by_x[position] = nil, nil end
    table.sort(view.by_x, by_position)
    view.tick, view.delay = state.frame_number, delay
    scan.views[key] = view
    return view
end

-- Whether `other` can hurt `self` in combat: another item of another team (a held weapon has its holder's team).
-- Independent fighters have their own team (base/game/match gives each one slot_offset + index).
function perception.can_hurt(state, self, other)
    if other.index == self.index then return false end
    return other.team ~= self.team
end
perception.hostile = perception.can_hurt

-- Whether `other` is an enemy of `self` for the choice of a target: the classic AI's rule (base/game/ai hostile). In
-- Stage mode only the stage's enemies and the players fight each other, and players of different teams do not.
function perception.enemy(state, self, other)
    if other.index == self.index then return false end
    local mine, theirs = self.team, other.team
    local stage = state.mode == constants.modes.stage
    return (theirs ~= mine and (not stage or mine == teams.enemies))
        or (theirs == teams.enemies and stage and theirs ~= mine)
end
return perception
