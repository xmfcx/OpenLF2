-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The new fight screen's HUD (OpenLF2 extension, docs/fight-screen.md): the layout of the window, a card for each
-- fighter, the boss bars and the stage panel of Stage mode, and the minimap. The cards and the stage panel are menus
-- of Dear ImGui (base/ui/imgui), so their text is sharp at any window size. Everything only reads the fight: every
-- computer runs the same final ticks, so every player sees the same numbers at the same time.
local constants = require("base/game/constants")
local catalog = require("base/game/catalog")
local object_data = require("base/game/object_data")
local stage = require("base/game/stage")
local controls = require("base/ui/controls")
local imgui = require("base/ui/imgui")
local player_colors = require("base/ui/player_colors")
local i18n = require("base/i18n/i18n")
local record_kinds, teams = constants.record_kinds, constants.teams
local hud = {}

local full = constants.points.full
local card_height, card_gap, team_gap, edge = 40, 4, 14, 6
local boss_row = 24
local hp_color, heal_color, dark_color, mp_color, back_color = 0xe02a2a, 0xff9a9a, 0x6a2232, 0x3a64ff, 0x141826

local function resource(path) return path and path:gsub("\\", "/"):lower() end

-- The fighters of the cards: a player's or a computer player's fighter in each slot, in slot order.
local function fighters(current)
    local list = {}
    for slot = 0, 7 do
        local index = current.items[slot] and slot or slot + 10
        local value = current.items[index]
        if value and value.record.kind == record_kinds.character then
            list[#list + 1] = {slot = slot, index = index, value = value}
        end
    end
    return list
end

-- What Stage mode shows (nil in the other modes): the title, the enemies that are left by type (on the field and
-- still to come) and the bosses on the field. stage.phase_entries gives the current phase's entries and counters.
function hud.stage_info(current)
    local run = current.stage_run
    if not run then return nil end
    local info = {enemies = {}, bosses = {}}
    if run.id >= constants.stage_levels.survival_start then
        info.title = i18n.tr("Survival") .. " " .. math.max(run.survival or 0, 0)
    else
        info.title = string.format("%s %d-%d", i18n.tr("Stage"), math.floor(run.id / 10) + 1, run.id % 10 + 1)
    end
    local by_id = {}
    local function add(id, count, boss, data)
        local entry = by_id[id]
        if not entry then
            entry = {id = id, count = 0, boss = false}
            by_id[id] = entry
            info.enemies[#info.enemies + 1] = entry
        end
        entry.count = entry.count + count
        entry.boss = entry.boss or boss
        if data and not entry.data then entry.data = data end
    end
    local entries, runtimes = stage.phase_entries(run)
    local boss_items = {}
    for position, entry in ipairs(entries) do
        local runtime = runtimes[position]
        if runtime and entry.id >= 0 then
            local boss = entry.kind > constants.stage_entry_kinds.soldier
            if boss then
                for slot = 0, (runtime.parallel or 0) - 1 do
                    local id = runtime.ids[slot]
                    if id and id >= 0 then boss_items[id] = true end
                end
            end
            local waiting = (runtime.total or 0) - (runtime.count or 0)
            if waiting > 0 then add(entry.id, waiting, boss) end
        end
    end
    for index = constants.first_spawned_slot, constants.item_slots - 1 do
        local value = current.items[index]
        if value and value.hp > 0 and value.team == teams.enemies and value.record.kind == record_kinds.character then
            add(value.record.id, 1, boss_items[index] == true, value.record.data)
            if boss_items[index] then info.bosses[#info.bosses + 1] = value end
        end
    end
    -- The data of the enemies that are not on the field yet (the random selectors have none).
    for _, entry in ipairs(info.enemies) do
        if not entry.data then
            local known = catalog.objects().by_id[entry.id]
            if known then entry.data = object_data.load(known.path) end
        end
    end
    table.sort(info.enemies, function(a, b)
        if a.boss ~= b.boss then return a.boss end
        return a.id < b.id
    end)
    return info
end

-- The layout of the window (`bounds`, viewport units): left, top, right, bottom, width, height; the cards (each with
-- x, y, width, height) and the bottom of their row (`cards_bottom`), the boss bars, and the rows for the world
-- (`region_top` to `region_bottom`). Only the window's size moves the rows: the card row keeps its height, and the
-- boss bars float over the top of the world's rows, so a boss that comes moves nothing.
function hud.layout(bounds, current, info)
    local layout = {left = bounds.left, top = bounds.top, right = bounds.right, bottom = bounds.bottom}
    layout.width, layout.height = layout.right - layout.left, layout.bottom - layout.top
    local list = fighters(current)
    -- Groups by team: a fighter without a team has a team of its own (its slot + 10).
    local groups, last = 0, nil
    table.sort(list, function(a, b)
        if a.value.team ~= b.value.team then return a.value.team < b.value.team end
        return a.slot < b.slot
    end)
    for _, card in ipairs(list) do
        if card.value.team ~= last then groups = groups + 1 end
        last = card.value.team
    end
    local count = #list
    local spaces = math.max(count - 1, 0) * card_gap + math.max(groups - 1, 0) * (team_gap - card_gap)
    local width = count > 0 and math.floor((layout.width - 2 * edge - spaces) / count) or 0
    width = math.max(70, math.min(210, width))
    local total = count * width + spaces
    local x = layout.left + math.floor((layout.width - total) / 2)
    layout.cards_top = layout.top + 3
    last = nil
    for position, card in ipairs(list) do
        if position > 1 then x = x + (card.value.team ~= last and team_gap or card_gap) end
        card.x, card.y, card.width, card.height = x, layout.cards_top, width, card_height
        x = x + width
        last = card.value.team
    end
    layout.cards = list
    layout.cards_bottom = layout.cards_top + card_height
    layout.region_top = layout.cards_bottom + 3
    layout.region_bottom = layout.bottom - 20
    layout.bosses = info and info.bosses or {}
    layout.boss_top = layout.region_top + 2
    layout.boss_height = #layout.bosses > 0 and 6 + #layout.bosses * boss_row or 0
    return layout
end

-- The classic picture as a layout, for the panels of the classic screen (its status panel is 108 rows high).
function hud.classic_layout()
    local width, height = constants.screen.width, constants.screen.height
    return {left = 0, top = 0, right = width, bottom = height, width = width, height = height, cards_bottom = 108,
        region_top = 108, cards = {}, bosses = {}}
end

local function name_of(card)
    if card.index < 8 then return controls.name(card.index) end
    return "Com"
end

function hud.draw_cards(context, current, layout)
    local flags = imgui.no_title + imgui.glass + imgui.passive + imgui.compact
    for _, card in ipairs(layout.cards) do
        local value, color = card.value, player_colors.of(card.slot)
        imgui.window(context, "card" .. card.slot, "", card.x, card.y, card.width, card.height, flags)
        local small = resource(value.record.data.small)
        if small then
            imgui.image(context, "face" .. card.slot, small, nil, 28, 32, {color}, value.hp <= 0 and imgui.dim or 0)
            imgui.same_line(context)
        end
        imgui.group(context)
        local extra = {}
        if value.ai_control then extra[#extra + 1] = "CPU" end
        if value.lives and value.lives >= 2 then extra[#extra + 1] = "x" .. (value.lives - 1) end
        if (value.kills or 0) > 0 then extra[#extra + 1] = "K" .. value.kills end
        imgui.text(context, name_of(card), color, imgui.small)
        if #extra > 0 then
            imgui.same_line(context)
            imgui.text(context, table.concat(extra, " "), 0x9aa4c8, imgui.small)
        end
        local hp = math.max(value.hp, 0)
        -- Healing (milk, regeneration): the bar flashes every other tick of the 12-tick counter, as the original's.
        local healing = (math.floor(value.regen_timer / constants.healing.timer_base) == 1 or value.heal_timer > 0)
            and current.counter_12 % 2 == 0
        imgui.bar(context, hp / full, healing and heal_color or hp_color, math.max(value.dark_hp, 0) / full, dark_color,
            back_color, tostring(hp), 0, 9)
        imgui.bar(context, math.max(value.mp, 0) / full, mp_color, 0, 0, back_color, tostring(math.max(value.mp, 0)), 0, 7)
        imgui.end_group(context)
        imgui.end_window(context)
    end
end

-- The bosses of Stage mode: a large bar each, over the top of the world under the cards (between the panels of the
-- corners).
function hud.draw_bosses(context, layout)
    if #layout.bosses == 0 then return end
    local width = math.min(420, math.floor(layout.width * 0.4))
    local x = layout.left + math.floor((layout.width - width) / 2)
    imgui.window(context, "bosses", "", x, layout.boss_top, width, layout.boss_height,
        imgui.no_title + imgui.glass + imgui.passive + imgui.compact)
    for position, value in ipairs(layout.bosses) do
        local small = resource(value.record.data.small)
        if small then
            imgui.image(context, "boss" .. position, small, nil, 18, 20, {0xff4040})
            imgui.same_line(context)
        end
        imgui.group(context)
        imgui.text(context, i18n.tr("BOSS") .. "  " .. (value.record.data.name or "?"), 0xff7070, imgui.small)
        local most = math.max(value.max_hp or full, 1)
        imgui.bar(context, math.max(value.hp, 0) / most, 0xd81e1e, math.max(value.dark_hp, 0) / most, dark_color,
            back_color, string.format("%d / %d", math.max(value.hp, 0), most), 0, 7)
        imgui.end_group(context)
    end
    imgui.end_window(context)
end

-- The stage panel at (x, y, width, height): the stage, and the enemies that are left by type (a boss has a red
-- frame).
function hud.draw_stage_panel(context, info, x, y, width, height)
    imgui.window(context, "stage_panel", "", x, y, width, height, imgui.no_title + imgui.glass + imgui.passive + imgui.compact)
    local left = 0
    for _, entry in ipairs(info.enemies) do left = left + entry.count end
    imgui.text(context, string.format("%s   %s %d", info.title, i18n.tr("enemies left:"), left), 0xffd24a, imgui.small)
    local item_width = 50
    local per_row = math.max(1, math.floor((width - 8) / item_width))
    for position, entry in ipairs(info.enemies) do
        if (position - 1) % per_row ~= 0 then imgui.same_line(context, 4 + ((position - 1) % per_row) * item_width) end
        local small = entry.data and resource(entry.data.small)
        imgui.image(context, "enemy" .. position, small or "pe/rface", nil, 20, 22, {entry.boss and 0xff4040 or 0x606880})
        imgui.same_line(context)
        imgui.text(context, "x" .. entry.count, entry.boss and 0xff8080 or 0xe0e4f0, imgui.small)
    end
    imgui.end_window(context)
end

-- The minimap at (x, y, width, height): the whole stage from above, the open part, the view of this computer's
-- camera (`view_left`, `view_width`, or nil), a dot in the player color for each fighter, small marks for the
-- enemies and a large one for a boss.
function hud.draw_minimap(context, current, info, x, y, width, height, view_left, view_width)
    local stage_width = current.stage.width or constants.screen.width
    local near, far = current.stage.zboundary[1] or 0, current.stage.zboundary[2] or 1
    context.fill(x, y, width, height, 0x0a, 0x0e, 0x1e, 185)
    local function map_x(world) return x + math.floor(math.max(0, math.min(stage_width, world)) * width / stage_width) end
    local function map_y(z) return y + 2 + math.floor((math.max(near, math.min(far, z)) - near) * (height - 4) / math.max(far - near, 1)) end
    if current.stage_bound and current.stage_bound > 0 and current.stage_bound < stage_width then
        local closed = map_x(current.stage_bound)
        context.fill(closed, y, x + width - closed, height, 0, 0, 0, 150)
    end
    if view_left then
        local left, right = map_x(view_left), map_x(view_left + view_width)
        context.fill(left, y, right - left, 1, 0xd0, 0xd8, 0xf0)
        context.fill(left, y + height - 1, right - left, 1, 0xd0, 0xd8, 0xf0)
        context.fill(left, y, 1, height, 0xd0, 0xd8, 0xf0)
        context.fill(right - 1, y, 1, height, 0xd0, 0xd8, 0xf0)
    end
    local bosses = {}
    for _, value in ipairs(info and info.bosses or {}) do bosses[value] = true end
    for index = 0, constants.item_slots - 1 do
        local value = current.items[index]
        if value and value.hp > 0 and value.record.kind == record_kinds.character then
            local px, py = map_x(value.x_int), map_y(value.z_int)
            local slot = player_colors.slot(index)
            if bosses[value] then
                context.fill(px - 3, py - 3, 7, 7, 0x20, 0, 0)
                context.fill(px - 2, py - 2, 5, 5, 0xff, 0x30, 0x30)
            elseif slot and value.team ~= teams.enemies then
                local r, g, b = player_colors.rgb(player_colors.of(slot))
                context.fill(px - 2, py - 2, 5, 5, 0, 0, 0)
                context.fill(px - 1, py - 1, 3, 3, r, g, b)
            elseif value.team == teams.enemies then
                context.fill(px - 1, py - 1, 2, 2, 0xc0, 0x60, 0x60)
            else
                context.fill(px - 1, py - 1, 3, 3, 0xc0, 0xc0, 0xc8)
            end
        end
    end
end

return hud
