-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Fight effects (OpenLF2 extension), drawn over the fighters; they only read the fight, so they never change a
-- network game or a recording, and they run on fight frames, so the game speed menu slows them too.
-- * A ghost: when a character's HP reaches 0, a small skull pops up above its head, sways up and fades away.
-- * A combo counter: damage that a character deals within 30 frames of its previous damage adds to its combo, and
--   from the second hit the combo's damage shows above it. The number grows flashier along the milestones 200, 500,
--   1000 and 2500 damage (intensity 0 to 4, linear between them): bigger, warmer colors, a glow, shaking, sparks,
--   flames and at last a rainbow; crossing a milestone sets off a burst. 30 frames without damage end the combo,
--   and the number fades out. While its character is hidden (Rudolf's invisibility: blink -25 or less, the rule of
--   its name label), the combo and its sparks are hidden too.
local constants = require("base/game/constants")
local font = require("base/ui/font")

local effects = {}

local record_kinds = constants.record_kinds
local combo_window = 30
local combo_fade = 24
local ghost_frames = 48
local milestones = {0, 200, 500, 1000, 2500}
-- The number's color at intensity 0, 1, 2, 3 and 4.
local level_colors = {{0xff, 0xff, 0xff}, {0xff, 0xe6, 0x5a}, {0xff, 0x96, 0x28}, {0xff, 0x3c, 0x28}, {0xdc, 0x50, 0xff}}
-- 3x5 digits, one string of rows per digit.
local digits = {
    ["0"] = {"111", "101", "101", "101", "111"}, ["1"] = {"010", "110", "010", "010", "111"},
    ["2"] = {"111", "001", "111", "100", "111"}, ["3"] = {"111", "001", "111", "001", "111"},
    ["4"] = {"101", "101", "111", "001", "001"}, ["5"] = {"111", "100", "111", "001", "111"},
    ["6"] = {"111", "100", "111", "101", "111"}, ["7"] = {"111", "001", "010", "010", "010"},
    ["8"] = {"111", "101", "111", "101", "111"}, ["9"] = {"111", "101", "111", "001", "111"},
}
local skull = {".XXXXX.", "XXXXXXX", "X..X..X", "X..X..X", "XXX.XXX", ".XXXXX.", ".X.X.X."}

-- The effects' own generator (Park-Miller), so they never touch the game's random numbers.
local function random(state)
    state.seed = state.seed * 16807 % 2147483647
    return state.seed / 2147483647
end

function effects.create()
    return {seed = 4242, match = nil, last_frame = nil, hp = {}, dealt = {}, combos = {}, ghosts = {}, particles = {}}
end

local function intensity(total)
    for index = 1, #milestones - 1 do
        if total < milestones[index + 1] then
            return index - 1 + (total - milestones[index]) / (milestones[index + 1] - milestones[index])
        end
    end
    return #milestones - 1
end

local function level_color(level, frame)
    if level >= 4 then
        -- A rainbow pulse at the top.
        local phase = frame * 0.35
        return math.floor(160 + 95 * math.sin(phase)), math.floor(160 + 95 * math.sin(phase + 2.1)),
            math.floor(160 + 95 * math.sin(phase + 4.2))
    end
    local low = math.floor(level)
    local blend = level - low
    local from, to = level_colors[low + 1], level_colors[low + 2]
    return math.floor(from[1] + (to[1] - from[1]) * blend), math.floor(from[2] + (to[2] - from[2]) * blend),
        math.floor(from[3] + (to[3] - from[3]) * blend)
end

-- The top of a character's picture in screen-space y (before the camera), as base/ui/match_screen draws it.
local function head_y(value)
    local frame = value.record.frame(value.frame)
    return value.z - (frame.center_y or 0) + value.y
end

local function burst(state, x, y, count, color, speed)
    for _ = 1, count do
        local angle = random(state) * 6.283
        local velocity = speed * (0.4 + random(state) * 0.8)
        state.particles[#state.particles + 1] = {x = x, y = y, vx = math.cos(angle) * velocity,
            vy = math.sin(angle) * velocity - 0.5, life = 14 + math.floor(random(state) * 14), age = 0,
            color = color, gravity = 0.12}
    end
end

-- Called after each fight frame.
function effects.observe(state, match)
    if state.match ~= match then
        state.match, state.last_frame = match, nil
        state.hp, state.dealt, state.combos, state.ghosts, state.particles = {}, {}, {}, {}, {}
    end
    local frame = match.frame_number
    if frame == state.last_frame then return end
    state.last_frame = frame
    for index = 0, constants.item_slots - 1 do
        local value = match.items[index]
        if value and value.record.kind == record_kinds.character then
            local before_hp = state.hp[index]
            if before_hp and before_hp > 0 and value.hp <= 0 then
                state.ghosts[#state.ghosts + 1] = {x = value.x + (value.draw_offset or 0), y = head_y(value) - 4,
                    born = frame, sway = random(state) * 6.283}
            end
            state.hp[index] = value.hp
            local dealt = value.damage_dealt or 0
            local before = state.dealt[index]
            if before and dealt > before then
                local combo = state.combos[index]
                if not combo or combo.ended or frame - combo.last > combo_window then
                    combo = {total = 0, hits = 0, start = frame}
                    state.combos[index] = combo
                end
                local previous_level = intensity(combo.total)
                combo.total, combo.hits, combo.last, combo.pop = combo.total + dealt - before, combo.hits + 1, frame, frame
                combo.x, combo.y = value.x + (value.draw_offset or 0), head_y(value)
                local level = intensity(combo.total)
                if combo.hits >= 2 and math.floor(level) > math.floor(previous_level) and value.blink > -25 then
                    -- A milestone: a burst of particles and a flash ring.
                    local r, g, b = level_color(level, frame)
                    burst(state, combo.x, combo.y - 26, 12 + 12 * math.floor(level), {r, g, b}, 2 + level)
                    combo.flash = frame
                end
            end
            state.dealt[index] = dealt
        elseif state.hp[index] then
            state.hp[index], state.dealt[index] = nil, nil
        end
    end
    -- Combos: they follow their character, end after the window, and are dropped after the fade.
    for index, combo in pairs(state.combos) do
        local value = match.items[index]
        if value and value.record.kind == record_kinds.character then
            combo.x, combo.y = value.x + (value.draw_offset or 0), head_y(value)
            combo.hidden = value.blink <= -25
        end
        if not combo.ended and frame - combo.last > combo_window then combo.ended = frame end
        if combo.ended and frame - combo.ended > combo_fade then state.combos[index] = nil end
        if combo.hits >= 2 and not combo.ended and not combo.hidden then
            local level = intensity(combo.total)
            local r, g, b = level_color(level, frame)
            -- Sparks from intensity 2, flames from intensity 3, more as it grows.
            if level >= 2 and random(state) < (level - 1.5) * 0.5 then
                burst(state, combo.x + (random(state) - 0.5) * 30, combo.y - 26, 1, {r, g, b}, 1.5 + level * 0.5)
            end
            if level >= 3 then
                for _ = 1, math.floor((level - 2) * 2) do
                    state.particles[#state.particles + 1] = {x = combo.x + (random(state) - 0.5) * 36,
                        y = combo.y - 18, vx = (random(state) - 0.5) * 0.6, vy = -1 - random(state) * 1.5,
                        life = 10 + math.floor(random(state) * 10), age = 0, gravity = -0.03,
                        color = random(state) < 0.5 and {0xff, 0x7a, 0x1e} or {0xff, 0xd2, 0x3c}}
                end
            end
        end
    end
    local kept = {}
    for _, particle in ipairs(state.particles) do
        particle.age = particle.age + 1
        particle.x, particle.y = particle.x + particle.vx, particle.y + particle.vy
        particle.vy = particle.vy + particle.gravity
        if particle.age < particle.life and #kept < 150 then kept[#kept + 1] = particle end
    end
    state.particles = kept
    local ghosts = {}
    for _, ghost in ipairs(state.ghosts) do
        if frame - ghost.born < ghost_frames then ghosts[#ghosts + 1] = ghost end
    end
    state.ghosts = ghosts
end

local function draw_ghost(context, ghost, frame, at)
    local age = frame - ghost.born
    local scale = age < 4 and 1 or 2
    local alpha = age < 24 and 230 or math.floor(230 * (ghost_frames - age) / (ghost_frames - 24))
    if alpha <= 0 then return end
    local ghost_x, ghost_y = at(ghost.x, ghost.y)
    local x = math.floor(ghost_x + math.sin(ghost.sway + age * 0.25) * 3) - 7
    local y = math.floor(ghost_y - age * 1.1) - 16
    -- The wispy tail under the skull.
    for wisp = 0, 2 do
        local wobble = math.floor(math.sin(ghost.sway + age * 0.4 + wisp) * 2)
        context.fill(x + 3 + wisp * 3 + wobble, y + 14, 2, 3 + wisp % 2 * 2, 0xdc, 0xe6, 0xff, math.floor(alpha / 3))
    end
    -- Each row of the skull as strips of its filled cells.
    for row, line in ipairs(skull) do
        for first, last in line:gmatch("()X+()") do
            context.fill(x + (first - 1) * scale, y + (row - 1) * scale, (last - first) * scale, scale, 0xeb, 0xf0, 0xff,
                alpha)
        end
    end
end

local function draw_number(context, text, x, y, size, r, g, b, alpha)
    local width = #text * 4 * size - size
    local left = x - math.floor(width / 2)
    -- A dark rim first, then the digits.
    for pass = 1, 2 do
        for position = 1, #text do
            local glyph = digits[text:sub(position, position)]
            local origin = left + (position - 1) * 4 * size
            -- Each row of the digit as strips of its lit cells.
            for row = 1, 5 do
                for first, last in glyph[row]:gmatch("()1+()") do
                    local px, py, strip = origin + (first - 1) * size, y + (row - 1) * size, (last - first) * size
                    if pass == 1 then
                        context.fill(px - 1, py - 1, strip + 2, size + 2, 0x18, 0x08, 0x10, alpha)
                    else
                        -- The top rows are lighter, for a bit of shine.
                        local light = row == 1 and 50 or 0
                        context.fill(px, py, strip, size, math.min(255, r + light), math.min(255, g + light),
                            math.min(255, b + light), alpha)
                    end
                end
            end
        end
    end
    return width
end

local function draw_combo(state, context, combo, frame, at)
    if combo.hits < 2 or combo.hidden then return end
    local level = intensity(combo.total)
    local alpha = 255
    if combo.ended then alpha = math.floor(255 * math.max(0, combo_fade - (frame - combo.ended)) / combo_fade) end
    if alpha <= 0 then return end
    local r, g, b = level_color(level, frame)
    -- Bigger with intensity, and a pop for a few frames after each hit.
    local size = 2 + math.floor(level + 0.5)
    if not combo.ended and frame - combo.pop < 3 then size = size + 1 end
    local shake = level >= 2 and (level - 1) * 1.5 or 0
    local combo_x, combo_y = at(combo.x, combo.y)
    local x = math.floor(combo_x + (random(state) - 0.5) * 2 * shake)
    local y = math.floor(combo_y - 14 - 5 * size + (random(state) - 0.5) * 2 * shake)
    if combo.ended then y = y - math.floor((frame - combo.ended) * 0.8) end
    local text = tostring(math.floor(combo.total))
    local width = #text * 4 * size
    -- The glow behind the number, from intensity 1.
    if level >= 1 then
        local glow = math.floor(math.min(level, 4) * 3)
        local glow_alpha = math.floor(math.min(90, 25 * level) * alpha / 255)
        context.fill(x - math.floor(width / 2) - glow, y - glow, width + glow * 2, 5 * size + glow * 2, r, g, b,
            math.floor(glow_alpha / 2))
        context.fill(x - math.floor(width / 2) - math.floor(glow / 2), y - math.floor(glow / 2), width + glow,
            5 * size + glow, r, g, b, glow_alpha)
    end
    -- The flash ring of a milestone.
    if combo.flash and frame - combo.flash < 10 then
        local radius = 8 + (frame - combo.flash) * 5
        local ring_alpha = math.floor(200 * (10 - (frame - combo.flash)) / 10)
        for step = 0, 23 do
            local angle = step * 6.283 / 24
            context.fill(x + math.floor(math.cos(angle) * radius) - 1, y + 2 * size + math.floor(math.sin(angle) * radius) - 1,
                3, 3, 0xff, 0xff, 0xff, ring_alpha)
        end
    end
    draw_number(context, text, x, y, size, r, g, b, alpha)
    font.gdi(context, "COMBO", x, y - 15, (r * 65536 + g * 256 + b), nil, "center")
end

-- `view`: the match screen's view (its camera includes the wide layout's shift). `at`: a function from a world place
-- to the screen, for the new fight screen, which draws the effects over the whole window so that a combo above a
-- jumping fighter or a rising ghost is not cut at the top of the world's picture; nil draws them in the world.
function effects.draw(state, context, view, at)
    local frame = state.last_frame
    if not frame then return end
    local camera = view.camera
    at = at or function(x, y) return x - camera, y end
    for _, particle in ipairs(state.particles) do
        local alpha = math.floor(255 * (1 - particle.age / particle.life))
        local color = particle.color
        local x, y = at(particle.x, particle.y)
        context.fill(math.floor(x), math.floor(y), 2, 2, color[1], color[2], color[3], alpha)
    end
    -- The newest ghosts only, so that a battle with many soldiers stays light.
    for index = math.max(1, #state.ghosts - 5), #state.ghosts do draw_ghost(context, state.ghosts[index], frame, at) end
    for _, combo in pairs(state.combos) do draw_combo(state, context, combo, frame, at) end
end

return effects
