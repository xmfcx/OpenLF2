-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The lobby of a server program (OpenLF2 extension, docs/ui-network-architecture.md): each computer shows its own
-- view of the lobby that the server keeps. Player 1's keys choose this computer's fighter (left, right) and team (up,
-- down), and attack switches ready. The player with the room role also sets the computers (jump) and starts the
-- fight (defend) when everybody is ready. Escape leaves.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local online = require("base/game/online")
local font = require("base/ui/font")
local screen = {}

local team_names = {[0] = "Independent", "Team 1", "Team 2", "Team 3", "Team 4"}

-- options: the runtime settings; address and port of the server; retry_ms: how long to try again when the server
-- does not answer yet (a server that this computer just started).
function screen.create(options, address, port, retry_ms)
    return {online = online.create(options, address, port, retry_ms), fighters = catalog.load(), held = {}}
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

function screen.update(state, held, context)
    local connection = state.online
    online.poll(connection)
    for _, event in ipairs(online.take_events(connection)) do
        if event.type == "start" then
            state.start = event
            context.action("online_fight")
            return
        end
    end
    local escape = held.keys[constants.virtual_keys.escape] == true
    if escape and not state.escape_held then
        online.close(connection)
        state.escape_held = true
        context.action("launch")
        return
    end
    state.escape_held = escape
    if connection.phase ~= "lobby" or not connection.lobby then return end
    local fresh = presses(state, held[0] or "")
    local me = own_player(state)
    if not me then return end
    local fighter, team = me.fighter, me.team
    if fresh.r then fighter = catalog.step(state.fighters, fighter, 1) end
    if fresh.l then fighter = catalog.step(state.fighters, fighter, -1) end
    if fresh.d then team = (team + 1) % 5 end
    if fresh.u then team = (team + 4) % 5 end
    if fighter ~= me.fighter or team ~= me.team then online.send(connection, {type = "choose", fighter = fighter, team = team}) end
    if fresh.c then online.send(connection, {type = "ready", value = not me.ready}) end
    if me.role and fresh.b then
        local most = 8 - #connection.lobby.players
        online.send(connection, {type = "settings", computers = (connection.lobby.settings.computers + 1) % (most + 1)})
    end
    if me.role and fresh.f then online.send(connection, {type = "start"}) end
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    local connection = state.online
    font.gdi(context, "Online lobby", 40, 30, 0xffffff)
    font.gdi(context, "Server " .. connection.address .. ":" .. connection.port, 40, 50, 0x9bb0ff)
    if connection.phase == "connecting" then
        font.gdi(context, "Connecting...", 40, 90, 0xffffff)
    elseif connection.phase == "failed" then
        font.gdi(context, tostring(connection.problem), 40, 90, 0xff9b9b)
        font.gdi(context, "Escape: back", 40, 120, 0x9bb0ff)
        return
    end
    local lobby = connection.lobby
    if not lobby then return end
    local y = 90
    for position, player in ipairs(lobby.players) do
        local fighter = state.fighters[player.fighter]
        local line = string.format("%d. %s   %s   %s   %s%s%s", player.slot + 1, player.name,
            fighter and fighter.name or "Random", team_names[player.team] or "?", player.ready and "READY" or "not ready",
            player.role and "   (room role)" or "", player.id == connection.id and "   <- you" or "")
        font.gdi(context, line, 40, y, player.ready and 0x9bff9b or 0xffffff)
        y = y + 22
    end
    y = y + 12
    font.gdi(context, string.format("Computers: %d", lobby.settings.computers), 40, y, 0xffffff)
    y = y + 40
    local help = {"Left/Right: fighter   Up/Down: team   Attack: ready", "Escape: leave"}
    local me = own_player(state)
    if me and me.role then table.insert(help, 2, "Jump: number of computers   Defend: start when everybody is ready") end
    for _, line in ipairs(help) do
        font.gdi(context, line, 40, y, 0x9bb0ff)
        y = y + 20
    end
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
