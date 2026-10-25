-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Rollback support (OpenLF2 extension, docs/netcode.md): a fight's state can be saved, restored and hashed, so that
-- a network client can go back to an earlier tick and run it again with corrected keys. The state of a fight is the
-- match table (base/game/match) and the position of the engine's random streams. Fixed game data reachable from it
-- (the object records, the stage description) is shared between the saved states, not copied.
local rollback = {}

-- Fields that hold data a fight never changes, or that only draw: kept as they are.
local shared_keys = {
    record = true,        -- an item's object record (frames, data file)
    records = true,       -- the match's cache of object records by id (base/game/objects)
    stage = true,         -- the background or stage description
    capture = true,       -- the match screen's snapshot function
    last_snapshot = true, -- what the last tick drew
    view = true,          -- the background's animation counters, which drawing advances
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    local done = seen[value]
    if done then return done end
    local result = {}
    seen[value] = result
    for key, entry in pairs(value) do
        if shared_keys[key] then result[key] = entry
        else result[copy(key, seen)] = copy(entry, seen) end
    end
    return result
end

-- A deep copy of a frame's input, to run it again.
function rollback.copy_input(held)
    return copy(held, {})
end

-- A saved state: a copy of the match and the position of the random streams.
function rollback.save(match)
    local index, sequence, crt = engine.random_position()
    return {match = copy(match, {}), random = {index, sequence, crt}}
end

-- Puts a saved state back into `match` (the same table, so that holders of it stay valid). The saved state stays
-- usable for another restore.
function rollback.restore(match, saved)
    local fresh = copy(saved.match, {})
    for key in pairs(match) do match[key] = nil end
    for key, value in pairs(fresh) do match[key] = value end
    engine.set_random_position(saved.random[1], saved.random[2], saved.random[3])
end

-- A hash of the state, the same on every computer for the same state: the fields in a fixed order, numbers with all
-- their digits. Two sums modulo primes below 2^31 keep every step exact in a double.
local prime_a, prime_b = 2147483629, 2147483587
local function feed(sums, text)
    local a, b = sums[1], sums[2]
    for position = 1, #text do
        local byte = text:byte(position)
        a = (a * 257 + byte) % prime_a
        b = (b * 263 + byte) % prime_b
    end
    sums[1], sums[2] = a, b
end
local function key_order(left, right)
    local left_type, right_type = type(left), type(right)
    if left_type ~= right_type then return left_type < right_type end
    if left_type == "number" or left_type == "string" then return left < right end
    return tostring(left) < tostring(right)
end
local function hash_value(sums, value, seen)
    local kind = type(value)
    if kind == "number" then
        feed(sums, string.format("n%.17g;", value))
    elseif kind == "string" then
        feed(sums, "s" .. #value .. ":" .. value)
    elseif kind == "boolean" then
        feed(sums, value and "T" or "F")
    elseif kind == "table" then
        -- A table met again is fed as its first visit's number, so shared links count but loops end.
        local visit = seen[value]
        if visit then
            feed(sums, "r" .. visit .. ";")
            return
        end
        seen.count = seen.count + 1
        seen[value] = seen.count
        local keys = {}
        for key in pairs(value) do
            if not shared_keys[key] and type(value[key]) ~= "function" then keys[#keys + 1] = key end
        end
        table.sort(keys, key_order)
        feed(sums, "{")
        -- The object of an item is shared data, but which object it is belongs to the state: two clients with
        -- different fighters must never give the same hash.
        local record = value.record
        if type(record) == "table" and record.id then feed(sums, "o" .. record.id .. ";") end
        for _, key in ipairs(keys) do
            hash_value(sums, key, seen)
            hash_value(sums, value[key], seen)
        end
        feed(sums, "}")
    end
end
function rollback.hash(match)
    local sums = {0, 0}
    hash_value(sums, match, {count = 0})
    local index, sequence, crt = engine.random_position()
    feed(sums, string.format("random%d,%d,%d", index, sequence, crt))
    return string.format("%08x%08x", sums[1], sums[2])
end

-- The same hash for a saved state (rollback.save), without restoring it.
function rollback.hash_saved(saved)
    local sums = {0, 0}
    hash_value(sums, saved.match, {count = 0})
    feed(sums, string.format("random%d,%d,%d", saved.random[1], saved.random[2], saved.random[3]))
    return string.format("%08x%08x", sums[1], sums[2])
end

-- For finding state that a rollback misses: a hash of each field of the match, and of each field of each item.
function rollback.field_hashes(match)
    local result = {}
    local function one(value)
        local sums = {0, 0}
        hash_value(sums, value, {count = 0})
        return string.format("%08x%08x", sums[1], sums[2])
    end
    for key, value in pairs(match) do
        if key ~= "items" and not shared_keys[key] and type(value) ~= "function" then result[tostring(key)] = one(value) end
    end
    for index, value in pairs(match.items) do
        for key, field in pairs(value) do
            if not shared_keys[key] and type(field) ~= "function" then result["items." .. index .. "." .. tostring(key)] = one(field) end
        end
    end
    local index, sequence, crt = engine.random_position()
    result.random = index .. "," .. sequence .. "," .. crt
    return result
end

-- The desync report (docs/netcode.md "Desync checks"): a short text of a saved state that goes with each hash to the
-- server. Two clients with the same state give the same text, so a difference shows what differs: the frame, the
-- random streams, each fighter in slots 0-19 (object id, hp, mp, place) and the number of other items.
function rollback.summary(saved)
    local match = saved.match
    local parts = {string.format("frame=%d random=%d,%d,%d", match.frame_number or 0, saved.random[1], saved.random[2],
        saved.random[3])}
    local others = 0
    for index, value in pairs(match.items) do
        if index >= 20 then others = others + 1 end
    end
    for index = 0, 19 do
        local value = match.items[index]
        if value then
            parts[#parts + 1] = string.format("item%d=id%d,hp%d,mp%d,at%d,%d,%d", index, value.record and value.record.id or -1,
                value.hp, value.mp, value.x_int, value.y_int, value.z_int)
        end
    end
    parts[#parts + 1] = "others=" .. others
    return table.concat(parts, " ")
end

-- The explanation of a difference: hashes of the parts of a saved state. Without `item`: each field of the match and
-- each item as a whole (with its object id); with `item`: each field of that item. The server compares the clients'
-- parts and logs the names that differ.
function rollback.explain(saved, item)
    local result = {}
    local function one(value)
        local sums = {0, 0}
        hash_value(sums, value, {count = 0})
        return string.format("%08x", sums[1])
    end
    if item then
        local value = saved.match.items[item]
        if not value then return result end
        for key, field in pairs(value) do
            if not shared_keys[key] and type(field) ~= "function" then result[tostring(key)] = one(field) end
        end
        result.object = tostring(value.record and value.record.id)
        return result
    end
    for key, value in pairs(saved.match) do
        if key ~= "items" and not shared_keys[key] and type(value) ~= "function" then result[tostring(key)] = one(value) end
    end
    for index, value in pairs(saved.match.items) do
        result["item" .. index] = one(value) .. "/" .. tostring(value.record and value.record.id)
    end
    result.random = table.concat(saved.random, ",")
    return result
end

-- For tuning the shared fields: how many tables and entries each field of the match holds (copied ones only).
function rollback.inventory(match)
    local function count(value, seen)
        if type(value) ~= "table" or seen[value] then return 0 end
        seen[value] = true
        local total = 1
        for key, entry in pairs(value) do
            if not shared_keys[key] then total = total + 1 + count(entry, seen) end
        end
        return total
    end
    local parts, seen = {}, {}
    local keys = {}
    for key, value in pairs(match) do
        if not shared_keys[key] then keys[#keys + 1] = key end
    end
    table.sort(keys, key_order)
    for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. count(match[key], seen) end
    return table.concat(parts, ",")
end

-- The check of --rollback-check (base/ui/match_screen): every `interval` ticks the screen saves the state, keeps the
-- next `span` inputs, then goes back and runs them again. The two runs must end with the same hash.
rollback.check = false
rollback.interval, rollback.span = 45, 8

return rollback
