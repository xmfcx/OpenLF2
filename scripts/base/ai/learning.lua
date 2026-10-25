-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Learning across fights (OpenLF2 extension, docs/ai-plan.md "Learning"): the move results of the brains (the
-- tactician's learn arrays) by fighter id, kept in config.json in local games and on the server in network sessions,
-- and given to the next fight as the match option `ai_learning`. A store: {[id as text] = {moves = {...}, tries =
-- {...}, hits = {...}}}. Old results fade: when a move has more than `limit` tries, its counts halve.
local learning = {}
local limit, moves_limit = 60, 12

-- A clean store from untrusted data (config.json or a network message): numbers only, short arrays.
function learning.clean(store)
    local result = {}
    if type(store) ~= "table" then return result end
    for key, entry in pairs(store) do
        local id = tonumber(key)
        if id and type(entry) == "table" and type(entry.moves) == "table" then
            local clean = {moves = {}, tries = {}, hits = {}}
            for position = 1, math.min(#entry.moves, moves_limit) do
                local move, tries, hits = tonumber(entry.moves[position]), tonumber((entry.tries or {})[position]),
                    tonumber((entry.hits or {})[position])
                if move and tries and hits then
                    local count = #clean.moves + 1
                    clean.moves[count], clean.tries[count] = math.floor(move), math.max(0, math.floor(tries))
                    clean.hits[count] = math.max(0, math.min(math.floor(hits), clean.tries[count]))
                end
            end
            result[tostring(math.floor(id))] = clean
        end
    end
    return result
end

-- Adds the results of the brains of a finished fight (`match`, the match table) to `store` (changed in place). The
-- fighters go in slot order, so every computer of a network game gets the same store.
function learning.merge(store, match)
    for index = 0, 399 do
        local value = match.items[index]
        local memory = value and value.ai
        if memory and memory.learn_moves and memory.record_id then
            local key = tostring(memory.record_id)
            local entry = store[key] or {moves = {}, tries = {}, hits = {}}
            store[key] = entry
            -- The memory starts from the store, so its counts already hold the earlier fights: they replace them.
            for position = 1, #memory.learn_moves do
                local move = memory.learn_moves[position]
                local slot
                for existing = 1, #entry.moves do
                    if entry.moves[existing] == move then slot = existing end
                end
                if not slot and #entry.moves < moves_limit then
                    slot = #entry.moves + 1
                    entry.moves[slot] = move
                end
                if slot then
                    local tries, hits = memory.learn_tries[position], memory.learn_hits[position]
                    if tries > limit then tries, hits = math.floor(tries / 2), math.floor(hits / 2) end
                    entry.tries[slot], entry.hits[slot] = tries, hits
                end
            end
        end
    end
    return store
end

-- The match option `ai_learning` for the computer fighters of match options `options` (by item index: a computer of
-- slot s is item s + 10), from `store`.
function learning.options_for(store, options)
    if not store or not options.slots then return nil end
    local result
    for slot = 0, 7 do
        local entry = options.slots[slot]
        local fighter = entry and entry.kind == "computer" and options.fighters and options.fighters[entry.fighter]
        local known = fighter and store[tostring(fighter.id)]
        if known then
            result = result or {}
            result[slot + 10] = known
        end
    end
    return result
end

-- The store of this computer (local games), from config.json.
function learning.load()
    local document = engine.read_settings()
    return learning.clean(type(document) == "table" and document.ai_learning or nil)
end

function learning.save(store)
    local document = engine.read_settings()
    if type(document) ~= "table" then document = {} end
    document.ai_learning = store
    engine.write_settings(document)
end
return learning
