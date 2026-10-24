-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- Game versions (OpenLF2 extension), opened from the build label on the launch screen: the versions installed in the
-- configuration directory, the program the player starts, and the published versions of the version index, newest
-- first, with each one's changes. Play starts a version (the game restarts in it and starts it from then on),
-- Install downloads one, Delete (pressed twice) removes one. Keys: up/down choose, Enter plays or installs, Delete
-- deletes, Escape goes back. The engine does the work (engine.versions, ports/versions.hpp).
local navigation = require("base/ui/navigation")
local font = require("base/ui/font")
local i18n = require("base/i18n/i18n")
local sounds = require("base/game/sounds")
local constants = require("base/game/constants")
local virtual_keys = constants.virtual_keys

local screen = {}

local list = {x = 30, y = 70, width = 360, row = 22, rows = 17}
local details = {x = 410, y = 70, width = 354, height = 374}
local buttons = {
    {name = "primary", x = 410, y = 460, width = 110, height = 26},
    {name = "delete", x = 530, y = 460, width = 110, height = 26},
    {name = "back", x = 650, y = 460, width = 110, height = 26},
}
local delete_key = 0x2e

local function inside(x, y, area)
    return x >= area.x and x <= area.x + area.width and y >= area.y and y <= area.y + area.height
end

-- Newest first: "2026.10.25-10" after "2026.10.25-9".
local function version_key(id)
    local year, month, day, count = (id or ""):match("^(%d+)%.(%d+)%.(%d+)%-(%d+)")
    if not year then return {0, 0, 0, 0, id or ""} end
    return {tonumber(year), tonumber(month), tonumber(day), tonumber(count), id}
end
local function newer(a, b)
    local first, second = version_key(a.id), version_key(b.id)
    for index = 1, 4 do
        if first[index] ~= second[index] then return first[index] > second[index] end
    end
    return first[5] > second[5]
end

-- The versions to show: installed ones, the base program and the index's, merged by id.
local function rebuild(state)
    local entries, by_id = {}, {}
    local function entry(id)
        if not by_id[id] then
            by_id[id] = {id = id, changes = {}}
            entries[#entries + 1] = by_id[id]
        end
        return by_id[id]
    end
    local function take(target, source)
        target.date = target.date or source.date
        target.commit = target.commit or source.commit
        if type(source.changes) == "table" and #target.changes == 0 then target.changes = source.changes end
    end
    local info = state.info or {}
    for _, version in ipairs(info.installed or {}) do
        local item = entry(version.id)
        item.installed = true
        take(item, version)
    end
    if info.base_id and info.base_id ~= "" then entry(info.base_id).base = true end
    if info.current and info.current ~= "" then
        local item = entry(info.current)
        item.current = true
        item.commit = item.commit or info.commit
    end
    local index = state.index and state.index.versions
    if type(index) == "table" then
        for _, version in ipairs(index) do
            if type(version) == "table" and type(version.id) == "string" then
                local item = entry(version.id)
                item.available = type(version.files) == "table" and version.files[info.platform] ~= nil
                take(item, version)
            end
        end
    end
    table.sort(entries, newer)
    local selected = state.entries and state.entries[state.selected] and state.entries[state.selected].id
    state.entries, state.selected = entries, 1
    for position, item in ipairs(entries) do
        if item.id == (selected or info.current) then state.selected = position end
    end
end

local function refresh(state)
    if not engine.versions then return end
    state.info = engine.versions("describe")
    rebuild(state)
end

function screen.create(options)
    local state = {nav = navigation.create(), background = (options and options.menu_seed or 0) % 13 + 1,
        pointer_x = 0, pointer_y = 0, selected = 1, entries = {}, top = 1, previous_keys = {}}
    if not engine.versions then
        state.message = "This build has no game versions."
        return state
    end
    refresh(state)
    local started, problem = engine.versions("index")
    state.message = started and "Reading the version list..." or problem
    state.waiting_index = started and true or false
    return state
end

local function status(item, info)
    if item.current then return "running", 0x6ee07a end
    if info.active == item.id or (item.base and (info.active or "") == "") then return "chosen", 0xffd24a end
    if item.installed or item.base then return "installed", 0xc8c8e0 end
    if item.available then return "available", 0x6ed7ff end
    return "", 0x808090
end

-- What the main button does for an entry: "play", "install" or nothing.
local function primary_action(item)
    if not item or item.current then return nil end
    if item.installed or item.base then return "play" end
    if item.available then return "install" end
    return nil
end

local function run_action(state, action, item, context)
    if action == "play" then
        local started, problem = engine.versions("launch", item.id)
        state.message = started and ("Starting " .. item.id .. "...") or problem
        sounds.direct(state, started and "ok" or "cancel")
    elseif action == "install" then
        local started, problem = engine.versions("install", item.id)
        state.message = started and ("Installing " .. item.id .. "...") or problem
        sounds.direct(state, started and "ok" or "cancel")
    elseif action == "delete" then
        if not item.installed or item.current then
            state.message = item.current and "The running version cannot be deleted." or "Only installed versions can be deleted."
        elseif state.confirm_delete ~= item.id then
            state.confirm_delete = item.id
            state.message = "Delete " .. item.id .. "? Press Delete again to confirm."
        else
            local deleted, problem = engine.versions("delete", item.id)
            state.confirm_delete = nil
            state.message = deleted and ("Deleted " .. item.id .. ".") or problem
            refresh(state)
        end
    elseif action == "back" then
        sounds.direct(state, "cancel")
        context.action("launch")
    end
end

function screen.update(state, flow_input, context)
    local input = navigation.apply(state.nav, flow_input, {page = "versions", targets = {}})
    state.pointer_x, state.pointer_y = input.pointer_x, input.pointer_y
    if engine.versions then
        local job = engine.versions("poll")
        if job and job.state == "running" then
            state.progress = job.progress
        elseif job and state.progress then
            state.progress = nil
            if job.state == "done" then
                if job.task == "index" then
                    state.index = job.index
                    state.message = nil
                else
                    state.message = job.task == "install" and "Installed. Choose Play to start it." or nil
                end
            elseif job.state == "failed" then
                state.message = job.message
            end
            refresh(state)
        elseif job and state.waiting_index and job.state ~= "running" then
            -- The index came back before the first poll.
            if job.state == "done" and job.index then state.index, state.message = job.index, nil
            elseif job.state == "failed" then state.message = job.message end
            refresh(state)
        end
        if job and job.state ~= "running" then state.waiting_index = false end
    end
    local count = #state.entries
    if input.nav.u and state.selected > 1 then state.selected, state.confirm_delete = state.selected - 1, nil end
    if input.nav.d and state.selected < count then state.selected, state.confirm_delete = state.selected + 1, nil end
    if state.selected < state.top then state.top = state.selected end
    if state.selected >= state.top + list.rows then state.top = state.selected - list.rows + 1 end
    local item = state.entries[state.selected]
    local busy = state.progress ~= nil
    if input.nav.cancel then
        run_action(state, "back", item, context)
    elseif input.nav.ok and item and not busy then
        local action = primary_action(item)
        if action then run_action(state, action, item, context) end
    elseif flow_input.keys[delete_key] and not state.previous_keys[delete_key] and item and not busy then
        run_action(state, "delete", item, context)
    elseif input.click then
        for row = 0, list.rows - 1 do
            local position = state.top + row
            if position <= count and inside(state.pointer_x, state.pointer_y,
                {x = list.x, y = list.y + row * list.row, width = list.width, height = list.row - 2}) then
                state.selected, state.confirm_delete = position, nil
            end
        end
        for _, button in ipairs(buttons) do
            if inside(state.pointer_x, state.pointer_y, button) and (button.name == "back" or not busy) then
                if button.name == "primary" then
                    local action = primary_action(item)
                    if action then run_action(state, action, item, context) end
                else
                    run_action(state, button.name, item, context)
                end
            end
        end
    end
    state.previous_keys = flow_input.keys
    for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
end

local function wrap(text, width)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if font.gdi_width(candidate) > width and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

local function draw_button(context, state, button, label, enabled)
    local pointed = enabled and inside(state.pointer_x, state.pointer_y, button)
    context.fill(button.x, button.y, button.width, button.height, 0xa0, 0xa0, 0xc0)
    context.fill(button.x + 1, button.y + 1, button.width - 2, button.height - 2, pointed and 0x32 or 0x10,
        pointed and 0x4d or 0x20, pointed and 0x9a or 0x50)
    font.gdi(context, i18n.tr(label), button.x + math.floor(button.width / 2), button.y + 5,
        enabled and 0xffffff or 0x707088, nil, "center")
end

function screen.draw(state, context)
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back" .. state.background, 0, 0, true)
    context.fill(0, 0, constants.screen.width, constants.screen.height, 0x08, 0x10, 0x30, 150)
    font.gdi(context, i18n.tr("Game versions"), 30, 30, 0xffffff)
    local info = state.info or {}
    if info.current then
        font.gdi(context, i18n.tr("Running: %s (%s, %s)", info.current, info.commit or "?", info.platform or "?"),
            30, 48, 0x9090b0)
    end
    context.fill(list.x - 4, list.y - 4, list.width + 8, list.rows * list.row + 6, 0x0a, 0x0e, 0x1e, 200)
    for row = 0, list.rows - 1 do
        local position = state.top + row
        local item = state.entries[position]
        if not item then break end
        local y = list.y + row * list.row
        if position == state.selected then context.fill(list.x, y, list.width, list.row - 2, 0x32, 0x4d, 0x9a) end
        font.gdi(context, item.id, list.x + 6, y + 1, 0xffffff)
        local label, color = status(item, info)
        font.gdi(context, i18n.tr(label), list.x + list.width - 6, y + 1, color, nil, "right")
    end
    if #state.entries == 0 then font.gdi(context, i18n.tr("No versions yet."), list.x + 6, list.y + 2, 0x9090b0) end
    context.fill(details.x - 4, details.y - 4, details.width + 8, details.height + 8, 0x0a, 0x0e, 0x1e, 200)
    local item = state.entries[state.selected]
    if item then
        local y = details.y
        font.gdi(context, item.id, details.x + 4, y, 0xffffff)
        y = y + 18
        local facts = {}
        if item.date then facts[#facts + 1] = item.date end
        if item.commit then facts[#facts + 1] = item.commit end
        if #facts > 0 then font.gdi(context, table.concat(facts, "  "), details.x + 4, y, 0x9090b0) end
        y = y + 22
        font.gdi(context, i18n.tr("Changes"), details.x + 4, y, 0xffd24a)
        y = y + 18
        if #item.changes == 0 then font.gdi(context, i18n.tr("No changes listed."), details.x + 4, y, 0x9090b0) end
        for _, change in ipairs(item.changes) do
            local sub = change:sub(1, 2) == "- "
            local lines = wrap(sub and change:sub(3) or change, details.width - (sub and 24 or 14))
            for number, line in ipairs(lines) do
                if y > details.y + details.height - 16 then break end
                font.gdi(context, (number == 1 and (sub and "  - " or "* ") or (sub and "    " or "  ")) .. line,
                    details.x + 4, y, sub and 0xb8b8d0 or 0xe0e0f0)
                y = y + 16
            end
        end
    end
    local action = primary_action(item)
    local busy = state.progress ~= nil
    draw_button(context, state, buttons[1], action == "install" and "Install" or "Play", action ~= nil and not busy)
    draw_button(context, state, buttons[2], "Delete", item ~= nil and item.installed and not item.current and not busy)
    draw_button(context, state, buttons[3], "Back", true)
    local message = state.message
    if busy then message = string.format("%s %d%%", state.message or "", math.floor((state.progress or 0) * 100)) end
    if message then font.gdi(context, i18n.clip(message, 94), 30, 500, 0xffffff) end
    font.gdi(context, i18n.tr("Up/Down: choose   Enter: play or install   Delete: delete   Escape: back"), 30, 520, 0x8080a0)
    context.image("pe/lf2_cursor", math.min(state.pointer_x, 0x307), math.min(state.pointer_y + 2, 0x217), true)
end

function screen.describe(state)
    local ids = {}
    for _, item in ipairs(state.entries) do ids[#ids + 1] = item.id end
    return "versions=" .. table.concat(ids, ",") .. " selected=" .. tostring(state.selected)
        .. (state.message and (" message=" .. state.message) or "")
end

return screen
