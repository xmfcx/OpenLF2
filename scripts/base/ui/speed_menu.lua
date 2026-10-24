-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Game speed menu (OpenLF2 extension), opened by typing M, F, D in order on any screen outside a network game.
-- One slider from 0 to 1 with a notch every 0.1 sets speed.tenths: a fight advances on that share of the frames
-- (0 stops it, 1 is the normal speed) while menus and this window keep the full frame rate. Left/right (keyboard or
-- d-pad) move one notch, the mouse clicks or drags the knob, and Enter, Escape, A, B or M, F, D again close it.
-- In a network game the host's speed counts for both peers, so the joining peer's menu only shows it.
-- Fairy dust drifts around the window; 0.4 is marked as the sweet spot.
local navigation = require("base/ui/navigation")
local font = require("base/ui/font")
local sounds = require("base/game/sounds")
local speed = require("base/game/speed")
local constants = require("base/game/constants")

local menu = {}

local panel = {x = 227, y = 190, width = 340, height = 150}
local track = {x = panel.x + 40, y = panel.y + 84, width = 260}
local notch_width = track.width / 10
local sweet_spot = 4
-- The keys that open and close the menu: M, F, D.
local sequence = {0x4d, 0x46, 0x44}
local dust_colors = {{0xff, 0xd7, 0x6e}, {0xff, 0x9e, 0xe6}, {0x9e, 0xe8, 0xff}, {0xff, 0xff, 0xff}, {0xc8, 0xa8, 0xff}}

function menu.tracker() return {place = 0, previous = {}} end

-- Feeds one frame's key-downs (live presses, or for traces the keys newly held since the previous frame);
-- true when they complete M, F, D.
function menu.observe(tracker, input)
    local presses = input.presses
    if not presses then
        presses = {}
        for code = 0, 255 do
            if input.keys[code] and not tracker.previous[code] then presses[#presses + 1] = code end
        end
        tracker.previous = {}
        for code in pairs(input.keys) do tracker.previous[code] = true end
    end
    local complete = false
    for _, code in ipairs(presses) do
        if code == sequence[tracker.place + 1] then
            tracker.place = tracker.place + 1
            if tracker.place == #sequence then complete, tracker.place = true, 0 end
        else
            tracker.place = code == sequence[1] and 1 or 0
        end
    end
    return complete
end

-- The dust's own generator (Park-Miller), so the window never touches the game's random numbers.
local function random(state)
    state.seed = state.seed * 16807 % 2147483647
    return state.seed / 2147483647
end

local function spawn(state)
    -- Anywhere on a band around the window's border.
    local margin = 14
    local side = random(state)
    local x, y
    if side < 0.3 then
        x, y = panel.x - margin + random(state) * (panel.width + 2 * margin), panel.y - margin + random(state) * margin * 2
    elseif side < 0.6 then
        x, y = panel.x - margin + random(state) * (panel.width + 2 * margin), panel.y + panel.height - margin + random(state) * margin * 2
    elseif side < 0.8 then
        x, y = panel.x - margin + random(state) * margin * 2, panel.y + random(state) * panel.height
    else
        x, y = panel.x + panel.width - margin + random(state) * margin * 2, panel.y + random(state) * panel.height
    end
    local life = 30 + math.floor(random(state) * 40)
    state.dust[#state.dust + 1] = {x = x, y = y, vx = (random(state) - 0.5) * 0.6, vy = -0.2 - random(state) * 0.6,
        age = 0, life = life, color = dust_colors[1 + math.floor(random(state) * #dust_colors)], star = random(state) < 0.35,
        phase = random(state) * 6.28}
end

-- `locked`: the joining peer of a network game, whose menu shows the host's speed and cannot change it.
function menu.create(locked)
    local state = {nav = navigation.create(), dust = {}, seed = 20261024, dragging = false, opened = true,
        pointer_x = 0, pointer_y = 0, locked = locked == true}
    for _ = 1, 90 do spawn(state) end
    for _, mote in ipairs(state.dust) do mote.age = math.floor(random(state) * mote.life) end
    return state
end

local function set_tenths(state, tenths)
    tenths = math.min(math.max(tenths, 0), 10)
    if tenths ~= speed.tenths then
        speed.tenths = tenths
        sounds.direct(state, "pass")
    end
end

local function on_track(x, y)
    return x >= track.x - 10 and x <= track.x + track.width + 10 and y >= track.y - 14 and y <= track.y + 18
end

-- `closing`: M, F, D were typed again. Returns "close" when the window closes.
function menu.update(state, input, context, closing)
    if state.opened then
        sounds.direct(state, "join")
        state.opened = false
    end
    local view = navigation.apply(state.nav, input, {page = "speed", targets = {}})
    state.pointer_x, state.pointer_y = view.pointer_x, view.pointer_y
    local result
    if closing or view.nav.ok or view.nav.cancel then
        result = "close"
        sounds.direct(state, "ok")
    elseif not state.locked then
        if view.nav.l then set_tenths(state, speed.tenths - 1) end
        if view.nav.r then set_tenths(state, speed.tenths + 1) end
        if view.click and on_track(view.pointer_x, view.pointer_y) then state.dragging = true end
        if not view.button then state.dragging = false end
        if state.dragging then
            set_tenths(state, math.floor((view.pointer_x - track.x) / notch_width + 0.5))
        end
    end
    -- The dust: a few new motes each frame, drifting up and fading out.
    for _ = 1, 3 do spawn(state) end
    local kept = {}
    for _, mote in ipairs(state.dust) do
        mote.age = mote.age + 1
        mote.x, mote.y = mote.x + mote.vx, mote.y + mote.vy
        if mote.age < mote.life then kept[#kept + 1] = mote end
    end
    state.dust = kept
    for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
    return result
end

local function bold(context, text, x, y, variant)
    for _, offset in ipairs({{-1, 1}, {-1, 0}, {0, 1}, {0, 0}}) do
        font.draw(context, text, x + offset[1], y + offset[2], variant, nil, "center")
    end
end

local function draw_dust(state, context)
    for _, mote in ipairs(state.dust) do
        -- Fades in and out over its life and twinkles on the way.
        local life = mote.age / mote.life
        local fade = math.min(life * 4, (1 - life) * 3, 1)
        local twinkle = 0.7 + 0.3 * math.sin(mote.phase + mote.age * 0.4)
        local alpha = math.floor(255 * fade * twinkle)
        if alpha > 0 then
            local x, y = math.floor(mote.x), math.floor(mote.y)
            local r, g, b = mote.color[1], mote.color[2], mote.color[3]
            if mote.star then
                -- A four-point sparkle: long faint arms, short bright arms, a white core.
                context.fill(x - 4, y, 9, 1, r, g, b, math.floor(alpha / 3))
                context.fill(x, y - 4, 1, 9, r, g, b, math.floor(alpha / 3))
                context.fill(x - 2, y, 5, 1, r, g, b, alpha)
                context.fill(x, y - 2, 1, 5, r, g, b, alpha)
                context.fill(x, y, 1, 1, 0xff, 0xff, 0xff, alpha)
            else
                context.fill(x - 1, y - 1, 4, 4, r, g, b, math.floor(alpha / 4))
                context.fill(x, y, 2, 2, r, g, b, alpha)
            end
        end
    end
end

function menu.draw(state, context)
    local tenths = state.locked and (speed.network_tenths or 10) or speed.tenths
    -- A soft violet glow, then the window.
    for layer = 3, 1, -1 do
        local grow = layer * 4
        context.fill(panel.x - grow, panel.y - grow, panel.width + grow * 2, panel.height + grow * 2, 0x9a, 0x6e, 0xff, 22)
    end
    context.fill(panel.x, panel.y, panel.width, panel.height, 0xc8, 0xa8, 0xff)
    context.fill(panel.x + 2, panel.y + 2, panel.width - 4, panel.height - 4, 0x1c, 0x10, 0x40, 240)
    bold(context, "Game Speed", panel.x + math.floor(panel.width / 2), panel.y + 14, constants.font_variants.magenta)
    local label = string.format("%.1f", tenths / 10)
    if tenths == 0 then label = label .. "  (stopped)"
    elseif tenths == 10 then label = label .. "  (normal)"
    elseif tenths == sweet_spot then label = label .. "  (sweet spot)" end
    font.gdi(context, label, panel.x + math.floor(panel.width / 2), panel.y + 46, 0xffffff, nil, "center")

    -- The track, lit up to the knob, with a notch every 0.1; the sweet spot's notch is gold and taller.
    local knob_x = track.x + math.floor(tenths * notch_width + 0.5)
    context.fill(track.x, track.y, track.width, 4, 0x4a, 0x3a, 0x7a)
    context.fill(track.x, track.y, knob_x - track.x, 4, 0xff, 0x9e, 0xe6)
    for notch = 0, 10 do
        local x = track.x + math.floor(notch * notch_width + 0.5)
        if notch == sweet_spot then
            context.fill(x - 1, track.y - 9, 3, 22, 0xff, 0xd7, 0x6e)
            context.fill(x - 3, track.y - 13, 7, 1, 0xff, 0xd7, 0x6e)
            context.fill(x, track.y - 16, 1, 7, 0xff, 0xd7, 0x6e)
        else
            context.fill(x, track.y - 5, 1, 14, 0xc8, 0xa8, 0xff)
        end
    end
    font.gdi(context, "0", track.x, track.y + 16, 0xc8a8ff, nil, "center")
    font.gdi(context, "1", track.x + track.width, track.y + 16, 0xc8a8ff, nil, "center")
    font.gdi(context, "sweet spot", track.x + math.floor(sweet_spot * notch_width + 0.5), track.y + 16, 0xffd76e, nil, "center")
    local lit = state.dragging and 0xff or 0xe6
    context.fill(knob_x - 6, track.y - 8, 13, 20, 0xff, 0xff, 0xff)
    context.fill(knob_x - 5, track.y - 7, 11, 18, 0xff, 0x9e, lit)
    font.gdi(context, state.locked and "The host sets the speed    Enter: close" or "Left/Right or mouse: change    Enter: close",
        panel.x + math.floor(panel.width / 2), panel.y + panel.height - 22, 0x8a7ab8, nil, "center")

    draw_dust(state, context)
    if state.nav.mode == "pointer" then
        context.image("pe/lf2_cursor", math.min(state.pointer_x, 0x307), math.min(state.pointer_y + 2, 0x217), true)
    end
end

return menu
