-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The senses of a brain (OpenLF2 extension, docs/ai-plan.md "Senses"): a brain notices that an enemy starts a move,
-- or that a ball flies, only after its reaction time, and it follows only a few sources at once (its attention). The
-- record lives in the brain's memory as three short arrays (the item index, a key for what it does, the tick when the
-- brain first saw it), so a rollback saves it.
local senses = {}

-- What a source does, as a number: the start frame of a character's move (-1 when it does not attack), or the
-- record id of a flying object plus 100000.
local function key_of(entry)
    if entry.character then return entry.move and entry.move.start or -1 end
    return 100000 + entry.id
end

-- Looks at the `limit` nearest hostile sources (attacking characters and flying objects) on this tick and updates the
-- record in `memory`.
function senses.update(memory, state, world, self, limit, hostile)
    local candidates = {}
    for _, other in ipairs(world.list) do
        if (other.ball or (other.character and other.move)) and hostile(state, self, other) then
            candidates[#candidates + 1] = {entry = other, distance = math.abs(other.x - self.x) + math.abs(other.z - self.z)}
        end
    end
    table.sort(candidates, function(a, b)
        if a.distance ~= b.distance then return a.distance < b.distance end
        return a.entry.index < b.entry.index
    end)
    local old_index, old_key, old_since = memory.seen_index or {}, memory.seen_key or {}, memory.seen_since or {}
    local index_list, key_list, since_list = {}, {}, {}
    for position = 1, math.min(limit, #candidates) do
        local entry = candidates[position].entry
        local key = key_of(entry)
        local since = world.tick
        for old = 1, #old_index do
            if old_index[old] == entry.index and old_key[old] == key then since = old_since[old] end
        end
        index_list[position], key_list[position], since_list[position] = entry.index, key, since
    end
    memory.seen_index, memory.seen_key, memory.seen_since = index_list, key_list, since_list
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
