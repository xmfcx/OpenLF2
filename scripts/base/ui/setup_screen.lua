-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The match setup screen (OpenLF2 extension, docs/pregame-ui-redesign.md): one screen with the roster, a grid of
-- fighter portraits, the arena or the stage, the difficulty and the start, drawn with Dear ImGui. It replaces the
-- classic character selection, which stays behind "Classic menus".
--
-- Each player slot has its own cursor, moved by that slot's keys (attack joins, chooses and confirms, jump goes
-- back, defend starts); the mouse acts for the slot in focus or on the shared values. Keys and clicks become
-- commands for the setup (base/game/setup), which the screen applies; so input traces can test the whole screen
-- with the players' keys.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local background = require("base/game/background")
local setup = require("base/game/setup")
local speed = require("base/game/speed")
local sounds = require("base/game/sounds")
local controls = require("base/ui/controls")
local imgui = require("base/ui/imgui")
local i18n = require("base/i18n/i18n")
local modes, teams = constants.modes, constants.teams
local screen = {}

local columns = 7
-- The color of each slot's cursor, its marker on the grid and its card.
local slot_colors = {[0] = 0xff5050, 0x50a0ff, 0x50e070, 0xffd040, 0xd070ff, 0x40e0e0, 0xff9040, 0xe0e0e0}
local team_colors = {[0] = 0xa0a0a0, 0xff7070, 0x70a0ff, 0x80e080, 0xffd060}
local difficulty_names = {[constants.difficulties.easy] = "Easy", [constants.difficulties.normal] = "Normal",
    [constants.difficulties.difficult] = "Difficult", [constants.difficulties.crazy] = "CRAZY!"}
local stage_names = {"Stage 1", "Stage 2", "Stage 3", "Stage 4", "Stage 5", "Survival"}
-- After a player is ready, up and down move the cursor between these panels.
local panels = {"arena", "difficulty", "computers", "start"}

-- mode: constants.modes.versus, stage or battle; previous: the screen of the last visit (its setup stays).
function screen.create(mode, previous)
    local fighters = catalog.load()
    local grid = {0}
    for index, fighter in ipairs(fighters) do
        if catalog.selectable(fighter) then grid[#grid + 1] = index end
    end
    local state = {fighters = fighters, backgrounds = catalog.backgrounds(), grid = grid,
        setup = setup.create(mode, previous and previous.setup), cursors = {}, held = {}, focus = 0,
        results = previous and previous.results}
    state.arenas = {constants.background_rows.random, constants.background_rows.lee_on_road}
    for row = 0, #state.backgrounds - 1 do state.arenas[#state.arenas + 1] = row end
    for slot = 0, 7 do
        local entry = state.setup.slots[slot]
        if entry.kind == "human" then state.cursors[slot] = {panel = entry.ready and "start" or "grid", index = 1} end
    end
    return state
end

-- After a fight: the setup again, with the Results buttons.
function screen.after_fight(previous)
    local state = screen.create(previous.setup.mode, previous)
    state.results = true
    return state
end

local function name_of(slot)
    local name = controls.name(slot)
    return name ~= "" and name or tostring(slot + 1)
end
local function names()
    local list = {}
    for slot = 0, 7 do list[slot] = name_of(slot) end
    return list
end
local function fighter_name(state, value)
    if value == 0 then return i18n.tr("Random") end
    return state.fighters[value] and state.fighters[value].name or "?"
end
local function portrait(state, value)
    if value == 0 then return "pe/rface" end
    return state.fighters[value] and state.fighters[value].portrait or "pe/rface"
end
local function team_name(team)
    if team == teams.independent then return i18n.tr("Independent") end
    return i18n.tr("Team %d", team)
end
local function arena_name(state, row)
    if row == constants.background_rows.random then return i18n.tr("Random") end
    if row == constants.background_rows.lee_on_road then return "Lee On Road" end
    local entry = state.backgrounds[row + 1]
    return entry and background.load(entry.path).name or "?"
end
local function arena_picture(state, row)
    local entry = row >= 0 and row < 99 and state.backgrounds[row + 1]
    if not entry then return nil end
    local layers = background.load(entry.path).layers
    return layers and layers[1] and layers[1].resource
end

local function apply(state, command)
    if setup.apply(state.setup, command, state.fighters) then
        sounds.direct(state, (command.type == "join" or command.type == "ready" or command.type == "start") and "join" or "ok")
        return true
    end
    sounds.direct(state, "cancel")
    return false
end
local function grid_index(state, fighter)
    for position, value in ipairs(state.grid) do
        if value == fighter then return position end
    end
    return 1
end
local function wrap(value, count) return (value - 1) % count + 1 end
local function arena_position(state)
    for position, row in ipairs(state.arenas) do
        if row == state.setup.background then return position end
    end
    return 1
end
local function first_empty(state)
    for slot = 0, 7 do
        if not state.setup.slots[slot].kind then return slot end
    end
    return nil
end
local function last_computer(state)
    for slot = 7, 0, -1 do
        if state.setup.slots[slot].kind == "computer" then return slot end
    end
    return nil
end

-- One slot's key presses: the cursor of that slot, and the commands it gives.
local function slot_keys(state, slot, pressed, context)
    local model = state.setup
    local entry = model.slots[slot]
    local cursor = state.cursors[slot]
    if model.countdown then
        if pressed.b then apply(state, {type = "wait", slot = slot}) end
        return
    end
    if entry.kind ~= "human" then
        if pressed.c and not entry.kind and apply(state, {type = "join", slot = slot}) then
            state.cursors[slot] = {panel = "grid", index = grid_index(state, 0)}
            state.focus = slot
        end
        return
    end
    cursor = cursor or {panel = "grid", index = 1}
    state.cursors[slot] = cursor
    local count = #state.grid
    if cursor.panel == "grid" then
        if pressed.l then cursor.index = wrap(cursor.index - 1, count) end
        if pressed.r then cursor.index = wrap(cursor.index + 1, count) end
        if pressed.u then cursor.index = cursor.index - columns < 1 and 1 or cursor.index - columns end
        if pressed.d then cursor.index = math.min(count, cursor.index + columns) end
        if pressed.c then
            apply(state, {type = "fighter", slot = slot, value = state.grid[cursor.index]})
            -- Stage mode has no team step.
            if model.mode == modes.stage then
                apply(state, {type = "ready", slot = slot, value = true})
                cursor.panel = "start"
            else
                cursor.panel = "team"
            end
        elseif pressed.b then
            apply(state, {type = "leave", slot = slot})
            state.cursors[slot] = nil
        end
    elseif cursor.panel == "team" then
        if pressed.l then apply(state, {type = "team", slot = slot, value = setup.step_team(model, entry.team, -1)}) end
        if pressed.r then apply(state, {type = "team", slot = slot, value = setup.step_team(model, entry.team, 1)}) end
        if pressed.c then
            apply(state, {type = "ready", slot = slot, value = true})
            cursor.panel = "start"
        elseif pressed.b then
            cursor.panel = "grid"
        end
    else
        -- Ready: up and down move between the panels, left and right change the value there.
        local position = 1
        for index, name in ipairs(panels) do
            if name == cursor.panel then position = index end
        end
        if pressed.u then position = math.max(1, position - 1) end
        if pressed.d then position = math.min(#panels, position + 1) end
        cursor.panel = panels[position]
        local step = pressed.l and -1 or pressed.r and 1 or 0
        if cursor.panel == "arena" and step ~= 0 then
            if model.mode == modes.stage then
                apply(state, {type = "stage", slot = slot, value = (model.stage_level / 10 + step) % setup.stage_groups})
            else
                apply(state, {type = "arena", slot = slot, value = state.arenas[wrap(arena_position(state) + step, #state.arenas)]})
            end
        elseif cursor.panel == "difficulty" and step ~= 0 then
            local order, at = setup.difficulty_order, 1
            for index, value in ipairs(order) do
                if value == model.difficulty then at = index end
            end
            local count_order = model.mode == modes.battle and 3 or 4
            apply(state, {type = "difficulty", slot = slot, value = order[wrap(at + step, count_order)]})
        elseif cursor.panel == "computers" and pressed.c then
            local empty = first_empty(state)
            if empty then apply(state, {type = "add_computer", slot = empty}) end
        elseif cursor.panel == "computers" and pressed.f then
            local computer = last_computer(state)
            if computer then apply(state, {type = "remove_computer", slot = computer}) end
        elseif cursor.panel == "start" and pressed.c then
            apply(state, {type = "start", slot = slot})
        end
        if pressed.f and cursor.panel ~= "computers" then apply(state, {type = "start", slot = slot}) end
        if pressed.b then
            apply(state, {type = "ready", slot = slot, value = false})
            cursor.panel = model.mode == modes.stage and "grid" or "team"
        end
    end
end

-- Clicks (Dear ImGui): for the slot in focus, or the shared values.
local function clicks(state, events, context)
    local model, clicked = state.setup, events.clicked
    for slot = 0, 7 do
        if clicked["card_" .. slot] then state.focus = slot end
        if clicked["join_" .. slot] and apply(state, {type = "join", slot = slot}) then
            state.cursors[slot], state.focus = {panel = "grid", index = 1}, slot
        end
        if clicked["computer_" .. slot] and apply(state, {type = "add_computer", slot = slot}) then state.focus = slot end
        if clicked["remove_" .. slot] then
            apply(state, {type = model.slots[slot].kind == "computer" and "remove_computer" or "leave", slot = slot})
            state.cursors[slot] = nil
        end
        if clicked["team_" .. slot] then
            apply(state, {type = "team", slot = slot, value = setup.step_team(model, model.slots[slot].team, 1)})
        end
        if clicked["ready_" .. slot] then
            local entry = model.slots[slot]
            if apply(state, {type = "ready", slot = slot, value = not entry.ready}) then
                if state.cursors[slot] then state.cursors[slot].panel = entry.ready and "start" or "grid" end
            end
        end
    end
    for position, value in ipairs(state.grid) do
        if clicked["fighter_" .. position] then
            local focus = model.slots[state.focus]
            if not focus.kind then
                if apply(state, {type = "join", slot = state.focus}) then state.cursors[state.focus] = {panel = "team", index = position} end
            end
            apply(state, {type = "fighter", slot = state.focus, value = value})
            if state.cursors[state.focus] then state.cursors[state.focus].index = position end
        end
    end
    for position, row in ipairs(state.arenas) do
        if clicked["arena_" .. position] then apply(state, {type = "arena", value = row}) end
    end
    for group = 0, setup.stage_groups - 1 do
        if clicked["stage_" .. group] then apply(state, {type = "stage", value = group}) end
    end
    for _, value in ipairs(setup.difficulty_order) do
        if clicked["difficulty_" .. (value + 1)] then apply(state, {type = "difficulty", value = value}) end
    end
    for _, mode in ipairs({modes.versus, modes.stage, modes.battle}) do
        if clicked["mode_" .. mode] then apply(state, {type = "mode", value = mode}) end
    end
    local tenths = imgui.slider_value(events, "setup_speed", speed.tenths, 1, 10)
    if tenths then speed.tenths = tenths end
    if clicked.start then apply(state, {type = "start"}) end
    if clicked.wait then apply(state, {type = "wait"}) end
    if clicked.exit or clicked.result_title then context.action("title") return true end
    if clicked.result_rematch then
        state.results = nil
        apply(state, {type = "start"})
    end
    if clicked.result_fighters then
        state.results = nil
        for slot = 0, 7 do
            if model.slots[slot].kind == "human" then
                apply(state, {type = "ready", slot = slot, value = false})
                state.cursors[slot] = {panel = "grid", index = grid_index(state, model.slots[slot].fighter)}
            end
        end
    end
    if clicked.result_setup then state.results = nil end
    return false
end

-- The match options of base/game/match, through the classic selection (base/game/setup `selection`).
function screen.selection(state) return setup.selection(state.setup) end

function screen.update(state, input, context)
    local events = imgui.events(input)
    -- Escape (and Android's back button) leaves to the title, unless a countdown runs (jump stops it).
    local escape = input.keys and input.keys[constants.virtual_keys.escape] == true
    if escape and not state.escape_held and not state.setup.countdown then
        state.escape_held = true
        context.action("title")
        return
    end
    state.escape_held = escape
    if clicks(state, events, context) then
        for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
        return
    end
    for slot = 0, 7 do
        local keys, before, pressed = input[slot] or "", state.held[slot] or "", {}
        for letter in ("udlrcbf"):gmatch(".") do
            pressed[letter] = keys:find(letter, 1, true) ~= nil and not before:find(letter, 1, true)
        end
        state.held[slot] = keys
        if next(pressed) and (pressed.u or pressed.d or pressed.l or pressed.r or pressed.c or pressed.b or pressed.f) then
            state.results = nil
            slot_keys(state, slot, pressed, context)
        end
    end
    if state.setup.countdown and setup.tick(state.setup) then
        -- Battle mode sets its troops on the classic panel next.
        context.action(state.setup.mode == modes.battle and "battle_setup" or "start_match")
    end
    for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
end

local function roster(state, context)
    local model = state.setup
    imgui.text(context, i18n.tr("Players"), 0xa8b8e8)
    for slot = 0, 7 do
        local entry = model.slots[slot]
        local color = slot_colors[slot]
        imgui.selectable(context, "card_" .. slot, string.format("%d", slot + 1), state.focus == slot, 14, 20)
        imgui.same_line(context)
        if entry.kind then
            imgui.image(context, "face_" .. slot, portrait(state, entry.fighter), nil, 20, 20, {color})
            imgui.same_line(context)
            local who = entry.kind == "computer" and i18n.tr("CPU") or name_of(slot):sub(1, 8)
            imgui.text(context, string.format("%s: %s", who, fighter_name(state, entry.fighter)), color)
            if model.mode ~= modes.stage then
                imgui.same_line(context, 170)
                imgui.button(context, "team_" .. slot, team_name(entry.team), 80, 20)
            end
            if entry.kind == "human" then
                imgui.same_line(context, 254)
                imgui.button(context, "ready_" .. slot, entry.ready and i18n.tr("Ready") or i18n.tr("Choosing"), 62, 20)
            end
            imgui.same_line(context, 320)
            imgui.button(context, "remove_" .. slot, "x", 20, 20)
        else
            imgui.text(context, i18n.tr("Attack joins"), 0x8090c0)
            imgui.same_line(context, 170)
            imgui.button(context, "join_" .. slot, i18n.tr("Join"), 80, 20)
            imgui.same_line(context, 254)
            imgui.button(context, "computer_" .. slot, i18n.tr("+ CPU"), 86, 20)
        end
    end
end

local function fighter_grid(state, context)
    imgui.text(context, i18n.tr("Fighters"), 0xa8b8e8)
    for position, value in ipairs(state.grid) do
        if (position - 1) % columns ~= 0 then imgui.same_line(context) end
        local frames = {}
        for slot = 0, 7 do
            local cursor = state.cursors[slot]
            if cursor and cursor.panel == "grid" and cursor.index == position then frames[#frames + 1] = slot_colors[slot] end
        end
        for slot = 0, 7 do
            local entry = state.setup.slots[slot]
            if entry.kind and entry.fighter == value and value ~= 0 and #frames == 0 then frames[#frames + 1] = 0x404860 end
        end
        imgui.image(context, "fighter_" .. position, portrait(state, value), nil, 42, 42, frames, imgui.clickable)
    end
    local focus = state.setup.slots[state.focus]
    imgui.text(context, i18n.tr("A click chooses the fighter of player %d (%s).", state.focus + 1,
        focus.kind == "computer" and i18n.tr("Computer") or name_of(state.focus)), 0x8090c0)
end

local function cursor_frames(state, panel)
    local frames = {}
    for slot = 0, 7 do
        local cursor = state.cursors[slot]
        if cursor and cursor.panel == panel then frames[#frames + 1] = slot_colors[slot] end
    end
    return frames
end
local function marked(state, panel, label)
    local frames = cursor_frames(state, panel)
    return #frames > 0 and "> " .. label or label
end

local function arena_panel(state, context)
    local model = state.setup
    if model.mode == modes.stage then
        imgui.text(context, marked(state, "arena", i18n.tr("Stage")), 0xa8b8e8)
        for group = 0, setup.stage_groups - 1 do
            if group > 0 then imgui.same_line(context) end
            imgui.selectable(context, "stage_" .. group, i18n.tr(stage_names[group + 1]), model.stage_level == group * 10, 80, 24)
        end
        return
    end
    imgui.text(context, marked(state, "arena", i18n.tr("Arena")) .. ": " .. arena_name(state, model.background), 0xa8b8e8)
    imgui.child(context, "arenas", 0, 58, false)
    for position, row in ipairs(state.arenas) do
        if position > 1 then imgui.same_line(context) end
        local picture = arena_picture(state, row)
        local frames = row == model.background and {0xffd24a} or {}
        if picture then
            imgui.image(context, "arena_" .. position, picture, nil, 84, 40, frames, imgui.clickable)
        else
            imgui.button(context, "arena_" .. position, arena_name(state, row), 84, 40)
        end
    end
    imgui.end_child(context)
end

local function rules_panel(state, context)
    local model = state.setup
    imgui.text(context, marked(state, "difficulty", i18n.tr("Difficulty")), 0xa8b8e8)
    imgui.same_line(context, 110)
    for index, value in ipairs(setup.difficulty_order) do
        if not (model.mode == modes.battle and value == constants.difficulties.crazy) then
            if index > 1 then imgui.same_line(context) end
            imgui.selectable(context, "difficulty_" .. (value + 1), i18n.tr(difficulty_names[value]), model.difficulty == value, 84, 0)
        end
    end
    local tenths = speed.tenths
    imgui.text(context, i18n.tr("Game speed: %s", tenths == 10 and "1.0" or "0." .. tenths)
        .. (tenths == 4 and " " .. i18n.tr("(recommended)") or ""), 0xa8b8e8)
    imgui.same_line(context, 230)
    imgui.slider(context, "setup_speed", "", tenths, 1, 10, 200)
    imgui.text(context, marked(state, "computers", i18n.tr("Computers: Attack adds one, Defend removes the last")), 0x8090c0)
end

local function start_bar(state, context)
    local model = state.setup
    local summary = {setup.mode_names[model.mode]}
    local count = 0
    for slot = 0, 7 do
        if model.slots[slot].kind then count = count + 1 end
    end
    summary[#summary + 1] = i18n.tr("%d fighters", count)
    summary[#summary + 1] = model.mode == modes.stage and i18n.tr(stage_names[model.stage_level / 10 + 1])
        or arena_name(state, model.background)
    summary[#summary + 1] = i18n.tr(difficulty_names[model.difficulty] or "")
    if speed.tenths < 10 then summary[#summary + 1] = i18n.tr("speed 0.%d", speed.tenths) end
    imgui.separator(context)
    if model.countdown then
        imgui.text(context, i18n.tr("The fight starts in %d...", math.ceil(model.countdown / 30)), 0xffd24a, imgui.large)
        imgui.same_line(context, 560)
        imgui.button(context, "wait", i18n.tr("Wait (Jump)"), -1, 30)
        return
    end
    imgui.text(context, table.concat(summary, " - "))
    local problem = setup.problem(model, names())
    imgui.same_line(context, 500)
    imgui.button(context, "start", marked(state, "start", i18n.tr("Start the fight (Defend)")), -1, 30, problem ~= nil)
    if problem then imgui.text(context, i18n.tr(problem), 0xff9b9b) end
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back1", 0, 0, true)
    if not imgui.available(context) then return end
    local model = state.setup
    imgui.window(context, "setup", i18n.tr("Match setup"), 6, 6, 782, 538, imgui.no_title)
    for _, mode in ipairs({modes.versus, modes.stage, modes.battle}) do
        imgui.selectable(context, "mode_" .. mode, i18n.tr(setup.mode_names[mode]), model.mode == mode, 70, 22)
        imgui.same_line(context)
    end
    imgui.same_line(context, 700)
    imgui.button(context, "exit", i18n.tr("Exit"), -1, 22)
    if state.results then
        imgui.separator(context)
        imgui.button(context, "result_rematch", i18n.tr("Rematch"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_fighters", i18n.tr("Change fighters"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_setup", i18n.tr("Setup"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_title", i18n.tr("Title"), -1, 28)
    end
    imgui.separator(context)
    imgui.child(context, "grid", 372, 240, false)
    fighter_grid(state, context)
    imgui.end_child(context)
    imgui.same_line(context)
    imgui.child(context, "roster", 0, 240, false)
    roster(state, context)
    imgui.end_child(context)
    imgui.separator(context)
    arena_panel(state, context)
    rules_panel(state, context)
    start_bar(state, context)
    imgui.end_window(context)
end

function screen.describe(state)
    local cursors = {}
    for slot = 0, 7 do
        local cursor = state.cursors[slot]
        if cursor then cursors[#cursors + 1] = string.format("%d:%s:%d", slot, cursor.panel, cursor.index) end
    end
    return setup.describe(state.setup) .. " cursors=" .. table.concat(cursors, ",") .. " focus=" .. state.focus
        .. (state.results and " results" or "")
end

return screen
