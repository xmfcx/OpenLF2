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
-- network: a server's session ({send, slot, names, set_speed, speed}): clicks go to the server as commands, which
-- come back in a final tick for every client (input.commands); keys act on every client alike, as they come in the
-- combined input. Any player starts the fight.
function screen.create(mode, previous, network)

    local fighters = catalog.load()
    local grid = {0}
    for index, fighter in ipairs(fighters) do
        if catalog.selectable(fighter) then grid[#grid + 1] = index end
    end
    local state = {fighters = fighters, backgrounds = catalog.backgrounds(), grid = grid,
        setup = setup.create(mode, previous and previous.setup, network and network.last_setup), cursors = {}, held = {}, focus = 0,
        results = previous and previous.results, network = network}
    state.arenas = {constants.background_rows.random, constants.background_rows.lee_on_road}
    for row = 0, #state.backgrounds - 1 do state.arenas[#state.arenas + 1] = row end
    if network and network.slot then state.focus = network.slot end
    for slot = 0, 7 do
        local entry = state.setup.slots[slot]
        if entry.kind == "human" then state.cursors[slot] = {panel = entry.ready and "start" or "grid", index = 1} end
    end
    return state
end

-- After a fight: the setup again, with the Results buttons.
function screen.after_fight(previous)
    local state = screen.create(previous.setup.mode, previous, previous.network)
    state.results = true
    return state
end

local current_network
local function name_of(slot)
    local name = current_network and current_network.names and current_network.names[slot + 1] or controls.name(slot)
    return name and name ~= "" and name or tostring(slot + 1)
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

-- Every player may start the fight (no player has more rights than the others).
local function may_start(state, slot) return true end
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
        elseif cursor.panel == "start" and pressed.c and may_start(state, slot) then
            apply(state, {type = "start", slot = slot})
        end
        if pressed.f and cursor.panel ~= "computers" and may_start(state, slot) then apply(state, {type = "start", slot = slot}) end
        if pressed.b then
            apply(state, {type = "ready", slot = slot, value = false})
            cursor.panel = model.mode == modes.stage and "grid" or "team"
        end
    end
end

-- Clicks (Dear ImGui): for the slot in focus, or the shared values. In a server's session a click becomes a command
-- for the server (it comes back in a final tick, see shared_command), so all clients apply it on the same tick.
local apply_click
local function clicks(state, events, context)
    local model, clicked = state.setup, events.clicked
    local apply = function(_, command) return apply_click(state, command, context) end
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
    local current = state.network and state.network.get_speed() or speed.tenths
    local tenths = imgui.slider_value(events, "setup_speed", current, 1, 10)
    if tenths and tenths ~= current then
        if state.network then state.network.set_speed(tenths) else speed.tenths = tenths end
    end
    if clicked.start then apply(state, {type = "start"}) end
    if clicked.wait then apply(state, {type = "wait"}) end
    -- The settings menu (base/ui/fight_menu) on its Sound page: music, volumes, and the speed on the Game page.
    if clicked.settings then context.action("settings") return true end
    if clicked.exit then
        if state.network then state.network.send({type = "exit"}) return false end
        context.action("quit")
        return true
    end
    -- The other modes of the original's title menu.
    for _, mode in ipairs({"championship", "team_championship"}) do
        if clicked[mode] then
            if state.network then state.network.send({type = mode}) return false end
            context.action(mode)
            return true
        end
    end
    if not state.network and clicked.demo then context.action("demo") return true end
    if not state.network and clicked.replay then context.action("replay") return true end
    if clicked.result_title then
        state.results = nil
        return false
    end
    if clicked.result_rematch then apply(state, {type = "rematch"}) end
    if clicked.result_fighters then apply(state, {type = "change_fighters"}) end
    if clicked.result_setup then apply(state, {type = "results_setup"}) end
    return false
end

-- A command of the screen itself, or of the setup (base/game/setup). Returns whether the screen leaves, and whether
-- the command acted.
local function screen_command(state, command, context)
    local model = state.setup
    -- Exit: the launch menu (a local game), or the lobby (a server's session, every client on this tick).
    if command.type == "exit" then context.action("quit") return true, true end
    if command.type == "championship" or command.type == "team_championship" then
        context.action(command.type)
        return true, true
    end
    if command.type == "rematch" then
        state.results = nil
        apply(state, {type = "start"})
    elseif command.type == "change_fighters" then
        state.results = nil
        for slot = 0, 7 do
            if model.slots[slot].kind == "human" then
                apply(state, {type = "ready", slot = slot, value = false})
                state.cursors[slot] = {panel = "grid", index = grid_index(state, model.slots[slot].fighter)}
            end
        end
    elseif command.type == "results_setup" then
        state.results = nil
    else
        -- In a server's session a player acts for its own slot (or a computer's); any player starts.
        local slot = command.slot
        if state.network and slot then
            local entry = model.slots[slot]
            if not entry then return false, false end
            local computer = entry.kind == "computer" or command.type == "add_computer"
            if not computer and command.from ~= slot then return false, false end
        end
        if command.type == "arena" then
            local known = false
            for _, row in ipairs(state.arenas) do
                if row == command.value then known = true end
            end
            if not known then return false, false end
        end
        local applied = apply(state, command)
        -- A click from another computer moves the cursors that its keys would move.
        if applied and state.network and command.type == "join" then state.cursors[command.slot] = {panel = "grid", index = 1} end
        if applied and state.network and command.type == "leave" then state.cursors[command.slot] = nil end
        if applied and state.network and command.type == "ready" and state.cursors[command.slot] then
            state.cursors[command.slot].panel = command.value and "start" or "grid"
        end
        return false, applied
    end
    return false, true
end
apply_click = function(state, command, context)
    if state.network then
        state.network.send(command)
        return false
    end
    -- A local game: the click acts now.
    local _, applied = screen_command(state, command, context)
    return applied
end

-- The match options of base/game/match, through the classic selection (base/game/setup `selection`).
function screen.selection(state) return setup.selection(state.setup) end

function screen.update(state, input, context)
    current_network = state.network
    -- The commands of a server's session, in its final tick (clicks of every client).
    for _, command in ipairs(input.commands or {}) do
        if screen_command(state, command, context) then return end
    end
    local events = imgui.events(input)
    -- Escape (and Android's back button) leaves to the launch menu, unless a countdown runs (jump stops it).
    local escape = input.keys and input.keys[constants.virtual_keys.escape] == true
    if escape and not state.escape_held and not state.setup.countdown then
        state.escape_held = true
        context.action("quit")
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

-- The players: a row for each slot that plays, then a row to join (this computer's own slot in a network game, the
-- next free slot in a local one) and a row to add a computer player. Buttons have their natural height, so that
-- their text sits in the middle.
local function roster(state, context)
    local model = state.setup
    imgui.text(context, i18n.tr("Players"), 0xa8b8e8)
    local free
    for slot = 0, 7 do
        local entry = model.slots[slot]
        local color = slot_colors[slot]
        if entry.kind then
            imgui.selectable(context, "card_" .. slot, string.format("%d", slot + 1), state.focus == slot, 14, 24)
            imgui.same_line(context)
            imgui.image(context, "face_" .. slot, portrait(state, entry.fighter), nil, 24, 24, {color})
            imgui.same_line(context)
            local who = entry.kind == "computer" and i18n.tr("CPU") or name_of(slot):sub(1, 6)
            imgui.text(context, string.format("%s: %s", who, fighter_name(state, entry.fighter):sub(1, 7)), color)
            if model.mode ~= modes.stage then
                -- The team: a click takes the next one; a cursor on the team step shows arrows (left and right).
                local label = entry.team == teams.independent and i18n.tr("No team") or team_name(entry.team)
                local cursor = state.cursors[slot]
                if cursor and cursor.panel == "team" then label = "< " .. label .. " >" end
                imgui.same_line(context, 164)
                imgui.button(context, "team_" .. slot, label, 92, 0)
            end
            if entry.kind == "human" then
                -- Not ready: an amber button to press; ready: a green one (a click makes the player choose again).
                imgui.same_line(context, 262)
                imgui.button(context, "ready_" .. slot, entry.ready and i18n.tr("Ready") or i18n.tr("Set ready"), 74, 0,
                    false, entry.ready and 0x6fdc8c or 0xffb347)
            end
            imgui.same_line(context, 342)
            imgui.button(context, "remove_" .. slot, "x", -1, 0)
        elseif not free then
            free = slot
        end
    end
    local own = state.network and state.network.slot
    local join = own and not model.slots[own].kind and own or (not own and free)
    if join then
        imgui.text(context, i18n.tr("Press Attack to join"), 0x8090c0)
        imgui.same_line(context, 150)
        imgui.button(context, "join_" .. join, i18n.tr("Join"), 100, 0)
    end
    local computer = free
    if computer == join then
        computer = nil
        for slot = join + 1, 7 do
            if not model.slots[slot].kind then computer = slot break end
        end
    end
    if computer then
        imgui.text(context, i18n.tr("A computer player"), 0x8090c0)
        imgui.same_line(context, 150)
        imgui.button(context, "computer_" .. computer, i18n.tr("+ Computer"), 100, 0)
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
    -- What the player in focus does next, with keys or the mouse.
    local focus = state.setup.slots[state.focus]
    local cursor = state.cursors[state.focus]
    local hint
    if not focus.kind then hint = i18n.tr("%s: press Attack or click Join.", name_of(state.focus))
    elseif focus.kind == "computer" then hint = i18n.tr("A click on a fighter sets the fighter of this computer player.")
    elseif focus.ready then hint = i18n.tr("%s is ready. Defend or the Start button starts; Jump: choose again.", name_of(state.focus))
    elseif cursor and cursor.panel == "team" then
        hint = i18n.tr("%s: Left/Right choose the team, Attack: ready, Jump: back.", name_of(state.focus))
    else hint = i18n.tr("%s: arrows or a click choose a fighter, Attack takes it.", name_of(state.focus)) end
    state.hint = hint
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
    -- Every arena shows: two rows of cards.
    local per_row = math.ceil(#state.arenas / 2)
    imgui.child(context, "arenas", 0, 84, false)
    for position, row in ipairs(state.arenas) do
        if (position - 1) % per_row ~= 0 then imgui.same_line(context) end
        local picture = arena_picture(state, row)
        local frames = row == model.background and {0xffd24a} or {}
        if picture then
            imgui.image(context, "arena_" .. position, picture, nil, 70, 32, frames, imgui.clickable)
        else
            imgui.button(context, "arena_" .. position, arena_name(state, row), 70, 32)
        end
    end
    imgui.end_child(context)
end

local function rules_panel(state, context)
    local model = state.setup
    imgui.text(context, marked(state, "difficulty", i18n.tr("Difficulty")), 0xa8b8e8)
    imgui.same_line(context, 100)
    for index, value in ipairs(setup.difficulty_order) do
        if not (model.mode == modes.battle and value == constants.difficulties.crazy) then
            if index > 1 then imgui.same_line(context) end
            imgui.selectable(context, "difficulty_" .. (value + 1), i18n.tr(difficulty_names[value]), model.difficulty == value, 64, 0)
        end
    end
    local tenths = state.network and state.network.get_speed() or speed.tenths
    imgui.same_line(context, 400)
    imgui.text(context, i18n.tr("Speed %s", tenths == 10 and "1.0" or "0." .. tenths), 0xa8b8e8)
    imgui.same_line(context, 480)
    imgui.slider(context, "setup_speed", "", tenths, 1, 10, -1)
    if #cursor_frames(state, "computers") > 0 then
        imgui.text(context, "> " .. i18n.tr("Computers: Attack adds one, Defend removes the last"), 0x8090c0)
    end
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
    local focus = model.slots[state.focus]
    if focus.kind == "human" and not focus.ready then
        -- The step that players miss: they must say that they are ready.
        imgui.same_line(context, 330)
        imgui.button(context, "ready_" .. state.focus, i18n.tr("I am ready (Attack)"), 160, 30, false, 0xffb347)
        imgui.same_line(context)
    else
        imgui.same_line(context, 500)
    end
    imgui.button(context, "start", marked(state, "start", i18n.tr("Start the fight (Defend)")), -1, 30, problem ~= nil)
    if problem then imgui.text(context, i18n.tr(problem), 0xff9b9b) end
end

function screen.draw(state, context)
    current_network = state.network
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back1", 0, 0, true)
    if not imgui.available(context) then return end
    local model = state.setup
    imgui.window(context, "setup", i18n.tr("Match setup"), 6, 6, 782, 538, imgui.no_title)
    for _, mode in ipairs({modes.versus, modes.stage, modes.battle}) do
        imgui.selectable(context, "mode_" .. mode, i18n.tr(setup.mode_names[mode]), model.mode == mode, 70, 22)
        imgui.same_line(context)
    end
    imgui.same_line(context, 250)
    imgui.button(context, "championship", i18n.tr("Championship"), 110, 22)
    imgui.same_line(context)
    imgui.button(context, "team_championship", i18n.tr("Team champ."), 100, 22)
    if not state.network then
        imgui.same_line(context)
        imgui.button(context, "demo", i18n.tr("Demo"), 60, 22)
        imgui.same_line(context)
        imgui.button(context, "replay", i18n.tr("Replay"), 70, 22)
    end
    imgui.same_line(context, 610)
    imgui.button(context, "settings", i18n.tr("Settings"), 80, 22)
    imgui.same_line(context)
    imgui.button(context, "exit", i18n.tr("Exit"), -1, 22)
    if state.results then
        imgui.separator(context)
        imgui.button(context, "result_rematch", i18n.tr("Rematch"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_fighters", i18n.tr("Change fighters"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_setup", i18n.tr("Setup"), 180, 28)
        imgui.same_line(context)
        imgui.button(context, "result_title", i18n.tr("Close"), -1, 28)
    end
    imgui.separator(context)
    imgui.child(context, "grid", 372, 220, false)
    fighter_grid(state, context)
    imgui.end_child(context)
    imgui.same_line(context)
    imgui.child(context, "roster", 0, 220, false)
    roster(state, context)
    imgui.end_child(context)
    if state.hint then imgui.text(context, state.hint, 0xffd24a) end
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
