-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The network menu of the server program (OpenLF2 extension, drawn with Dear ImGui, base/ui/imgui): host a game
-- (the server program starts on this computer), or join one by its address or from the servers joined before. The
-- flow then opens the lobby (base/ui/online_lobby).
local constants = require("base/game/constants")
local server_list = require("base/game/server_list")
local imgui = require("base/ui/imgui")
local screen = {}

function screen.create(options, message)
    return {address = "", servers = server_list.load(), message = message, background = (options.menu_seed or 0) % 13 + 1}
end

local function valid_address(address)
    local parts = {address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
    if #parts ~= 4 then return false end
    for _, part in ipairs(parts) do
        if tonumber(part) > 255 then return false end
    end
    return true
end

local function join(state, address, context)
    if not valid_address(address) then
        state.message = "Type an address like 78.189.235.195"
        return
    end
    state.servers = server_list.remember(state.servers, address)
    state.request = {host = false, address = address}
    context.action("online_connect")
end

function screen.update(state, input, context)
    local events = imgui.events(input)
    if events.changed.address then state.address = events.changed.address:gsub("[^%d.]", ""):sub(1, 15) end
    if events.clicked.host then
        state.request = {host = true, address = "127.0.0.1"}
        context.action("online_connect")
    elseif events.clicked.join or events.submitted.address then
        join(state, state.address, context)
    elseif events.clicked.back or (input.keys[constants.virtual_keys.escape] and not state.escape_held) then
        context.action("launch")
    end
    state.escape_held = input.keys[constants.virtual_keys.escape] == true
    for index, entry in ipairs(state.servers) do
        if events.clicked["server" .. index] then
            state.address = entry.address
            join(state, entry.address, context)
            break
        end
        if events.clicked["star" .. index] then
            entry.favorite = not entry.favorite
            state.servers = server_list.sort(state.servers)
            server_list.save(state.servers)
            break
        end
    end
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back" .. state.background, 0, 0, true)
    -- Height 0: the window fits its content (the server list, the message).
    imgui.window(context, "network", "Network game", 197, 0, 400, 0)
    imgui.text(context, "Play with friends through a game server.", 0xa8b8e8, imgui.wrap)
    imgui.spacing(context, 6)
    imgui.button(context, "host", "Host a game", -1, 34)
    imgui.text(context, "Starts a server on this computer. Friends join your address.", 0x8090c0, imgui.wrap)
    imgui.spacing(context, 6)
    imgui.separator(context)
    imgui.spacing(context, 4)
    imgui.text(context, "Join a game")
    imgui.input(context, "address", state.address, "Server address (IPv4)", 280)
    imgui.same_line(context)
    imgui.button(context, "join", "Join", -1)
    if #state.servers > 0 then
        imgui.spacing(context, 4)
        imgui.text(context, "Servers you joined", 0xa8b8e8)
        imgui.child(context, "servers", -1, 110, true)
        for index, entry in ipairs(state.servers) do
            imgui.button(context, "star" .. index, entry.favorite and "\226\152\133" or "\226\152\134", 26)
            imgui.same_line(context)
            imgui.selectable(context, "server" .. index, entry.address .. (entry.favorite and "   (favorite)" or ""))
        end
        imgui.end_child(context)
    end
    if state.message then
        imgui.spacing(context, 4)
        imgui.text(context, state.message, 0xff9b9b, imgui.wrap)
    end
    imgui.spacing(context, 6)
    imgui.button(context, "back", "Back", 100)
    imgui.end_window(context)
end

function screen.describe(state)
    return "online_menu address=" .. state.address .. (state.message and " message=" .. state.message or "")
end

return screen
