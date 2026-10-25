-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The match setup (OpenLF2 extension, docs/pregame-ui-redesign.md "The match setup screen"): the shared values
-- before a fight, which change only through commands. A command that the rules do not allow does nothing, so every
-- computer that applies the same commands has the same setup. The screen (base/ui/setup_screen) draws it and turns
-- keys and clicks into commands; it never changes the setup itself.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local character_select = require("base/ui/character_select")
local modes, teams, difficulties = constants.modes, constants.teams, constants.difficulties
local setup = {}

-- The start shows a countdown of three seconds, which any player can stop.
setup.countdown_frames = 90
setup.stage_groups = 6
setup.mode_names = {[modes.versus] = "VS", [modes.stage] = "Stage", [modes.battle] = "Battle"}
setup.difficulty_order = {difficulties.easy, difficulties.normal, difficulties.difficult, difficulties.crazy}

-- mode: constants.modes.versus, stage or battle; previous: the setup of the last visit, whose values stay.
function setup.create(mode, previous)
    local state = {mode = mode, slots = {}, background = constants.background_rows.random, stage_level = 0,
        difficulty = difficulties.difficult, countdown = nil, changed_by = nil}
    for slot = 0, 7 do state.slots[slot] = {kind = nil, fighter = 0, team = teams.independent, ready = false} end
    if previous then
        for slot = 0, 7 do
            local before = previous.slots[slot]
            state.slots[slot] = {kind = before.kind, fighter = before.fighter, team = before.team, ready = before.ready}
        end
        state.background, state.stage_level, state.difficulty = previous.background, previous.stage_level, previous.difficulty
    end
    setup.apply(state, {type = "mode", value = mode})
    return state
end

local function allowed_team(state, team)
    if state.mode == modes.stage then return team == teams.player_one end
    if state.mode == modes.battle then return team == teams.player_one or team == teams.player_two end
    return team >= teams.independent and team <= teams.player_four
end
local function first_team(state, slot)
    if state.mode == modes.stage then return teams.player_one end
    if state.mode == modes.battle then return slot < 4 and teams.player_one or teams.player_two end
    return teams.independent
end
-- The next team of the mode after `team` (step 1 or -1), wrapping.
function setup.step_team(state, team, step)
    for _ = 1, 5 do
        team = (team + step) % 5
        if allowed_team(state, team) then return team end
    end
    return team
end
local function valid_fighter(fighters, value)
    return value == 0 or (fighters[value] ~= nil and catalog.selectable(fighters[value]))
end

-- Applies `command` ({type, slot, value}) and returns whether it changed the setup. The fighters list is the
-- catalog (fighter 0 is Random).
function setup.apply(state, command, fighters)
    local slot = tonumber(command.slot)
    local entry = slot and state.slots[slot]
    local kind = command.type
    -- During the countdown only `wait` acts: the others must stop it first.
    if state.countdown and kind ~= "wait" then return false end
    if kind == "mode" then
        local mode = tonumber(command.value)
        if mode ~= modes.versus and mode ~= modes.stage and mode ~= modes.battle then return false end
        state.mode = mode
        for index = 0, 7 do
            local other = state.slots[index]
            if other.kind and not allowed_team(state, other.team) then other.team = first_team(state, index) end
        end
        if mode == modes.battle and state.difficulty == difficulties.crazy then state.difficulty = difficulties.difficult end
        return true
    elseif kind == "join" then
        if not entry or entry.kind then return false end
        state.slots[slot] = {kind = "human", fighter = 0, team = first_team(state, slot), ready = false}
        return true
    elseif kind == "leave" or kind == "remove_computer" then
        if not entry or not entry.kind or (kind == "remove_computer") ~= (entry.kind == "computer") then return false end
        state.slots[slot] = {kind = nil, fighter = 0, team = teams.independent, ready = false}
        return true
    elseif kind == "add_computer" then
        if not entry or entry.kind then return false end
        -- A new computer is Random, on the first team that is not the team of every fighter so far.
        local team = first_team(state, slot)
        if state.mode == modes.versus then
            local used = {}
            for index = 0, 7 do
                if state.slots[index].kind then used[state.slots[index].team] = true end
            end
            for candidate = teams.player_one, teams.player_four do
                if not used[candidate] then team = candidate break end
            end
        end
        state.slots[slot] = {kind = "computer", fighter = 0, team = team, ready = true}
        return true
    elseif kind == "fighter" then
        local value = tonumber(command.value)
        if not entry or not entry.kind or not value or (fighters and not valid_fighter(fighters, value)) then return false end
        if entry.kind == "human" and entry.ready then return false end
        entry.fighter = value
        return true
    elseif kind == "team" then
        local value = tonumber(command.value)
        if not entry or not entry.kind or not value or not allowed_team(state, value) then return false end
        if entry.kind == "human" and entry.ready then return false end
        entry.team = value
        return true
    elseif kind == "ready" then
        if not entry or entry.kind ~= "human" then return false end
        entry.ready = command.value == true
        return true
    elseif kind == "arena" then
        local value = tonumber(command.value)
        if not value then return false end
        state.background = value
        return true
    elseif kind == "stage" then
        local value = tonumber(command.value)
        if not value or value < 0 or value >= setup.stage_groups then return false end
        state.stage_level = value * 10
        return true
    elseif kind == "difficulty" then
        local value = tonumber(command.value)
        if value ~= difficulties.easy and value ~= difficulties.normal and value ~= difficulties.difficult
           and value ~= difficulties.crazy then return false end
        if state.mode == modes.battle and value == difficulties.crazy then return false end
        state.difficulty = value
        return true
    elseif kind == "start" then
        if setup.problem(state) then return false end
        state.countdown = setup.countdown_frames
        return true
    elseif kind == "wait" then
        if not state.countdown then return false end
        state.countdown = nil
        return true
    end
    return false
end

-- Why the fight cannot start, or nil. `names[slot]` names the players.
function setup.problem(state, names)
    local fighters, ready, sides = 0, 0, {}
    for slot = 0, 7 do
        local entry = state.slots[slot]
        if entry.kind then
            fighters = fighters + 1
            if entry.kind == "human" and not entry.ready then
                return string.format("%s is still choosing", names and names[slot] or ("Player " .. (slot + 1)))
            end
            if entry.kind == "human" then ready = ready + 1 end
            sides[entry.team == teams.independent and (100 + slot) or entry.team] = true
        end
    end
    if ready == 0 then return "Nobody has joined: press Attack to join" end
    local count = 0
    for _ in pairs(sides) do count = count + 1 end
    if state.mode == modes.versus and fighters > 1 and count < 2 then
        return "All fighters are on one team. Change a team, or add a computer."
    end
    return nil
end

-- One frame of the countdown; returns true when it reaches zero (the fight starts).
function setup.tick(state)
    if not state.countdown then return false end
    state.countdown = state.countdown - 1
    if state.countdown > 0 then return false end
    state.countdown = nil
    return true
end

-- The classic character selection with the same choices (base/ui/character_select): the flow keeps using it for
-- the fight, the Stage progression, Battle mode's troop panel and the round's end. Random fighters are picked here,
-- like the classic screen's `resolve_random` (shared random numbers, slot order, fighters not taken yet).
function setup.selection(state)
    local phases = constants.character_slot_phases
    local selection = character_select.create({mode = state.mode == modes.versus and "versus"
        or state.mode == modes.stage and "stage" or "battle"})
    for slot = 0, 7 do
        local entry, target = state.slots[slot], selection.slots[slot]
        target.fighter, target.team = entry.fighter, entry.team
        if entry.kind == "human" then target.phase = phases.ready
        elseif entry.kind == "computer" then target.phase = phases.computer_ready end
        target.was_random = entry.kind ~= nil and entry.fighter == 0
    end
    for slot = 0, 7 do
        local target = selection.slots[slot]
        if target.was_random then
            local candidates = {}
            for index, fighter in ipairs(selection.fighters) do
                if fighter.record >= 1 and fighter.id < constants.record_id_ranges.random_fighter_end_exclusive then
                    local taken = false
                    for other = 0, 7 do
                        if selection.slots[other].fighter == index then taken = true end
                    end
                    if not taken then candidates[#candidates + 1] = index end
                end
            end
            assert(#candidates > 0, "no fighter left for a random pick")
            target.fighter = candidates[engine.random(#candidates) + 1]
        end
    end
    selection.options.background, selection.options.difficulty = state.background, state.difficulty
    -- Battle mode's options panel picks a random arena only for Random.
    selection.options.random_background = state.background == constants.background_rows.random
    selection.options.stage_level = state.stage_level
    selection.menu, selection.last_menu = constants.character_menus.options, constants.character_menus.options
    return selection
end

function setup.describe(state)
    local slots = {}
    for slot = 0, 7 do
        local entry = state.slots[slot]
        slots[#slots + 1] = entry.kind and string.format("%s:%d:%d:%s", entry.kind:sub(1, 1), entry.fighter, entry.team,
            entry.ready and "r" or "-") or "."
    end
    return string.format("mode=%d slots=%s arena=%d stage=%d difficulty=%d countdown=%s", state.mode,
        table.concat(slots, ","), state.background, state.stage_level, state.difficulty, tostring(state.countdown))
end

return setup
