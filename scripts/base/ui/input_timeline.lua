-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Input timeline (OpenLF2 extension): during a fight, the last five seconds of this computer's first player, one row
-- per key, scrolling from right to left and fading with age. A thin grey line is the key as held on the keyboard; the
-- colored bar under it is the key as the fight read it (it reads the keys on every second fight frame, marked by the
-- ticks under the rows), so the input buffer of the game speed menu (base/ui/flow) shows at work. The header shows
-- how many key states wait in that buffer. V shows or hides it. It is a panel (base/ui/panels): it can move anywhere
-- in the window. It only reads the keys, so it never changes a network game or a recording.
local font = require("base/ui/font")

local timeline = {}

local history = 150
local column = 2
local label_width, row_height, header_height, footer_height = 26, 9, 13, 6
local width = label_width + history * column + 4
local height = header_height + 7 * row_height + footer_height
local keys = {
    {letter = "u", label = "Up", color = {0x5a, 0xa8, 0xff}}, {letter = "d", label = "Dn", color = {0x5a, 0xa8, 0xff}},
    {letter = "l", label = "Lt", color = {0x5a, 0xa8, 0xff}}, {letter = "r", label = "Rt", color = {0x5a, 0xa8, 0xff}},
    {letter = "c", label = "Atk", color = {0xff, 0x6b, 0x5a}}, {letter = "b", label = "Jmp", color = {0x5a, 0xe0, 0x8a}},
    {letter = "f", label = "Def", color = {0xff, 0xd2, 0x4a}},
}
-- Older parts fade in steps of this many frames.
local fade_frames = 25
local toggle_key = 0x56

timeline.width, timeline.height = width, height

function timeline.create()
    return {frames = {}}
end

-- The local keys, before a network game exchanges input: returns true when V asks to show or hide the timeline.
function timeline.toggled(state, input)
    local toggle = input.keys[toggle_key] == true
    local fresh = toggle and not state.toggle_held
    state.toggle_held = toggle
    return fresh
end

-- One frame of a fight: `held`, the keys as held; `read`, the keys the fight read this frame (nil when it did not
-- read them); `stepped`, whether the fight ran; `waiting`, the key states waiting in the buffer. A new fight starts
-- a new timeline.
function timeline.record(state, match, held, read, stepped, waiting)
    if state.match ~= match then state.match, state.frames, state.seen = match, {}, "" end
    if read then state.seen = read end
    local frames = state.frames
    frames[#frames + 1] = {held = held or "", seen = state.seen, read = read ~= nil, stepped = stepped}
    if #frames > history then table.remove(frames, 1) end
    state.waiting = waiting
end

-- Fills the runs of frames where `test` holds, split where the fade steps change.
local function runs(context, frames, left, y, h, test, color)
    local count = #frames
    local start
    for index = 1, count + 1 do
        local frame = frames[index]
        local on = frame and test(frame)
        local age = count - index
        local bucket = frame and math.floor(age / fade_frames)
        if start and (not on or bucket ~= start.bucket) then
            local alpha = math.floor(255 * (1 - start.bucket * fade_frames / (history + fade_frames)))
            context.fill(left + (start.index - 1) * column, y, (index - start.index) * column, h, color[1], color[2],
                color[3], alpha)
            start = nil
        end
        if on and not start then start = {index = index, bucket = bucket} end
    end
end

-- The timeline at (x, y) (its panel, base/ui/panels).
function timeline.draw(state, context, x, y)
    if not state.match then return end
    context.fill(x, y, width, height, 0x0a, 0x0e, 0x1e, 185)
    context.fill(x, y, width, 1, 0x70, 0x78, 0xa0)
    context.fill(x, y + height - 1, width, 1, 0x70, 0x78, 0xa0)
    local title = "Input  (V: hide)"
    if state.waiting then title = title .. "   waiting: " .. state.waiting end
    font.gdi(context, title, x + 4, y - 1, 0xc8c8e0)
    local frames = state.frames
    -- The newest frame is at the right edge.
    local left = x + label_width + (history - #frames) * column
    for row, key in ipairs(keys) do
        local top = y + header_height + (row - 1) * row_height
        font.gdi(context, key.label, x + 3, top - 4, 0x9090b0)
        local letter = key.letter
        runs(context, frames, left, top, 2, function(frame) return frame.held:find(letter, 1, true) ~= nil end,
            {0xc8, 0xc8, 0xd8})
        runs(context, frames, left, top + 3, 5, function(frame) return frame.seen:find(letter, 1, true) ~= nil end,
            key.color)
    end
    -- Ticks: the fight's key reads.
    local tick_y = y + header_height + 7 * row_height + 1
    runs(context, frames, left, tick_y, 3, function(frame) return frame.read end, {0xff, 0xff, 0xff})
end

return timeline
