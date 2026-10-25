-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The difficulty of the AI (OpenLF2 extension, docs/ai-plan.md "Personas, difficulty and fighter kits"): how well a
-- brain sees and types, apart from its personality. The four classic levels have human limits, from weak to strong.
-- Superhuman has none, and it uses the game rules of Crazy.
--
-- A row: reaction (ticks of the delayed view), rate ("human": keys change only on the ticks where human keys change,
-- "fast": on every tick), keys_per_second (the most key changes a second), timing_error (the most ticks that a key
-- comes late), noise (the most pixels that a distance is wrong), attention (sources followed closely), full_book
-- (whether the planner knows every move), think (ticks between two thinks).
local constants = require("base/game/constants")
local difficulty = {}

difficulty.rows = {
    easy = {name = "easy", reaction = 12, rate = "human", keys_per_second = 4, timing_error = 4, noise = 30, attention = 2,
        full_book = false, think = 6},
    normal = {name = "normal", reaction = 9, rate = "human", keys_per_second = 6, timing_error = 2, noise = 18, attention = 3,
        full_book = false, think = 5},
    difficult = {name = "difficult", reaction = 6, rate = "human", keys_per_second = 8, timing_error = 1, noise = 8,
        attention = 4, full_book = true, think = 4},
    crazy = {name = "crazy", reaction = 4, rate = "human", keys_per_second = 10, timing_error = 0, noise = 4, attention = 5,
        full_book = true, think = 3},
    superhuman = {name = "superhuman", reaction = 0, rate = "fast", keys_per_second = 30, timing_error = 0, noise = 0,
        attention = 8, full_book = true, think = 2},
}

local by_difficulty = {[constants.difficulties.easy] = "easy", [constants.difficulties.normal] = "normal",
    [constants.difficulties.difficult] = "difficult", [constants.difficulties.crazy] = "crazy"}

-- The row of a fight: its AI level (match option ai_level), or the row of its game difficulty.
function difficulty.of(state)
    return difficulty.rows[state.ai_level or ""] or difficulty.rows[by_difficulty[state.difficulty] or "crazy"]
end
return difficulty
