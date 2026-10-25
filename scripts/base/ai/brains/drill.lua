-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain `drill` (docs/ai-plan.md phase 6): a test brain that types every special move of its fighter's book
-- through the actuator, from standing and from a jump, and logs whether the move started and after how many ticks
-- (`ev=drill ... result=ok latency=N` or `result=fail why=...`). It turns away from the nearest enemy first, so its
-- moves do not end the fight. tools/ai_drill_check.py reads the log. The difficulty sets the typing rate.
local actuator = require("base/ai/actuator")
local difficulty = require("base/ai/difficulty")
local perception = require("base/ai/perception")
local drill = {name = "drill", version = 1}
local settle_ticks, watch_ticks, wait_limit = 4, 40, 900

-- The tests of a book: each special move with each of its inputs, from standing (a free source frame) and from a jump
-- (a source frame in the jumping state). Fixed data, cached by book.
local cache = {}
local function tests_of(book)
    local tests = cache[book]
    if tests then return tests end
    tests = {}
    for _, move in ipairs(book.moves) do
        if move.kind == "special" then
            for _, entry in ipairs(move.inputs) do
                local stand, jump = false, false
                for _, source in ipairs(entry.sources) do
                    if book.class[source] == "free" then stand = true end
                    if source >= 210 and source <= 212 then jump = true end
                end
                if stand then tests[#tests + 1] = {move = move, input = entry.input, from = "stand"} end
                if jump then tests[#tests + 1] = {move = move, input = entry.input, from = "jump"} end
            end
        end
    end
    cache[book] = tests
    return tests
end

function drill.start(state, index, seed)
    local memory = {version = drill.version, rng = seed, test = 1, phase = "settle", since = state.frame_number, ok = 0,
        failed = 0, right = 1}
    actuator.start(memory)
    return memory
end

local function nearest_enemy(state, world, me)
    local best, distance = nil, math.huge
    for _, other in ipairs(world.list) do
        if other.character and other.hp > 0 and perception.enemy(state, me, other) then
            local d = math.abs(other.x - me.x) + math.abs(other.z - me.z)
            if d < distance then best, distance = other, d end
        end
    end
    return best
end

local function finish(state, index, memory, log, test, result, detail)
    if result == "ok" then memory.ok = memory.ok + 1 else memory.failed = memory.failed + 1 end
    if log then
        log(state, index, string.format("ev=drill n=%d move=%d name=%s input=%s from=%s rate=%s result=%s %s", memory.test,
            test.move.start, test.move.name, test.input, test.from, difficulty.of(state).rate, result, detail))
    end
    memory.test, memory.phase, memory.since = memory.test + 1, "settle", state.frame_number
    actuator.hold(memory, 0)
end

function drill.tick(state, index, memory, scan, log, book)
    local self = state.items[index]
    local row = difficulty.of(state)
    local world = perception.world(state, scan)
    local me = world.entries[index]
    local tests = tests_of(book)
    local test = tests[memory.test]
    local now = state.frame_number
    if not test then
        if memory.phase ~= "done" then
            memory.phase = "done"
            if log then log(state, index, string.format("ev=drill_done total=%d ok=%d fail=%d", #tests, memory.ok, memory.failed)) end
        end
        actuator.hold(memory, 0)
    elseif memory.phase == "settle" then
        -- Stand still, free and on the ground, with the mp of the move, then turn the move away from the enemy.
        local ready = me.class == "free" and me.y == 0 and self.mp >= test.move.mp and self.hp > test.move.hp
        if not ready then memory.since = now end
        if now - memory.since >= settle_ticks then
            local enemy = nearest_enemy(state, world, me)
            memory.right = (enemy and enemy.x < me.x) and 1 or 0
            if test.from == "jump" then
                actuator.program(memory, {actuator.bits.jump}, 0)
                memory.phase, memory.since = "jump", now
            else
                actuator.type_input(memory, self, test.input, memory.right == 1, row.rate)
                memory.phase, memory.since = "watch", now
            end
        elseif now - memory.since > wait_limit then
            finish(state, index, memory, log, test, "fail", "why=never_ready mp=" .. self.mp)
        end
    elseif memory.phase == "jump" then
        if me.state == 4 and me.y < -20 then
            actuator.type_input(memory, self, test.input, memory.right == 1, row.rate)
            memory.phase, memory.since = "watch", now
        elseif now - memory.since > watch_ticks then
            finish(state, index, memory, log, test, "fail", "why=no_jump frame=" .. self.frame)
        end
    elseif memory.phase == "watch" then
        -- The move entered in the control of the last tick, so it shows in this tick's frame (or a later frame of it).
        local at = book.move_at[self.frame]
        if at and at.move == test.move and memory.act_started >= 0 then
            finish(state, index, memory, log, test, "ok", string.format("latency=%d", now - 1 - memory.act_started))
        elseif now - memory.since > watch_ticks then
            finish(state, index, memory, log, test, "fail", string.format("why=not_started frame=%d mp=%d", self.frame, self.mp))
        end
    end
    actuator.tick(state, self, memory, row)
end

function drill.describe(memory)
    return string.format("test:%d,ok:%d,fail:%d", memory.test, memory.ok, memory.failed)
end
return drill
