-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The senses of a brain (OpenLF2 extension, docs/ai-plan.md "Senses"): a brain notices that an enemy starts a move,
-- or that a ball flies, only after its reaction time, and it follows only a few sources at once (its attention). The
-- record lives in the brain's memory as three short arrays (the item index, a key for what it does, the tick when the
-- brain first saw it), so a rollback saves it.
local senses = {}

-- What a source does, as a number: the start frame of a character's move (-1 when it does not attack), or for a flying
-- object a negative number from its spawn tick and record id, so that a new object in a reused slot is a new source.
local function key_of(entry)
    if entry.character then return entry.move and entry.move.start or -1 end
    return -2 - (entry.born * 1000 + entry.id)
end

-- Scratch lists of this module: rebuilt on each call, never kept by a brain.
local candidates, distances, new_index, new_key, new_since = {}, {}, {}, {}, {}
local function nearer(a, b)
    if distances[a] ~= distances[b] then return distances[a] < distances[b] end
    return a.index < b.index
end

-- Looks at the `limit` nearest hostile sources (attacking characters and flying objects) on this tick and updates the
-- record in `memory` in place.
function senses.update(memory, state, world, self, limit, hostile)
    for position = #candidates, 1, -1 do candidates[position] = nil end
    for _, other in ipairs(world.list) do
        if (other.ball or (other.character and other.move)) and hostile(state, self, other) then
            candidates[#candidates + 1] = other
            distances[other] = math.abs(other.x - self.x) + math.abs(other.z - self.z)
        end
    end
    table.sort(candidates, nearer)
    local old_index, old_key, old_since = memory.seen_index, memory.seen_key, memory.seen_since
    if not old_index then
        old_index, old_key, old_since = {}, {}, {}
        memory.seen_index, memory.seen_key, memory.seen_since = old_index, old_key, old_since
    end
    local count = math.min(limit, #candidates)
    for position = 1, count do
        local entry = candidates[position]
        local key = key_of(entry)
        local since = world.tick
        for old = 1, #old_index do
            if old_index[old] == entry.index and old_key[old] == key then since = old_since[old] end
        end
        new_index[position], new_key[position], new_since[position] = entry.index, key, since
    end
    for position = 1, count do
        old_index[position], old_key[position], old_since[position] = new_index[position], new_key[position], new_since[position]
    end
    for position = #old_index, count + 1, -1 do old_index[position], old_key[position], old_since[position] = nil, nil, nil end
    for entry in pairs(distances) do distances[entry] = nil end
end

-- Whether the brain noticed what `entry` does now, `reaction` ticks after it saw it first.
function senses.noticed(memory, world, entry, reaction)
    local list = memory.seen_index
    if not list then return false end
    local key = key_of(entry)
    for position = 1, #list do
        if list[position] == entry.index and memory.seen_key[position] == key then
            return world.tick - memory.seen_since[position] >= reaction
        end
    end
    return false
end
return senses
