-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The dynamic camera (OpenLF2 extension, docs/camera.md): this computer's own view of a fight. It frames the fighters
-- that the player follows and zooms out up to a limit that the player sets, so a wide screen shows more of the stage.
-- It only draws: it reads the fight's snapshot and never writes to the fight, so it cannot change a network game or a
-- recording. The fight keeps its own camera (base/game/camera), which the classic picture and the sounds use.
local constants = require("base/game/constants")
local camera_view = {}

-- The picture rows of the original's art: the backgrounds start at row 128 and end at row 550.
camera_view.top, camera_view.bottom = 128, 550
-- Units around each followed fighter, and the look-ahead in the direction it faces.
local margin, lookahead = 150, 40

function camera_view.create() return {zoom = 1} end

-- Page Up and Page Down zoom out and in (a factor on the automatic view), Home goes back to the automatic view.
function camera_view.keys(view, page_up, page_down, home)
    if page_up then view.zoom = math.min(3, view.zoom * 1.15) end
    if page_down then view.zoom = math.max(0.4, view.zoom / 1.15) end
    if home then view.zoom = 1 end
end

-- The view for this frame: `left` (world x of the view's left edge) and `width` (world units across), for a
-- destination `window_width` viewport units wide. snapshot: the drawn items; current: the match (stage width,
-- Stage mode bound); follow: this computer's slots in a network game, or nil; widest: the largest width as a
-- multiple of the window width (the player's setting).
function camera_view.step(view, snapshot, current, follow, window_width, widest)
    local stage_width = current.stage.width or constants.screen.width
    -- The fighters to show: this computer's (a network game) or the human ones first; the other fighters (computer
    -- players, slots below 20) join when all of them still fit in the widest view.
    local wanted = {}
    if follow then
        for _, slot in ipairs(follow) do wanted[slot] = true end
    end
    local function span(test)
        local low, high
        for _, entry in ipairs(snapshot.items) do
            if entry.record.kind == constants.record_kinds.character and entry.hp > 0 and test(entry) then
                local x = entry.x + (entry.facing == 0 and lookahead or -lookahead)
                low, high = math.min(low or x, x), math.max(high or x, x)
            end
        end
        return low, high
    end
    local function first(entry)
        if follow then return wanted[entry.index] == true end
        return entry.human == true
    end
    local limit = window_width * widest
    local low, high = span(first)
    local all_low, all_high = span(function(entry) return first(entry) or entry.index < 20 end)
    if not low or (all_low and (all_high - all_low + 2 * margin) * view.zoom <= limit) then low, high = all_low, all_high end
    low, high = low or stage_width / 2, high or stage_width / 2
    -- The width: the fighters with their margins, between the classic scale and the player's widest view.
    local width = (high - low + 2 * margin) * view.zoom
    -- Never wider than the open stage (past its edges there is nothing to see), and never closer than the classic scale.
    local open_width = stage_width
    if current.stage_bound and current.stage_bound > 0 and current.stage_bound < stage_width then open_width = current.stage_bound end
    width = math.max(window_width, math.min(limit, open_width, width))
    -- The open area: the stage, or the part of Stage mode that is open.
    local open = stage_width
    if current.stage_bound and current.stage_bound > 0 and current.stage_bound < stage_width then open = current.stage_bound end
    local center = (low + high) / 2
    if width < open then center = math.max(width / 2, math.min(open - width / 2, center))
    else center = open / 2 end
    -- Smooth motion: the zoom moves out faster than in; a new stage or a jump of half a view snaps.
    local stage_id = current.stage_run and current.stage_run.id
    if not view.center or view.stage_id ~= stage_id or math.abs(center - view.center) > view.width then
        view.center, view.width = center, width
    else
        view.center = view.center + (center - view.center) * 0.18
        local rate = width > view.width and 0.2 or 0.06
        view.width = math.exp(math.log(view.width) + (math.log(width) - math.log(view.width)) * rate)
    end
    view.stage_id = stage_id
    return math.floor(view.center - view.width / 2 + 0.5), math.floor(view.width + 0.5)
end

return camera_view
