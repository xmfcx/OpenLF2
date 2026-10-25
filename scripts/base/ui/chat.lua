-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The chat of a server program's lobby and fights (OpenLF2 extension, docs/netcode.md "Chat and presence"). Enter
-- opens the chat line (T when Enter is a player's key), Enter sends it and Escape closes it. While it is open, the
-- keys write into the line and the players' keys are held back. The last messages show for a few seconds. A message
-- that is only a number from 1 to 42 plays that taunt on every computer (mods/base/taunts/NN.wav).
local constants = require("base/game/constants")
local controls = require("base/ui/controls")
local online = require("base/game/online")
local music = require("base/game/music")
local font = require("base/ui/font")
local virtual_keys = constants.virtual_keys
local chat = {}

local shown_ms, fade_ms, lines_shown, line_limit = 10000, 2000, 6, 120

function chat.create()
    return {open = false, text = "", held = {}}
end

-- Enter, unless a player uses it; then T.
local function open_key()
    for _, set in ipairs(controls.current().sets) do
        for _, key in ipairs(set.keys) do
            if key == virtual_keys.enter then return string.byte("T") end
        end
    end
    return virtual_keys.enter
end

local function pressed(state, input, code)
    local down = input.keys[code] == true
    local fresh = down and not state.held[code]
    state.held[code] = down
    return fresh
end

-- Returns true while the chat line takes the keys (the caller then holds the players' keys back).
function chat.update(state, input, connection, context)
    local enter = pressed(state, input, virtual_keys.enter)
    local escape = pressed(state, input, virtual_keys.escape)
    local backspace = pressed(state, input, virtual_keys.backspace)
    local key = open_key()
    local opening = key == virtual_keys.enter and enter or pressed(state, input, key)
    local was_open = state.open
    if not state.open then
        if opening and connection.phase == "lobby" then state.open, state.text, state.skip_text = true, "", true end
    else
        if escape then
            state.open = false
        elseif enter then
            if state.text ~= "" then online.send(connection, {type = "chat", text = state.text}) end
            state.open = false
        else
            if backspace then state.text = state.text:sub(1, -2) end
            -- The key that opened the line (T) also arrives as typed text: it is not part of the message.
            local typed = state.skip_text and "" or input.text or ""
            state.skip_text = false
            for character in typed:gmatch("[%w%p ]") do
                if #state.text < line_limit then state.text = state.text .. character end
            end
        end
    end
    if state.open ~= was_open then context.text_input(state.open) end
    -- The key that closed the line stays held back until it is let go.
    if not state.open and was_open then state.release = true end
    if state.release then
        if not (input.keys[virtual_keys.enter] or input.keys[virtual_keys.escape]) then state.release = nil end
        return true
    end
    return state.open
end

-- The taunts that arrived since the last call.
function chat.play_taunts(connection, context)
    for _, number in ipairs(connection.taunts) do
        if music.master > 0 then
            context.sound(string.format("mods/base/taunts/%02d.wav", number), math.floor((music.master - 100) * 3800 / 100), 0)
        end
    end
    connection.taunts = {}
end

function chat.draw(state, context, connection)
    local now = engine.network_time()
    local y = 440
    local first = math.max(1, #connection.chat - lines_shown + 1)
    for index = #connection.chat, first, -1 do
        local line = connection.chat[index]
        local age = now - line.at
        if age < shown_ms + fade_ms or state.open then
            local alpha = state.open and 1 or math.max(0, math.min(1, (shown_ms + fade_ms - age) / fade_ms))
            local gray = math.floor(0xff * alpha)
            font.gdi(context, line.name .. ": " .. line.text, 10, y, gray * 65536 + gray * 256 + gray, 0x000000)
            y = y - 18
        end
    end
    if state.open then
        font.gdi(context, "Say: " .. state.text .. "_", 10, 462, 0xffd24a, 0x000000)
    end
end

return chat
