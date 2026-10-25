-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The lobby of a server program (OpenLF2 extension, docs/ui-network-architecture.md, drawn with Dear ImGui,
-- base/ui/imgui): the players who joined, each with a slot, say they are ready; the player with the room role
-- starts the game, and every client goes to the title menu of the same session (base/game/online), where the game
-- runs as the original's network game: the character selection, the modes, the fights. The chat panel sends
-- messages; a number from 1 to 42 plays a taunt. Escape or Leave goes back to the network menu.
local constants = require("base/game/constants")
local online = require("base/game/online")
local imgui = require("base/ui/imgui")
local screen = {}

-- options: the runtime settings; address and port of the server; retry_ms: how long to try again when the server
-- does not answer yet (a server that this computer just started).
function screen.create(options, address, port, retry_ms)
    return {online = online.create(options, address, port, retry_ms), chat_text = "", held = {},
        background = (options.menu_seed or 0) % 13 + 1}
end

local function own_player(state)
    local lobby = state.online.lobby
    for _, player in ipairs(lobby and lobby.players or {}) do
        if player.id == state.online.id then return player end
    end
    return nil
end

local function everybody_ready(lobby)
    for _, player in ipairs(lobby.players) do
        if not player.ready then return false end
    end
    return #lobby.players > 0
end

-- Fresh presses of player 1's keys (attack: ready; defend: start).
local function presses(state, keys)
    local fresh = {}
    for letter in ("cf"):gmatch(".") do
        local down = keys:find(letter, 1, true) ~= nil
        if down and not state.held[letter] then fresh[letter] = true end
        state.held[letter] = down
    end
    return fresh
end

function screen.update(state, input, context)
    local connection = state.online
    online.poll(connection)
    for _, event in ipairs(online.take_events(connection)) do
        if event.type == "session" then
            context.action("online_session")
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
    -- Player 1's keys work too (keyboard players, headless tests): attack says ready, the room role's defend starts.
    local fresh = input.ui_keyboard and {} or presses(state, input[0] or "")
    if events.clicked.ready or fresh.c then online.send(connection, {type = "ready", value = not me.ready}) end
    -- A stopped session of these players goes on (base/game/server "can_resume").
    if me.role and events.clicked.resume and connection.lobby.resume then online.send(connection, {type = "start", resume = true}) end
    if me.role and (events.clicked.start or fresh.f) and everybody_ready(connection.lobby) then
        online.send(connection, {type = "start"})
    end
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back" .. state.background, 0, 0, true)
    local connection = state.online
    imgui.window(context, "lobby", "Lobby   " .. connection.address .. ":" .. connection.port, 120, 0, 554, 0)
    local lobby = connection.lobby
    if connection.phase == "connecting" then
        imgui.text(context, "Connecting to the server...")
    elseif connection.phase == "failed" or connection.phase == "closed" then
        imgui.text(context, tostring(connection.problem or "Not connected"), 0xff9b9b, imgui.wrap)
    elseif lobby then
        local me = own_player(state)
        -- UPnP (the server program of a hosting game): the address that friends on the internet type.
        if lobby.upnp == "mapped" and lobby.public_address then
            imgui.text(context, "Friends on the internet join with " .. lobby.public_address .. ":" .. connection.port, 0xffd24a)
        elseif lobby.upnp == "working" then
            imgui.text(context, "Opening the port on the router (UPnP)...", 0x8090c0)
        elseif lobby.upnp == "failed" then
            imgui.text(context, "The router did not open the port (UPnP): friends on the internet cannot join unless "
                .. "UDP port " .. connection.port .. " is forwarded to this computer.", 0xff9b9b, imgui.wrap)
        end
        imgui.text(context, "Players", 0xa8b8e8)
        imgui.child(context, "players", -1, 170, true)
        for _, player in ipairs(lobby.players) do
            imgui.text(context, string.format("%d.", player.slot + 1), 0x8090c0)
            imgui.same_line(context, 30)
            imgui.text(context, player.name .. (player.id == connection.id and "  (you)" or ""),
                player.id == connection.id and 0xffffff or 0xd0d8f0)
            imgui.same_line(context, 260)
            imgui.text(context, player.ready and "Ready" or "Not ready", player.ready and 0x8fef8f or 0x8090c0)
            if player.role then
                imgui.same_line(context, 370)
                imgui.text(context, "room role", 0xffd24a)
            end
        end
        imgui.end_child(context)
        imgui.text(context, "Everybody chooses a fighter in the game's own character selection.", 0x8090c0, imgui.wrap)
        imgui.button(context, "ready", me and me.ready and "I am not ready" or "I am ready", 250, 32)
        imgui.same_line(context)
        if me and me.role then
            imgui.button(context, "start", "Start the game", -1, 32, not everybody_ready(lobby))
            if lobby.resume then imgui.button(context, "resume", "Resume the stopped game", -1, 32) end
        else
            imgui.text(context, "The room role starts the game.", 0x8090c0)
        end
        imgui.spacing(context, 4)
        imgui.separator(context)
        imgui.text(context, "Chat", 0xa8b8e8)
        imgui.child(context, "chat_log", -1, 90, true)
        for _, line in ipairs(connection.chat) do imgui.text(context, line.name .. ": " .. line.text, nil, imgui.wrap) end
        imgui.end_child(context)
        imgui.input(context, "chat", state.chat_text, "Message (a number from 1 to 42 plays a taunt)", 420)
        imgui.same_line(context)
        imgui.button(context, "send", "Send", -1)
    end
    imgui.spacing(context, 4)
    imgui.button(context, "leave", "Leave", 100)
    imgui.end_window(context)
end

function screen.describe(state)
    local connection = state.online
    local parts = {"online=" .. connection.phase .. (connection.lobby and connection.lobby.resume and " resume" or "")}
    if connection.problem then parts[#parts + 1] = "problem=" .. connection.problem end
    for _, player in ipairs(connection.lobby and connection.lobby.players or {}) do
        parts[#parts + 1] = string.format("player{slot=%d,name=%s,ready=%s,role=%s}", player.slot, player.name,
            tostring(player.ready), tostring(player.role))
    end
    local log = connection.chat or {}
    if #log > 0 then parts[#parts + 1] = string.format("chat=%d last=%s", #log, log[#log].text) end
    return table.concat(parts, " ")
end

return screen
