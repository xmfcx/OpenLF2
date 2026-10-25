-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The brain registry of the AI (OpenLF2 extension, docs/ai-plan.md): the match asks it to control each computer
-- fighter. A fighter's brain is the name in its memory (`value.ai.brain`), or the match's `ai_brain`, or `classic`
-- (the original's routines, base/game/ai). A brain other than `classic` keeps its memory in `value.ai`, in the match
-- table, so a rollback saves and restores it, and it uses its own random stream (base/ai/random).
--
-- A brain is a table {name, version, start, tick, describe}:
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
local brains = {}

local registry = {classic = classic, idle = require("base/ai/brains/idle")}

-- The brain that the computer fighters of local fights use when the match names none (--ai-brain, a developer
-- option; base/ui/match_screen applies it). nil means `classic`.
brains.default = nil

-- Adds a brain, for example from a mod. The name must be lower-case letters and underscores.
function brains.register(brain)
    assert(type(brain.name) == "string" and brain.name:match("^[a-z_]+$"), "a brain needs a lower-case name")
    assert(brain.name == "classic" or (type(brain.start) == "function" and type(brain.tick) == "function"),
        "a brain needs start and tick")
    registry[brain.name] = brain
end

function brains.known(name) return registry[name] ~= nil end

-- Writes the keys of the computer fighter in `state.items[index]` for this tick.
function brains.control(state, index, scan)
    local value = state.items[index]
    local memory = value.ai
    local name = memory and memory.brain or state.ai_brain
    local brain = registry[name]
    if brain == nil or brain == classic then return classic.tick(state, index, scan) end
    local logging = trace.active(state, index)
    if not memory then
        memory = brain.start(state, index, random.seed(state, index, value.record.id))
        memory.brain = name
        value.ai = memory
        if logging then
            trace.add(state, index, string.format("ev=start brain=%s version=%d id=%d", name, brain.version or 0, value.record.id))
        end
    end
    brain.tick(state, index, memory, scan, logging and trace.add or nil, move_book.get(value.record))
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
