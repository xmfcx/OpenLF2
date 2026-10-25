-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The panels over a fight (OpenLF2 extension, docs/fight-screen.md "Panels"): the damage share, the input timeline,
-- the stage panel and the minimap. A panel can sit anywhere in the window: dragging it moves it, dragging its
-- bottom-right corner resizes it (when it has a size of its own). It keeps the nearest corner or edge of the window
-- as its anchor, so it stays in place when the window changes its size, and config.json keeps the places ("panels").
-- The panels only read the fight, so they never change a network game or a recording.
local panels = {}

local handle_size = 9
-- anchor: two letters, the vertical edge (t: under the cards and boss bars, b: the window's bottom) and the horizontal one (l, c,
-- r); dx and dy: the distance from them; resize: the limits of the size, or nil for a panel of a fixed size.
local defaults = {
    chart = {anchor = "tr", dx = 6, dy = 20, width = 220, height = 100, shown = true,
        resize = {width = {120, 600}, height = {64, 400}}},
    timeline = {anchor = "bl", dx = 6, dy = 22, width = 330, height = 82, shown = true},
    stage = {anchor = "tl", dx = 6, dy = 20, width = 210, height = 74, shown = true,
        resize = {width = {120, 500}, height = {40, 300}}},
    minimap = {anchor = "tc", dx = 0, dy = 0, width = 360, height = 28, shown = true,
        resize = {width = {160, 1600}, height = {18, 80}}},
}
panels.ids = {"chart", "timeline", "stage", "minimap"}

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function number(value) return type(value) == "number" and value == value and value > -10000 and value < 10000 end

function panels.create()
    local state = {places = {}, button = false}
    local document = engine.read_settings()
    local saved = type(document) == "table" and type(document.panels) == "table" and document.panels or {}
    for _, id in ipairs(panels.ids) do
        local default, given = defaults[id], saved[id]
        local place = {anchor = default.anchor, dx = default.dx, dy = default.dy, width = default.width,
            height = default.height, shown = default.shown}
        if type(given) == "table" then
            if type(given.anchor) == "string" and given.anchor:match("^[tb][lcr]$") then place.anchor = given.anchor end
            for _, key in ipairs({"dx", "dy", "width", "height"}) do
                if number(given[key]) then place[key] = math.floor(given[key]) end
            end
            if type(given.shown) == "boolean" then place.shown = given.shown end
        end
        if default.resize then
            place.width = clamp(place.width, default.resize.width[1], default.resize.width[2])
            place.height = clamp(place.height, default.resize.height[1], default.resize.height[2])
        else
            place.width, place.height = default.width, default.height
        end
        state.places[id] = place
    end
    return state
end

local function save(state)
    local document = engine.read_settings()
    if type(document) ~= "table" then document = {} end
    local places = {}
    for id, place in pairs(state.places) do
        places[id] = {anchor = place.anchor, dx = place.dx, dy = place.dy, width = place.width, height = place.height,
            shown = place.shown}
    end
    document.panels = places
    engine.write_settings(document)
end

function panels.shown(state, id) return state.places[id].shown end
function panels.toggle(state, id)
    state.places[id].shown = not state.places[id].shown
    save(state)
end
function panels.set_shown(state, id, shown)
    if state.places[id].shown == shown then return end
    state.places[id].shown = shown
    save(state)
end

-- The rectangle of panel `id` in the layout (base/ui/fight_hud layout: the window, and `region_top` under the cards
-- and the boss bars):
-- x, y, width, height, kept inside the window.
function panels.rect(state, id, layout)
    local place = state.places[id]
    local width, height = math.min(place.width, layout.width), math.min(place.height, layout.height)
    local vertical, horizontal = place.anchor:sub(1, 1), place.anchor:sub(2, 2)
    local x
    if horizontal == "l" then x = layout.left + place.dx
    elseif horizontal == "r" then x = layout.right - place.dx - width
    else x = math.floor((layout.left + layout.right - width) / 2) + place.dx end
    local y = vertical == "t" and layout.region_top + place.dy or layout.bottom - place.dy - height
    x = clamp(x, layout.left, layout.right - width)
    y = clamp(y, layout.top, layout.bottom - height)
    return x, y, width, height
end

-- Keeps the place of a moved panel: the nearest edges of the window become its anchor.
local function anchor(place, layout, x, y)
    local center_x, center_y = x + place.width / 2, y + place.height / 2
    local third = layout.width / 3
    local horizontal = center_x < layout.left + third and "l" or center_x > layout.right - third and "r" or "c"
    local vertical = center_y < (layout.top + layout.bottom) / 2 and "t" or "b"
    place.anchor = vertical .. horizontal
    if horizontal == "l" then place.dx = x - layout.left
    elseif horizontal == "r" then place.dx = layout.right - x - place.width
    else place.dx = x - math.floor((layout.left + layout.right - place.width) / 2) end
    place.dy = vertical == "t" and y - layout.region_top or layout.bottom - y - place.height
end

-- The local mouse (before a network game exchanges input): a press on a shown panel starts a move, or a resize on
-- its bottom-right corner; releasing the button saves the new place. `ids`: the panels on the screen now.
function panels.pointer(state, input, layout, ids)
    local x, y = input.pointer_x, input.pointer_y
    local valid = x and y and layout
    local pressed = input.button and not state.button
    state.button = input.button
    if pressed and valid and not input.ui_mouse then
        for _, id in ipairs(ids) do
            local place = state.places[id]
            local left, top, width, height = panels.rect(state, id, layout)
            if place.shown and x >= left and x < left + width and y >= top and y < top + height then
                local resize = defaults[id].resize and x >= left + width - handle_size and y >= top + height - handle_size
                state.drag = {id = id, resize = resize, dx = x - left, dy = y - top, right = left + width - x,
                    bottom = top + height - y}
                break
            end
        end
    end
    local drag = state.drag
    if drag and input.button and valid then
        local place, limits = state.places[drag.id], defaults[drag.id].resize
        local left, top = panels.rect(state, drag.id, layout)
        if drag.resize then
            place.width = clamp(x + drag.right - left, limits.width[1], limits.width[2])
            place.height = clamp(y + drag.bottom - top, limits.height[1], limits.height[2])
            anchor(place, layout, left, top)
        else
            anchor(place, layout, clamp(x - drag.dx, layout.left, layout.right - place.width),
                clamp(y - drag.dy, layout.top, layout.bottom - place.height))
        end
    elseif drag and not input.button then
        state.drag = nil
        save(state)
    end
    return state.drag ~= nil
end

-- The resize corner of a panel at (x, y, width, height): three short diagonal lines.
function panels.draw_handle(context, x, y, width, height)
    for _, length in ipairs({3, 6, 9}) do
        for step = 0, length - 1 do
            context.fill(x + width - 3 - step, y + height - 3 - (length - 1 - step), 1, 1, 0xa0, 0xa8, 0xd0)
        end
    end
end

return panels
