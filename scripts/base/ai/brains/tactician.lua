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
local trace = require("base/ai/trace")
local reflex = require("base/ai/reflex")
local predict = require("base/ai/predict")
local perception = require("base/ai/perception")
local tree = require("base/ai/tree")
local kits = require("base/ai/kits")
local constants = require("base/game/constants")
local bits = actuator.bits
local tactician = {name = "tactician", version = 1, interface = 2}

-- The generic persona: whole numbers from 0 to 100, and distances in pixels.
local generic = {aggression = 85, risk = 40, mp_thrift = 30, combo_greed = 60, defense = 60, range = 0, depth_offset = 0,
    spacing = 38, mobility = 30, teamwork = 50, adapt = 50}

-- Learning (docs/ai-plan.md phase 12): the results of its moves, in the memory as three dense arrays (the start frame,
-- the tries, the hits) of at most `learn_size` moves. A try counts as a hit when the target loses hp before the move
-- ends. The hit chance of a move moves toward its measured rate by the persona's `adapt`. The match option
-- `ai_learning[index]` (the results of earlier fights, base/game/arena and base/ui/flow) starts the arrays.
local learn_size, learn_least, drop_tries = 12, 3, 4
tactician.learn_size = learn_size
tactician.generic = generic

-- A kit's persona with the generic numbers for the ones that it does not set. Fixed data, cached by persona.
local merged = {}
local function full_persona(entry)
    if not entry then return generic end
    local result = merged[entry]
    if result then return result end
    result = {}
    for key, value in pairs(generic) do result[key] = value end
    for key, value in pairs(entry) do result[key] = value end
    result.prefer = entry.prefer or {}
    merged[entry] = result
    return result
end

function tactician.start(state, index, seed)
    local memory = {version = tactician.version, rng = seed, target = -1, intent = 0, path = {}, plan = 0, plan_tick = -1,
        reflex_until = -1, combo = -1, moves = 0, thinks = 0, hp = state.items[index].hp, class = "", persona = 0,
        learn_moves = {}, learn_tries = {}, learn_hits = {}, try_move = 0, try_until = -1, try_target = -1, try_hp = 0}
    local earlier = state.ai_learning and state.ai_learning[index]
    if earlier then
        for position = 1, math.min(#(earlier.moves or {}), learn_size) do
            memory.learn_moves[position] = earlier.moves[position]
            memory.learn_tries[position] = earlier.tries[position] or 0
            memory.learn_hits[position] = earlier.hits[position] or 0
        end
    end
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
    -- What this fight (and earlier ones) taught about this move.
    local memory = context.memory
    for position = 1, #memory.learn_moves do
        if memory.learn_moves[position] == move.start and memory.learn_tries[position] >= learn_least and not sure then
            local rate = math.floor(memory.learn_hits[position] * 100 / memory.learn_tries[position])
            -- A ranged move that clearly does not work against this enemy drops out (an adapting persona only). A close
            -- move keeps its place: its chance only moves toward its rate, so a few misses never stop all attacks.
            if move.tags.ranged and board.persona.adapt > 0 and memory.learn_tries[position] >= drop_tries and rate < 20 then return nil end
            chance = math.floor((chance * (100 - board.persona.adapt) + rate * board.persona.adapt) / 100)
        end
    end
    local value = chance * damage
    if move.tags.knockdown then value = value + chance * 10 end
    local persona = board.persona
    local risk = predict.risk(context.state, context.view, me, move)
    -- A miss is punished only sometimes: the enemy must see it and choose to answer.
    value = value - math.floor((100 - chance) * risk * (100 - persona.risk) / 400)
    value = value - move.mp * persona.mp_thrift
    -- The persona's taste for this move: a share of its value and a bonus by the hit chance, so that a persona picks
    -- its moves when they hit, and drops a favorite that keeps missing (learning lowers the chance).
    local taste = persona.prefer and persona.prefer[move.start]
    if taste then
        if value > 0 then value = math.floor(value * (100 + taste) / 100) end
        value = value + math.floor(taste * chance / 3)
    end
    return value, ticks + lead, sure
end

-- Whether learning dropped a move (by its results against this enemy).
local function dropped(context, start)
    local memory = context.memory
    for position = 1, #memory.learn_moves do
        if memory.learn_moves[position] == start and memory.learn_tries[position] >= drop_tries
           and memory.learn_hits[position] * 100 < memory.learn_tries[position] * 20 then return true end
    end
    return false
end

local function best_attack(context, board)
    local best, best_value, best_ticks, best_sure
    for _, candidate in ipairs(candidates_of(context.book)) do
        if candidate.move.tags.ranged and context.self.mp >= candidate.move.mp
           and not (board.persona.adapt > 0 and dropped(context, candidate.move.start)) then
            board.candidate_ranged = true
        end
        local value, ticks, sure = score(context, board, candidate)
        if value and board.scores then
            board.scores[#board.scores + 1] = {name = candidate.move.name, start = candidate.move.start, value = value,
                ticks = ticks, sure = sure}
        end
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

local learn
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
    -- A try of this move: its result shows when the move (and its ball's flight) is over. An open try counts first.
    learn(context, true)
    memory.try_move, memory.try_target, memory.try_hp = candidate.move.start, target.index, context.state.items[target.index].hp
    memory.try_until = context.state.frame_number + candidate.move.ticks + 12
    if context.log then
        context.log(context.state, context.index, string.format("ev=move m=%s/%d input=%s why=%s target=%d dx=%d dz=%d",
            candidate.move.name, candidate.move.start, candidate.input, reason, target.index, board.tx - me.x, board.tz - me.z))
    end
end

-- The team table (docs/ai-plan.md "Teams and Stage mode"): in the match, the target of each AI fighter and the tick
-- when it chose it, and an order for each member (kept for orders of human players, unused yet). A brain reads only
-- entries of earlier ticks, so the order of the brains in a tick does not change a result.
local function team_table(state)
    local team = state.ai_team
    if not team then
        team = {targets = {}, ticks = {}, orders = {}}
        state.ai_team = team
    end
    return team
end

-- The nearest enemy in the view, kept while it stays near, and nearer by `teamwork` when allies attack it too.
local function choose_target(context, persona)
    local me, memory, view, state = context.me, context.memory, context.view, context.state
    local team = team_table(state)
    local now = state.frame_number
    local best, best_distance
    for _, other in ipairs(view.list) do
        if other.character and other.hp > 0 and perception.enemy(state, me, other) then
            local distance = math.abs(other.x - me.x) + 2 * math.abs(other.z - me.z)
            if other.index == memory.target then distance = distance - 150 end
            for _, ally in ipairs(view.list) do
                if ally.character and ally.index ~= me.index and ally.team == me.team and team.targets[ally.index] == other.index
                   and (team.ticks[ally.index] or now) < now then
                    distance = distance - persona.teamwork * 2
                end
            end
            if not best_distance or distance < best_distance then best, best_distance = other, distance end
        end
    end
    memory.target = best and best.index or -1
    team.targets[context.index], team.ticks[context.index] = memory.target, now
    return best
end

local function walk_to(context, x, z, run)
    local me, memory = context.me, context.memory
    local mask = 0
    if x > me.x + 6 then mask = mask + bits.right elseif x < me.x - 6 then mask = mask + bits.left end
    if z > me.z + 2 then mask = mask + bits.down elseif z < me.z - 2 then mask = mask + bits.up end
    if run and me.class == "free" and math.abs(x - me.x) > 60 and not actuator.busy(memory) then
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
    tree.sequence(28, "heal", {
        tree.condition(29, "low and safe", function(context, board)
            local kit, self, me = board.kit, context.self, context.me
            local move = kit and kit.heal and context.book.by_start[kit.heal]
            if not move or me.class ~= "free" or self.mp < move.mp or self.hp * 100 >= self.max_hp * 45 then return false end
            if math.abs(board.tx - me.x) < 160 and math.abs(board.tz - me.z) < 40 then return false end
            for _, entry in ipairs(move.inputs) do board.heal = {move = move, input = entry.input} end
            return board.heal ~= nil
        end),
        tree.action(30, "heal itself", function(context, board)
            start_move(context, board, board.heal, "heal")
            return "success"
        end),
    }),
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
            -- Patience runs out: the threshold falls by 4 for each tick since its last move, so two waiting fighters
            -- do not stand still forever.
            local quiet = context.state.frame_number - math.max(context.memory.plan_tick, 0)
            local needed = math.max((100 - board.persona.aggression) * 20 - quiet * 4, 0)
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
        local zoning = persona.range > 0 and board.candidate_ranged
        if target.class == "lying" then distance = 80
        elseif zoning and (target.class == "free" or target.class == "moving") and math.abs(tx - me.x) > 90 then
            -- A zoner stands at its range in the target's depth lane, where its balls fly.
            distance, z = persona.range, tz
        elseif target.class ~= "free" and target.class ~= "moving" then distance = 35
        elseif math.abs(tz - me.z) >= offset - 2 then distance = 38 -- out of its depth line: close in
        else distance = persona.spacing end -- in its line: keep away until the offset is taken
        -- Run when far, or when the target walks away (a chase at walking speed never closes).
        local away = (tx > me.x and target.vx > 0.5) or (tx < me.x and target.vx < -0.5)
        walk_to(context, tx + side * distance, z, math.abs(tx - me.x) > 250 or (away and math.abs(tx - me.x) > 70))
        return "running"
    end),
})
tactician.tree = root
tactician.names = tree.names(root)

-- The persona of this fighter: the match option (a number, or a name from the arena), else a random one of its kit,
-- chosen once with the brain's random stream (memory.persona keeps its number; 0 before the first tick).
local function persona_of(context)
    local memory, state = context.memory, context.state
    local kit = kits.of(context.self.record.id)
    if memory.persona == 0 then
        local choice = state.ai_personas and state.ai_personas[context.index]
        local entry = kits.persona(kit, choice)
        local number = -1
        if entry then
            for position, candidate in ipairs(kit.personas) do if candidate == entry then number = position end end
        elseif kit then
            number = context.random(#kit.personas) + 1
        end
        memory.persona = number
    end
    if state.ai_persona_values and state.ai_persona_values[context.index] then return state.ai_persona_values[context.index], kit end
    return full_persona(kit and kit.personas[memory.persona]), kit
end

-- Counts the result of the last try when its time is over, or at once (`now`) when a new try starts.
learn = function(context, now)
    local memory, state = context.memory, context.state
    if memory.try_move == 0 or (state.frame_number < memory.try_until and not now) then return end
    local target = state.items[memory.try_target]
    local hit = target ~= nil and target.hp < memory.try_hp
    local slot
    for position = 1, #memory.learn_moves do
        if memory.learn_moves[position] == memory.try_move then slot = position end
    end
    if not slot and #memory.learn_moves < learn_size then
        slot = #memory.learn_moves + 1
        memory.learn_moves[slot], memory.learn_tries[slot], memory.learn_hits[slot] = memory.try_move, 0, 0
    end
    if slot then
        memory.learn_tries[slot] = memory.learn_tries[slot] + 1
        if hit then memory.learn_hits[slot] = memory.learn_hits[slot] + 1 end
        if context.log then
            context.log(state, context.index, string.format("ev=result m=%d hit=%d tries=%d hits=%d", memory.try_move, hit and 1 or 0,
                memory.learn_tries[slot], memory.learn_hits[slot]))
        end
    end
    memory.try_move = 0
end

local board = {}
function tactician.tick(context)
    learn(context)
    local memory, state = context.memory, context.state
    local now = state.frame_number
    for key in pairs(board) do board[key] = nil end
    -- The persona: the match's copy (live edits in the development view), the kit's, or the generic one.
    board.persona, board.kit = persona_of(context)
    -- The hits that it takes, with its class and intent on the tick before.
    if context.self.hp < memory.hp and context.log then
        context.log(state, context.index, string.format("ev=hurt hit=%d dmg=%d class=%s intent=%s", now - 1,
            memory.hp - context.self.hp, memory.class, (tactician.names[memory.intent] or "-"):gsub(" ", "_")))
    end
    memory.hp, memory.class = context.self.hp, context.me and context.me.class or ""
    local target = choose_target(context, board.persona)
    -- The reflexes run on every tick, the tree on a think. In a jump, a dash or a run the moment of the attack matters:
    -- it thinks on every tick there. Level of detail: far from its target it thinks three times less.
    local interval = context.row.think
    if target and math.abs(target.x - context.me.x) > 450 then interval = interval * 3 end
    local think = (now + context.index) % interval == 0 or (context.me and in_motion(context.me) ~= nil)
    if target and (think or (memory.reflex_until or -1) >= now) then
        board.target = target
        -- Where the target is now: the view is `delay` ticks old, so its position moves on by its speed. Whole pixels.
        board.delay = context.view.delay or 0
        board.tx = math.floor(target.x + target.vx * board.delay + 0.5)
        board.tz = math.floor(target.z + target.vz * board.delay + 0.5)
        local before = memory.path[2] or 0
        -- The view and the log keep the scores of the candidates.
        if context.log then board.scores = {} end
        tree.run(root, context, board, memory.path)
        if context.log then
            local path = {}
            for position, id in ipairs(memory.path) do path[position] = id end
            table.sort(board.scores, function(a, b)
                if a.value ~= b.value then return a.value > b.value end
                return a.start < b.start
            end)
            local best = board.scores[1]
            local intent = memory.path[2] or 0
            local frame = {intent = intent, intent_name = tactician.names[intent] or "-", path = path, target = target.index,
                dx = board.tx - context.me.x, dz = board.tz - context.me.z, delay = board.delay, scores = board.scores,
                hp = context.self.hp, mp = context.self.mp, program = memory.act_program, persona = board.persona}
            trace.frame(state, context.index, frame, string.format("intent=%s target=%d dx=%d dz=%d best=%s value=%d hp=%d mp=%d path=%s",
                frame.intent_name:gsub(" ", "_"), target.index, frame.dx, frame.dz, best and (best.name .. "/" .. best.start) or "-",
                best and best.value or 0, frame.hp, frame.mp, table.concat(path, ".")))
        end
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
    return string.format("intent:%s,target:%d,moves:%d,persona:%d", (tactician.names[memory.intent] or "-"):gsub(" ", "_"),
        memory.target, memory.moves, memory.persona)
end
return tactician
