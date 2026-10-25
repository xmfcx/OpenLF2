-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The development view of the AI, world layer (OpenLF2 extension, docs/ai-plan.md "Development view"): it draws over
-- the fighters the body boxes (blue) and the hit boxes (red when they hurt, yellow for the others) of every item, the
-- frame class of each fighter with the ticks until it is free, the ticks to the next threat (base/ai/predict) in red,
-- and the next steps of each flying object. It is local to this computer and only reads the fight: the same trace
-- gives the same fight with the view on and off. --ai-view turns it on, F10 turns it on and off.
--
-- With the view on, the brains write their frames to the trace (base/ai/trace capture), and the view adds:
--   the decision timeline: a row for each AI fighter at the top of the picture, its intent on each of the last 300
--   ticks in a color;
--   the inspector (Dear ImGui, view.draw_ui): the AI fighters to choose from, and for the chosen one its brain, level,
--   intent, target, behavior tree with the active path, candidate moves with their values, key program, persona
--   numbers (sliders that change the match's copy, in local fights only) and last events;
--   F8 moves a paused local fight one tick forward (base/ui/match_screen).
local constants = require("base/game/constants")
local ai = require("base/game/ai")
local perception = require("base/ai/perception")
local predict = require("base/ai/predict")
local font = require("base/ui/font")
local imgui = require("base/ui/imgui")
local trace = require("base/ai/trace")
local view = {on = false, selected = nil}
local toggle_key = 0x79 -- F10
local short = {free = "free", moving = "run", attacking = "atk", air = "air", defending = "def", hurt = "hurt",
    falling = "fall", lying = "lie", dizzy = "dizzy", caught = "caught", catching = "catch", frozen = "ice",
    recovering = "rec", busy = "busy"}

function view.configure(options)
    view.on = options.ai_view == true
    trace.capture = view.on
end

-- F10 turns the view on and off (a fresh press).
function view.toggled(input)
    local down = input.keys[toggle_key] == true
    local fresh = down and not view.held
    view.held = down
    if fresh then view.on = not view.on end
    trace.capture = view.on
    return fresh
end

-- The colors of the intents (node ids of a brain's tree) on the timeline.
local palette = {0x808080, 0xe04040, 0xffffff, 0x40c0ff, 0x60ff60, 0xffc040, 0xff60ff, 0xc0c0ff, 0x40ffc0, 0xffff60,
    0xa06030, 0x6060ff, 0xff9090, 0x90ff90, 0x9090ff, 0xc0a060}
local function color_of(id)
    local value = palette[(id % #palette) + 1]
    return math.floor(value / 65536), math.floor(value / 256) % 256, value % 256
end

-- The decision timeline: a row of 300 ticks for each fighter with a timeline, oldest at the left.
local function draw_timeline(context, current)
    local row = 0
    local indices = {}
    for index in pairs(trace.timeline) do indices[#indices + 1] = index end
    table.sort(indices)
    local ticks = trace.timeline_ticks
    for _, index in ipairs(indices) do
        local line = trace.timeline[index]
        local y = 134 + row * 7
        context.fill(38, y - 1, ticks + 2, 7, 0, 0, 0, 120)
        font.gdi(context, tostring(index), 8, y - 4, 0xffffff)
        for age = 0, ticks - 1 do
            local tick = (line.last or 0) - age
            local id = tick >= 0 and line[tick % ticks + 1]
            if id and id > 0 then
                local r, g, b = color_of(id)
                context.fill(39 + ticks - 1 - age, y, 1, 5, r, g, b, 230)
            end
        end
        row = row + 1
    end
end
view.color_of = color_of

local function outline(context, x0, y0, x1, y1, r, g, b, alpha)
    local width, height = math.max(x1 - x0, 1), math.max(y1 - y0, 1)
    context.fill(x0, y0, width, 1, r, g, b, alpha)
    context.fill(x0, y1 - 1, width, 1, r, g, b, alpha)
    context.fill(x0, y0, 1, height, r, g, b, alpha)
    context.fill(x1 - 1, y0, 1, height, r, g, b, alpha)
end

-- Draws the world layer of `current` (the match table) for the camera position `camera`, in the coordinates of the
-- fight picture (x - camera, z + y), after the fighters and before the HUD.
function view.draw_world(context, current, camera)
    if not view.on then return end
    draw_timeline(context, current)
    local scan = ai.prepare(current)
    local world = perception.world(current, scan)
    for _, entry in ipairs(world.list) do
        local screen_x, screen_z = -camera, entry.z
        for _, body in ipairs(entry.bodies) do
            outline(context, body.x0 + screen_x, body.y0 + screen_z, body.x1 + screen_x, body.y1 + screen_z, 80, 160, 255, 200)
        end
        for _, hit in ipairs(entry.hits) do
            if hit.damaging then
                outline(context, hit.x0 + screen_x, hit.y0 + screen_z, hit.x1 + screen_x, hit.y1 + screen_z, 255, 60, 60, 230)
            else
                outline(context, hit.x0 + screen_x, hit.y0 + screen_z, hit.x1 + screen_x, hit.y1 + screen_z, 255, 220, 60, 160)
            end
        end
        if entry.ball then
            for step = 1, 10 do
                context.fill(math.floor(entry.x + entry.vx * step) - camera, math.floor(entry.z + entry.y + entry.vy * step), 2, 2,
                    255, 140, 60, 200)
            end
        end
        if entry.character and entry.hp > 0 then
            local top = entry.z + entry.y - 100
            local label = short[entry.class] or entry.class
            if entry.free_in > 0 then label = label .. " " .. entry.free_in end
            font.gdi(context, label, entry.x - camera, top, 0xffffff, nil, "center")
            local threats = predict.threats(current, world, entry, predict.horizon)
            if threats[1] then
                font.gdi(context, "!" .. threats[1].ticks, entry.x - camera, top - 14, 0xff5050, nil, "center")
            end
        end
    end
end
local key_names = {{1, "u"}, {2, "d"}, {4, "l"}, {8, "r"}, {16, "A"}, {32, "J"}, {64, "D"}}
local function mask_text(mask)
    local text = ""
    for _, pair in ipairs(key_names) do
        if math.floor(mask / pair[1]) % 2 == 1 then text = text .. pair[2] end
    end
    return text == "" and "-" or text
end

-- The tree as lines: the root's branches, and the children of the active branch only.
local function tree_lines(node, active, depth, lines)
    local on = active[node.id] == true
    lines[#lines + 1] = {text = string.rep("  ", depth) .. (on and "> " or "  ") .. node.name, on = on}
    if depth == 0 or on then
        for _, child in ipairs(node.children or {}) do tree_lines(child, active, depth + 1, lines) end
    end
    return lines
end

-- The persona sliders: the name, the lowest and the highest value.
local persona_limits = {aggression = {0, 100}, risk = {0, 100}, mp_thrift = {0, 100}, combo_greed = {0, 100},
    defense = {0, 100}, mobility = {0, 100}, range = {0, 400}, depth_offset = {0, 20}, spacing = {20, 200}}

-- The inspector. `editable` is false in a network game: the persona numbers only show there.
function view.draw_ui(context, current, editable)
    if not view.on or not imgui.available(context) then return end
    local brains = require("base/ai/brains")
    imgui.window(context, "ai_inspector", "AI inspector (F10)", 524, 30, 262, 480, imgui.glass + imgui.compact)
    local indices = {}
    for index = 0, constants.item_slots - 1 do
        local value = current.items[index]
        if value and value.ai and value.ai.brain then indices[#indices + 1] = index end
    end
    if #indices == 0 then imgui.text(context, "No fighter has a brain other than classic (--ai-brain).", 0xc0c0c0, imgui.wrap) end
    if not view.selected or not current.items[view.selected] then view.selected = indices[1] end
    for _, index in ipairs(indices) do
        local value = current.items[index]
        imgui.selectable(context, "ai_pick_" .. index, string.format("%d  %s  %s", index, value.record.data.name or "?",
            value.ai.brain), view.selected == index)
    end
    local index = view.selected
    local value = index and current.items[index]
    local frame = index and trace.frames[index]
    if value then
        imgui.separator(context)
        local row = require("base/ai/difficulty").of(current)
        imgui.text(context, string.format("brain %s, level %s, hp %d, mp %d", value.ai.brain, row.name, value.hp, value.mp), nil, imgui.small)
        if frame then
            imgui.text(context, string.format("intent %s, target %d, dx %d, dz %d, view %d ticks old", frame.intent_name,
                frame.target or -1, frame.dx or 0, frame.dz or 0, frame.delay or 0), 0xffe080, imgui.small + imgui.wrap)
            local brain = brains.get(value.ai.brain)
            if brain and brain.tree then
                local active = {}
                for _, id in ipairs(frame.path or {}) do active[id] = true end
                imgui.child(context, "ai_tree", 0, 150, true)
                for _, line in ipairs(tree_lines(brain.tree, active, 0, {})) do
                    imgui.text(context, line.text, line.on and 0x60ff60 or 0x909090, imgui.small)
                end
                imgui.end_child(context)
            end
            imgui.text(context, "candidates (value, hit tick):", nil, imgui.small)
            for position = 1, math.min(5, #(frame.scores or {})) do
                local score = frame.scores[position]
                imgui.text(context, string.format("  %s/%d  %d  %s%s", score.name, score.start, score.value, tostring(score.ticks),
                    score.sure and "  sure" or ""), nil, imgui.small)
            end
            local keys = {}
            for _, mask in ipairs(frame.program or {}) do keys[#keys + 1] = mask_text(mask) end
            imgui.text(context, "keys: " .. (#keys > 0 and table.concat(keys, " ") or "-"), nil, imgui.small)
            if frame.persona then
                local names = {}
                for name in pairs(persona_limits) do if frame.persona[name] then names[#names + 1] = name end end
                table.sort(names)
                for _, name in ipairs(names) do
                    local limits = persona_limits[name]
                    imgui.slider(context, "ai_p_" .. name, name .. " %d", frame.persona[name], limits[1], limits[2], 200, not editable)
                end
            end
        end
        imgui.child(context, "ai_events", 0, 0, true, true)
        for _, line in ipairs(trace.recent[index] or {}) do
            imgui.text(context, (line:gsub("^ai ", "")), 0xc0c0c0, imgui.small)
        end
        imgui.end_child(context)
    end
    imgui.end_window(context)
end

-- The clicks and slider moves of the inspector (from the frame's input). A persona change writes a copy of the persona
-- into the match (`ai_persona_values`), in local fights only.
function view.update(events, current, editable)
    if not view.on then return end
    for id in pairs(events.clicked) do
        local index = id:match("^ai_pick_(%d+)$")
        if index then view.selected = tonumber(index) end
    end
    local index = view.selected
    local frame = index and trace.frames[index]
    if not (editable and frame and frame.persona) then return end
    for name, limits in pairs(persona_limits) do
        local changed = frame.persona[name] and imgui.slider_value(events, "ai_p_" .. name, frame.persona[name], limits[1], limits[2])
        if changed and changed ~= frame.persona[name] then
            current.ai_persona_values = current.ai_persona_values or {}
            local copy = current.ai_persona_values[index]
            if not copy then
                copy = {}
                for key, number in pairs(frame.persona) do copy[key] = number end
                current.ai_persona_values[index] = copy
            end
            copy[name] = changed
        end
    end
end
return view
