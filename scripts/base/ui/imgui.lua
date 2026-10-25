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

-- Whether this engine draws menus (older runtimes have no context.ui).
function imgui.available(context) return context.ui ~= nil end

-- The events of `input`: clicked[id] = true, changed[id] = text, submitted[id] = text.
local none = {clicked = {}, changed = {}, submitted = {}}
function imgui.events(input) return input.ui or none end

-- A height of 0 fits the content and centers the window in the picture's height (y is not used then).
function imgui.window(context, id, title, x, y, width, height, flags)
    context.ui("window", id, title, "", x, y, width, height, -1, flags or 0)
end
function imgui.end_window(context) context.ui("end_window") end
-- color: 0xRRGGBB or nil; flags: imgui.wrap, imgui.large.
function imgui.text(context, text, color, flags) context.ui("text", "", text, "", 0, 0, 0, 0, color or -1, flags or 0) end
function imgui.button(context, id, label, width, height, disabled)
    context.ui("button", id, label, "", 0, 0, width or 0, height or 0, -1, disabled and imgui.disabled or 0)
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
function imgui.child(context, id, width, height, border)
    context.ui("child", id, "", "", 0, 0, width or 0, height or 0, -1, border and imgui.border or 0)
end
function imgui.end_child(context) context.ui("end_child") end

return imgui
