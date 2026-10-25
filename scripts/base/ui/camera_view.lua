-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The camera of the new fight screen (OpenLF2 extension, docs/camera.md and docs/fight-screen.md "Camera"): this
-- computer's own view of a fight. The automatic camera frames the fighters that the player follows; the player can
-- also set a zoom of their own (the mouse wheel, Page Up, Page Down), which config.json keeps, and Home goes back to
-- the automatic camera. The widest view is the whole stage. It only draws: it reads the fight's snapshot and never
-- writes to the fight, so it cannot change a network game or a recording. The fight keeps its own camera
-- (base/game/camera), which the classic picture and the sounds use.
local constants = require("base/game/constants")
local camera_view = {}

-- The picture rows of the original's art: the backgrounds start at row 128, and the ground ends at row 528 (the rows
-- under it are the original's black status line), or lower on a stage whose fighters walk lower.
camera_view.top = 128
function camera_view.bottom(current)
    local far = current and current.stage and current.stage.zboundary and current.stage.zboundary[2] or 0
    return math.min(constants.screen.height, math.max(528, far + 30))
end
-- Units around each followed fighter, and the look-ahead in the direction it faces.
local margin, lookahead = 150, 40
-- One step of the wheel or of Page Up and Page Down.
local step_factor = 1.15

-- zoom: the saved zoom (options.camera_zoom: 0 for the automatic camera, or percent of the window's width).
function camera_view.create(zoom)
    return {zoom = (zoom or 0) > 0 and zoom or nil}
end

-- steps: wheel steps or keys (positive zooms out); home: back to the automatic camera. Returns true when the zoom
-- changed (the caller saves it).
function camera_view.keys(view, steps, home)
    if home then
        local changed = view.zoom ~= nil
        view.zoom = nil
        return changed
    end
    if steps == 0 or not view.window_width then return false end
    -- The first step from the automatic camera starts at its view.
    local percent = view.zoom or (view.width or view.window_width) * 100 / view.window_width
    percent = percent * step_factor ^ steps
    -- Never further than the widest and the closest view of the last frame, so that a step back acts at once.
    if view.widest_percent then percent = math.min(percent, view.widest_percent) end
    if view.closest_percent then percent = math.max(percent, view.closest_percent) end
    percent = math.max(40, math.min(2000, math.floor(percent + 0.5)))
    if percent == view.zoom then return false end
    view.zoom = percent
    return true
end

-- The view for this frame: `left` (world x of the view's left edge) and `width` (world units across).
-- snapshot: the drawn items; current: the match (stage width, Stage mode bound); follow: this computer's slots in a
-- network game, or nil; limits: {window_width = viewport units across, closest = the narrowest view in world units
-- (the band fills the height), widest = the automatic camera's widest view as a multiple of the window width}.
function camera_view.step(view, snapshot, current, follow, limits)
    local window_width = limits.window_width
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
    -- The closest view fills the band's height; the widest is the whole stage.
    local closest = math.min(limits.closest, stage_width)
    local widest = math.max(closest, stage_width)
    local automatic = math.max(closest, math.min(widest, window_width * limits.widest))
    local low, high = span(first)
    local all_low, all_high = span(function(entry) return first(entry) or entry.index < 20 end)
    if not low or (all_low and all_high - all_low + 2 * margin <= automatic) then low, high = all_low, all_high end
    low, high = low or stage_width / 2, high or stage_width / 2
    local width
    if view.zoom then
        width = window_width * view.zoom / 100
    else
        width = math.min(automatic, high - low + 2 * margin)
    end
    width = math.max(closest, math.min(widest, width))
    view.window_width = window_width
    view.widest_percent, view.closest_percent = widest * 100 / window_width, closest * 100 / window_width
    -- The view stays in the open area when it fits (the stage, or the part of Stage mode that is open), as the
    -- original's camera; a wider view shows the closed part too, which the screen darkens.
    local open = stage_width
    if current.stage_bound and current.stage_bound > 0 and current.stage_bound < stage_width then open = current.stage_bound end
    local center = (low + high) / 2
    if width <= open then center = math.max(width / 2, math.min(open - width / 2, center))
    elseif width < stage_width then center = width / 2
    else center = stage_width / 2 end
    -- Smooth motion: the zoom moves out faster than in; a new stage or a jump of half a view snaps.
    local stage_id = current.stage_run and current.stage_run.id
    if not view.center or view.stage_id ~= stage_id or math.abs(center - view.center) > view.width then
        view.center, view.width = center, width
    else
        view.center = view.center + (center - view.center) * 0.18
        local rate = width > view.width and 0.2 or 0.06
        if view.zoom then rate = 0.35 end
        view.width = math.exp(math.log(view.width) + (math.log(width) - math.log(view.width)) * rate)
    end
    view.stage_id = stage_id
    return math.floor(view.center - view.width / 2 + 0.5), math.floor(view.width + 0.5)
end

return camera_view
