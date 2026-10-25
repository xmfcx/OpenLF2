-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The chat during a server program's session, in its menus and fights (OpenLF2 extension, docs/netcode.md "Chat and
-- presence"; the lobby has its own chat panel). Enter opens the chat line (T when Enter is a player's key); its text field takes the
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
    return {open = false, text = "", held = {}, opened_at = 0}
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

-- Returns true while the chat line takes the keys: while it is open (the engine gives its text field the keys), and
-- after it closes, until the keys are let go.
function chat.update(state, input, connection)
    local key = open_key()
    local down = input.keys[key] == true
    local fresh = down and not state.held[key]
    state.held[key] = down
    -- After the line closes, the keys stay held back until Enter, the opening key and Escape are let go: while the
    -- text field had the keyboard, the scripts saw them as released, so a key still down would act again.
    if state.release then
        if not input.ui_keyboard and not down and not input.keys[virtual_keys.enter]
           and not input.keys[virtual_keys.escape] then
            state.release = nil
        end
        return true
    end
    if not state.open then
        if fresh and connection.phase == "session" then state.open, state.text, state.opened_at = true, "", engine.network_time() end
        return state.open
    end
    -- In real time: a frame that waits for the server's tick runs its scripts again and again.
    local age = engine.network_time() - state.opened_at
    local events = imgui.events(input)
    if events.changed.chat_line then state.text = events.changed.chat_line end
    -- The Enter that opened the line reaches its text field too: a send in its first 150 ms is that Enter.
    if events.submitted.chat_line and age > 150 then
        if state.text:match("%S") then online.send(connection, {type = "chat", text = state.text}) end
        state.open = false
    -- Escape (or a click elsewhere) leaves the text field: the line closes. Its focus takes a few frames to arrive.
    elseif age > 400 and not input.ui_keyboard then
        state.open = false
    end
    if not state.open then state.release = true end
    return true
end

-- The taunts that arrived since the last call.
function chat.play_taunts(connection, context)
    for _, number in ipairs(connection.taunts) do
        if music.effects > 0 then
            context.sound(string.format("mods/base/taunts/%02d.wav", number), math.floor((music.effects - 100) * 3800 / 100), 0)
        end
        connection.taunts_played = (connection.taunts_played or 0) + 1
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
    -- The open line is a window of its own: ImGui gives the keyboard to no field of a window that took no input.
    imgui.window(context, state.open and "chat_open" or "chat_lines", "Chat", 8, 400 - height, 420, height,
        imgui.no_title + imgui.glass + (state.open and 0 or imgui.passive))
    for _, line in ipairs(lines) do imgui.text(context, line.name .. ": " .. line.text, nil, imgui.wrap) end
    if state.open then
        imgui.input(context, "chat_line", state.text, "Message (1 to 42 plays a taunt), Enter sends", -1, true)
    end
    imgui.end_window(context)
end

return chat
