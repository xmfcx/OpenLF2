-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Menus at the window's own resolution (OpenLF2 extension): a screen describes its menu in draw() with these
-- functions, the engine draws it with Dear ImGui, and what the player did comes back in the next frame's input
-- (`input.ui`, see events below). Positions and sizes are in screen units (794 x 550) and scale with the picture;
-- 0 means automatic. Every element has an id of letters, digits and '_', unique in its window.
local imgui = {}

-- Element flags (ports/platform.hpp UiFlag).
imgui.no_title, imgui.wrap, imgui.large, imgui.focus, imgui.border, imgui.disabled = 1, 2, 4, 8, 16, 32
-- Window flags: see-through (over a fight), and clicks pass through.
imgui.glass, imgui.passive = 64, 128
-- Image flags: the image is a button, the image is dim.
imgui.clickable, imgui.dim = 256, 512
-- A window with small spaces (the fight screen's cards), and a small text (older engines ignore both).
imgui.compact, imgui.small = 1024, 2048
-- A child that stays at its bottom while new lines come (a chat log; older engines ignore it).
imgui.bottom = 4096

-- Whether this engine draws menus (older runtimes have no context.ui).
function imgui.available(context) return context.ui ~= nil end

-- The events of `input`: clicked[id] = true, changed[id] = text, submitted[id] = text.
local none = {clicked = {}, changed = {}, submitted = {}}
function imgui.events(input) return input.ui or none end
-- The new value of slider `id` in `events`, or nil (also from the buttons of an older engine).
function imgui.slider_value(events, id, value, low, high)
    local changed = tonumber(events.changed[id] or "")
    if changed then return math.max(low, math.min(high, math.floor(changed))) end
    if events.clicked[id .. "_less"] then return math.max(low, value - 1) end
    if events.clicked[id .. "_more"] then return math.min(high, value + 1) end
    return nil
end

-- A height of 0 fits the content and centers the window in the picture's height (y is not used then).
function imgui.window(context, id, title, x, y, width, height, flags)
    context.ui("window", id, title, "", x, y, width, height, -1, flags or 0)
end
function imgui.end_window(context) context.ui("end_window") end
-- color: 0xRRGGBB or nil; flags: imgui.wrap, imgui.large.
function imgui.text(context, text, color, flags) context.ui("text", "", text, "", 0, 0, 0, 0, color or -1, flags or 0) end
-- color: 0xRRGGBB for a button that shows a state (older engines draw it in the theme's color).
function imgui.button(context, id, label, width, height, disabled, color)
    context.ui("button", id, label, "", 0, 0, width or 0, height or 0, color or -1, disabled and imgui.disabled or 0)
end
-- value: the text as the screen knows it (a change replaces what is typed); hint: shown while empty.
function imgui.input(context, id, value, hint, width, focus)
    context.ui("input", id, hint or "", value or "", 0, 0, width or 0, 0, -1, focus and imgui.focus or 0)
end
function imgui.selectable(context, id, label, selected, width, height, disabled)
    context.ui("selectable", id, label, selected and "1" or "", 0, 0, width or 0, height or 0, -1,
        disabled and imgui.disabled or 0)
end
-- Puts the next element on the same line, at `x` from the window's left when given.
function imgui.same_line(context, x) context.ui("same_line", "", "", "", x or 0) end
function imgui.separator(context) context.ui("separator") end
function imgui.spacing(context, height) context.ui("spacing", "", "", "", 0, 0, 0, height or 4) end
-- A scrolling area inside a window.
-- bottom: it stays at its bottom while new lines come (a chat log).
function imgui.child(context, id, width, height, border, bottom)
    context.ui("child", id, "", "", 0, 0, width or 0, height or 0, -1, (border and imgui.border or 0) + (bottom and imgui.bottom or 0))
end
function imgui.end_child(context) context.ui("end_child") end
-- A bar filled to `fraction` (0 to 1) with `label` on it (older engines show the label alone).
function imgui.progress(context, fraction, label, width)
    local permille = math.max(0, math.min(1000, math.floor(fraction * 1000)))
    if not (context.ui_kinds and context.ui_kinds.progress) then
        imgui.text(context, label or string.format("%d %%", math.floor(permille / 10)))
        return
    end
    context.ui("progress", "", label or "", "", permille, 0, width or 0, 0, -1, 0)
end
-- A plain bar (the fight screen's HP and MP): filled to `value` (0 to 1) in `color`, to `behind` (0 to 1) in
-- `behind_color` under it, the rest in `back`; `label` at its right end. Older engines draw a progress bar.
function imgui.bar(context, value, color, behind, behind_color, back, label, width, height)
    local function mille(fraction) return math.max(0, math.min(1000, math.floor((fraction or 0) * 1000 + 0.5))) end
    if not (context.ui_kinds and context.ui_kinds.bar) then
        imgui.progress(context, value, label or "", width)
        return
    end
    context.ui("bar", "", label or "", string.format("%06x,%06x", behind_color or 0, back or 0x101420), mille(value),
        mille(behind), width or 0, height or 0, color, 0)
end
-- The elements between group and end_group act as one, for example on the line after an image.
function imgui.group(context) if context.ui_kinds and context.ui_kinds.group then context.ui("group") end end
function imgui.end_group(context) if context.ui_kinds and context.ui_kinds.group then context.ui("end_group") end end
-- An integer from `low` to `high`; a moved knob comes back as changed[id] = the value as text.
function imgui.slider(context, id, label, value, low, high, width, disabled)
    if not (context.ui_kinds and context.ui_kinds.slider) then
        -- An older engine: two buttons step the value.
        imgui.button(context, id .. "_less", "-", 0, 0, disabled or value <= low)
        imgui.same_line(context)
        imgui.text(context, label ~= "" and label or tostring(value))
        imgui.same_line(context)
        imgui.button(context, id .. "_more", "+", 0, 0, disabled or value >= high)
        return
    end
    context.ui("slider", id, label or "", tostring(value), low, high, width or 0, 0, -1, disabled and imgui.disabled or 0)
end
-- A bitmap of the game data, or the part `source` = {x, y, width, height} of it, at `width` x `height` (0: its own
-- size). frames: colors (0xRRGGBB) of the frames around it, outside first. flags: imgui.clickable, imgui.dim.
function imgui.image(context, id, resource, source, width, height, frames, flags)
    if not (context.ui_kinds and context.ui_kinds.image) then
        imgui.spacing(context, height)
        return
    end
    local label = source and string.format("%d,%d,%d,%d", source[1], source[2], source[3], source[4]) or ""
    if frames and #frames > 0 then
        local colors = {}
        for position, color in ipairs(frames) do colors[position] = string.format("%06x", color) end
        label = label .. "|" .. table.concat(colors, ",")
    end
    context.ui("image", id, label, resource, 0, 0, width or 0, height or 0, -1, flags or 0)
end

return imgui
