-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The settings menu (OpenLF2 extension, docs/pregame-ui-redesign.md "The settings menu"): Escape opens it in a fight
-- and in a network game's menus. It draws with Dear ImGui (base/ui/imgui). The menu never changes the fight: a shared
-- value goes into the input of the next frame (a function key, the control letters of base/game/match, the speed),
-- and a local value changes only this computer's configuration. The flow does what update() returns.
--
-- A local game stops while the menu is open; a network game goes on, and this computer's keys are held back.
local constants = require("base/game/constants")
local music = require("base/game/music")
local user_options = require("base/game/options")
local imgui = require("base/ui/imgui")
local i18n = require("base/i18n/i18n")
local menu = {}

local pages = {{id = "game", label = "Game"}, {id = "sound", label = "Sound"}, {id = "display", label = "Display"}}
local track_names = {[-1] = "Off", [0] = "Random", "Main Theme", "Stage 1", "Stage 2", "Stage 3", "Stage 4", "Stage 5",
    "Boss", "Final Boss"}
-- The cheat keys of the original: F6 to F9.
local cheats = {{key = "6", label = "Unlimited mana (F6)"}, {key = "7", label = "Heal all (F7)"},
    {key = "8", label = "Weapons (F8)"}, {key = "9", label = "No weapons (F9)"}}

-- page: the page that shows first ("game", "sound" or "display").
function menu.create(page) return {page = page or "game", confirm = nil} end

-- env: online (a server's session), fight (a fight runs), mode, fighters = {{slot, name, ai}} of this computer's
-- human fighters, speed (tenths), speed_shared (any player of a network game sets it), cheat_keys (the word's flag),
-- cheats_online (the cheat word reaches the other computers).
local function cheats_work(env)
    return env.fight and (env.mode == constants.modes.versus or env.cheat_keys)
end

-- Returns what the flow does, or nil: {close = true}, {leave = true} (the network game), {end_fight = true}, {functions
-- = "N"}, {control = {slot, letter}}, {speed = tenths}, {cheat_keys = true}.
function menu.update(state, input, env)
    local events = imgui.events(input)
    local clicked = events.clicked
    for _, page in ipairs(pages) do
        if clicked["page_" .. page.id] then state.page, state.confirm = page.id, nil end
    end
    if state.confirm then
        if clicked.confirm_no then state.confirm = nil return nil end
        if clicked.confirm_yes then
            local confirm = state.confirm
            state.confirm = nil
            if confirm == "leave" then return {leave = true} end
            if confirm == "end_fight" then return {end_fight = true, close = true} end
            if confirm == "cheat_keys" then return {cheat_keys = true, close = true} end
        end
        return nil
    end
    if clicked.resume then return {close = true} end
    if clicked.leave then state.confirm = env.online and "leave" or "end_fight" return nil end
    for _, fighter in ipairs(env.fighters or {}) do
        if clicked["control_" .. fighter.slot] then
            return {control = {fighter.slot, fighter.ai and "P" or "A"}, close = true}
        end
    end
    if clicked.pause then return {functions = "1", close = true} end
    if clicked.fast then return {functions = "5", close = true} end
    for _, cheat in ipairs(cheats) do
        if clicked["cheat_" .. cheat.key] then return {functions = cheat.key, close = not env.online} end
    end
    if clicked.cheat_keys then
        -- Turning them on asks first; turning them off does not.
        if env.cheat_keys then return {cheat_keys = true, close = true} end
        state.confirm = "cheat_keys"
        return nil
    end
    local tenths = imgui.slider_value(events, "speed", env.speed or 10, 1, 10)
    if tenths and tenths ~= env.speed then return {speed = tenths} end
    -- Sound and display: this computer's configuration, saved at once.
    local values, changed = user_options.current(), false
    for track = 0, 8 do
        if clicked["track_" .. (track + 1)] then values.music_track, changed = track, true end
    end
    if clicked.music_switch then
        values.music, changed = not values.music, true
        if values.music and values.music_track == -1 then values.music_track = 0 end
    end
    local volume = imgui.slider_value(events, "music_volume", values.music_volume, 0, 100)
    if volume and volume ~= values.music_volume then values.music_volume, changed = volume, true end
    volume = imgui.slider_value(events, "sound_volume", values.sound_volume, 0, 100)
    if volume and volume ~= values.sound_volume then values.sound_volume, changed = volume, true end
    if clicked.fullscreen then values.fullscreen, changed = not values.fullscreen, true end
    if clicked.show_fps then values.show_fps, changed = not values.show_fps, true end
    if clicked.classic_menus then values.classic_menus, changed = not values.classic_menus, true end
    for _, layout in ipairs({"classic", "expand", "dynamic"}) do
        if clicked["camera_" .. layout] then values.battlefield_layout, changed = layout, true end
    end
    local widest = imgui.slider_value(events, "camera_widest", values.camera_widest, 100, 300)
    if widest and widest ~= values.camera_widest then values.camera_widest, changed = widest, true end
    if clicked.show_connection then values.show_connection, changed = not values.show_connection, true end
    for delay = -1, 2 do
        if clicked["input_delay_" .. (delay + 1)] then values.input_delay, changed = delay, true end
    end
    if changed then user_options.save(values) end
    return nil
end

local function game_page(context, env)
    if env.fight then
        for _, fighter in ipairs(env.fighters or {}) do
            local label = fighter.ai and i18n.tr("%s: take the control back", fighter.name)
                or i18n.tr("%s: let the computer play", fighter.name)
            imgui.button(context, "control_" .. fighter.slot, label, -1, 26)
        end
        imgui.button(context, "pause", env.online and i18n.tr("Pause for everyone (F1)") or i18n.tr("Pause (F1)"), -1, 26)
        if not env.online then imgui.button(context, "fast", i18n.tr("Fast mode (F5)"), -1, 26) end
        if cheats_work(env) then
            for position, cheat in ipairs(cheats) do
                if position % 2 == 0 then imgui.same_line(context) end
                imgui.button(context, "cheat_" .. cheat.key, i18n.tr(cheat.label), position % 2 == 1 and 178 or -1, 24)
            end
        end
        imgui.spacing(context, 4)
    end
    local tenths = env.speed or 10
    local label = tenths == 10 and i18n.tr("Game speed: 1.0 (normal)")
        or i18n.tr("Game speed: 0.%d", tenths) .. (tenths == 4 and " " .. i18n.tr("(recommended)") or "")
    imgui.text(context, label .. (env.speed_shared and "  " .. i18n.tr("[for everyone]") or ""))
    imgui.slider(context, "speed", "", tenths, 1, 10, -1, env.online and not env.speed_shared)
    if env.online then
        -- The input delay of this computer (docs/netcode.md "Input from the client"): it takes effect in the next fight.
        local values = user_options.current()
        imgui.text(context, i18n.tr("Input delay"))
        local names = {[-1] = i18n.tr("Automatic"), [0] = "0", "1", "2"}
        for delay = -1, 2 do
            imgui.same_line(context)
            imgui.selectable(context, "input_delay_" .. (delay + 1), names[delay], values.input_delay == delay, delay == -1 and 90 or 40, 0)
        end
    end
    if env.fight then
        imgui.spacing(context, 4)
        imgui.text(context, env.cheat_keys and i18n.tr("Cheat keys: all modes") or i18n.tr("Cheat keys: VS mode only"))
        imgui.button(context, "cheat_keys", env.cheat_keys and i18n.tr("Turn off cheat keys") or i18n.tr("Turn on cheat keys"),
            -1, 24, env.online and not env.cheats_online)
    end
end

local function sound_page(context)
    local values = user_options.current()
    imgui.text(context, i18n.tr("[only on this computer, kept for the next start]"), 0x8090c0)
    imgui.button(context, "music_switch", values.music and i18n.tr("Music: on (click to turn off)") or i18n.tr("Music: off (click to turn on)"),
        -1, 26, false, values.music and 0x6fdc8c or 0xffb347)
    imgui.text(context, i18n.tr("Music in VS mode"))
    for track = 0, 8 do
        imgui.selectable(context, "track_" .. (track + 1), i18n.tr(track_names[track]), values.music_track == track, 0, 0)
    end
    imgui.spacing(context, 4)
    imgui.text(context, i18n.tr("Music volume: %d", values.music_volume))
    imgui.slider(context, "music_volume", "", values.music_volume, 0, 100, -1)
    imgui.text(context, i18n.tr("Sound effects volume: %d", values.sound_volume))
    imgui.slider(context, "sound_volume", "", values.sound_volume, 0, 100, -1)
end

local function display_page(context)
    local values = user_options.current()
    imgui.text(context, i18n.tr("[only on this computer]"))
    -- The camera of the fight (docs/camera.md): the original's picture, more stage at its scale, or a camera that
    -- frames the fighters and zooms out (Page Up, Page Down, Home in the fight).
    imgui.text(context, i18n.tr("Camera"))
    local names = {classic = i18n.tr("Classic"), expand = i18n.tr("Wide"), dynamic = i18n.tr("Dynamic zoom")}
    for position, layout in ipairs({"classic", "expand", "dynamic"}) do
        if position > 1 then imgui.same_line(context) end
        imgui.selectable(context, "camera_" .. layout, names[layout], values.battlefield_layout == layout, 110, 0)
    end
    if values.battlefield_layout == "dynamic" then
        imgui.text(context, i18n.tr("Widest view: %d %% of the window", values.camera_widest))
        imgui.slider(context, "camera_widest", "", values.camera_widest, 100, 300, -1)
    end
    imgui.selectable(context, "fullscreen", i18n.tr("Fullscreen"), values.fullscreen, 0, 0)
    imgui.selectable(context, "show_fps", i18n.tr("Show FPS"), values.show_fps, 0, 0)
    imgui.selectable(context, "show_connection", i18n.tr("Show the connection in network games"), values.show_connection, 0, 0)
    imgui.selectable(context, "classic_menus", i18n.tr("Classic menus (the character selection of the original)"),
        values.classic_menus, 0, 0)
end

function menu.draw(state, context, env)
    imgui.window(context, "settings", i18n.tr("Settings"), 197, 0, 400, 0)
    if state.confirm then
        local questions = {
            leave = i18n.tr("Leave the network game? The others wait for you, or choose to go on without you."),
            end_fight = i18n.tr("End the fight?"),
            cheat_keys = i18n.tr("Cheat keys F6 to F9 then work in all modes, also in the fight that runs now. Turn them on?"),
        }
        imgui.text(context, questions[state.confirm], nil, imgui.wrap)
        imgui.spacing(context, 6)
        imgui.button(context, "confirm_yes", state.confirm == "cheat_keys" and i18n.tr("Turn on") or i18n.tr("Yes"), 150, 28)
        imgui.same_line(context)
        imgui.button(context, "confirm_no", i18n.tr("No"), -1, 28)
        imgui.end_window(context)
        return
    end
    imgui.button(context, "resume", i18n.tr("Resume"), -1, 30)
    imgui.spacing(context, 2)
    for position, page in ipairs(pages) do
        if position > 1 then imgui.same_line(context) end
        imgui.selectable(context, "page_" .. page.id, i18n.tr(page.label), state.page == page.id, 80, 0)
    end
    imgui.separator(context)
    if state.page == "game" then game_page(context, env)
    elseif state.page == "sound" then sound_page(context)
    else display_page(context) end
    imgui.separator(context)
    local leave = env.online and i18n.tr("Leave the network game") or (env.fight and i18n.tr("End the fight"))
    if leave then imgui.button(context, "leave", leave, -1, 28) end
    imgui.end_window(context)
end

function menu.describe(state)
    return "settings=" .. state.page .. (state.confirm and ":" .. state.confirm or "")
end

return menu
