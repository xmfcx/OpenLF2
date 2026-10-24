-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Damage share chart (OpenLF2 extension): a 100% stacked area chart over a fight, like the timeline at the end of a
-- game of Age of Empires II. The chart always has the same height; at each moment, each fighter's band is their
-- share of all damage dealt so far, and each kill is a mark on the killer's band. It only reads the fight, so it
-- never changes a network game or a recording. Dragging the chart moves it, dragging its bottom-right corner resizes
-- it, and the place and size are saved in config.json ("damage_chart").
local font = require("base/ui/font")
local controls = require("base/ui/controls")
local constants = require("base/game/constants")

local chart = {}

local screen_width, screen_height = constants.screen.width, constants.screen.height
-- Below the status panels at the top right, so that the HP bars stay visible.
local defaults = {x = screen_width - 226, y = 132, width = 220, height = 100}
local limits = {width = {120, 600}, height = {64, 400}}
-- A sample every half second of fight time (30 fight frames per second).
local sample_frames = 15
local max_columns = 40
local title_height, legend_height, handle_size = 13, 13, 9
-- One color for each player slot.
local colors = {{0x4e, 0x9b, 0xff}, {0xff, 0x6b, 0x6b}, {0x4c, 0xd0, 0x7d}, {0xff, 0xc2, 0x3d},
    {0xb0, 0x7c, 0xff}, {0x3d, 0xd6, 0xd0}, {0xff, 0x8f, 0xc7}, {0xff, 0x9a, 0x3d}}

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

local function fit(layout)
    layout.width = clamp(layout.width, limits.width[1], limits.width[2])
    layout.height = clamp(layout.height, limits.height[1], limits.height[2])
    layout.x = clamp(layout.x, 0, screen_width - layout.width)
    layout.y = clamp(layout.y, 0, screen_height - layout.height)
end

function chart.create()
    local state = {x = defaults.x, y = defaults.y, width = defaults.width, height = defaults.height,
        samples = {}, kills = {}, kill_counts = {}, button = false}
    local document = engine.read_settings()
    local saved = type(document) == "table" and document.damage_chart
    if type(saved) == "table" then
        for _, key in ipairs({"x", "y", "width", "height"}) do
            local value = saved[key]
            if type(value) == "number" and value == value and value > -10000 and value < 10000 then
                state[key] = math.floor(value)
            end
        end
    end
    fit(state)
    return state
end

local function save(state)
    local document = engine.read_settings()
    if type(document) ~= "table" then document = {} end
    document.damage_chart = {x = state.x, y = state.y, width = state.width, height = state.height}
    engine.write_settings(document)
end

local function inside(state, x, y)
    return x >= state.x and x < state.x + state.width and y >= state.y and y < state.y + state.height
end

-- The local mouse (before a network game exchanges input): a press on the chart starts a move, or a resize on the
-- bottom-right corner; releasing the button saves the new place.
function chart.pointer(state, input)
    local x, y = input.pointer_x, input.pointer_y
    local valid = x and y and x >= 0 and y >= 0
    local pressed = input.button and not state.button
    state.button = input.button
    if pressed and valid and inside(state, x, y) then
        if x >= state.x + state.width - handle_size and y >= state.y + state.height - handle_size then
            state.drag = {resize = true, dx = state.x + state.width - x, dy = state.y + state.height - y}
        else
            state.drag = {dx = x - state.x, dy = y - state.y}
        end
    end
    local drag = state.drag
    if drag and input.button and valid then
        if drag.resize then
            state.width = clamp(x + drag.dx - state.x, limits.width[1], math.min(limits.width[2], screen_width - state.x))
            state.height = clamp(y + drag.dy - state.y, limits.height[1], math.min(limits.height[2], screen_height - state.y))
        else
            state.x, state.y = x - drag.dx, y - drag.dy
        end
        fit(state)
    elseif drag and not input.button then
        state.drag = nil
        save(state)
    end
end

-- The fighter in each player slot: a player's, or the computer's in that slot.
local function fighters(match)
    local list = {}
    for slot = 0, 7 do
        local index = match.items[slot] and slot or slot + 10
        local value = match.items[index]
        if value then list[#list + 1] = {slot = slot, index = index, value = value} end
    end
    return list
end

-- Called after each frame of a fight: a new fight starts a new chart; kills are noted when they happen, the damage
-- totals every half second. The chart stops with a last sample when the round is over (round_counter leaves 0), so
-- the summary screen does not stretch it.
function chart.observe(state, match)
    if state.match ~= match then
        state.match, state.samples, state.kills, state.kill_counts, state.last_frame = match, {}, {}, {}, nil
        state.closed = false
    end
    local over = (match.round_counter or 0) > 0
    if match.frame_number == state.last_frame or over and state.closed then return end
    state.last_frame = match.frame_number
    local list = fighters(match)
    for _, fighter in ipairs(list) do
        local kills = fighter.value.kills or 0
        local before = state.kill_counts[fighter.slot] or 0
        for _ = before + 1, kills do state.kills[#state.kills + 1] = {sample = #state.samples + 1, slot = fighter.slot} end
        state.kill_counts[fighter.slot] = kills
    end
    state.closed = over
    if #state.samples == 0 or over or match.frame_number % sample_frames == 0 then
        local sample = {}
        for _, fighter in ipairs(list) do sample[fighter.slot] = math.max(fighter.value.damage_dealt or 0, 0) end
        state.samples[#state.samples + 1] = sample
        state.slots = list
    end
end

-- The band edges of one sample: bottom-to-top y of each slot's band, in slot order.
local function bands(sample, slots, top, height)
    local total = 0
    for _, fighter in ipairs(slots) do total = total + (sample[fighter.slot] or 0) end
    if total == 0 then return nil end
    local edges, running = {}, 0
    local bottom = top + height
    for _, fighter in ipairs(slots) do
        local low = bottom - math.floor(height * running / total + 0.5)
        running = running + (sample[fighter.slot] or 0)
        local high = bottom - math.floor(height * running / total + 0.5)
        edges[fighter.slot] = {high, low}
    end
    return edges
end

function chart.draw(state, context)
    local x, y, width, height = state.x, state.y, state.width, state.height
    context.fill(x, y, width, height, 0x0c, 0x10, 0x24, 190)
    context.fill(x, y, width, 1, 0x80, 0x88, 0xb0)
    context.fill(x, y + height - 1, width, 1, 0x80, 0x88, 0xb0)
    context.fill(x, y, 1, height, 0x80, 0x88, 0xb0)
    context.fill(x + width - 1, y, 1, height, 0x80, 0x88, 0xb0)
    font.gdi(context, "Damage share", x + 4, y - 1, 0xc8c8e0)
    local plot = {x = x + 3, y = y + title_height, width = width - 6, height = height - title_height - legend_height - 2}
    local samples, slots = state.samples, state.slots or {}
    local edges_of = {}
    local count = #samples
    local columns = math.min(count, max_columns, math.floor(plot.width / 2))
    local drawn = false
    for column = 1, columns do
        local left = plot.x + math.floor((column - 1) * plot.width / columns)
        local right = plot.x + math.floor(column * plot.width / columns)
        local sample = math.max(1, math.floor(column * count / columns))
        local edges = bands(samples[sample], slots, plot.y, plot.height)
        if edges then
            drawn = true
            for _, fighter in ipairs(slots) do
                local edge, color = edges[fighter.slot], colors[fighter.slot + 1]
                if edge[2] > edge[1] then
                    context.fill(left, edge[1], right - left, edge[2] - edge[1], color[1], color[2], color[3], 230)
                end
            end
        end
    end
    if not drawn then
        font.gdi(context, "No damage yet", x + math.floor(width / 2), plot.y + math.floor(plot.height / 2) - 8,
            0x8080a0, nil, "center")
    end
    -- Kill marks: a small white diamond with a dark rim in the middle of the killer's band.
    for _, kill in ipairs(state.kills) do
        local sample = samples[math.min(kill.sample, count)]
        local edges = sample and bands(sample, slots, plot.y, plot.height)
        local edge = edges and edges[kill.slot]
        if edge then
            local mark_x = plot.x + math.floor((math.min(kill.sample, count) - 0.5) * plot.width / count)
            local mark_y = math.floor((edge[1] + edge[2]) / 2)
            context.fill(mark_x - 3, mark_y - 1, 7, 3, 0x10, 0x10, 0x20)
            context.fill(mark_x - 1, mark_y - 3, 3, 7, 0x10, 0x10, 0x20)
            context.fill(mark_x - 2, mark_y, 5, 1, 0xff, 0xff, 0xff)
            context.fill(mark_x, mark_y - 2, 1, 5, 0xff, 0xff, 0xff)
        end
    end
    -- The legend: a color square and the name of each fighter, as far as the width goes.
    local legend_x, legend_y = x + 4, y + height - legend_height - 1
    for _, fighter in ipairs(slots) do
        local name = fighter.index < 8 and controls.name(fighter.index) or "Com"
        name = name:sub(1, 10)
        local needed = 10 + font.gdi_width(name) + 8
        if legend_x + needed > x + width - handle_size then break end
        local color = colors[fighter.slot + 1]
        context.fill(legend_x, legend_y + 4, 7, 7, color[1], color[2], color[3])
        font.gdi(context, name, legend_x + 10, legend_y - 1, 0xd0d0e8)
        legend_x = legend_x + needed
    end
    -- The resize corner: three short diagonal lines.
    for _, length in ipairs({3, 6, 9}) do
        for step = 0, length - 1 do
            context.fill(x + width - 3 - step, y + height - 3 - (length - 1 - step), 1, 1, 0xa0, 0xa8, 0xd0)
        end
    end
end

return chart
