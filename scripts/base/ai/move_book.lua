-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The move book of the AI (OpenLF2 extension, docs/ai-plan.md "Move book"): what each move of a fighter does, read
-- once from the frames of its data file. It is fixed data: the cache holds it by the data table (base/game/
-- object_data shares one table for each file), outside the match table, so a rollback never copies it and the hash
-- never sees it. It reads nothing of a fight and changes nothing.
--
-- A book: {id, name, movement, moves = {move...}, by_start = {[frame] = move}, inputs = {[frame] = {entry...}},
--   class = {[frame] = class name}, free_in = {[frame] = ticks or -1},
--   move_at = {[frame] = {move = move, tick = timeline index of the frame's first tick}}}.
-- A move: {start, name, kind ("special", "basic", or "fragment" for an attacking chain that no move starts), inputs = {{input, sources = {frame...}}}, label, mp, hp, hold_mp,
--   ticks, first_hit, last_hit, active, recovery, reach, reach_back, high, low, damage, fall, bdefend, effect,
--   frames = {frame per tick}, hits = {hit boxes or false per tick}, body = {true or false per tick},
--   forward = {distance from the start per tick}, projectiles = {...}, follow = {{key, to, from_tick}...},
--   loops, holds, tags = {name = true}}.
-- A hit box: {kind, x0, x1, y0, y1, zwidth, injury, fall, bdefend, effect, dvx}, with x forward from the fighter's
-- center for a fighter that faces right and y up from the feet as negative numbers (base/game/collision).
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local states = constants.frame_states
local attack_kinds = constants.attack_kinds
local character_frames = constants.character_frames
local move_cost = constants.move_cost_encoding
local velocity_encoding = constants.velocity_encoding
local default_zwidth = constants.combat.default_zwidth
local return_to_standing = constants.frame_selectors.return_to_standing
local move_book = {}

-- The sequences of base/game/control: Defend, then a direction or Jump, then Attack or Jump.
move_book.combo_inputs = {{"Fa", "D>A"}, {"Ua", "D^A"}, {"Da", "DvA"}, {"Fj", "D>J"}, {"Uj", "D^J"}, {"Dj", "DvJ"}, {"ja", "DJA"}}
-- Frames that the engine enters without a frame field (base/game/control and the original's fixed numbers).
move_book.basic_moves = {
    {character_frames.punch, "A", "punch"}, {character_frames.punch + 5, "A", "punch 2"},
    {character_frames.super_punch, "A on a dizzy enemy", "super punch"}, {character_frames.jump_attack, "A in a jump", "jump attack"},
    {character_frames.run_attack, "A while running", "run attack"}, {character_frames.dash_attack, "A in a dash", "dash attack"},
    {character_frames.defend, "D", "defend"}, {character_frames.rowing + 2, "D in the air after a hit", "rowing"},
    {character_frames.catching, "walk into a dizzy enemy", "catch"},
    {character_frames.weapon_attack, "A with a light weapon", "weapon attack"},
    {character_frames.jump_weapon_attack, "A in a jump with a light weapon", "jump weapon attack"},
    {character_frames.run_weapon_attack, "A while running with a light weapon", "run weapon attack"},
    {character_frames.dash_weapon_attack, "A in a dash with a light weapon", "dash weapon attack"},
    {character_frames.light_weapon_throw, "throw a light weapon", "light weapon throw"},
    {character_frames.heavy_weapon_throw, "throw a heavy weapon", "heavy weapon throw"},
}

-- The class of a frame by its state: what a fighter in it can do and what it is open to.
local classes = {
    [states.standing] = "free", [states.walking] = "free", [states.running] = "moving", [states.attacking] = "attacking",
    [states.jumping] = "air", [states.dashing] = "air", [states.rowing] = "air", [states.defending] = "defending",
    [states.broken_defend] = "hurt", [states.catching] = "catching", [states.caught] = "caught", [states.injured] = "hurt",
    [states.falling] = "falling", [states.frozen] = "frozen", [states.lying] = "lying", [15] = "recovering",
    [states.dizzy] = "dizzy", [states.drinking] = "busy", [states.burning] = "hurt", [states.burning_run] = "attacking",
    [states.louis_dash_attack] = "attacking", [states.deep_dash_sword] = "attacking",
}
-- A move ends when its chain reaches a frame with one of these states: the fighter can act again.
local free_states = {[states.standing] = true, [states.walking] = true, [states.running] = true, [states.jumping] = true}
-- Hit boxes that hurt or move the victim.
local hurting = {[attack_kinds.plain] = true, [attack_kinds.thrown_body] = true, [attack_kinds.held_item] = true,
    [attack_kinds.super_window] = true, [attack_kinds.whirlwind] = true, [attack_kinds.conditional_whirlwind] = true,
    [attack_kinds.pulling_whirlwind] = true, [attack_kinds.freezing_whirlwind] = true}
local chain_limit, free_limit = 60, 200

local function frame_of(frames, id) return frames[id] end

-- The frames from `start` until the move ends: a frame of a free state, 999, 1000 (removed) or a loop.
-- `character` is false for a ball, which has no free states. Returns the list, `loops` and `holds` (next 0: the
-- frame stays until something else changes it).
local function chain(frames, start, character)
    local order, seen, current = {}, {}, start
    while #order < chain_limit do
        if seen[current] then return order, true, false end
        local frame = frame_of(frames, current)
        if not frame then break end
        seen[current] = true
        order[#order + 1] = {id = current, frame = frame}
        local following = math.abs(frame.next)
        if following == 0 then return order, false, true end
        if following == return_to_standing or following == 1000 then break end
        local after = frame_of(frames, following)
        if character and after and free_states[after.state] and following ~= start then break end
        current = following
    end
    return order, false, false
end

local function cost(value)
    if value >= move_cost.hp_radix then
        return value % move_cost.hp_radix, math.floor(value / move_cost.hp_radix) * move_cost.hp_unit
    end
    return value, 0
end

local function hit_box(frame, itr)
    return {kind = itr.kind, x0 = itr.x - frame.center_x, x1 = itr.x + itr.width - frame.center_x,
        y0 = itr.y - frame.center_y, y1 = itr.y + itr.height - frame.center_y,
        zwidth = itr.zwidth ~= 0 and itr.zwidth or default_zwidth, injury = itr.injury, fall = itr.fall,
        bdefend = itr.bdefend, effect = itr.effect, dvx = itr.dvx}
end

-- The objects that a move spawns (opoint), with the strongest hit box of each object's chain. A chasing ball whose
-- hit frames come after a state change (hit_Fa) shows its first chain only.
local object_cache = {}
local function object_summary(oid, action, dvx)
    local key = string.format("%d:%d:%d", oid, action, dvx)
    local cached = object_cache[key]
    if cached then return cached end
    local entry = catalog.objects().by_id[oid]
    local summary = {oid = oid, action = action, name = "object" .. oid, dvx = dvx, damage = 0, heal = 0, chase = false,
        character = false}
    if entry then
        local data = object_data.load(entry.path)
        summary.name = entry.path:match("([^/]+)%.dat$") or summary.name
        summary.character = entry.kind == constants.record_kinds.character
        local first = data.frames[action]
        if first then
            if dvx == 0 then summary.dvx = first.dvx end
            summary.chase = first.hits.Fa ~= 0
            local order = chain(data.frames, action, false)
            for _, step in ipairs(order) do
                for _, itr in ipairs(step.frame.interactions) do
                    if hurting[itr.kind] and itr.effect ~= constants.effects.skip_characters and itr.injury > summary.damage then
                        summary.damage = itr.injury
                    end
                    if itr.kind == attack_kinds.heal and itr.injury > summary.heal then summary.heal = itr.injury end
                end
            end
        end
    end
    object_cache[key] = summary
    return summary
end

-- The forward distance on the ground from a start at rest, by base/game/control frame_velocity and the ground
-- friction of base/game/physics (one unit per tick). Close enough for the planner, not exact.
local function advance_speed(speed, dvx)
    if dvx > velocity_encoding.absolute_threshold then return dvx - velocity_encoding.absolute_offset end
    if dvx > 0 and dvx > speed then return dvx end
    if dvx < 0 and dvx < speed then return dvx end
    return speed
end

local function analyse_move(frames, start, kind)
    local order, loops, holds = chain(frames, start, true)
    if #order == 0 then return nil end
    local first = order[1].frame
    local mp, hp = cost(first.mp)
    local move = {start = start, name = first.name, kind = kind, inputs = {}, mp = mp, hp = hp, hold_mp = 0,
        ticks = 0, active = 0, reach = 0, reach_back = 0, high = 0, low = 0, damage = 0, fall = 0, bdefend = 0, effect = 0,
        heal = 0, frames = {}, hits = {}, body = {}, forward = {}, projectiles = {}, follow = {}, loops = loops, holds = holds,
        tags = {}}
    local speed, distance, tick = 0, 0, 0
    local followed = {}
    for position, step in ipairs(order) do
        local frame = step.frame
        if position > 1 and frame.mp < 0 then move.hold_mp = math.max(move.hold_mp, -frame.mp) end
        local boxes = false
        for _, itr in ipairs(frame.interactions) do
            local box = hit_box(frame, itr)
            if not boxes then boxes = {} end
            boxes[#boxes + 1] = box
            if hurting[itr.kind] and itr.effect ~= constants.effects.skip_characters then
                if itr.injury > move.damage then
                    move.damage, move.fall, move.bdefend, move.effect = itr.injury, itr.fall, itr.bdefend, itr.effect
                end
                if box.x1 > move.reach then move.reach = box.x1 end
                if -box.x0 > move.reach_back then move.reach_back = -box.x0 end
                if -box.y0 > move.high then move.high = -box.y0 end
            elseif itr.effect == constants.effects.skip_characters then
                move.tags.hits_balls = true
            end
            if itr.kind == attack_kinds.catch or itr.kind == attack_kinds.catch_nearest then move.tags.catch = true end
            if itr.kind == attack_kinds.heal then
                move.tags.heal = true
                if itr.injury > move.heal then move.heal = itr.injury end
            end
            if itr.kind == attack_kinds.reflect_ball then move.tags.reflect = true end
        end
        local point = frame.opoint
        if point.kind ~= 0 and point.oid ~= 0 then
            local summary = object_summary(point.oid, point.action, point.dvx)
            move.projectiles[#move.projectiles + 1] = summary
        end
        for _, pair in ipairs({{"a", "A"}, {"j", "J"}, {"d", "D"}}) do
            local goal = math.abs(frame.hits[pair[1]])
            if goal ~= 0 and goal ~= return_to_standing and not followed[pair[2]] then
                followed[pair[2]] = true
                move.follow[#move.follow + 1] = {key = pair[2], to = goal, from_tick = tick + 1}
            end
        end
        for _, pair in ipairs(move_book.combo_inputs) do
            local goal = math.abs(frame.hits[pair[1]])
            if goal ~= 0 and not followed[pair[2]] then
                followed[pair[2]] = true
                move.follow[#move.follow + 1] = {key = pair[2], to = goal, from_tick = tick + 1}
            end
        end
        local state_class = frame.state
        if state_class == states.teleport_to_enemy or state_class == states.teleport_to_ally then move.tags.teleport = true end
        if state_class == states.transform_start or state_class == states.transform_complete
           or state_class == states.transform_louis_ex then move.tags.transform = true end
        if state_class == states.heal_self then move.tags.heal = true end
        if state_class == states.defending then move.tags.defends = true end
        local has_body = #frame.bodies > 0
        for _ = 0, frame.wait do
            tick = tick + 1
            speed = advance_speed(speed, frame.dvx)
            distance = distance + speed
            if speed > 0.0001 then speed = math.max(speed - 1, 0) elseif speed < -0.0001 then speed = math.min(speed + 1, 0) end
            move.frames[tick], move.hits[tick], move.body[tick], move.forward[tick] = step.id, boxes, has_body, math.floor(distance)
            if boxes then
                local damaging = false
                for _, box in ipairs(boxes) do
                    if hurting[box.kind] and box.effect ~= constants.effects.skip_characters then damaging = true end
                end
                if damaging then
                    move.active = move.active + 1
                    if not move.first_hit then move.first_hit = tick end
                    move.last_hit = tick
                end
            end
            if not has_body then move.tags.untouchable = true end
        end
    end
    move.ticks = tick
    move.recovery = move.last_hit and (tick - move.last_hit) or tick
    local tags = move.tags
    if move.fall >= 60 then tags.knockdown = true end
    if move.bdefend >= 60 then tags.guard_break = true end
    if move.damage > 0 then tags.close = true end
    for _, projectile in ipairs(move.projectiles) do
        if projectile.character then tags.summon = true
        elseif projectile.damage > 0 or projectile.chase then tags.ranged = true end
        if projectile.heal > 0 then tags.heal = true end
    end
    if move.high >= 80 then tags.anti_air = true end
    local farthest = 0
    for _, value in ipairs(move.forward) do if math.abs(value) > farthest then farthest = math.abs(value) end end
    if farthest >= 80 then tags.movement = true end
    if first.state == states.jumping or first.state == states.dashing then tags.air = true end
    return move
end

-- The ticks from the start of frame `id` until the fighter reaches a free frame, or -1 when the chain holds (next 0,
-- for example lying until the engine lifts the fighter) or loops.
local function free_ticks(frames, id)
    local ticks, seen, current = 0, {}, id
    while ticks < free_limit do
        local frame = frames[current]
        if not frame then return -1 end
        if free_states[frame.state] then return ticks end
        if seen[current] then return -1 end
        seen[current] = true
        ticks = ticks + frame.wait + 1
        local following = math.abs(frame.next)
        if following == 0 then return -1 end
        if following == return_to_standing then return ticks end
        current = following
    end
    return -1
end

local cache = {}

-- The book of a fighter record (base/game/item record), built on the first call.
function move_book.get(record)
    local data = record.data
    local book = cache[data]
    if book then return book end
    local frames = data.frames
    book = {id = record.id, name = data.name or tostring(record.id), movement = data.movement or {}, moves = {}, by_start = {},
        inputs = {}, class = {}, free_in = {}, move_at = {}}
    local ids = {}
    for id in pairs(frames) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local frame = frames[id]
        book.class[id] = classes[frame.state] or "busy"
        book.free_in[id] = free_ticks(frames, id)
        for _, pair in ipairs(move_book.combo_inputs) do
            local goal = math.abs(frame.hits[pair[1]])
            if goal ~= 0 and frames[goal] then
                local move = book.by_start[goal]
                if not move then
                    move = analyse_move(frames, goal, "special")
                    if move then
                        book.by_start[goal] = move
                        book.moves[#book.moves + 1] = move
                    end
                end
                if move then
                    local entry
                    for _, existing in ipairs(move.inputs) do
                        if existing.input == pair[2] then entry = existing end
                    end
                    if not entry then
                        entry = {input = pair[2], sources = {}}
                        move.inputs[#move.inputs + 1] = entry
                    end
                    entry.sources[#entry.sources + 1] = id
                    local list = book.inputs[id] or {}
                    list[#list + 1] = {input = pair[2], move = move}
                    book.inputs[id] = list
                end
            end
        end
    end
    for _, basic in ipairs(move_book.basic_moves) do
        local id = basic[1]
        if frames[id] and not book.by_start[id] then
            local move = analyse_move(frames, id, "basic")
            if move then
                move.label = basic[3]
                move.inputs[1] = {input = basic[2], sources = {}}
                book.by_start[id] = move
                book.moves[#book.moves + 1] = move
            end
        end
    end
    -- Where each frame sits in a move, so that prediction can read the rest of an enemy's move from its frame: the move
    -- that starts at the frame, or else the first move whose chain holds it.
    for _, move in ipairs(book.moves) do book.move_at[move.start] = {move = move, tick = 1} end
    for _, move in ipairs(book.moves) do
        for tick, id in ipairs(move.frames) do
            if not book.move_at[id] then book.move_at[id] = {move = move, tick = tick} end
        end
    end
    -- An attacking frame that no move reaches from its start (for example the second weapon swing, or a frame that a
    -- follow-up enters) gets a fragment: the chain from that frame. Fragments are not in `moves`.
    for _, id in ipairs(ids) do
        if not book.move_at[id] and book.class[id] == "attacking" then
            local fragment = analyse_move(frames, id, "fragment")
            if fragment then
                for tick, frame_id in ipairs(fragment.frames) do
                    if not book.move_at[frame_id] then book.move_at[frame_id] = {move = fragment, tick = tick} end
                end
            end
        end
    end
    cache[data] = book
    return book
end

-- The special moves that a fighter in frame `id` can start: the frame's own fields and, for a fighter that can
-- defend first (the sequences begin with Defend, base/game/control chord_available), the fields of its defend frame.
function move_book.inputs_from(book, id)
    local own = book.inputs[id] or {}
    local class = book.class[id]
    if class ~= "free" and class ~= "moving" then return own end
    local defend = book.inputs[character_frames.defend]
    if not defend then return own end
    local result, seen = {}, {}
    for _, entry in ipairs(own) do
        result[#result + 1] = entry
        seen[entry.input] = true
    end
    for _, entry in ipairs(defend) do
        if not seen[entry.input] then result[#result + 1] = entry end
    end
    return result
end

local function sorted_tags(tags)
    local list = {}
    for name in pairs(tags) do list[#list + 1] = name end
    table.sort(list)
    return #list > 0 and table.concat(list, ",") or "-"
end

-- One text line for each move of `book`, for the log (--ai-book) and the check against tools/lf2_moves.py. The first
-- line sums up the fighter: the number of frames of each class and the moves that a standing fighter can start.
function move_book.lines(book)
    local counts, names, frames = {}, {}, 0
    for _, class in pairs(book.class) do
        frames = frames + 1
        if not counts[class] then names[#names + 1] = class end
        counts[class] = (counts[class] or 0) + 1
    end
    table.sort(names)
    local classes_text = {}
    for _, name in ipairs(names) do classes_text[#classes_text + 1] = name .. ":" .. counts[name] end
    local standing = {}
    for _, entry in ipairs(move_book.inputs_from(book, character_frames.standing)) do
        standing[#standing + 1] = entry.input .. ":" .. entry.move.start
    end
    local lines = {string.format("book id=%d fighter=%s frames=%d classes=%s stand=%s", book.id, book.name, frames,
        table.concat(classes_text, ","), #standing > 0 and table.concat(standing, ",") or "-")}
    for _, move in ipairs(book.moves) do
        local inputs = {}
        for _, entry in ipairs(move.inputs) do inputs[#inputs + 1] = entry.input:gsub(" ", "_") end
        local projectiles = {}
        for _, projectile in ipairs(move.projectiles) do
            projectiles[#projectiles + 1] = string.format("%s:%d:%d", projectile.name, projectile.dvx, projectile.damage)
        end
        local follow = {}
        for _, entry in ipairs(move.follow) do follow[#follow + 1] = string.format("%s:%d@%d", entry.key, entry.to, entry.from_tick) end
        lines[#lines + 1] = string.format(
            "book id=%d kind=%s start=%d name=%s inputs=%s mp=%d hp=%d hold=%d ticks=%d hit=%d last=%d active=%d recovery=%d"
                .. " dmg=%d fall=%d bdefend=%d reach=%d high=%d move=%d tags=%s shots=%s follow=%s",
            book.id, move.kind, move.start, move.name, table.concat(inputs, ","), move.mp, move.hp, move.hold_mp, move.ticks,
            move.first_hit or -1, move.last_hit or -1, move.active, move.recovery, move.damage, move.fall, move.bdefend,
            move.reach, move.high, move.forward[#move.forward] or 0, sorted_tags(move.tags),
            #projectiles > 0 and table.concat(projectiles, ",") or "-", #follow > 0 and table.concat(follow, ",") or "-")
    end
    return lines
end
return move_book
