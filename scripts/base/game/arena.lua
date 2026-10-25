-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The arena (OpenLF2 extension, docs/ai-plan.md "Arena", developer option --fight SPEC --fights N): headless fights of
-- computer fighters, one whole fight in each frame, without drawing. Each fight writes an `ai-result` log line (and
-- `ai-moves` lines), and the run asks to quit after the last one. tools/ai-arena.py runs many of them.
--
-- SPEC: the sides separated by `|`, the fighters of a side separated by `,`, a fighter as NAME[/BRAIN[/PERSONA]]
-- (the data name such as davis or louisex, or the id), then `;key=value` options:
--   time=TICKS (3600: at the limit the side with more hp wins, equal hp is a draw), difficulty=easy|normal|difficult|
--   crazy|superhuman (crazy), background=ROW (1), seed=N (1), mirror=0|1 (1: every seed plays twice, the second time
--   with the sides in swapped slots), first=K (the number of the first fight, for a single run of one fight), mp=N (the
--   mp of every fighter at the start).
-- Fight K uses seed + (K - 1) / 2 with mirroring (seed + K - 1 without), and the engine's random streams start from
-- that number alone, so a fight is the same in a batch and in a single run.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local match = require("base/game/match")
local ticks = require("base/game/ticks")
local brains = require("base/ai/brains")
local move_book = require("base/ai/move_book")
local ai_trace = require("base/ai/trace")
local record_kinds = constants.record_kinds
local arena = {}

local difficulties = {easy = constants.difficulties.easy, normal = constants.difficulties.normal,
    difficult = constants.difficulties.difficult, crazy = constants.difficulties.crazy,
    superhuman = constants.difficulties.crazy}

local function find_fighter(fighters, token)
    local number = tonumber(token)
    for position, fighter in ipairs(fighters) do
        if (number and fighter.id == number) or (not number and fighter.name:lower() == token) then return position, fighter end
    end
    error("arena: unknown fighter " .. token)
end

-- Reads SPEC into {sides = {{{fighter, brain, persona}...}...}, time, difficulty, level, background, seed, mirror, first}.
function arena.parse(text)
    local fighters = catalog.load()
    local parts = {}
    for part in (text .. ";"):gmatch("([^;]*);") do parts[#parts + 1] = part end
    local spec = {sides = {}, time = 3600, difficulty = difficulties.crazy, level = "crazy", background = 1, seed = 1,
        mirror = true, first = 1}
    for side_text in (parts[1] .. "|"):gmatch("([^|]*)|") do
        local side = {}
        for token in side_text:gmatch("[^,]+") do
            local name, brain, persona = token:match("^([^/]+)/?([^/]*)/?([^/]*)$")
            assert(name, "arena: a fighter is NAME[/BRAIN[/PERSONA]]: " .. token)
            local position, fighter = find_fighter(fighters, name)
            brain = brain ~= "" and brain or "classic"
            assert(brains.known(brain), "arena: unknown brain " .. brain)
            side[#side + 1] = {position = position, id = fighter.id, name = fighter.name:lower(), brain = brain,
                persona = persona ~= "" and persona or nil}
        end
        assert(#side > 0, "arena: a side needs a fighter")
        spec.sides[#spec.sides + 1] = side
    end
    assert(#spec.sides == 2, "arena: a fight needs two sides, A|B")
    for position = 2, #parts do
        local key, value = parts[position]:match("^(%a+)=([%w_]+)$")
        if key == "time" then spec.time = assert(tonumber(value), "arena: time is a number")
        elseif key == "difficulty" then
            spec.difficulty = assert(difficulties[value], "arena: unknown difficulty " .. value)
            spec.level = value
        elseif key == "background" then spec.background = assert(tonumber(value), "arena: background is a number")
        elseif key == "seed" then spec.seed = assert(tonumber(value), "arena: seed is a number")
        elseif key == "mirror" then spec.mirror = value ~= "0"
        elseif key == "first" then spec.first = assert(tonumber(value), "arena: first is a number")
        elseif key == "mp" then spec.mp = assert(tonumber(value), "arena: mp is a number")
        elseif parts[position] ~= "" then error("arena: unknown option " .. parts[position]) end
    end
    return spec
end

function arena.create(options)
    local spec = arena.parse(options.fight)
    return {spec = spec, count = options.fights or 1, done = 0, text = options.fight}
end

-- The engine's random streams from one number: the shared table (3000 bytes) from a Park-Miller generator, the
-- position at its start and the C runtime's state.
local function seed_random(number)
    local value = number % 2147483646 + 1
    local bytes = {}
    for position = 1, 3000 do
        value = value * 48271 % 2147483647
        bytes[position] = string.char(value % 256)
    end
    engine.set_random_state(table.concat(bytes), 0)
    value = value * 48271 % 2147483647
    engine.set_random_position(0, 0, value % 4294967296)
end

-- The match options of fight `number`: every fighter is a computer, side 1 on team 1, side 2 on team 2.
local function options_of(spec, number)
    local mirrored = spec.mirror and (number - 1) % 2 == 1
    local seed = spec.mirror and spec.seed + math.floor((number - 1) / 2) or spec.seed + number - 1
    local order = mirrored and {2, 1} or {1, 2}
    local slots, brain_names, personas, members = {}, {}, {}, {}
    local slot = 0
    for _, side_number in ipairs(order) do
        for _, fighter in ipairs(spec.sides[side_number]) do
            assert(slot <= 7, "arena: at most 8 fighters")
            slots[slot] = {kind = "computer", fighter = fighter.position, team = constants.teams.player_one + side_number - 1}
            if fighter.brain ~= "classic" then brain_names[slot + 10] = fighter.brain end
            personas[slot + 10] = fighter.persona
            members[#members + 1] = {index = slot + 10, side = side_number, fighter = fighter}
            slot = slot + 1
        end
    end
    local options = {mode = constants.modes.versus, difficulty = spec.difficulty, background = spec.background,
        fighters = catalog.load(), backgrounds = catalog.backgrounds(), slots = slots,
        ai_brains = next(brain_names) and brain_names or nil, ai_personas = personas, ai_level = spec.level, start_mp = spec.mp}
    return options, seed, mirrored, members
end

local function side_hp(state, members, side)
    local total, alive = 0, false
    for _, member in ipairs(members) do
        local value = state.items[member.index]
        if member.side == side and value then
            total = total + math.max(value.hp, 0)
            if value.hp > 0 then alive = true end
        end
    end
    return total, alive
end

local function side_damage(state, members, side)
    local total = 0
    for _, member in ipairs(members) do
        local value = state.items[member.index]
        if member.side == side and value then total = total + value.damage_dealt end
    end
    return total
end

local function side_text(spec, side)
    local names = {}
    for _, fighter in ipairs(spec.sides[side]) do
        names[#names + 1] = fighter.name .. "/" .. fighter.brain .. (fighter.persona and ("/" .. fighter.persona) or "")
    end
    return table.concat(names, ",")
end

-- Runs fight `number` to its end and returns its log lines.
function arena.fight(spec, number)
    local options, seed, mirrored, members = options_of(spec, number)
    seed_random(seed)
    local state = match.create(options)
    if options.ai_brains then move_book.prepare_all() end
    ai_trace.watch(state, false)
    local held = ticks.held(ticks.empty())
    local previous, counts = {}, {}
    brains.timing = {}
    local winner, ticks_run = 0, 0
    for tick = 1, spec.time do
        match.step(state, held)
        ticks_run = tick
        -- Move use: a fighter that enters the start frame of a move of its book.
        for _, member in ipairs(members) do
            local value = state.items[member.index]
            if value then
                local frame = value.frame
                local book = move_book.get(value.record)
                if previous[member.index] ~= frame and book.by_start[frame] then
                    local list = counts[member.index] or {}
                    list[frame] = (list[frame] or 0) + 1
                    counts[member.index] = list
                end
                previous[member.index] = frame
            end
        end
        local _, one_alive = side_hp(state, members, 1)
        local _, two_alive = side_hp(state, members, 2)
        if not one_alive or not two_alive then
            winner = one_alive and 1 or (two_alive and 2 or 0)
            break
        end
    end
    local hp1, hp2 = side_hp(state, members, 1), side_hp(state, members, 2)
    if winner == 0 and ticks_run >= spec.time then winner = hp1 > hp2 and 1 or (hp2 > hp1 and 2 or 0) end
    -- The AI time for each brain: microseconds for each fighter and tick.
    local timing = {}
    for name, entry in pairs(brains.timing) do
        timing[#timing + 1] = string.format("%s:%.1f", name, entry.ms * 1000 / math.max(entry.calls, 1))
    end
    table.sort(timing)
    brains.timing = nil
    local lines = {string.format("ai-result fight=%d seed=%d mirror=%d winner=%d ticks=%d hp1=%d hp2=%d dmg1=%d dmg2=%d"
        .. " side1=%s side2=%s level=%s us=%s", number, seed, mirrored and 1 or 0, winner, ticks_run, hp1, hp2,
        side_damage(state, members, 1), side_damage(state, members, 2), side_text(spec, 1), side_text(spec, 2), spec.level,
        #timing > 0 and table.concat(timing, ",") or "-")}
    for _, member in ipairs(members) do
        local list = {}
        for frame, count in pairs(counts[member.index] or {}) do list[#list + 1] = {frame, count} end
        table.sort(list, function(a, b) return a[1] < b[1] end)
        local parts = {}
        for _, pair in ipairs(list) do parts[#parts + 1] = pair[1] .. ":" .. pair[2] end
        local line = string.format("ai-moves fight=%d side=%d i=%d id=%d moves=%s", number, member.side, member.index,
            member.fighter.id, #parts > 0 and table.concat(parts, ",") or "-")
        lines[#lines + 1] = #line > 500 and line:sub(1, 500) or line
    end
    return lines, state
end

-- One frame of the arena: the next fight, its log lines, and quit after the last one.
function arena.update(state, context)
    if state.done >= state.count then return end
    local number = state.spec.first + state.done
    local lines = arena.fight(state.spec, number)
    ai_trace.flush(context, true)
    for _, line in ipairs(lines) do context.action("log " .. line) end
    state.done = state.done + 1
    if state.done >= state.count then context.action("quit") end
end
return arena
