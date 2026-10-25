-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The lobby of a server program (OpenLF2 extension, docs/ui-network-architecture.md, drawn with Dear ImGui,
-- base/ui/imgui): each computer shows its own view of the lobby that the server keeps. A player chooses a fighter and
-- a team and says ready; the player with the room role sets the number of computers and starts the fight when
-- everybody is ready. The chat panel sends messages; a number from 1 to 42 plays a taunt. Escape or Leave goes back.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local online = require("base/game/online")
local imgui = require("base/ui/imgui")
local screen = {}

local team_names = {[0] = "No team", "Team 1", "Team 2", "Team 3", "Team 4"}
local team_colors = {[0] = 0xd0d8f0, 0x7fb0ff, 0xff8080, 0x80e080, 0xffd060}

-- options: the runtime settings; address and port of the server; retry_ms: how long to try again when the server
-- does not answer yet (a server that this computer just started).
function screen.create(options, address, port, retry_ms)
    local fighters, choices = catalog.load(), {0}
    for index, fighter in ipairs(fighters) do
        if catalog.selectable(fighter) then choices[#choices + 1] = index end
    end
    return {online = online.create(options, address, port, retry_ms), fighters = fighters, choices = choices,
        chat_text = "", held = {}, background = (options.menu_seed or 0) % 13 + 1}
end

local function own_player(state)
    local lobby = state.online.lobby
    for _, player in ipairs(lobby and lobby.players or {}) do
        if player.id == state.online.id then return player end
    end
    return nil
end

-- Fresh presses of player 1's keys (u d l r c b f).
local function presses(state, keys)
    local fresh = {}
    for letter in ("udlrcbf"):gmatch(".") do
        local down = keys:find(letter, 1, true) ~= nil
        if down and not state.held[letter] then fresh[letter] = true end
        state.held[letter] = down
    end
    return fresh
end

-- The fighter `step` places away from `fighter` in the list of choices.
local function step_fighter(state, fighter, step)
    for position, choice in ipairs(state.choices) do
        if choice == fighter then return state.choices[(position - 1 + step) % #state.choices + 1] end
    end
    return state.choices[1]
end

local function everybody_ready(lobby)
    for _, player in ipairs(lobby.players) do
        if not player.ready then return false end
    end
    return #lobby.players + lobby.settings.computers >= 2
end

function screen.update(state, input, context)
    local connection = state.online
    online.poll(connection)
    for _, event in ipairs(online.take_events(connection)) do
        if event.type == "start" then
            state.start = event
            context.action("online_fight")
            return
        end
    end
    local events = imgui.events(input)
    local escape = input.keys[constants.virtual_keys.escape] == true
    if events.clicked.leave or (escape and not state.escape_held) then
        online.close(connection)
        context.action("network")
        return
    end
    state.escape_held = escape
    if events.changed.chat then state.chat_text = events.changed.chat end
    if (events.submitted.chat or events.clicked.send) and state.chat_text:match("%S") then
        online.send(connection, {type = "chat", text = state.chat_text})
        state.chat_text = ""
    end
    local me = connection.phase == "lobby" and own_player(state)
    if not me then return end
    -- Player 1's keys work too (keyboard players, headless tests): left and right choose the fighter, up and down
    -- the team, attack switches ready; for the room role, jump adds a computer and defend starts.
    local fresh = input.ui_keyboard and {} or presses(state, input[0] or "")
    if fresh.r or fresh.l then
        online.send(connection, {type = "choose", fighter = step_fighter(state, me.fighter, fresh.r and 1 or -1), team = me.team})
    end
    if fresh.u or fresh.d then online.send(connection, {type = "choose", fighter = me.fighter, team = (me.team + (fresh.d and 1 or 4)) % 5}) end
    if fresh.c then events.clicked.ready = true end
    if fresh.b and me.role then
        local most = 8 - #connection.lobby.players
        online.send(connection, {type = "settings", computers = (connection.lobby.settings.computers + 1) % (most + 1)})
    end
    if fresh.f then events.clicked.start = true end
    for _, fighter in ipairs(state.choices) do
        if events.clicked["fighter" .. fighter] then online.send(connection, {type = "choose", fighter = fighter, team = me.team}) end
    end
    for team = 0, 4 do
        if events.clicked["team" .. team] then online.send(connection, {type = "choose", fighter = me.fighter, team = team}) end
    end
    if events.clicked.ready then online.send(connection, {type = "ready", value = not me.ready}) end
    if me.role then
        local computers, most = connection.lobby.settings.computers, 8 - #connection.lobby.players
        if events.clicked.fewer and computers > 0 then online.send(connection, {type = "settings", computers = computers - 1}) end
        if events.clicked.more and computers < most then online.send(connection, {type = "settings", computers = computers + 1}) end
        if events.clicked.start then online.send(connection, {type = "start"}) end
    end
end

local function draw_chat(state, context, connection)
    imgui.text(context, "Chat", 0xa8b8e8)
    imgui.child(context, "chat_log", -1, 54, true)
    for _, line in ipairs(connection.chat) do imgui.text(context, line.name .. ": " .. line.text, nil, imgui.wrap) end
    imgui.end_child(context)
    imgui.input(context, "chat", state.chat_text, "Message (a number from 1 to 42 plays a taunt)", 560)
    imgui.same_line(context)
    imgui.button(context, "send", "Send", -1)
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back" .. state.background, 0, 0, true)
    local connection = state.online
    imgui.window(context, "lobby", "Lobby   " .. connection.address .. ":" .. connection.port, 30, 0, 734, 0)
    local lobby = connection.lobby
    if connection.phase == "connecting" then
        imgui.text(context, "Connecting to the server...")
    elseif connection.phase == "failed" then
        imgui.text(context, tostring(connection.problem), 0xff9b9b, imgui.wrap)
    elseif lobby then
        local me = own_player(state)
        -- The players.
        imgui.child(context, "players", 400, 232, true)
        imgui.text(context, "Players", 0xa8b8e8)
        imgui.separator(context)
        for _, player in ipairs(lobby.players) do
            local fighter = state.fighters[player.fighter]
            imgui.text(context, string.format("%d.", player.slot + 1), 0x8090c0)
            imgui.same_line(context, 30)
            imgui.text(context, player.name .. (player.id == connection.id and " (you)" or ""),
                player.id == connection.id and 0xffffff or 0xd0d8f0)
            imgui.same_line(context, 150)
            imgui.text(context, fighter and fighter.name or "Random")
            imgui.same_line(context, 240)
            imgui.text(context, team_names[player.team] or "?", team_colors[player.team])
            imgui.same_line(context, 330)
            imgui.text(context, player.ready and "Ready" or "...", player.ready and 0x8fef8f or 0x8090c0)
            if player.role then imgui.text(context, "    room role: starts the fight", 0x8090c0) end
        end
        if lobby.settings.computers > 0 then
            imgui.text(context, string.format("+ %d computer%s", lobby.settings.computers,
                lobby.settings.computers == 1 and "" or "s"), 0xff9b9b)
        end
        imgui.end_child(context)
        imgui.same_line(context)
        -- This computer's choices.
        imgui.child(context, "choices", -1, 232, true)
        imgui.text(context, "Your fighter", 0xa8b8e8)
        imgui.child(context, "fighters", -1, 72, false)
        for _, fighter in ipairs(state.choices) do
            local entry = state.fighters[fighter]
            imgui.selectable(context, "fighter" .. fighter, entry and entry.name or "Random", me and me.fighter == fighter)
        end
        imgui.end_child(context)
        imgui.text(context, "Team", 0xa8b8e8)
        for team = 0, 4 do
            if team > 0 then imgui.same_line(context) end
            imgui.selectable(context, "team" .. team, team == 0 and "None" or tostring(team), me and me.team == team, 44)
        end
        imgui.spacing(context, 4)
        imgui.button(context, "ready", me and me.ready and "Not ready" or "Ready", -1, 30)
        imgui.end_child(context)
        if me and me.role then
            imgui.text(context, "Computers", 0xa8b8e8)
            imgui.same_line(context)
            imgui.button(context, "fewer", "-", 30)
            imgui.same_line(context)
            imgui.text(context, tostring(lobby.settings.computers))
            imgui.same_line(context)
            imgui.button(context, "more", "+", 30)
            imgui.same_line(context, 420)
            imgui.button(context, "start", "Start the fight", -1, 30, not everybody_ready(lobby))
        else
            imgui.text(context, "The player with the room role starts the fight when everybody is ready.", 0x8090c0)
        end
        imgui.separator(context)
        draw_chat(state, context, connection)
    end
    imgui.spacing(context, 4)
    imgui.button(context, "leave", "Leave", 100)
    imgui.end_window(context)
end

function screen.describe(state)
    local connection = state.online
    local parts = {"online=" .. connection.phase}
    if connection.problem then parts[#parts + 1] = "problem=" .. connection.problem end
    for _, player in ipairs(connection.lobby and connection.lobby.players or {}) do
        parts[#parts + 1] = string.format("player{slot=%d,name=%s,fighter=%d,team=%d,ready=%s,role=%s}", player.slot,
            player.name, player.fighter, player.team, tostring(player.ready), tostring(player.role))
    end
    local log = connection.chat or {}
    if #log > 0 then parts[#parts + 1] = string.format("chat=%d last=%s", #log, log[#log].text) end
    return table.concat(parts, " ")
end

return screen
