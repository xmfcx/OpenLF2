-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local record_kinds = constants.record_kinds
local camera_view = require("base/ui/camera_view")
local player_colors = require("base/ui/player_colors")
local fight_hud = require("base/ui/fight_hud")
local match = require("base/game/match")
local background = require("base/game/background")
local object_data = require("base/game/object_data")
local font = require("base/ui/font")
local i18n = require("base/i18n/i18n")
local sounds = require("base/game/sounds")
local rumble = require("base/game/rumble")
local controls = require("base/ui/controls")
local options = require("base/game/options")
local fight_effects = require("base/ui/fight_effects")
local rollback_client = require("base/game/rollback_client")
local rollback = require("base/game/rollback")
local netsim = require("base/game/netsim")
local online = require("base/game/online")
local screen = {}
local replay_lines, mode_line, follow_step

-- The function that a fight calls at the end of each tick to keep what it draws (match.step). It also advances the
-- hit sparks, so every copy of a fight needs one (base/game/netsim).
local function make_capture()
    local snapshots, next_snapshot = {{items = {}}, {items = {}}}, 1
    return function(current)
        local snapshot = screen.snapshot(current, snapshots[next_snapshot])
        next_snapshot = 3 - next_snapshot
        return snapshot
    end
end

screen.make_capture = make_capture

-- options: see base/game/match create(). connection: the session of a server program (base/game/online) that runs
-- this fight with rollback.
function screen.create(options, connection)
    -- --net-sim (developer, base/game/netsim): the fight runs through a simulated network; recording is off, because
    -- the screen's fight runs predicted ticks.
    local start_random
    if netsim.params or connection then
        options.record = nil
        start_random = {engine.random_position()}
    end
    local state = {match = match.create(options), effects = fight_effects.create()}
    state.match.capture = make_capture()
    if connection then
        online.begin_match(connection, state.match)
        state.online = connection
    elseif netsim.params then
        state.netsim = netsim.create(state.match, options, start_random, make_capture)
    end
    return state
end

local function advance_sparks(list, drawn)
    local count = 0
    local position = 1
    while position <= #list do
        local spark = list[position]
        local timer = spark.timer
        local frame, left, up
        if timer < 5 then frame, left, up = timer, 0x33, 0x28
        elseif timer >= 10 and timer < 15 then frame, left, up = timer - 5, 0x1e, 0x18
        elseif timer >= 20 and timer < 29 then frame, left, up = math.floor((timer - 20) / 2) + 10, 0x33, 0x28
        elseif timer >= 30 and timer < 39 then frame, left, up = math.floor((timer - 30) / 2) + 15, 0x1e, 0x18 end
        if frame then
            count = count + 1
            local entry = drawn[count] or {}
            entry.frame, entry.x, entry.y = frame, spark.x - left, spark.y - up
            drawn[count] = entry
            spark.timer = timer + 1
        elseif position == #list then
            list[position] = nil
        end
        position = position + 1
    end
    for index = count + 1, #drawn do drawn[index] = nil end
    return drawn
end

function screen.snapshot(state, snapshot)
    snapshot = snapshot or {items = {}}
    local order, count = snapshot.items, 0
    for index = 0, constants.item_slots - 1 do
        local value = state.items[index]
        if value then
            count = count + 1
            local entry = order[count] or {sparks = {}}
            entry.index, entry.record, entry.frame = index, value.record, value.frame
            entry.x, entry.y, entry.z, entry.facing = value.x_int, value.y_int, value.z_int, value.facing
            entry.blink, entry.hit_lag, entry.draw_offset = value.blink, value.hit_lag, value.draw_offset
            entry.pic_offset, entry.weapon, entry.team = value.pic_offset, value.weapon, value.team
            entry.hp, entry.max_hp, entry.human = value.hp, value.max_hp, value.human
            entry.lives = value.lives
            advance_sparks(value.sparks, entry.sparks)
            order[count] = entry
        end
    end
    for index = count + 1, #order do order[index] = nil end
    -- Keep the original slot order for equal depths.
    for index = 2, count do
        local entry, position = order[index], index
        while position > 1 and entry.z < order[position - 1].z do
            order[position] = order[position - 1]
            position = position - 1
        end
        order[position] = entry
    end
    snapshot.camera, snapshot.shake = state.camera, state.shake
    snapshot.paused, snapshot.held_by, snapshot.stage = nil, nil, nil
    return snapshot
end

-- --rollback-check (developer, base/game/rollback): every `rollback.interval` ticks the state is saved and the next
-- `rollback.span` inputs are kept; then the fight goes back to the saved state and runs them again. Both runs must
-- end with the same hash. The times are summed for the description.
local function rollback_check(state, held)
    local check = state.rollback_check
    if not check then
        check = {ticks = 0, count = 0, failures = 0, save_ms = 0, run_ms = 0, hash_ms = 0}
        state.rollback_check = check
    end
    check.ticks = check.ticks + 1
    if not check.saved and check.ticks % rollback.interval == 0 then
        local started = engine.network_time()
        check.saved, check.inputs = rollback.save(state.match), {}
        check.save_ms = check.save_ms + engine.network_time() - started
        check.saved_hash = rollback.hash(state.match)
        check.inventory = check.inventory or rollback.inventory(state.match)
    end
    if check.saved then check.inputs[#check.inputs + 1] = rollback.copy_input(held) end
end
local function rollback_compare(state)
    local check = state.rollback_check
    if not (check and check.saved and #check.inputs >= rollback.span) then return end
    local started = engine.network_time()
    local first = rollback.hash(state.match)
    check.hash_ms = check.hash_ms + engine.network_time() - started
    local first_fields = rollback.field_hashes(state.match)
    rollback.restore(state.match, check.saved)
    -- A restore alone must give back the saved hash.
    if rollback.hash(state.match) == check.saved_hash then check.restored = (check.restored or 0) + 1 end
    started = engine.network_time()
    for position, input in ipairs(check.inputs) do
        match.step(state.match, input)
        -- The first run played the sounds and rumbles of each tick but the last (which update plays below); the run
        -- again drops them.
        if position < #check.inputs then
            sounds.flush(state.match)
            rumble.flush(state.match)
        end
    end
    check.run_ms = check.run_ms + engine.network_time() - started
    local second = rollback.hash(state.match)
    check.count = check.count + 1
    if first ~= second then
        check.failures = check.failures + 1
        check.first_failure = check.first_failure or state.match.frame_number
        if not check.differ then
            local second_fields, names = rollback.field_hashes(state.match), {}
            for name, value in pairs(first_fields) do
                if second_fields[name] ~= value then names[#names + 1] = name end
            end
            for name in pairs(second_fields) do
                if first_fields[name] == nil then names[#names + 1] = name .. "(new)" end
            end
            table.sort(names)
            check.differ = table.concat(names, ";")
        end
    end
    check.saved, check.inputs = nil, nil
end

-- A frame of a fight with rollback, through the simulated network or a server program: its sounds play here, and a
-- result counts once its tick is final.
local function rollback_update(state, held, context)
    local played, results, stepped
    if state.online then
        -- Escape, and the end of the session, belong to the flow (base/ui/flow).
        played, results, stepped = online.frame(state.online, held)
        if state.online.client then state.overlay_match = rollback_client.confirmed_view(state.online.client) end
    else
        played, results, stepped = netsim.frame(state.netsim, held)
        state.overlay_match = netsim.confirmed(state.netsim)
    end
    for _, sound in ipairs(played) do context.sound(sound.resource, sound.volume, sound.pan) end
    fight_effects.observe(state.effects, state.overlay_match)
    for _ = 1, stepped do follow_step(state, state.match) end
    state.view = state.match.last_snapshot
    for _, result in ipairs(results) do
        if result == "finished" then context.action("round_over") return end
        if result == "leave" then context.action("title") return end
        if result == "replay_error" then context.action("replay_error") return end
    end
end

function screen.update(state, held, context)
    if state.netsim or state.online then return rollback_update(state, held, context) end
    if rollback.check then rollback_check(state, held) end
    local result = match.step(state.match, held)
    if rollback.check and result == nil then rollback_compare(state) end
    if result == "leave" then
        -- F4 in Championship or during a replay: the game state becomes 10, the title.
        context.action("title")
        return
    end
    if result == "replay_error" then
        context.action("replay_error")
        return
    end
    for _, sound in ipairs(sounds.flush(state.match)) do context.sound(sound.resource, sound.volume, sound.pan) end
    -- Rumble (OpenLF2 extension): a landed hit on a local player's slot rumbles their controller,
    -- or device haptics when slot 1 is reading the on-screen touch gamepad.
    local rumble_enabled = options.current().rumble
    for _, event in ipairs(rumble.flush(state.match)) do
        if rumble_enabled then
            local set = controls.current().sets[event.item_index + 1]
            if set and set.device and set.device >= constants.input_devices.controller_one then
                context.rumble("gamepad", set.device - constants.input_devices.controller_one, event.strength)
            elseif set and set.device == constants.input_devices.keyboard and event.item_index == 0 and held.touch_active then
                context.rumble("phone", 0, event.strength)
            end
        end
    end
    fight_effects.observe(state.effects, state.match)
    follow_step(state, state.match)
    if result == "finished" then
        context.action("round_over")
        return
    end
    state.view = state.match.last_snapshot
end

local function bold_text(context, text, x, y)
    for _, offset in ipairs({{-1, 1}, {-1, 0}, {0, 1}, {0, 0}}) do font.draw(context, text, x + offset[1], y + offset[2]) end
end
local function wrapped_text(context, text, x, y, lines)
    local line = 0
    for part in (text .. "\n"):gmatch("([^\n]*)\n") do
        repeat
            if line >= lines then return end
            bold_text(context, part:sub(1, 64), x, y + line * 16)
            part = part:sub(65)
            line = line + 1
        until part == ""
    end
end
local function clock(frames)
    local seconds = math.floor((frames + 15) / 30)
    if seconds < 3600 then return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60) end
    return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 3600 % 60)
end
replay_lines = function(context, current)
    local replay = current.replay
    local y = current.mode == constants.modes.battle and 0x9b or 0x85
    if replay.author ~= "<No name>" then
        bold_text(context, "Author:", 10, y)
        bold_text(context, replay.author:sub(1, 64), 0x4b, y)
        y = y + 0x16
    end
    if replay.info ~= "<No info>" then
        bold_text(context, "  Info:", 10, y)
        wrapped_text(context, replay.info, 0x4b, y, 4)
    end
    bold_text(context, clock(current.elapsed) .. " / " .. clock(replay.total_time), 5, 0x1fe)
end
local mode_text = ""
mode_line = function(context, current, replaying)
    local names = {
        [constants.modes.versus] = "VS mode ",
        [constants.modes.championship] = "1 on 1 ",
        [constants.modes.team_championship] = "2 on 2 ",
        [constants.modes.battle] = "Battle mode "}
    local base
    if current.mode == constants.modes.stage then
        base = math.floor((current.stage_run and current.stage_run.id or 0) / 10) == 5 and "Survival Stage " or "Stage mode "
    else
        base = names[current.mode]
    end
    if base then
        local suffixes = {[0] = "(Difficult)", [1] = "(Normal)", [2] = "(Easy)", [-1] = "(CRAZY!)"}
        -- `base` ends with a space; its parts are translated one by one.
        mode_text = i18n.tr(base:sub(1, -2)) .. " " .. i18n.tr(suffixes[current.difficulty] or "")
    end
    if mode_text ~= "" then bold_text(context, mode_text, 0x316 - font.width(mode_text), replaying and 0x1fe or 0x213) end
end

local function label_font(team)
    if team >= constants.teams.player_one and team <= constants.teams.player_four then
        return "pe/words" .. team
    end
    return "pe/words0"
end
local function glyphs(context, sheet, text, x, y, advance, tint)
    for position = 1, #text do
        local code = text:byte(position)
        context.sprite(sheet, {(code % 16) * 16, math.floor(code / 16) * 16 + 1, 8, 16},
            x + (position - 1) * advance, y, true, false, false, tint)
    end
end

-- The original passes COLORREF values (0xBBGGRR) to its text routine; font.gdi takes 0xRRGGBB.
local function colorref(value)
    return value % 256 * 65536 + math.floor(value / 256) % 256 * 256 + math.floor(value / 65536)
end

local spark_frames = {}
for frame = 1, 4 do
    spark_frames[frame] = {0x66 * frame, 0, 0x66, 0x50}
    spark_frames[frame + 10] = {0x66 * frame, 0x80, 0x66, 0x50}
    spark_frames[frame + 5] = {0x3d * frame, 0x50, 0x3d, 0x30}
    spark_frames[frame + 15] = {0x3d * frame, 0xd0, 0x3d, 0x30}
end

-- colored: the new fight screen's names in the player colors (base/ui/player_colors), not in the team fonts.
local function draw_item(context, stage, view, entry, bounds, lighting, colored)
    local frame = entry.record.frame(entry.frame)
    local blink = math.abs(entry.blink)
    local camera = view.camera
    local casts_shadow = entry.weapon >= 0 and frame.state ~= constants.frame_states.vanishing_ball
       and frame.state ~= constants.frame_states.team_order_marker
       and entry.record.id ~= constants.object_ids.firzen_ball
       and entry.record.id ~= constants.object_ids.bat_ball
       and entry.blink > -70 and blink % 4 < 2
    if casts_shadow and stage.shadow and not lighting.projected_shadows then
        local width, height = stage.shadow_size[1] or 0, stage.shadow_size[2] or 0
        local shadow = stage.shadow:gsub("\\", "/"):lower()
        context.image(shadow, entry.draw_offset + entry.x - camera - math.floor(width / 2),
            entry.z - math.floor(height / 2), true)
    end
    local shake = entry.hit_lag < 0 and view.shake * 6 - 3 or 0
    local visible = blink % 4 < 2 and entry.blink > -25
    local on_screen = frame.state == constants.frame_states.team_order_marker
    local resource, source = object_data.picture(entry.record.data, entry.frame, entry.pic_offset)
    if visible and resource and not frame.undefined then
        local y = entry.z - frame.center_y + entry.y
        local x
        if entry.facing == constants.facings.right then x = entry.draw_offset - frame.center_x + entry.x - camera + shake
        else x = frame.center_x + entry.draw_offset + entry.x - camera + shake - source[3] end
        if on_screen then
            -- Order markers stay on the screen: the classic one, or the whole window in the widescreen layout.
            if bounds then x = math.max(bounds.left, math.min(x, bounds.right - (constants.screen.width - 0x2ca)))
            else x = math.max(0, math.min(x, 0x2ca)) end
        end
        if (lighting.character_shading or lighting.projected_shadows) and not on_screen then
            local kind = entry.record.kind
            local physical = kind == record_kinds.light_item or kind == record_kinds.heavy_item
                or kind == record_kinds.baseball or kind == record_kinds.drink
            context.world_sprite(resource, source, x, y, entry.facing ~= constants.facings.right,
                entry.z, lighting.light_azimuth, lighting.light_elevation,
                lighting.character_shading and kind == record_kinds.character,
                lighting.projected_shadows and (casts_shadow or physical), lighting.shadow_blur, lighting.shadow_opacity)
        else
            context.sprite(resource, source, x, y, true, entry.facing ~= constants.facings.right)
        end
    end
    if visible and not on_screen and entry.hp < math.floor(entry.max_hp / 3) and frame.bpoint.x > 0 then
        local offset = entry.facing == constants.facings.right and frame.bpoint.x - frame.center_x or frame.center_x - frame.bpoint.x
        context.sprite("pe/bars", {0, 20, 1, 3}, offset + entry.draw_offset + entry.x - camera + shake,
            frame.bpoint.y - frame.center_y + entry.z + entry.y, false)
    end
    if entry.lives > 1 then
        -- Remaining lives ("x2"; two digits at most) above the head, in the default font, unclamped.
        local text = entry.lives < 10 and ("x" .. entry.lives)
            or ("x" .. math.floor(entry.lives / 10) % 10 .. entry.lives % 10)
        glyphs(context, "pe/words0", text, entry.draw_offset + entry.x - camera - math.floor(#text * 9 / 2),
            entry.z - frame.center_y + entry.y - 7, 9)
    end
    local is_character = entry.record.kind == record_kinds.character
    local label, sheet
    if entry.index < 20 or (entry.team ~= constants.teams.enemies and is_character) then
        label = entry.index < 8 and controls.name(entry.index) or "Com"
        sheet = label_font(entry.team)
    elseif is_character and entry.team == constants.teams.enemies
           and (entry.record.id < constants.record_id_ranges.enemy_character_first
           or entry.record.id > constants.record_id_ranges.enemy_character_last or entry.record.id == constants.fighter_ids.bat) then
        -- Bosses and other enemy characters in slots 20+ (WORDS5 sheet).
        label, sheet = "Com", "pe/words5"
    end
    if label and entry.blink > -25 then
        local length = #label
        local x = entry.draw_offset + entry.x - camera - math.floor(length * 9 / 2)
        if bounds then
            x = math.max(bounds.left, math.min(x, bounds.right - length * 9))
        else
            if x < 0 then x = 0 end
            if x > constants.screen.width - length * 9 then x = constants.screen.width - length * 9 end
        end
        local slot = colored and player_colors.slot(entry.index)
        if slot then
            -- A dark shadow keeps the light colors readable on light ground.
            glyphs(context, "pe/words0", label, x + 1, entry.z + 4, 9, 0x101018)
            glyphs(context, "pe/words0", label, x, entry.z + 3, 9, player_colors.of(slot))
        else
            glyphs(context, sheet, label, x, entry.z + 3, 9)
        end
    end
    for _, spark in ipairs(entry.sparks) do
        local source = spark_frames[spark.frame]
        -- Frames 0, 5, 10 and 15 are never given a rectangle (assumed empty; see docs).
        if source then context.sprite("pe/spark", source, entry.draw_offset + spark.x - camera, spark.y, true) end
    end
end

local function draw_status(context, state)
    for slot = 0, 7 do
        local row, column = math.floor(slot / 4) * 54, (slot % 4) * 198
        context.image("pe/frame", column, row, false)
        local value = state.items[slot] or state.items[slot + 10]
        if value then
            local small = value.record.data.small
            if small then context.image(small:gsub("\\", "/"):lower(), column + 9, row + 7, false) end
            if value.hp > 0 then
                local function bar(source_y, width, y)
                    if width > 0 then context.sprite("pe/bars", {0, source_y, width, 10}, column + 57, row + y, false) end
                end
                bar(30, math.floor(value.dark_hp * 31 / 125), 16)
                bar(20, math.floor(value.hp * 31 / 125), 16)
                -- Healing (milk, regeneration): the bar flashes every other tick of the 12-tick counter.
                if (math.floor(value.regen_timer / constants.healing.timer_base) == 1 or value.heal_timer > 0) and state.counter_12 % 2 == 0 then
                    bar(40, math.floor(value.hp * 31 / 125), 16)
                end
                bar(10, 124, 36)
                bar(0, math.floor(value.mp * 31 / 125), 36)
            end
            glyphs(context, label_font(value.team), string.char(254), column + 5, row, 8)
        end
    end
end

local function draw_scoreboard(context, current)
    local counter = current.round_counter
    if counter < 101 or counter >= constants.round_counters.finished then return end
    local players = 0
    for slot = 0, 7 do
        if current.items[slot] or current.items[slot + 10] then players = players + 1 end
    end
    local players_alive = false
    for index = 0, constants.item_slots - 1 do
        local value = current.items[index]
        if value and value.hp > 0 and value.record.kind == record_kinds.character
           and value.team > constants.teams.independent
           and value.team < constants.teams.active_end_exclusive
           and value.team ~= constants.teams.enemies then
            players_alive = true
        end
    end
    local battle_run = current.battle_run
    local height = players * 45 + (battle_run and 138 or 93)
    local top = math.floor((530 - height) / 2)
    local row_y = top + 16
    context.image("pe/score_board1", 150, top, false)
    for slot = 0, 7 do
        local index = current.items[slot] and slot or slot + 10
        local value = current.items[index]
        if value then
            row_y = row_y + 45
            context.image("pe/score_board2", 150, row_y, false)
            local small = value.record.data.small
            if small then context.image(small:gsub("\\", "/"):lower(), 165, row_y, false) end
            local label = index < 10 and ("P" .. (index + 1) .. " ") or "Com"
            glyphs(context, label_font(value.team), label, 206, row_y + 15, 9)
            font.gdi(context, tostring(value.kills), 271, row_y + 15, colorref(0xaaaaff))
            font.gdi(context, tostring(value.damage_dealt), 326, row_y + 15, colorref(0xaaaaff))
            font.gdi(context, tostring(value.hp_spent), 390, row_y + 15, colorref(0xaaf0f0))
            font.gdi(context, tostring(value.mp_spent), 454, row_y + 15, colorref(0xaaf0f0))
            font.gdi(context, tostring(value.pickings), 527, row_y + 15, colorref(0xaaf5aa))
            local result
            if current.mode == constants.modes.stage then
                if not players_alive then result = "pe/lose_dead"
                else result = value.hp < 1 and "pe/win_dead" or "pe/win_alive" end
            elseif current.winner >= 0 then
                if current.winner == value.team then
                    result = value.hp < 1 and "pe/win_dead" or "pe/win_alive"
                else
                    result = "pe/lose_dead"
                end
            end
            if result then context.image(result, 571, row_y + 15, false) end
        end
    end
    local footer = top + players * 45 + 61
    if battle_run then
        context.image("pe/score_board4", 150, footer, false)
        context.image("pe/score_board3", 150, footer + 45, false)
        font.gdi(context, tostring(battle_run.deaths[1]), 243, footer + 23, colorref(0xffafaf))
        font.gdi(context, tostring(battle_run.deaths[2]), 483, footer + 23, colorref(0xafafff))
        font.gdi(context, tostring(battle_run.damage[1]), 323, footer + 23, colorref(0xffafaf))
        font.gdi(context, tostring(battle_run.damage[2]), 563, footer + 23, colorref(0xafafff))
    else
        context.image("pe/score_board3", 150, footer, false)
    end
    local seconds = math.floor((current.elapsed + 15) / 30)
    local text
    if seconds < 3600 then text = string.format("%02d : %02d", math.floor(seconds / 60), seconds % 60)
    else
        text = string.format("%02d : %02d : %02d", math.floor(seconds / 3600),
            math.floor(seconds % 3600 / 60), seconds % 3600 % 60)
    end
    font.gdi(context, text, 580, top + players * 45 + (battle_run and 112 or 67))
end

function screen.describe(state)
    local current = state.match
    local parts = {"frame=" .. current.frame_number, "background=" .. current.background_row,
        "camera=" .. current.camera, "round=" .. current.round_counter, "winner=" .. current.winner}
    if current.paused then parts[#parts + 1] = "paused" end
    if current.menu_hold then parts[#parts + 1] = "menu_hold=" .. current.menu_hold end
    if current.mode == constants.modes.demo then parts[#parts + 1] = current.random_game and "demo" or "demo_ending" end
    if current.cheat_lock > 0 then
        local counts = current.function_counts
        parts[#parts + 1] = string.format("fkeys=%d:%d,%d,%d,%d", current.cheat_lock, counts[6], counts[7],
            counts[8], counts[9])
    end
    local run = current.stage_run
    if run then
        parts[#parts + 1] = string.format("stage=%d phase=%d go=%d shutter=%d result=%d bound=%d width=%d", run.id,
            run.phase, run.go, run.shutter, run.result, current.stage_bound, current.stage.width or constants.screen.width)
    end
    if state.netsim then parts[#parts + 1] = netsim.describe(state.netsim) end
    if state.online and state.online.client then
        parts[#parts + 1] = "online=" .. rollback_client.describe(state.online.client) .. ",sent=" .. (state.online.hashes_sent or 0)
            .. ",fights=" .. (state.online.fights or 0)
    end
    local check = state.rollback_check
    if check then
        -- Times are averages per check, in milliseconds; `differ` names the fields of the first failed check.
        local count = math.max(check.count, 1)
        parts[#parts + 1] = string.format("rollback=checks:%d,failures:%d,restored:%d,first:%s,save_ms:%.2f,run_ms:%.2f,"
            .. "hash_ms:%.2f differ=%s inventory=%s", check.count, check.failures, check.restored or 0,
            tostring(check.first_failure), check.save_ms / count, check.run_ms / count, check.hash_ms / count,
            check.differ or "", check.inventory or "")
    end
    for index = 0, constants.item_slots - 1 do
        local value = current.items[index]
        if value then
            -- Holding links are listed only when set, so plain items keep the short form.
            local held = value.weapon ~= constants.weapon_holder_codes.none and string.format(" weapon=%d link=%d", value.weapon,
                value.weapon > 0 and value.held_item or value.holder) or ""
            if value.ai_control then held = held .. " computer=1" end
            parts[#parts + 1] = string.format("item%d{id=%d frame=%d x=%.3f y=%.3f z=%.3f vx=%.3f vy=%.3f vz=%.3f hp=%d mp=%d facing=%d%s}",
                index, value.record.id, value.frame, value.x, value.y, value.z, value.vx, value.vy, value.vz,
                value.hp, value.mp, value.facing, held)
        end
    end
    return table.concat(parts, " ")
end

function screen.outcome(state)
    local run = state.match.stage_run
    if not run then return {} end
    return {stage_level = run.id, auto_start = run.next_group, ending = run.ending}
end

-- The camera of a network game (OpenLF2 extension, drawing only; the match's own camera, which both peers share,
-- is unchanged): base/game/camera's motion, step for step once per fight frame, but focused on this computer's
-- fighters (`state.follow`, set by base/ui/flow) with the same look-ahead. Once they are all down it follows another
-- living character, players first, and each Tab press (`state.follow_next`) moves on to the next one.
local function cdiv(a, b)
    local q = a / b
    if q >= 0 then return math.floor(q) end
    return math.ceil(q)
end
follow_step = function(state, current)
    local follow = state.follow
    if not follow then
        state.follow_camera, state.follow_motion, state.spectated = nil, nil, nil
        return
    end
    local motion = constants.camera_motion
    local lookahead = motion.facing_lookahead
    local sum, count = 0, 0
    for _, slot in ipairs(follow) do
        local value = current.items[slot]
        if value and value.hp > 0 then
            if value.record.frame(value.frame).state == constants.frame_states.lying then sum = sum + value.x_int
            else sum = sum + lookahead + value.x_int - value.facing * (lookahead * 2) end
            count = count + 1
        end
    end
    state.spectated = nil
    if count == 0 then
        -- All of this computer's fighters are down: follow a living character, players first.
        local candidates = {}
        for pass = 1, 2 do
            for index = 0, constants.item_slots - 1 do
                local value = current.items[index]
                if value and value.record.kind == record_kinds.character and value.hp > 0
                   and (pass == 1) == (index < 20) then
                    candidates[#candidates + 1] = index
                end
            end
        end
        if #candidates > 0 then
            local position = 1
            for at, index in ipairs(candidates) do
                if index == state.followed then position = at end
            end
            position = (position - 1 + (state.follow_next or 0)) % #candidates + 1
            state.followed = candidates[position]
            state.spectated = state.followed
            sum, count = current.items[state.followed].x_int, 1
        end
    else
        state.followed = nil
    end
    state.follow_next = 0
    local screen_width = constants.screen.width
    local width = current.stage.width or screen_width
    local camera, step = state.follow_camera, state.follow_motion
    if not camera then camera, step = current.camera, current.camera_step or 0 end
    if count == 0 then
        state.follow_camera, state.follow_motion = current.camera, current.camera_step or 0
        return
    end
    local target = cdiv(sum, count) - screen_width / 2
    if target < 0 then target = 0 end
    if target > width - screen_width then target = width - screen_width end
    if current.camera_limit ~= 0 and target > current.camera_limit then target = current.camera_limit end
    step = cdiv(cdiv(target - camera, motion.target_distance_divisor) + step * motion.previous_step_weight,
        motion.step_weight_divisor)
    if step == 0 then
        if camera < target then step = 1
        elseif target < camera then step = -1 end
    end
    camera = camera + step
    if camera < 0 then camera = 0 end
    if camera > width - screen_width then camera = width - screen_width end
    state.follow_camera, state.follow_motion = camera, step
end

-- camera: the new fight screen's camera of this computer ({mode = "modern", widest = N, zoom = percent or 0}), or nil
-- for the classic picture.
function screen.draw(state, context, window_bounds, camera)
    context.viewport(constants.screen.width, constants.screen.height, 0, 0, 0)
    local view = state.view
    local current = state.match
    if not view then return end
    local spectated = state.follow and state.spectated
    if state.follow and state.follow_camera then
        view = {camera = math.floor(state.follow_camera), items = view.items, paused = view.paused, held_by = view.held_by, shake = view.shake,
            stage = view.stage}
    end
    local bounds, passable_bounds, wide, closed, layout
    local modern = camera and camera.mode == "modern" and context.render_scale
    if modern then
        -- Without a window (headless runs) the screen uses the classic picture's size.
        window_bounds = window_bounds or {left = 0, top = 0, right = constants.screen.width, bottom = constants.screen.height}
        -- The new fight screen (docs/fight-screen.md): the cards at the top, the world in the middle of the rows under
        -- them. The camera (base/ui/camera_view) draws the world 1:1 into a texture `width` units across and the
        -- art's height, and the engine scales it into the window's width; the HUD draws over it at its own size.
        local info = fight_hud.stage_info(current)
        layout = fight_hud.layout(window_bounds, current, info)
        state.hud_layout, state.stage_info = layout, info
        state.camera_view = state.camera_view or camera_view.create(camera.zoom)
        local window_width = layout.width
        local art_top, art_bottom = camera_view.top, camera_view.bottom(current)
        local rows = art_bottom - art_top
        local region = math.max(layout.region_bottom - layout.region_top, 1)
        local left, width = camera_view.step(state.camera_view, view, current, state.follow,
            {window_width = window_width, closest = window_width * rows / region, widest = camera.widest})
        local scale = window_width / width
        local height = math.floor(rows * scale + 0.5)
        layout.band_top = layout.region_top + math.floor((region - height) / 2)
        layout.band_bottom = layout.band_top + height
        layout.view_left, layout.view_width = left, width
        local stage_width = current.stage.width or constants.screen.width
        wide = {left = 0, right = width, camera = left}
        view = {camera = left, items = view.items, paused = view.paused, held_by = view.held_by, shake = view.shake,
            stage = view.stage}
        bounds = {left = math.max(0, -left), right = math.min(width, stage_width - left)}
        passable_bounds = {left = bounds.left, right = bounds.right}
        -- Stage mode's closed part shows darker (drawn after the fighters).
        if current.stage_bound > 0 and current.stage_bound - left < bounds.right then
            closed = {left = math.max(bounds.left, current.stage_bound - left), right = bounds.right, top = art_top, rows = rows}
        end
        context.render_area(layout.left, layout.band_top, window_width, height, 0, art_top, math.floor(scale * 1000 + 0.5))
        context.clip(passable_bounds.left, art_top, passable_bounds.right - passable_bounds.left, rows)
    end
    if current.background_row == constants.background_rows.lee_on_road then
        background.paint_lee_on_road(context, view.camera, bounds)
    else
        background.paint(context, current.stage, current.view, view.camera, bounds, wide)
    end
    context.clip(passable_bounds and passable_bounds.left or 0, 128,
        passable_bounds and passable_bounds.right - passable_bounds.left or constants.screen.width, constants.screen.height - 128)
    local lighting = options.current()
    for _, entry in ipairs(view.items) do
        draw_item(context, current.stage, view, entry, passable_bounds, lighting, modern)
    end
    context.clip()
    -- Ghosts and combo counters (OpenLF2 extension).
    fight_effects.draw(state.effects, context, view)
    if closed then context.fill(closed.left, closed.top, closed.right - closed.left, closed.rows, 0, 0, 0, 150) end
    -- The new fight screen: everything after the world (the HUD, the texts, the flow's overlays) draws at the
    -- window's scale over the picture, and the free rows above and below the world get a dark gradient.
    if modern then
        context.overlay(true)
        local function gradient(top, bottom, from, to)
            local steps = 8
            for step = 0, steps - 1 do
                local y0 = top + math.floor((bottom - top) * step / steps)
                local y1 = top + math.floor((bottom - top) * (step + 1) / steps)
                local value = math.floor(from + (to - from) * step / (steps - 1))
                if y1 > y0 then context.fill(layout.left, y0, layout.width, y1 - y0, value, value, math.floor(value * 1.6)) end
            end
        end
        gradient(layout.top, layout.band_top, 8, 22)
        gradient(layout.band_bottom, layout.bottom, 22, 8)
    end
    if spectated then
        local name = spectated < 8 and controls.name(spectated) or "Com"
        font.gdi(context, "Following " .. name .. "  (Tab: next)", math.floor(constants.screen.width / 2),
            layout and layout.region_top or 132, 0xffffff, nil, "center")
    end
    for _, command in ipairs(view.stage or {}) do
        if command[1] == "sprite" then context.sprite(command[2], command[3], command[4], command[5], true)
        elseif command[1] == "fill" then
            if bounds and command[2] == 0 and command[4] == constants.screen.width then
                -- Stage shutters cover the whole window, including blocked scenery.
                context.clip(window_bounds.left, window_bounds.top,
                    window_bounds.right - window_bounds.left, window_bounds.bottom - window_bounds.top)
                context.fill(window_bounds.left, command[3],
                    window_bounds.right - window_bounds.left, command[5], 0, 0, 0)
                context.clip()
            else
                context.fill(command[2], command[3], command[4], command[5], 0, 0, 0)
            end
        elseif command[1] == "text" then
            -- The new fight screen shows Stage mode's status line in its stage panel and cards.
            if not (layout and command.status) then
                font.gdi(context, command[2], command[3], command[4], command[5] and colorref(command[5]))
            end
        elseif command[1] == "caption" then
            -- Outlined bitmap text in a team font (the original's four-way offset draw).
            for _, offset in ipairs({{-1, 1}, {-1, 0}, {0, 1}, {0, 0}}) do
                glyphs(context, "pe/words" .. command[5], command[2], command[3] + offset[1], command[4] + offset[2], 8)
            end
        end
    end
    if layout then
        fight_hud.draw_cards(context, current, layout)
        fight_hud.draw_bosses(context, layout)
    else
        draw_status(context, current)
    end
    if view.paused then
        context.image("pe/pause", 360, 288, true)
        -- A network game's settings menus hold the fight (base/game/match "menu_hold"): who holds it.
        if view.held_by then
            local names = {}
            for slot in view.held_by:gmatch("%d") do names[#names + 1] = controls.name(tonumber(slot)) end
            font.gdi(context, "Paused by " .. table.concat(names, ", ") .. " (settings menu)",
                math.floor(constants.screen.width / 2), 330, 0xffffff, nil, "center")
        end
        return
    end
    -- After the end loop: the demo's exit hint and DEMO picture, or the function-key line (GDI
    -- text; font.gdi stands in).
    if current.random_game then
        font.gdi(context, i18n.tr("Press F4 or 'Attack' to exit"), 0x262, 0x6e, 0x7d7d7d)
        font.gdi(context, "http://www.LittleFighter.com", 5, 0x6e, 0xc8c8c8)
        context.image("pe/demo", 0x168, 0x120, true)
    elseif current.cheat_lock == 1 then
        local counts = current.function_counts
        local text = i18n.tr("Function Keys Used:    F6: %d time(s)    F7: %d time(s)    F8: %d time(s)    F9: %d time(s)",
            counts[6], counts[7], counts[8], counts[9])
        if current.mode == constants.modes.stage then
            context.fill(0, 128, constants.screen.width, 21, 0, 0, 0)
            font.gdi(context, text, 0, 129)
        else
            font.gdi(context, text, 0, 109)
        end
    elseif current.cheat_lock == 2 then
        font.gdi(context, i18n.tr("Function Keys Locked"), 0, 109)
    end
    draw_scoreboard(context, current)
    local replaying = current.replay and not current.replay_ended
    if replaying then
        context.sprite("pe/menu_clip4", {2, 586, 725, 12}, 0x43, 0x216, false)
        if current.replay_status then replay_lines(context, current) end
    end
    mode_line(context, current, replaying)
end

return screen
