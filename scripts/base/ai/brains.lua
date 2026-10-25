-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain registry of the AI (OpenLF2 extension, docs/ai-plan.md): the match asks it to control each computer
-- fighter. A fighter's brain is the name in its memory (`value.ai.brain`), or the match's `ai_brains[index]`, or the
-- match's `ai_brain`, or `classic` (the original's routines, base/game/ai). A brain other than `classic` keeps its
-- memory in `value.ai`, in the match table, so a rollback saves and restores it, and it uses its own random stream
-- (base/ai/random). A brain starts again when the fighter's record changes (a transform or a merge changes
-- `value.record` in place) and when the computer takes a human fighter again (base/game/match read_control).
--
-- The rules for brains (docs/ai-plan.md "Rules for brains"; --rollback-check checks the memory):
--   the memory holds numbers, short strings, booleans and dense arrays of them: no functions, no tables of the move
--   book or the snapshot, no field named record, records, stage, view, capture or last_snapshot (base/game/rollback
--   shares these names at any depth), at most 64 fields and 8 arrays of at most 32 entries;
--   a brain updates its arrays in place, never walks a table with pairs or next, uses no math.exp, math.log,
--   trigonometric functions or ^ with a fraction, compares whole numbers, uses only its own random stream after its
--   start, writes the trace and never reads it, and never reads a timer.
--
-- A brain is a table {name, version, interface, start, tick, describe}. Interface 2 (docs/ai-plan.md "Brain context")
-- calls tick(context) with one reused table: state, index, self (the fighter), memory, scan, world (the snapshot), me
-- (this fighter's entry), view (the delayed view for the reaction of the difficulty), book, row (the difficulty row),
-- persona (or nil), log (or nil) and random(range) (the brain's stream). A brain never keeps the context.
-- Interface 1 (the default) calls:
--   start(state, index, seed) returns the memory (numbers, short strings and short arrays only);
--   tick(state, index, memory, scan, log, book) writes the keys of item `index` for this tick. `scan` is ai.prepare's
--     scan of the tick. `log` is nil, or a function(state, index, text) that writes an event to the trace. `book` is
--     the move book of the fighter's record (base/ai/move_book). It is fixed data: a brain keeps frame numbers in its
--     memory, never the book's tables, because a rollback copies the memory;
--   describe(memory) returns a short text without spaces or braces for the fight description (optional).
local random = require("base/ai/random")
local trace = require("base/ai/trace")
local classic = require("base/ai/brains/classic")
local move_book = require("base/ai/move_book")
local rollback = require("base/game/rollback")
local perception = require("base/ai/perception")
local difficulty = require("base/ai/difficulty")
local brains = {}

local context = {}
function context.random(range) return random.next(context.memory, range) end

-- The names that base/game/rollback shares instead of copying, at any depth (its `shared_keys`).
local banned = {record = true, records = true, stage = true, view = true, capture = true, last_snapshot = true}
local field_limit, array_limit, array_length = 64, 8, 32

-- Checks a brain's memory against the rules (with --rollback-check). Raises an error that names the field.
function brains.validate(memory, name)
    local fields, arrays = 0, 0
    for key, value in pairs(memory) do
        local where = name .. " memory." .. tostring(key)
        assert(type(key) == "string", where .. ": the memory's keys must be names")
        assert(not banned[key], where .. ": base/game/rollback shares this name, so a rollback would not copy it")
        fields = fields + 1
        local kind = type(value)
        if kind == "table" then
            arrays = arrays + 1
            local length = #value
            assert(length <= array_length, where .. ": an array holds at most " .. array_length .. " entries")
            local count = 0
            for inner_key, inner in pairs(value) do
                count = count + 1
                assert(type(inner_key) == "number" and inner_key >= 1 and inner_key <= length and inner_key % 1 == 0,
                    where .. ": a memory table must be a dense array")
                local inner_kind = type(inner)
                assert(inner_kind == "number" or inner_kind == "boolean" or (inner_kind == "string" and #inner <= 64),
                    where .. ": an array holds numbers, booleans and short strings only")
            end
            assert(count == length, where .. ": a memory table must be a dense array")
        else
            assert(kind == "number" or kind == "boolean" or (kind == "string" and #value <= 64),
                where .. ": a memory field holds a number, a boolean, a short string or an array")
        end
    end
    assert(fields <= field_limit, name .. " memory: more than " .. field_limit .. " fields")
    assert(arrays <= array_limit, name .. " memory: more than " .. array_limit .. " arrays")
end

local registry = {classic = classic, idle = require("base/ai/brains/idle"), sentry = require("base/ai/brains/sentry"),
    drill = require("base/ai/brains/drill"), guard = require("base/ai/brains/guard"),
    tactician = require("base/ai/brains/tactician")}

-- The brains of the computer fighters of local fights when the match names none (--ai-brain, a developer option;
-- base/ui/match_screen applies it): `default` for all of them, `by_index` for single item indices. nil means
-- `classic`.
brains.default = nil
brains.by_index = nil

-- Reads the value of --ai-brain: "NAME" for all computer fighters, "INDEX=NAME" for one fighter, or a list of both,
-- such as "idle,11=sentry". Returns the default name (or nil) and a table of names by item index (or nil). Raises an
-- error for an unknown brain.
function brains.parse(text)
    local default, by_index
    for part in text:gmatch("[^,]+") do
        local index, name = part:match("^(%d+)=([a-z_]+)$")
        name = name or part
        assert(registry[name], "unknown brain: " .. name)
        if index then
            by_index = by_index or {}
            by_index[tonumber(index)] = name
        else
            default = name
        end
    end
    return default, by_index
end

-- Adds a brain, for example from a mod. The name must be lower-case letters and underscores.
function brains.register(brain)
    assert(type(brain.name) == "string" and brain.name:match("^[a-z_]+$"), "a brain needs a lower-case name")
    assert(brain.name == "classic" or (type(brain.start) == "function" and type(brain.tick) == "function"),
        "a brain needs start and tick")
    registry[brain.name] = brain
end

function brains.known(name) return registry[name] ~= nil end
-- The module of a brain, for the development view (its tree and node names), or nil.
function brains.get(name) return registry[name] end
-- The names of the registered brains, sorted.
function brains.names()
    local list = {}
    for name in pairs(registry) do list[#list + 1] = name end
    table.sort(list)
    return list
end

-- The AI time by brain name ({ms, calls}), measured only while the arena sets this table (base/game/arena). A timer
-- never reaches a decision: it measures around the brain.
brains.timing = nil

local control
-- Writes the keys of the computer fighter in `state.items[index]` for this tick.
function brains.control(state, index, scan)
    local timing = brains.timing
    if not timing then return control(state, index, scan) end
    local started = engine.network_time()
    control(state, index, scan)
    local value = state.items[index]
    local name = value and value.ai and value.ai.brain or "classic"
    local entry = timing[name]
    if not entry then entry = {ms = 0, calls = 0}; timing[name] = entry end
    entry.ms, entry.calls = entry.ms + engine.network_time() - started, entry.calls + 1
end

control = function(state, index, scan)
    local value = state.items[index]
    local memory = value.ai
    local name = memory and memory.brain or (state.ai_brains and state.ai_brains[index]) or state.ai_brain
    local brain = registry[name]
    if brain == nil or brain == classic then return classic.tick(state, index, scan) end
    local logging = trace.active(state, index)
    if not memory or memory.record_id ~= value.record.id then
        -- A new start, or a new record: the memory's frame numbers belong to the old move book. A restart takes its
        -- seed from the old stream, so it calls engine.random only once per fighter.
        local seed = memory and random.next(memory, 2147483646) + 1 or random.seed(state, index, value.record.id)
        memory = brain.start(state, index, seed)
        memory.brain, memory.record_id = name, value.record.id
        value.ai = memory
        if logging then
            trace.add(state, index, string.format("ev=start brain=%s version=%d id=%d", name, brain.version or 0, value.record.id))
        end
    end
    if brain.interface == 2 then
        local row = difficulty.of(state, index)
        local world = perception.world(state, scan)
        context.state, context.index, context.self, context.memory, context.scan = state, index, value, memory, scan
        context.world, context.me, context.book, context.row = world, world.entries[index], move_book.get(value.record), row
        context.view = perception.view(state, scan, row.reaction, index)
        context.persona = state.ai_personas and state.ai_personas[index] or nil
        context.log = logging and trace.add or nil
        brain.tick(context)
        context.memory, context.self = nil, nil
    else
        brain.tick(state, index, memory, scan, logging and trace.add or nil, move_book.get(value.record))
    end
    if rollback.check then brains.validate(memory, name) end
end

-- The text of the fight description for a fighter with a brain other than `classic`, or nil.
function brains.describe(value)
    local memory = value.ai
    if not memory then return nil end
    local brain = registry[memory.brain]
    local detail = brain and brain.describe and brain.describe(memory)
    return detail and (memory.brain .. "/" .. detail) or memory.brain
end
return brains
