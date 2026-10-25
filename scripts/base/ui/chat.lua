-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The chat during the fights of a server program (OpenLF2 extension, docs/netcode.md "Chat and presence"; the lobby
-- has its own chat panel). Enter opens the chat line (T when Enter is a player's key); its text field takes the
-- keyboard, Enter sends and Escape closes it. The last messages show for a few seconds in a see-through window
-- (base/ui/imgui). A message that is only a number from 1 to 42 plays that taunt on every computer
-- (mods/base/taunts/NN.wav).
local constants = require("base/game/constants")
local controls = require("base/ui/controls")
local online = require("base/game/online")
local music = require("base/game/music")
local imgui = require("base/ui/imgui")
local virtual_keys = constants.virtual_keys
local chat = {}

local shown_ms, lines_shown = 10000, 6

function chat.create()
    return {open = false, text = "", held = {}, frames = 0}
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

-- Returns true while the chat line is open (the engine gives its text field the keys).
function chat.update(state, input, connection)
    local key = open_key()
    local down = input.keys[key] == true
    local fresh = down and not state.held[key]
    state.held[key] = down
    if not state.open then
        if fresh and connection.phase == "lobby" then state.open, state.text, state.frames = true, "", 0 end
        return state.open
    end
    state.frames = state.frames + 1
    local events = imgui.events(input)
    if events.changed.chat_line then state.text = events.changed.chat_line end
    if events.submitted.chat_line then
        if state.text:match("%S") then online.send(connection, {type = "chat", text = state.text}) end
        state.open = false
    -- Escape (or a click elsewhere) leaves the text field: the line closes. Its focus takes a frame to arrive.
    elseif state.frames > 3 and not input.ui_keyboard then
        state.open = false
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
    local lines = {}
    for index = math.max(1, #connection.chat - lines_shown + 1), #connection.chat do
        local line = connection.chat[index]
        if state.open or now - line.at < shown_ms then lines[#lines + 1] = line end
    end
    if #lines == 0 and not state.open then return end
    -- Its bottom stays above the input timeline (base/ui/input_timeline).
    local height = 34 + 25 * #lines + (state.open and 40 or 0)
    imgui.window(context, "chat_window", "Chat", 8, 400 - height, 420, height,
        imgui.no_title + imgui.glass + (state.open and 0 or imgui.passive))
    for _, line in ipairs(lines) do imgui.text(context, line.name .. ": " .. line.text, nil, imgui.wrap) end
    if state.open then
        imgui.input(context, "chat_line", state.text, "Message (1 to 42 plays a taunt), Enter sends", -1, true)
    end
    imgui.end_window(context)
end

return chat
