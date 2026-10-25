-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `tactician` (docs/ai-plan.md phase 8): the first brain that fights with the framework. Every tick it runs
-- its reflexes and the actuator. On a think (every `row.think` ticks, with an offset for each slot) it runs its
-- behavior tree:
--
--   root (selector)
--     reflex: a threat arrives too soon to plan (base/ai/reflex)
--     busy: a key program still runs
--     combo: its own move has a follow-up that hits now
--     punish: the target cannot act, and a move hits before it can
--     attack: the best move pays (hit chance, damage, risk, mp)
--     space: a free enemy can hit it: it steps out of the enemy's depth line
--     zone: a ball reaches the target in its lane
--     approach: it walks or runs to its distance and depth from the target
--
-- It sees the other fighters through the delayed view of its difficulty and types through the actuator, like a player.
-- Scores are whole numbers. The persona numbers (base/ai/personas, phase 11) default to a generic fighter.
local actuator = require("base/ai/actuator")
local reflex = require("base/ai/reflex")
local predict = require("base/ai/predict")
local perception = require("base/ai/perception")
local tree = require("base/ai/tree")
local constants = require("base/game/constants")
local bits = actuator.bits
local tactician = {name = "tactician", version = 1, interface = 2}

-- The generic persona: whole numbers from 0 to 100, and distances in pixels.
local generic = {aggression = 85, risk = 40, mp_thrift = 30, combo_greed = 60, defense = 60, range = 0, depth_offset = 0,
    spacing = 38, mobility = 30}
tactician.generic = generic

function tactician.start(state, index, seed)
    local memory = {version = tactician.version, rng = seed, target = -1, intent = 0, path = {}, plan = 0, plan_tick = -1,
        reflex_until = -1, combo = -1, moves = 0, thinks = 0, hp = state.items[index].hp, class = ""}
    actuator.start(memory)
    return memory
end

-- The candidate moves of a book that start from standing: the punch and the special moves that hurt (close or
-- ranged). Fixed data, cached by book.
local candidates_cache = {}
local function candidates_of(book)
    local list = candidates_cache[book]
    if list then return list end
    list = {}
    local punch = book.by_start[constants.character_frames.punch]
    if punch then list[#list + 1] = {move = punch, input = "A"} end
    for _, move in ipairs(book.moves) do
        if move.kind == "special" and not move.tags.transform and (move.damage > 0 or move.tags.ranged) then
            for _, entry in ipairs(move.inputs) do
                local stand = false
                for _, source in ipairs(entry.sources) do
                    if book.class[source] == "free" then stand = true end
                end
                if stand then list[#list + 1] = {move = move, input = entry.input} break end
            end
        end
    end
    candidates_cache[book] = list
    return list
end

-- The ticks from the first key to the move's first frame (base/ai/actuator): one input tick for Attack, the typed keys
-- of a sequence, and a turn first when the input does not choose the direction.
local function latency(context, candidate, right)
    local human = context.row.rate ~= "fast"
    local facing_right = context.me.facing == constants.facings.right
    local turn = (candidate.input:sub(2, 2) ~= ">" and facing_right ~= right) and (human and 2 or 1) or 0
    if candidate.input == "A" then return turn + (human and 2 or 1) end
    local index = actuator.sequence_of(candidate.input, right)
    local masks = actuator.input_masks(candidate.input, right, context.row.rate, index and context.self.sequences[index] or 0)
    if not masks then return 99 end
    return turn + math.max(#masks - 1, 0) * (human and 2 or 1) + (human and 1 or 0)
end

-- The value of a candidate against the target, as a whole number: the hit chance (in percent) times the damage, less
-- the miss chance times the damage of a punish (by the persona's `risk`), less the mp (by `mp_thrift`). Returns the
-- value, the tick of the hit and whether the hit is sure, or nil when the move cannot hit.
local function score(context, board, candidate)
    local me, target, move = context.me, board.target, candidate.move
    if context.self.mp < move.mp or context.self.hp <= move.hp then return nil end
    local right = board.tx > me.x
    local lead = latency(context, candidate, right)
    local facing = right and constants.facings.right or constants.facings.left
    -- The target in the view is `delay` ticks old: it moves on for the delay and the input latency.
    local ticks, box = predict.move_hit(me, move, 1, facing, target, move.ticks, true, me.x, me.z, lead + board.delay)
    local damage = box and (box.injury or 0) or 0
    local ranged = false
    if not ticks and move.tags.ranged and move.projectiles[1] then
        -- A ball: in the target's lane, in front and not too far, it reaches the target after its spawn and its flight.
        local ball = move.projectiles[1]
        local distance = math.abs(board.tx - me.x)
        if math.abs(board.tz - me.z) < 8 and distance > 80 and distance < 320 and ball.dvx > 0 then
            ticks = 6 + math.floor(distance / ball.dvx)
            damage, ranged = ball.damage, true
        end
    end
    if not ticks or damage <= 0 then return nil end
    local opening = predict.opening(target)
    local sure = opening < 0 or ticks + lead < opening
    local chance
    if sure then chance = 95
    elseif target.class == "defending" then chance = 15
    elseif ranged then chance = 35
    elseif target.class == "attacking" then chance = 70
    else chance = 60 end
    local value = chance * damage
    if move.tags.knockdown then value = value + chance * 10 end
    local persona = board.persona
    local risk = predict.risk(context.state, context.view, me, move)
    -- A miss is punished only sometimes: the enemy must see it and choose to answer.
    value = value - math.floor((100 - chance) * risk * (100 - persona.risk) / 400)
    value = value - move.mp * persona.mp_thrift
    return value, ticks + lead, sure
end

local function best_attack(context, board)
    local best, best_value, best_ticks, best_sure
    for _, candidate in ipairs(candidates_of(context.book)) do
        local value, ticks, sure = score(context, board, candidate)
        if value and (not best_value or value > best_value) then
            best, best_value, best_ticks, best_sure = candidate, value, ticks, sure
        end
    end
    return best, best_value, best_ticks, best_sure
end

-- The attack of a fighter in motion: the jump attack in a jump, the dash attack in a dash, the run attack while
-- running. They start with Attack alone, from the speed that the fighter has (base/game/control), so prediction runs
-- them from the fighter's current speed and height. Returns the move and the hit tick, or nil.
local motion_frames = {air = constants.character_frames.jump_attack, dash = constants.character_frames.dash_attack,
    run = constants.character_frames.run_attack}
local function motion_attack(context, board, kind)
    local me, target = context.me, board.target
    local move = context.book.by_start[motion_frames[kind]]
    if not move or context.self.mp < move.mp then return nil end
    local human = context.row.rate ~= "fast"
    local lead = (human and 2 or 1) + board.delay
    local ticks, box = predict.move_hit(me, move, 1, me.facing, target, move.ticks, true, nil, nil, lead)
    if not ticks or not box or (box.injury or 0) <= 0 then return nil end
    return move, ticks + lead
end

local function in_motion(me)
    if me.class == "moving" then return "run" end
    if me.class == "air" then
        if me.frame >= constants.character_frames.dash and me.frame <= constants.character_frames.dash + 1 then return "dash" end
        if me.frame >= constants.character_frames.jump and me.frame <= constants.character_frames.jump + 2 then return "air" end
    end
    return nil
end

-- Starts a candidate: a turn first when the input does not choose the direction, then its keys.
local function start_move(context, board, candidate, reason)
    local memory, me, target = context.memory, context.me, board.target
    local right = board.tx > me.x
    local facing_right = me.facing == constants.facings.right
    local masks = {}
    if candidate.input:sub(2, 2) ~= ">" and facing_right ~= right then masks[1] = right and bits.right or bits.left end
    if candidate.input == "A" then
        masks[#masks + 1] = bits.attack
    else
        local index = actuator.sequence_of(candidate.input, right)
        local typed = actuator.input_masks(candidate.input, right, context.row.rate, index and context.self.sequences[index] or 0)
        for _, mask in ipairs(typed or {}) do masks[#masks + 1] = mask end
    end
    actuator.program(memory, masks, 0)
    memory.plan, memory.plan_tick, memory.moves = candidate.move.start, context.state.frame_number, memory.moves + 1
    if context.log then
        context.log(context.state, context.index, string.format("ev=move m=%s/%d input=%s why=%s target=%d dx=%d dz=%d",
            candidate.move.name, candidate.move.start, candidate.input, reason, target.index, board.tx - me.x, board.tz - me.z))
    end
end

-- The nearest enemy in the view, kept while it stays near.
local function choose_target(context)
    local me, memory, view = context.me, context.memory, context.view
    local best, best_distance
    for _, other in ipairs(view.list) do
        if other.character and other.hp > 0 and perception.enemy(context.state, me, other) then
            local distance = math.abs(other.x - me.x) + 2 * math.abs(other.z - me.z)
            if other.index == memory.target then distance = distance - 150 end
            if not best_distance or distance < best_distance then best, best_distance = other, distance end
        end
    end
    memory.target = best and best.index or -1
    return best
end

local function walk_to(context, x, z, run)
    local me, memory = context.me, context.memory
    local mask = 0
    if x > me.x + 6 then mask = mask + bits.right elseif x < me.x - 6 then mask = mask + bits.left end
    if z > me.z + 2 then mask = mask + bits.down elseif z < me.z - 2 then mask = mask + bits.up end
    if run and me.class == "free" and math.abs(x - me.x) > 220 and not actuator.busy(memory) then
        actuator.run(memory, x > me.x)
    elseif me.class ~= "moving" or mask % 16 < 4 then
        actuator.hold(memory, mask)
    end
end

-- The nodes of the tree.
local root = tree.selector(1, "root", {
    tree.sequence(2, "reflex", {
        tree.condition(3, "threat near", function(context, board)
            board.answer, board.threat, board.remaining, board.source = reflex.decide(context)
            return board.answer ~= nil
        end),
        tree.action(4, "answer", function(context, board)
            reflex.act(context, board.answer, board.threat, board.remaining, board.source)
            return "success"
        end),
    }),
    tree.condition(5, "keys running", function(context) return actuator.busy(context.memory) end),
    tree.sequence(6, "combo", {
        tree.condition(7, "follow-up ready", function(context, board)
            local me = context.me
            if not me.move or context.memory.combo == me.move.start then return false end
            local target = board.target
            if target.class ~= "hurt" and target.class ~= "dizzy" and target.class ~= "falling" then return false end
            for _, entry in ipairs(me.move.follow) do
                if entry.key:sub(1, 1) == "D" and #entry.key == 3 and me.move_tick >= entry.from_tick - 2 then
                    local follow = context.book.by_start[entry.to]
                    if follow and follow.damage > 0 and context.self.mp >= follow.mp
                       and context.random(100) < board.persona.combo_greed then
                        board.follow = {move = follow, input = entry.key}
                        return true
                    end
                end
            end
            return false
        end),
        tree.action(8, "type follow-up", function(context, board)
            context.memory.combo = context.me.move.start
            start_move(context, board, board.follow, "combo")
            return "success"
        end),
    }),
    tree.sequence(22, "motion attack", {
        tree.condition(23, "it hits in motion", function(context, board)
            local kind = in_motion(context.me)
            if not kind then return false end
            board.motion_move, board.motion_ticks = motion_attack(context, board, kind)
            return board.motion_move ~= nil
        end),
        tree.action(24, "attack in motion", function(context, board)
            local memory = context.memory
            local toward = board.tx > context.me.x and bits.right or bits.left
            -- Attack keeps the direction held, so a run or a jump goes on toward the target.
            actuator.program(memory, {bits.attack + toward}, toward)
            memory.plan, memory.plan_tick, memory.moves = board.motion_move.start, context.state.frame_number, memory.moves + 1
            if context.log then
                context.log(context.state, context.index, string.format("ev=move m=%s/%d input=A why=motion target=%d dx=%d dz=%d",
                    board.motion_move.name, board.motion_move.start, board.target.index, board.tx - context.me.x, board.tz - context.me.z))
            end
            return "success"
        end),
    }),
    tree.sequence(9, "punish", {
        tree.condition(10, "target open", function(context, board)
            if context.me.class ~= "free" and context.me.class ~= "moving" then return false end
            local opening = predict.opening(board.target)
            if opening == 0 or board.target.class == "lying" then return false end
            board.candidate, board.value, board.ticks, board.sure = best_attack(context, board)
            return board.candidate ~= nil and board.sure and board.value > 0
        end),
        tree.action(11, "hit the opening", function(context, board)
            start_move(context, board, board.candidate, "punish")
            return "success"
        end),
    }),
    tree.sequence(12, "attack", {
        tree.condition(13, "a move pays", function(context, board)
            if context.me.class ~= "free" and context.me.class ~= "moving" then return false end
            if not board.candidate then board.candidate, board.value, board.ticks, board.sure = best_attack(context, board) end
            local needed = (100 - board.persona.aggression) * 20
            return board.candidate ~= nil and board.value >= needed
        end),
        tree.action(14, "start the move", function(context, board)
            start_move(context, board, board.candidate, "attack")
            return "success"
        end),
    }),
    tree.sequence(15, "space", {
        tree.condition(16, "enemy can hit", function(context, board)
            local me, target = context.me, board.target
            if target.class ~= "free" and target.class ~= "moving" then return false end
            if board.candidate and board.value and board.value > 0 then return false end
            return math.abs(board.tx - me.x) < 120 and math.abs(board.tz - me.z) < board.persona.depth_offset - 2
        end),
        tree.action(17, "leave the line", function(context, board)
            local me = context.me
            local offset = board.persona.depth_offset
            local z = board.tz + ((me.z >= board.tz) and offset or -offset)
            local near = (context.state.stage.zboundary or {})[1] or 0
            local far = (context.state.stage.zboundary or {})[2] or 0
            if z > far - 5 or z < near + 5 then z = board.tz + ((me.z >= board.tz) and -offset or offset) end
            walk_to(context, me.x, z, false)
            return "success"
        end),
    }),
    tree.sequence(25, "leap", {
        tree.condition(26, "in leap range", function(context, board)
            local me = context.me
            if me.class ~= "free" and me.class ~= "moving" then return false end
            local distance = math.abs(board.tx - me.x)
            local lane = math.abs(board.tz - me.z)
            local jump = context.book.by_start[constants.character_frames.jump_attack]
            if not jump or lane > 12 then return false end
            if me.class == "moving" then return distance > 90 and distance < 240 and context.random(100) < board.persona.mobility end
            return distance > 80 and distance < 190 and context.random(100) < board.persona.mobility
        end),
        tree.action(27, "jump or dash in", function(context, board)
            local memory = context.memory
            local toward = board.tx > context.me.x and bits.right or bits.left
            -- A jump while running is a dash (base/game/control running).
            actuator.program(memory, {bits.jump + toward}, toward)
            if context.log then
                context.log(context.state, context.index, string.format("ev=leap from=%s dx=%d dz=%d", context.me.class,
                    board.tx - context.me.x, board.tz - context.me.z))
            end
            return "success"
        end),
    }),
    tree.sequence(18, "zone", {
        tree.condition(19, "ball reaches", function(context, board)
            return board.candidate ~= nil and board.candidate.move.tags.ranged and board.value > 0
        end),
        tree.action(20, "throw", function(context, board)
            start_move(context, board, board.candidate, "zone")
            return "success"
        end),
    }),
    tree.action(21, "approach", function(context, board)
        local me, target = context.me, board.target
        local persona = board.persona
        local tx, tz = board.tx, board.tz
        local side = me.x < tx and -1 or 1
        local offset = persona.depth_offset
        local z = tz + ((me.z >= tz) and offset or -offset)
        local near = (context.state.stage.zboundary or {})[1] or 0
        local far = (context.state.stage.zboundary or {})[2] or 0
        if z > far - 5 or z < near + 5 then z = tz + ((me.z >= tz) and -offset or offset) end
        local distance
        if target.class == "lying" then distance = 80
        elseif target.class ~= "free" and target.class ~= "moving" then distance = 35
        elseif math.abs(tz - me.z) >= offset - 2 then distance = 38 -- out of its depth line: close in
        else distance = persona.spacing end -- in its line: keep away until the offset is taken
        walk_to(context, tx + side * distance, z, math.abs(tx - me.x) > 250)
        return "running"
    end),
})
tactician.tree = root
tactician.names = tree.names(root)

local board = {}
function tactician.tick(context)
    local memory, state = context.memory, context.state
    local now = state.frame_number
    for key in pairs(board) do board[key] = nil end
    board.persona = generic
    -- The hits that it takes, with its class and intent on the tick before.
    if context.self.hp < memory.hp and context.log then
        context.log(state, context.index, string.format("ev=hurt hit=%d dmg=%d class=%s intent=%s", now - 1,
            memory.hp - context.self.hp, memory.class, (tactician.names[memory.intent] or "-"):gsub(" ", "_")))
    end
    memory.hp, memory.class = context.self.hp, context.me and context.me.class or ""
    local target = choose_target(context)
    -- The reflexes run on every tick, the tree on a think.
    -- In a jump, a dash or a run the moment of the attack matters: it thinks on every tick there.
    local think = (now + context.index) % context.row.think == 0 or (context.me and in_motion(context.me) ~= nil)
    if target and (think or (memory.reflex_until or -1) >= now) then
        board.target = target
        -- Where the target is now: the view is `delay` ticks old, so its position moves on by its speed. Whole pixels.
        board.delay = context.view.delay or 0
        board.tx = math.floor(target.x + target.vx * board.delay + 0.5)
        board.tz = math.floor(target.z + target.vz * board.delay + 0.5)
        local before = memory.path[2] or 0
        tree.run(root, context, board, memory.path)
        memory.thinks = memory.thinks + 1
        local chosen = memory.path[2] or 0
        if chosen ~= before and context.log and chosen ~= 5 then
            context.log(state, context.index, string.format("ev=intent to=%s target=%d", tactician.names[chosen] or "?", target.index))
        end
        memory.intent = chosen
    elseif not target then
        actuator.hold(memory, 0)
    end
    actuator.tick(state, context.self, memory, context.row)
end

function tactician.describe(memory)
    return string.format("intent:%s,target:%d,moves:%d", (tactician.names[memory.intent] or "-"):gsub(" ", "_"), memory.target,
        memory.moves)
end
return tactician
