-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The development view of the AI, world layer (OpenLF2 extension, docs/ai-plan.md "Development view"): it draws over
-- the fighters the body boxes (blue) and the hit boxes (red when they hurt, yellow for the others) of every item, the
-- frame class of each fighter with the ticks until it is free, the ticks to the next threat (base/ai/predict) in red,
-- and the next steps of each flying object. It is local to this computer and only reads the fight: the same trace
-- gives the same fight with the view on and off. --ai-view turns it on, F10 turns it on and off.
local constants = require("base/game/constants")
local ai = require("base/game/ai")
local perception = require("base/ai/perception")
local predict = require("base/ai/predict")
local font = require("base/ui/font")
local view = {on = false}
local toggle_key = 0x79 -- F10
local short = {free = "free", moving = "run", attacking = "atk", air = "air", defending = "def", hurt = "hurt",
    falling = "fall", lying = "lie", dizzy = "dizzy", caught = "caught", catching = "catch", frozen = "ice",
    recovering = "rec", busy = "busy"}

function view.configure(options) view.on = options.ai_view == true end

-- F10 turns the view on and off (a fresh press).
function view.toggled(input)
    local down = input.keys[toggle_key] == true
    local fresh = down and not view.held
    view.held = down
    if fresh then view.on = not view.on end
    return fresh
end

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
return view
