-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local transport = require("base/game/network")
local controls = require("base/ui/controls")
local server_list = require("base/game/server_list")
local font = require("base/ui/font")
local i18n = require("base/i18n/i18n")
local sounds = require("base/game/sounds")
local navigation = require("base/ui/navigation")
local constants = require("base/game/constants")
local virtual_keys = constants.virtual_keys
local screen = {}
local frames = {[1] = {0, 41, 434, 80}, [2] = {434, 41, 62, 68}, [3] = {0, 247, 304, 126}, [4] = {0, 376, 363, 123},
    [5] = {500, 42, 291, 27}, [6] = {500, 72, 291, 27}, [10] = {460, 203, 334, 108},
    [11] = {460, 313, 334, 108}, [12] = {643, 426, 151, 26}, [13] = {489, 426, 151, 26},
    [14] = {490, 462, 304, 38}}
local function inside(input, left, top, right, bottom)
    return input.pointer_x >= left and input.pointer_x <= right and input.pointer_y >= top and input.pointer_y <= bottom
end
-- The question when the host offers its game scripts (base/game/network): Allow or Refuse, Refuse focused first;
-- Escape refuses.
local question = {x = 192, y = 196, width = 410, height = 132}
local allow_button = {x = question.x + 50, y = question.y + 94, width = 130, height = 26}
local refuse_button = {x = question.x + 230, y = question.y + 94, width = 130, height = 26}
local function inside_area(input, area)
    return inside(input, area.x, area.y, area.x + area.width, area.y + area.height)
end
-- When the host names a game version (base/ui/versions) other than this one, the question also offers to switch to
-- it: the game installs it if needed, restarts in it and joins the host again.
local switch_buttons = {
    switch = {x = question.x + 15, y = question.y + 94, width = 120, height = 26},
    allow = {x = question.x + 145, y = question.y + 94, width = 120, height = 26},
    refuse = {x = question.x + 275, y = question.y + 94, width = 120, height = 26},
}
local function switchable(state)
    local version = state.session.host_version
    return engine.versions ~= nil and version ~= nil and version ~= "" and version ~= transport.own_version()
end
local function question_buttons(state)
    if switchable(state) then return switch_buttons.switch, switch_buttons.allow, switch_buttons.refuse end
    return nil, allow_button, refuse_button
end
-- The join page's server list (OpenLF2 extension): the addresses joined before and the favorites, saved in
-- config.json ("network_servers"), favorites first. A click on a row joins it, a click on its star makes it a
-- favorite or not. While the page is open, each server is checked in turn with a short connection (closed at once;
-- a waiting host goes on waiting): green is a host waiting for a player, red is none.
local servers_shown = 5
local server_rows = {x = 0xdb, y = 418, width = 363, height = 17, step = 18}
local star_width = 26
local probe_timeout, probe_interval = 1500, 4000
-- The list itself lives in base/game/server_list (the network menu of the server program uses it too).
local load_servers, save_servers, sort_servers = server_list.load, server_list.save, server_list.sort
local function remember_server(state, address) state.servers = server_list.remember(state.servers, address) end
local function server_row(index)
    local top = server_rows.y + (index - 1) * server_rows.step
    return {x = server_rows.x, y = top, width = server_rows.width, height = server_rows.height}
end
-- One step of the status checks: start the next one that is due, or finish the running one.
local function probe_servers(state)
    local now = engine.network_time()
    local probe = state.probe
    if probe then
        local _, problem = engine.network("poll")
        local up
        if engine.network("status") == "connected" then up = true
        elseif problem or now - probe.started > probe_timeout then up = false end
        if up ~= nil then
            engine.network("close")
            state.server_status[probe.address] = {up = up, checked = now}
            state.probe = nil
        end
        return
    end
    for index = 1, math.min(#state.servers, servers_shown) do
        local address = state.servers[index].address
        local status = state.server_status[address]
        if not status or now - status.checked > probe_interval then
            if engine.network("join", address, state.session.port) then
                state.probe = {address = address, started = now}
            else
                state.server_status[address] = {up = false, checked = now}
            end
            return
        end
    end
end
local function stop_probe(state)
    if state.probe then
        engine.network("close")
        state.probe = nil
    end
end
function screen.create(options)
    return {session = transport.create(options), page = "choice", address = "", previous_keys = {},
        servers = sort_servers(load_servers()), server_status = {},
        nav = navigation.create(), keyboard = false,
        background = (options.menu_seed or 0) % 13 + 1, pointer_x = 0, pointer_y = 0,
        bind = options.network_bind or "0.0.0.0", started = engine.network_time(),
        -- After a script swap the joining game connects again; the host may need a moment to listen again.
        retry_until = options.network_retry and engine.network_time() + 5000 or nil}
end
function screen.begin(state, host, address)
    stop_probe(state)
    state.message = nil
    if transport.start(state.session, host, address) then state.page = "waiting"
    else state.message = state.session.error end
    state.started = engine.network_time()
end
-- The clickable areas for keyboard and controller navigation (base/ui/navigation); the join
-- page starts on its Connect button so Enter connects at once, as it always did.
local function navigation_spec(page, asking, servers)
    local target = navigation.target
    if asking then
        local targets = {}
        for _, area in ipairs(asking) do
            targets[#targets + 1] = target(area.x, area.y, area.x + area.width, area.y + area.height)
        end
        return {page = "share", default = #targets, autofocus = true, targets = targets}
    end
    if page == "waiting" then return {page = page, targets = {target(0x142, 0x169, 0x1d8, 0x182)}} end
    if page == "join" then
        local targets = {target(0xef, 0x165, 0x185, 0x17e), target(0x19b, 0x165, 0x231, 0x17e)}
        for index = 1, math.min(servers, servers_shown) do
            local row = server_row(index)
            targets[#targets + 1] = target(row.x, row.y, row.x + row.width - star_width, row.y + row.height)
        end
        return {page = page, autofocus = true, targets = targets}
    end
    return {page = page, targets = {target(0x104, 0x112, 0x223, 0x12c), target(0x104, 0x131, 0x223, 0x14a),
        target(0x104, 0x150, 0x223, 0x169)}}
end
-- One step of switching to the host's game version: install it from the version index when it is missing, then
-- start it with the host's address, so the game restarts in it and joins again.
function screen.switch_step(state, cancel)
    local switch = state.switch
    local function stop(message)
        state.switch, state.page, state.message = nil, "choice", message
    end
    if cancel then return stop("Switching canceled.") end
    local function launch()
        local started, problem = engine.versions("launch", switch.id, switch.address, switch.port)
        if not started then return stop(problem) end
        switch.phase, switch.text, switch.progress = "launching", "Restarting the game...", nil
    end
    if switch.phase == "start" then
        local info = engine.versions("describe") or {}
        local installed = info.base_id == switch.id
        for _, version in ipairs(info.installed or {}) do installed = installed or version.id == switch.id end
        if installed then return launch() end
        local started, problem = engine.versions("index")
        if not started then return stop(problem) end
        switch.phase, switch.text = "index", "Reading the version list..."
        return
    end
    if switch.phase ~= "index" and switch.phase ~= "install" then return end
    local job = engine.versions("poll") or {}
    if job.state == "running" then
        switch.progress = job.progress
    elseif job.state == "failed" then
        stop(job.message)
    elseif job.state == "done" and switch.phase == "index" then
        local started, problem = engine.versions("install", switch.id)
        if not started then return stop(problem) end
        switch.phase, switch.text, switch.progress = "install", "Downloading...", 0
    elseif job.state == "done" and switch.phase == "install" then
        launch()
    end
end
function screen.update(state, flow_input, context)
    local asking = state.page == "waiting" and state.session.phase == "ask"
    local switch, allow, refuse = question_buttons(state)
    local areas = asking and (switch and {switch, allow, refuse} or {allow, refuse}) or nil
    local input = navigation.apply(state.nav, flow_input, navigation_spec(state.page, areas, #state.servers))
    state.pointer_x, state.pointer_y = input.pointer_x, input.pointer_y
    local cancel = input.nav.cancel
    if state.page == "switching" then
        screen.switch_step(state, cancel)
        cancel = false
    elseif asking then
        if cancel or input.click and inside_area(input, refuse) then
            sounds.direct(state, "cancel")
            transport.answer(state.session, false)
        elseif input.click and inside_area(input, allow) then
            sounds.direct(state, "ok")
            transport.answer(state.session, true)
        elseif switch and input.click and inside_area(input, switch) then
            sounds.direct(state, "ok")
            state.switch = {id = state.session.host_version, address = state.session.address,
                port = state.session.port, phase = "start"}
            transport.close(state.session)
            state.page, state.message = "switching", nil
            screen.switch_step(state, false)
            return
        end
        cancel = false
        local _, problem = transport.poll(state.session)
        if problem then state.page, state.message = "choice", problem end
    elseif state.page == "waiting" then
        cancel = cancel or input.click and inside(input, 0x142, 0x169, 0x1d8, 0x182)
        if not cancel then
            local ready, problem = transport.poll(state.session)
            if ready then
                if not state.session.host then remember_server(state, state.session.address) end
                context.action("network_ready")
            elseif problem and state.retry_until and not state.session.host
                   and engine.network_time() < state.retry_until then
                screen.begin(state, false, state.session.address)
            elseif problem and state.session.host and state.session.accepted then
                -- A peer that left before the game started (a status check, a refused script offer...): the host
                -- waits again, and tells why only when the peer got as far as its profile.
                local shown = state.session.profiled and problem or nil
                screen.begin(state, true, state.session.address)
                state.message = shown
            elseif problem then state.page, state.message = "choice", problem end
        end
    elseif state.page == "join" then
        for code = 0, 255 do
            if input.keys[code] and not state.previous_keys[code] then
                if code == virtual_keys.backspace then state.address = state.address:sub(1, -2)
                else
                    local character = controls.key_character(code, false)
                    if character and character:match("^[%d.]$") and #state.address < 15 then state.address = state.address .. character end
                end
            end
        end
        -- Text a soft keyboard delivers without key events.
        for character in input.text:gmatch("[%d.]") do
            if #state.address < 15 then state.address = state.address .. character end
        end
        cancel = cancel or input.click and inside(input, 0x19b, 0x165, 0x231, 0x17e)
        -- A saved server: its star makes it a favorite or not, the rest of its row joins it.
        local joining = false
        for index = 1, math.min(#state.servers, servers_shown) do
            local row, entry = server_row(index), state.servers[index]
            if not cancel and input.click and inside_area(input, row) then
                if input.pointer_x >= row.x + row.width - star_width then
                    entry.favorite = not entry.favorite
                    state.servers = sort_servers(state.servers)
                    save_servers(state.servers)
                else
                    sounds.direct(state, "ok")
                    state.address, joining = entry.address, true
                    screen.begin(state, false, entry.address)
                end
                break
            end
        end
        -- Enter connects wherever the focus is (the raw keys: navigation may have taken it).
        if not cancel and not joining and (flow_input.keys[virtual_keys.enter] and not state.previous_keys[virtual_keys.enter]
           or input.click and inside(input, 0xef, 0x165, 0x185, 0x17e)) then
            screen.begin(state, false, state.address)
        elseif not cancel and not joining then
            probe_servers(state)
        end
    else
        cancel = cancel or input.click and inside(input, 0x104, 0x150, 0x223, 0x169)
        if input.click and inside(input, 0x104, 0x112, 0x223, 0x12c) then
            sounds.direct(state, "ok")
            screen.begin(state, true, state.bind)
        elseif input.click and inside(input, 0x104, 0x131, 0x223, 0x14a) then
            sounds.direct(state, "ok")
            state.page = "join"
        end
    end
    if cancel then
        stop_probe(state)
        transport.close(state.session)
        sounds.direct(state, "cancel")
        if state.page == "choice" then context.action("launch") else state.page = "choice" end
    end
    state.previous_keys = flow_input.keys
    -- The on-screen keyboard follows the address field.
    local typing = state.page == "join"
    if typing ~= state.keyboard then
        state.keyboard = typing
        context.text_input(typing)
    end
    for _, sound in ipairs(sounds.flush(state)) do context.sound(sound.resource, sound.volume, sound.pan) end
end
function screen.draw(state, context)
    local function sprite(frame, x, y) context.sprite("pe/menu_clip", frames[frame], x, y, true) end
    context.viewport(constants.screen.width, constants.screen.height, 16, 32, 108)
    context.image("pe/menu_back" .. state.background, 0, 0, true)
    -- The logo without the version in its bottom-right corner.
    sprite(1, 0x9b, 0x69)
    sprite(2, 0x9b + 434, 0x69)
    sprite(3, 0xfd, 0xde)
    sprite(14, 0xfd, 0x14f)
    -- The original writes " Your IP Address: <address>" here on an opaque box, which also hides
    -- the art's own label; OpenLF2 has no address to show, so it shows its TCP port instead.
    font.gdi(context, " " .. i18n.tr("Your TCP port: %s", state.session.port), 0x121, 0xfb, 0xffffff, 0x001e50)
    if state.page == "waiting" then
        sprite(state.session.host and 10 or 11, 0xec, 0x122)
        sprite(12, 0x142, 0x169)
        local count = math.floor((engine.network_time() - state.started) / 150) % 14
        for index = 0, count - 1 do context.fill(0x119 + index * 20, 0x156, 5, 12, 87, 127, 215) end
    elseif state.page == "join" then
        sprite(4, 0xdb, 0x10c)
        sprite(13, 0xef, 0x165)
        sprite(12, 0x19b, 0x165)
        font.gdi(context, state.address .. "_", 0x153, 0x147, 0xffffff, 0x001e50)
        local shown = math.min(#state.servers, servers_shown)
        if shown > 0 then
            font.gdi(context, i18n.tr("Servers (click to join, * for favorite)"), server_rows.x + 4, server_rows.y - 17, 0xc8c8e0)
        end
        for index = 1, shown do
            local row, entry = server_row(index), state.servers[index]
            local pointed = inside_area(state, row)
            context.fill(row.x, row.y, row.width, row.height, pointed and 0x32 or 0x10, pointed and 0x4d or 0x20,
                pointed and 0x9a or 0x50, 220)
            local status = state.server_status[entry.address]
            local checking = state.probe and state.probe.address == entry.address
            local r, g, b, text = 0x80, 0x80, 0x90, "checking..."
            if status and status.up then r, g, b, text = 0x50, 0xe0, 0x70, "waiting for you"
            elseif status then r, g, b, text = 0xe0, 0x50, 0x50, "not hosting" end
            if checking and not status then text = "checking..." end
            context.fill(row.x + 6, row.y + 5, 7, 7, r, g, b)
            font.gdi(context, entry.address, row.x + 20, row.y, 0xffffff)
            font.gdi(context, i18n.tr(text), row.x + 150, row.y, r * 65536 + g * 256 + b)
            font.gdi(context, "*", row.x + row.width - 16, row.y, entry.favorite and 0xffd24a or 0x606070)
        end
    else
        local input = {pointer_x = state.pointer_x, pointer_y = state.pointer_y}
        if inside(input, 0x104, 0x112, 0x223, 0x12c) then sprite(5, 0x103, 0x112) end
        if inside(input, 0x104, 0x131, 0x223, 0x14a) then sprite(6, 0x103, 0x130) end
        if inside(input, 0x104, 0x150, 0x223, 0x169) then sprite(12, 0x149, 0x150) end
    end
    if state.page == "waiting" and state.session.phase == "ask" then
        context.fill(question.x, question.y, question.width, question.height, 0xa0, 0xa0, 0xc0)
        context.fill(question.x + 2, question.y + 2, question.width - 4, question.height - 4, 0x10, 0x20, 0x50)
        local middle = question.x + math.floor(question.width / 2)
        font.gdi(context, i18n.tr("The host wants to send its game scripts (%d KB).",
            math.floor(state.session.share.size / 1024 + 0.5)), middle, question.y + 16, 0xffffff, nil, "center")
        font.gdi(context, i18n.tr("Do you allow it?"), middle, question.y + 36, 0xffffff, nil, "center")
        local switch, allow, refuse = question_buttons(state)
        if switch then
            font.gdi(context, i18n.tr("The host runs version %s, you run %s.", state.session.host_version,
                transport.own_version() or "?"), middle, question.y + 62, 0xffd24a, nil, "center")
        else
            font.gdi(context, i18n.tr("They replace your scripts until you restart the game."), middle, question.y + 62,
                0xa0a0c0, nil, "center")
        end
        local shown = {{allow, "Allow"}, {refuse, "Refuse"}}
        if switch then table.insert(shown, 1, {switch, "Switch version"}) end
        for _, button in ipairs(shown) do
            local area = button[1]
            local pointed = inside_area(state, area)
            context.fill(area.x, area.y, area.width, area.height, 0xa0, 0xa0, 0xc0)
            context.fill(area.x + 1, area.y + 1, area.width - 2, area.height - 2,
                pointed and 0x32 or 0x10, pointed and 0x4d or 0x20, pointed and 0x9a or 0x50)
            font.gdi(context, i18n.tr(button[2]), area.x + math.floor(area.width / 2), area.y + 5, 0xffffff, nil, "center")
        end
    end
    if state.page == "switching" and state.switch then
        context.fill(question.x, question.y, question.width, question.height, 0xa0, 0xa0, 0xc0)
        context.fill(question.x + 2, question.y + 2, question.width - 4, question.height - 4, 0x10, 0x20, 0x50)
        local middle = question.x + math.floor(question.width / 2)
        font.gdi(context, i18n.tr("Switching to version %s", state.switch.id), middle, question.y + 24, 0xffffff, nil, "center")
        local text = state.switch.text or ""
        if state.switch.progress then text = string.format("%s %d%%", text, math.floor(state.switch.progress * 100)) end
        font.gdi(context, i18n.tr(text), middle, question.y + 52, 0xc8c8e0, nil, "center")
        font.gdi(context, i18n.tr("Escape: cancel"), middle, question.y + 96, 0x8080a0, nil, "center")
    end
    if state.session.notice and state.page == "waiting" then
        font.gdi(context, i18n.clip(i18n.tr(state.session.notice), 94), 10, 490)
    end
    if state.message then font.gdi(context, i18n.clip(state.message, 94), 10, 510) end
    context.image("pe/lf2_cursor", math.min(state.pointer_x, 0x307), math.min(state.pointer_y + 2, 0x217), true)
end
function screen.describe(state)
    return "network_page=" .. state.page .. " phase=" .. state.session.phase .. (state.message and " error=" .. state.message or "")
end
return screen
