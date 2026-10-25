-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

local constants = require("base/game/constants")
local virtual_keys = constants.virtual_keys
-- Session-owned screen routing. Base screens and replacements share this API.
local title = require("base/ui/title")
local speed = require("base/game/speed")
local controls = require("base/ui/controls")
local music = require("base/game/music")
local recording = require("base/game/recording")
local catalog = require("base/game/catalog")
local font = require("base/ui/font")
local i18n = require("base/i18n/i18n")
local network = require("base/game/network")
local unlock = require("base/game/unlock")
local control = require("base/game/control")
local user_options = require("base/game/options")
local touch_gamepad = require("base/ui/touch_gamepad")
local quit_dialog = require("base/ui/quit_dialog")
local speed_menu = require("base/ui/speed_menu")
local damage_chart = require("base/ui/damage_chart")
local input_timeline = require("base/ui/input_timeline")
local chat = require("base/ui/chat")
local online = require("base/game/online")
local imgui = require("base/ui/imgui")
local fight_menu = require("base/ui/fight_menu")
local panels = require("base/ui/panels")
local fight_hud = require("base/ui/fight_hud")
local camera_view = require("base/ui/camera_view")
local ai_trace = require("base/ai/trace")
local flow = {}
local function screen_module(name)
    if name == "characters" then return require("base/ui/character_select") end
    if name == "setup" then return require("base/ui/setup_screen") end
    if name == "backgrounds" then return require("base/ui/background_preview") end
    if name == "match" then return require("base/ui/match_screen") end
    if name == "battle" then return require("base/ui/battle_setup") end
    if name == "championship" then return require("base/ui/championship") end
    if name == "ending" then return require("base/ui/ending") end
    if name == "network" then return require("base/ui/network") end
    if name == "launch" then return require("base/ui/launch") end
    if name == "versions" then return require("base/ui/versions") end
    if name == "online_lobby" then return require("base/ui/online_lobby") end
    if name == "online_menu" then return require("base/ui/online_menu") end
    return title
end
-- Whether the current screen reads key sets directly (not mouse/touch via base/ui/navigation);
-- the on-screen gamepad only has something to drive there ("full"); while a match is paused or
-- replaying only its pause button shows ("pause"); in a live match it shows too ("match").
local function gamepad_mode(state)
    if state.active == "launch" or state.active == "network" then return nil end
    if state.active == "match" then
        local match = state.match.match
        -- Paused or replaying: only the pause button stays, to resume.
        if match.replay and not match.replay_ended then return "pause" end
        if state.match.view and state.match.view.paused then return "pause" end
        return "match"
    end
    return "full"
end
-- The match setup screen replaces the title menu and the classic character selection, except with "Classic menus"
-- (or --classic-menus), in a server session whose server says so, and in the old two-computer game.
local function setup_screen_used(state)
    -- A server's session: every client uses the same screen, as the server says.
    if state.session and state.session.online then return not state.session.classic end
    return not state.session and not state.options.classic_menus and not user_options.current().classic_menus
end
-- The match setup screen in `mode` (the values of the last visit stay); in a server's session its clicks go to the
-- server as commands.
local function open_setup(state, mode)
    local session = state.session and state.session.online and state.session
    local last = session and not state.setup and session.last_setup
    state.setup = require("base/ui/setup_screen").create(mode or (state.setup and state.setup.setup.mode)
        or (last and tonumber(last.mode)) or constants.modes.versus, state.setup, session and {
            last_setup = last,
            send = function(command) online.send(session, {type = "command", command = command}) end,
            slot = session.slot, names = session.names, set_speed = function(tenths)
                online.send(session, {type = "set_speed", tenths = tenths}) end,
            -- The session's speed as the server announced it to every client (base/game/online "notice").
            get_speed = function() return session.speed or 10 end})
    state.active = "setup"
    state.wait_release = true
end
-- The title menu, or the match setup screen in its place (it has the modes, the championships, the demo and the
-- replays as buttons).
local function open_title(state)
    if setup_screen_used(state) then open_setup(state) else state.active = "title" end
end
local function screen_state(state)
    return state[state.active]
end
local function can_drop_replay(state)
    return not state.session and not state.quit_dialog and (state.active == "title"
        or (state.active == "launch" and state.launch.page == "menu"))
end
function flow.create(options)
    require("base/game/rollback").check = options.rollback_check == true
    if options.game_speed_tenths then speed.tenths = options.game_speed_tenths end
    require("base/game/netsim").params = require("base/game/netsim").parse(options.net_sim)
    -- --ai-log and --ai-brain (developer, docs/ai-plan.md): the AI log and the brain of local computer fighters.
    require("base/ai/trace").configure(options.ai_log)
    require("base/ui/ai_view").configure(options)
    if options.ai_brain then
        local brains = require("base/ai/brains")
        brains.default, brains.by_index = brains.parse(options.ai_brain)
    end
    local settings = controls.load(options.default_controller)
    -- OpenLF2's own options (base/game/options), e.g. the unlocked characters.
    user_options.start()
    music.seed(options.menu_seed)
    local state = {active = "launch", title = title.create(options), options = options,
        launch = require("base/ui/launch").create({menu_seed = options.menu_seed, problem = settings.problem}),
        pointer_x = 0, pointer_y = 0, previous_button = false, volume_frames = 0,
        touch_gamepad = touch_gamepad.create(user_options.current().gamepad, user_options.current().digipad), mouse_touch = false,
        -- Optional mouse input can stand in for touch while testing the on-screen gamepad.
        mouse_touch_enabled = options.mouse_touch == true, speed_keys = speed_menu.tracker(),
        chart = damage_chart.create(), timeline = input_timeline.create(), panels = panels.create()}
    music.play("bgm/main.wma")
    -- A startup recording is already queued by the host; route consumes it on the first frame.
    if options.start_screen == "replay" then state.active = "title" end
    -- Developer entry points requested by the host; not part of the original flow.
    if options.start_screen == "ending" then
        state.ending = require("base/ui/ending").create(0)
        state.active = "ending"
    end
    if options.start_screen == "backgrounds" then
        state.backgrounds = require("base/ui/background_preview").create()
        state.active = "backgrounds"
    end
    -- The server program (`--server`): no screens, only the server (base/game/server).
    if options.server_port then
        state.server = require("base/game/server").create(options)
        state.active = "server"
        return state
    end
    -- A client of a server program (`--connect`): the lobby first.
    if options.connect_address then
        state.online_lobby = require("base/ui/online_lobby").create(options, options.connect_address, options.connect_port)
        state.active = "online_lobby"
    end
    if options.network_role then
        state.network = require("base/ui/network").create(options)
        state.active = "network"
        state.network_cli = options.network_trace
        require("base/ui/network").begin(state.network, options.network_role == "host", options.network_address)
    end
    return state
end
local function with_recording(state, options)
    options.network = state.session ~= nil
    local settings = controls.current()
    if settings.record == 0 then return options end
    local names = {}
    for slot = 0, 7 do names[slot + 1] = controls.name(slot) end
    options.record = {names = names, version = state.options.recording_version or 0, time = engine.local_time(),
        music = music.selected and music.selected:gsub("/", "\\") or "", author = settings.author,
        info = settings.info, email = settings.email}
    return options
end
-- The title's Replay entry: a recording the player chose arrives from the host; after
-- data/version checks, the game starts at once.
local function start_replay(state, block)
    local replay, problem = recording.open(block, state.options.recording_version or 0)
    if not replay then
        recording.status = {kind = constants.recording_statuses.error, text = i18n.clip(i18n.tr(problem), 96), count = 0}
        return
    end
    controls.replace_names(replay.names)
    unlock.begin_replay(replay.unlock_characters, replay.unlock_function_keys)
    -- A replay plays the music of this computer's configuration, not the track of the recording (owner's decision).
    if replay.mode ~= constants.modes.stage and replay.music ~= "" then music.play_selected() end
    local options = {mode = replay.mode, difficulty = replay.difficulty, background = replay.background,
        stage_level = replay.stage_level, fighters = catalog.load(), backgrounds = catalog.backgrounds(), slots = {},
        replay = replay, battle = replay.battle, free_transform = replay.unlock_characters == 1}
    state.match = require("base/ui/match_screen").create(options)
    state.active = "match"
    state.wait_release = true
end
local function leave_replay(state)
    controls.replace_names(nil)
    unlock.end_replay()
    music.play("bgm/main.wma")
    speed.fast = false
    open_title(state)
    state.wait_release = true
end

-- Ends the session (a network connection, or a local game) and opens the launch menu with a clean state: the next
-- game starts as after a program start. `message` (or nil) shows on the launch menu.
local function disconnect(state, message)
    local online_session = state.session and state.session.online
    if online_session then online.close(state.session)
    elseif state.session then network.close(state.session) end
    -- A setup of a network game does not carry over to local games.
    if online_session then state.setup = nil end
    state.session, state.fight_menu = nil, nil
    controls.replace_names(nil)
    unlock.end_replay()
    state.active, state.wait_release = "launch", nil
    state.launch.page, state.launch.message = "menu", message
    state.title = title.create(state.options)
    state.characters, state.championship, state.championship_options, state.battle_config = nil, nil, nil, nil
    state.speed_menu, state.speed_release = nil, nil
    speed.fast = false
    music.play("bgm/main.wma")
    -- A server's session: the network menu, with the reason.
    if online_session then
        state.online_menu = require("base/ui/online_menu").create(state.options, message)
        state.active = "online_menu"
    end
end
-- The end of a server's session while connected (the title's Quit, or the server ended it): back to its lobby.
local function back_to_lobby(state)
    state.session, state.fight_menu, state.setup = nil, nil, nil
    controls.replace_names(nil)
    state.title = title.create(state.options)
    state.characters, state.championship, state.championship_options, state.battle_config = nil, nil, nil, nil
    state.speed_menu, state.speed_release = nil, nil
    speed.fast = false
    music.play("bgm/main.wma")
    state.active, state.wait_release = "online_lobby", true
end

local function route(state, input, context)
    if can_drop_replay(state) then
        local block, problem = engine.take_recording()
        if block then
            start_replay(state, block)
            return
        elseif problem then
            recording.status = {kind = constants.recording_statuses.error, text = i18n.tr("Loading error!  Recording file may be corrupted!!"), count = 0}
        end
    end
    if state.wait_release then
        if not controls.idle(input) then return end
        state.wait_release = false
    end
    local routed = {}
    for key, value in pairs(context) do routed[key] = value end
    local requested
    function routed.action(name)
        assert(not requested, "multiple screen actions in one update")
        requested = name
    end
    screen_module(state.active).update(screen_state(state), input, routed)
    -- A recording opened from a file manager or the command line owns this window.
    -- F4 and leaving its result screen finish that invocation.
    if state.options.start_screen == "replay" and state.active == "match"
       and state.match.match.replay and (requested == "title" or requested == "round_over") then
        context.action("quit")
        return
    end
    -- A server's session starts like the original's network game: the title menu, on the server's final ticks.
    if requested == "online_session" then
        state.network = {session = state.online_lobby.online}
        state.network.session.online = true
        requested = "network_ready"
    end
    -- The setup screen hands its choices to the classic selection, which the fight, the Stage progression and
    -- Battle mode's troop panel read.
    if state.active == "setup" and (requested == "start_match" or requested == "battle_setup") then
        -- A server keeps the values of the match for the next session of these players.
        local model = state.setup.setup
        if state.session and state.session.online then
            online.send(state.session, {type = "setup_used", mode = model.mode, difficulty = model.difficulty,
                background = model.background, stage_level = model.stage_level, free_transform = model.free_transform and 1 or 0})
        end
        state.characters = require("base/ui/setup_screen").selection(state.setup)
        if state.characters.mode == constants.modes.versus then music.play_selected() end
    end
    if requested == "settings" then
        state.fight_menu = fight_menu.create("sound")
        return
    end
    if requested == "versions" then
        state.versions = require("base/ui/versions").create(state.options)
        state.active = "versions"
        state.wait_release = true
    elseif requested == "network" and engine.messages then
        -- An engine with UDP messages plays through the server program (base/ui/online_menu); older ones keep the
        -- two-computer game below.
        state.online_menu = require("base/ui/online_menu").create(state.options)
        state.active = "online_menu"
    elseif requested == "network" then
        state.network = require("base/ui/network").create(state.options)
        state.active = "network"
    elseif requested == "network_ready" then
        -- Every client starts the session with the same setup (none from earlier local games).
        state.setup = nil
        unlock.reset_session()
        state.session = state.network.session
        controls.replace_names(state.session.names)
        state.title = title.create(state.options)
        if title.set_replay_disabled then title.set_replay_disabled(state.title, true) end
        open_title(state)
        state.wait_release = true
        -- A new connection starts a new deterministic menu session on both peers.
        state.characters, state.championship, state.championship_options, state.battle_config = nil, nil, nil, nil
        require("base/game/stage").set_random_list({constants.fighter_ids.deep,
            constants.fighter_ids.john, constants.fighter_ids.henry, constants.fighter_ids.rudolf,
            constants.fighter_ids.louis, constants.fighter_ids.davis, constants.fighter_ids.dennis,
            constants.fighter_ids.woody, constants.fighter_ids.freeze, constants.fighter_ids.firen}, -1)
        require("base/ui/demo").reset()
        recording.status = nil
        music.configure(user_options.current())
        music.selected = nil
        speed.fast = false
        music.play("bgm/main.wma")
    elseif requested == "online_connect" then
        -- Host or Join on the network screen: hosting starts the server program on this computer first, so the lobby
        -- tries to connect for a while (the server needs a moment to load the game data).
        local request = state.online_menu.request
        state.online_menu.request = nil
        if request.host then context.action("start_server") end
        state.online_lobby = require("base/ui/online_lobby").create(state.options, request.address,
            state.options.network_port or constants.network.default_port, request.host and 20000 or nil)
        state.active = "online_lobby"
    elseif requested == "launch" then
        state.active = "launch"
        state.session = nil
        controls.replace_names(nil)
    elseif (requested == "versus" or requested == "stage" or requested == "battle") and setup_screen_used(state) then
        open_setup(state, constants.modes[requested])
    elseif requested == "versus" or requested == "stage" or requested == "battle" then
        -- The previous visit's state carries the values the original keeps in globals.
        state.characters = require("base/ui/character_select").create({mode = requested,
            previous = state.characters, network = state.session ~= nil})
        state.active = "characters"
        state.wait_release = true
    elseif requested == "start_match" then
        local options
        if state.active == "battle" then
            options = require("base/ui/battle_setup").match_options(state.battle)
        elseif state.active == "championship" then
            options = require("base/ui/championship").match_options(state.championship)
        else
            options = require("base/ui/character_select").match_options(state.characters)
        end
        -- A server's session runs its fights with rollback (base/game/online).
        local online_session = state.session and state.session.online and state.session or nil
        state.match = require("base/ui/match_screen").create(with_recording(state, options), online_session)
        state.active = "match"
        state.wait_release = not online_session
    elseif requested == "championship" or requested == "team_championship" then
        state.championship_options = state.championship_options or (state.characters and state.characters.options)
            or {background = constants.background_rows.random, random_background = true, difficulty = 0}
        state.championship = require("base/ui/championship").create(state.championship_options,
            requested == "team_championship")
        state.active = "championship"
        state.wait_release = true
    elseif requested == "battle_setup" then
        local setup = require("base/ui/battle_setup")
        state.battle_config = state.battle_config or setup.create_config()
        state.battle = setup.create(state.characters, state.battle_config)
        state.active = "battle"
        state.wait_release = true
    elseif requested == "characters" and state.setup and setup_screen_used(state) then
        state.active = "setup"
        state.wait_release = true
    elseif requested == "characters" then
        -- Reset All / back from the Battle setup: the character menu starts over.
        state.characters = require("base/ui/character_select").reset_all(state.characters)
        state.active = "characters"
        state.wait_release = true
    elseif requested == "replay_error" then
        recording.status = {kind = constants.recording_statuses.error, text = i18n.tr("Recording file error! Replaying canceled!"), count = 0}
        leave_replay(state)
    elseif requested == "round_over" and state.match.match.replay then
        -- After a replay, the game returns to the title.
        leave_replay(state)
    elseif requested == "demo" or (requested == "round_over" and state.match.match.mode == constants.modes.demo) then
        if requested == "round_over" and not state.match.match.random_game then
            speed.fast = false
            music.play("bgm/main.wma")
            open_title(state)
        else
            music.play_selected()
            state.match = require("base/ui/match_screen").create(require("base/ui/demo").match_options(state.characters))
            state.active = "match"
        end
        state.wait_release = true
    elseif requested == "round_over" then
        local outcome = require("base/ui/match_screen").outcome(state.match)
        local selection = require("base/ui/character_select")
        if state.match.match.mode == constants.modes.championship
           or state.match.match.mode == constants.modes.team_championship then
            require("base/ui/championship").round_over(state.championship, state.match.match)
            state.active = "championship"
        elseif state.characters.mode == constants.modes.battle then
            state.battle = require("base/ui/battle_setup").create(state.characters, state.battle_config)
            state.battle.state = constants.battle_setup_states.options
            state.active = "battle"
        elseif outcome.ending then
            state.ending = require("base/ui/ending").create(state.match.match.difficulty)
            state.active = "ending"
        elseif outcome.auto_start then
            state.characters = selection.resume_options(state.characters, outcome)
            state.match = require("base/ui/match_screen").create(with_recording(state, selection.match_options(state.characters)))
            state.active = "match"
        elseif state.setup and setup_screen_used(state) then
            -- The setup screen again, with the Results buttons; a lost stage starts at the stage the players reached.
            state.setup = require("base/ui/setup_screen").after_fight(state.setup)
            if outcome.stage_level then state.setup.setup.stage_level = outcome.stage_level - outcome.stage_level % 10 end
            state.active = "setup"
        else
            state.characters = selection.resume_options(state.characters, outcome)
            state.active = "characters"
        end
        state.wait_release = true
    elseif requested == "game_start" then
        music.play("bgm/main.wma")
        open_title(state)
        if state.active == "title" and title.latch_input then title.latch_input(state.title, input)
        else state.wait_release = true end
    elseif requested == "title" then
        if not state.session then controls.replace_names(nil) end
        unlock.end_replay()
        music.play("bgm/main.wma")
        open_title(state)
        -- Do not turn the key returning to the title into a new title action.
        state.wait_release = true
    elseif requested == "quit" and (state.active == "title" or state.active == "setup") then
        -- The title's Quit (OpenLF2 change): the original closes the program here, OpenLF2 goes back to the launch
        -- menu, whose Exit closes it. In a network game both computers choose it on the same frame and each closes
        -- its side of the connection. In a server's session every client chooses it on the same tick and goes back to
        -- the lobby, still connected.
        if state.session and state.session.online then
            online.send(state.session, {type = "lobby_return"})
            back_to_lobby(state)
        else
            disconnect(state, nil)
            state.wait_release = true
        end
    elseif requested then context.action(requested) end
end
function flow.describe(state)
    if state.server then return require("base/game/server").describe(state.server) end
    local module = screen_module(state.active)
    local detail = module.describe and module.describe(screen_state(state)) or ""
    local status = recording.status_text()
    local unlocked = unlock.describe()
    return (state.session and "network_frames=" .. state.session.frames .. " " or "") .. "screen=" .. state.active .. (detail ~= "" and " " .. detail or "") .. (status and " status=" .. status or "")
        .. (unlocked and " unlock=" .. unlocked or "") .. (speed.tenths < 10 and " speed=" .. speed.tenths / 10 or "")
        .. (state.speed_menu and " speed_menu" or "")
end
-- The runtime stops a frame with too many commands: 1048576 in this runtime (engine.frame_command_limit), 4096 in
-- older ones (such as the released Windows build that a joining player may run). A busy fight (battle mode's
-- soldiers) and the OpenLF2 overlays drawn on top of it could get there, so the frame's commands are counted and
-- those past a safe share of the limit are left out: the last overlays lose detail instead of the game stopping.
-- (Some runtime commands, such as translated text, add commands of their own, hence the margin.)
local command_budget = math.floor((engine.frame_command_limit or 4096) * 0.92)
local function budgeted(context)
    local used = 0
    local limited = {}
    for name, command in pairs(context) do
        if type(command) == "function" then
            limited[name] = function(...)
                if used >= command_budget then return end
                used = used + 1
                return command(...)
            end
        else
            limited[name] = command
        end
    end
    return limited
end
-- The mouse pointer (OpenLF2 extension): every screen's pointer image (pe/lf2_cursor) shows where this computer's
-- mouse really is, also in a network game, whose exchanged input has no pointer. Screens without a pointer of their
-- own (the character selection, the fight) show it for three seconds after the mouse moves. It follows the system
-- mouse over the whole window, also over the bars at the sides of the picture (where the coordinates are below 0 or
-- past the picture), and it hides while the mouse is outside the window (the platform's pointer -1,-1). Drawing only:
-- the screens' own logic keeps the pointer it always had.
local pointer_shown_ms = 3000
-- The connection to a server program while its lobby or its session shows (base/game/online), and whether the
-- session shows (it has the chat window of base/ui/chat; the lobby has its own chat panel).
local function online_connection(state)
    if state.session and state.session.online then return state.session, true end
    if state.active == "online_lobby" and state.online_lobby then return state.online_lobby.online, false end
    return nil
end
-- A dropped player: the game waits for them, and any player can choose another way (base/game/server "drop_choice").
local function draw_drops(state, context, connection)
    imgui.window(context, "drops", i18n.tr("The game waits"), 197, 0, 400, 0)
    for slot, drop in pairs(connection.drops) do
        if drop.catching then
            -- A player who came back (or a resumed game): its computer runs the ticks so far.
            imgui.text(context, i18n.tr("%s is back. Their game catches up:", drop.name), nil, imgui.wrap)
            imgui.progress(context, (drop.percent or 0) / 100, string.format("%d %%", drop.percent or 0), -1)
        else
            local waited = math.floor((engine.network_time() - drop.since) / 1000)
            imgui.text(context, i18n.tr("%s lost the connection. The game waits for them (%d s).", drop.name, waited), nil, imgui.wrap)
            if not connection.spectator then
                imgui.text(context, i18n.tr("Or any player chooses:"), 0x8090c0)
                imgui.button(context, "drop_computer_" .. slot, i18n.tr("Let the computer play"), -1, 26)
                for _, player in ipairs(connection.lobby and connection.lobby.players or {}) do
                    imgui.button(context, "drop_give_" .. slot .. "_" .. player.id, i18n.tr("Give the fighter to %s", player.name), -1, 26)
                end
                imgui.button(context, "drop_stop_" .. slot, i18n.tr("Stop and resume later"), -1, 26)
            end
        end
        imgui.spacing(context, 4)
    end
    imgui.end_window(context)
end
-- This computer runs the session's ticks so far: a window with its progress.
local function draw_catch_up(context, fraction)
    imgui.window(context, "catch_up", i18n.tr("Catching up with the game"), 197, 0, 400, 0)
    imgui.text(context, i18n.tr("Your game runs the moves of the session so far. The others wait."), nil, imgui.wrap)
    imgui.progress(context, fraction, string.format("%d %%", math.floor(fraction * 100)), -1)
    imgui.end_window(context)
end
-- What the settings menu (base/ui/fight_menu) shows: this computer's human fighters, the speed, the cheat keys.
local function menu_env(state)
    local fight = state.active == "match" and state.match and state.match.match
    local session = state.session and state.session.online and state.session
    local env = {online = session and true or false, fight = fight and not fight.replay and true or false,
        mode = fight and fight.mode, speed = session and (session.speed or 10) or speed.tenths, speed_shared = session and true or false,
        cheat_keys = unlock.flags.function_keys == 1, cheats_online = false, fighters = {}, panels = state.panels}
    if env.fight then
        local slots = session and {session.slot} or {0, 1, 2, 3, 4, 5, 6, 7}
        for _, slot in ipairs(slots) do
            local value = fight.items[slot]
            if value and value.human then
                local name = session and session.names and session.names[slot + 1] or controls.name(slot)
                env.fighters[#env.fighters + 1] = {slot = slot, name = name ~= "" and name or tostring(slot + 1),
                    ai = value.ai_control == true}
            end
        end
    end
    return env
end
-- A short line about the screens and the network session, which the tests read from a window (OPENLF2_PROBE=1:
-- the flow logs it every 15 frames).
-- --ai-book all|ID (developer, docs/ai-plan.md phase 2): the move book of every fighter (or of one fighter id) as log
-- lines, and the time that the books took to build. tools/lf2_moves.py --check compares the lines with the data files.
function flow.move_book_lines(wanted)
    local move_book = require("base/ai/move_book")
    local item = require("base/game/item")
    local object_data = require("base/game/object_data")
    local records = {}
    for _, fighter in ipairs(catalog.load()) do
        if fighter.id ~= constants.fighter_ids.template and (wanted == "all" or tonumber(wanted) == fighter.id) then
            records[#records + 1] = item.record({id = fighter.id, kind = constants.record_kinds.character}, object_data.load(fighter.path))
        end
    end
    -- The object files (balls and other spawned objects) load first: the game loads them anyway when they spawn, so
    -- `ms` is the time of the books alone.
    local loading = engine.network_time()
    for _, entry in ipairs(catalog.objects().list) do
        if entry.kind ~= constants.record_kinds.character then object_data.load(entry.path) end
    end
    local load_ms = engine.network_time() - loading
    local started = engine.network_time()
    local books = {}
    for _, record in ipairs(records) do books[#books + 1] = move_book.get(record) end
    local elapsed = engine.network_time() - started
    local lines, moves = {}, 0
    for _, book in ipairs(books) do
        for _, line in ipairs(move_book.lines(book)) do
            -- An engine log line holds at most 512 bytes.
            lines[#lines + 1] = #line > 500 and line:sub(1, 500) or line
        end
        moves = moves + #book.moves
    end
    lines[#lines + 1] = string.format("book done fighters=%d moves=%d ms=%d load_ms=%d", #books, moves, elapsed, load_ms)
    return lines
end

function flow.probe(state)
    local connection = online_connection(state)
    local parts = {"probe screen=" .. state.active}
    if connection then
        parts[#parts + 1] = string.format("online=%s chat_open=%s chat_lines=%d taunts_played=%d chat_release=%s",
            connection.phase, tostring(state.chat and state.chat.open or false), #connection.chat,
            connection.taunts_played or 0, tostring(state.chat and state.chat.release or false))
    end
    if state.fight_menu then parts[#parts + 1] = fight_menu.describe(state.fight_menu) end
    if connection and connection.drops and next(connection.drops) then parts[#parts + 1] = "drop" end
    local fight = state.active == "match" and state.match and state.match.match
    if fight then
        local computer = {}
        for slot = 0, 7 do
            if fight.items[slot] and fight.items[slot].ai_control then computer[#computer + 1] = tostring(slot) end
        end
        if #computer > 0 then parts[#parts + 1] = "computer_controls=" .. table.concat(computer, ",") end
        if fight.paused then parts[#parts + 1] = "paused" end
        local view = state.match.camera_view
        if view and view.width then
            parts[#parts + 1] = string.format("camera=%d,%d,zoom=%s", math.floor(view.center), math.floor(view.width),
                view.zoom and tostring(view.zoom) or "auto")
        end
    end
    return table.concat(parts, " ")
end
-- The layout for the panels (base/ui/panels): the new fight screen's (base/ui/fight_hud, kept by the match screen
-- when it draws), or the classic picture.
local function panel_layout(state)
    if state.active ~= "match" then return nil end
    if user_options.current().battlefield_layout == "modern" then return state.match.hud_layout end
    return fight_hud.classic_layout()
end
-- The panels on the screen now: the stage panel in Stage mode, the minimap on the new fight screen.
local function panel_ids(state)
    local ids = {"chart", "timeline"}
    local layout = panel_layout(state)
    if layout and state.match.stage_info then ids[#ids + 1] = "stage" end
    if layout and layout.view_width then ids[#ids + 1] = "minimap" end
    return ids
end
local function draw_panels(state, context)
    local layout = panel_layout(state)
    if not layout then return end
    local shown = state.panels
    if state.chart.match and panels.shown(shown, "chart") then
        damage_chart.draw(state.chart, context, panels.rect(shown, "chart", layout))
    end
    if panels.shown(shown, "timeline") then
        local x, y = panels.rect(shown, "timeline", layout)
        input_timeline.draw(state.timeline, context, x, y)
    end
    local current = state.match.match
    local info = state.match.stage_info
    if info and panels.shown(shown, "stage") then
        local x, y, width, height = panels.rect(shown, "stage", layout)
        fight_hud.draw_stage_panel(context, info, x, y, width, height)
        panels.draw_handle(context, x, y, width, height)
    end
    if layout.view_width and panels.shown(shown, "minimap") then
        local x, y, width, height = panels.rect(shown, "minimap", layout)
        fight_hud.draw_minimap(context, current, info, x, y, width, height, layout.view_left, layout.view_width)
        panels.draw_handle(context, x, y, width, height)
    end
end
-- The shared state of the screens of a server's session as text, for the menus' desync check (base/game/online
-- menu_check): the screen, its state (the setup screen's without this computer's focus) and the random streams.
local function shared_summary(state)
    local parts = {"screen=" .. tostring(state.active)}
    local module = screen_module(state.active)
    if state.active == "setup" then parts[#parts + 1] = module.shared_describe(state.setup)
    elseif module.describe then parts[#parts + 1] = module.describe(screen_state(state)) end
    local index, sequence, crt = engine.random_position()
    parts[#parts + 1] = string.format("random=%d,%d,%d", index, sequence, crt)
    return table.concat(parts, " ")
end
-- Screens drawn with Dear ImGui (base/ui/imgui), which draws its own pointer.
local imgui_screens = {online_menu = true, online_lobby = true, setup = true}
local function pointer_position(state)
    return state.local_pointer_x, state.local_pointer_y + 2
end
function flow.draw(state, context)
    -- The server draws nothing, but the runtime expects a viewport on every frame.
    if state.server then return context.viewport(constants.screen.width, constants.screen.height, 0, 0, 0) end
    context = budgeted(context)
    -- A screen's pointer is drawn last, over the whole window (see draw_pointer).
    local pointer_drawn = false
    local draw_image = context.image
    context.image = function(resource, x, y, keyed)
        if resource == "pe/lf2_cursor" then
            pointer_drawn = true
            return
        end
        return draw_image(resource, x, y, keyed)
    end
    context.replay_drop(can_drop_replay(state))
    local shown_options = user_options.current()
    context.render_filter(shown_options.upscaling_filter)
    -- Fullscreen (OpenLF2 extension): no-op without a real window; reasserted every frame
    -- like the filter above.
    context.fullscreen(shown_options.fullscreen)
    if state.active == "match" and shown_options.battlefield_layout ~= "classic" then
        screen_module(state.active).draw(screen_state(state), context, state.window_bounds,
            {mode = shown_options.battlefield_layout, widest = shown_options.camera_widest / 100,
             zoom = shown_options.camera_zoom})
    else
        screen_module(state.active).draw(screen_state(state), context)
    end
    -- The on-screen gamepad draws on top of every screen it drives; hidden while paused (it
    -- would sit under the PAUSE picture).
    if gamepad_mode(state) then
        state.touch_gamepad.fast_on = speed.fast
        touch_gamepad.draw(state.touch_gamepad, context)
    end
    local status = recording.status_text()
    if status then font.gdi(context, i18n.clip(status, 128), 3, 0x213, recording.status_color())
    elseif state.volume_text then font.gdi(context, state.volume_text, 3, 0x213, 0x00ff00) end
    -- Show FPS (OpenLF2 extension): centered on the statusbar line so it never overlaps the
    -- left-aligned text.
    if shown_options.show_fps and state.fps then
        local fps_text = "FPS: " .. state.fps
        font.gdi(context, fps_text, math.floor((constants.screen.width - font.gdi_width(fps_text)) / 2), 0x213)
    end
    -- The connection of a server's session (docs/netcode.md "What players see"): the round trip, and in a fight the
    -- input delay, the rollbacks and the waits.
    local session = state.session and state.session.online and state.session
    if session and shown_options.show_connection and session.rtt then
        local text = string.format("ping %d ms", math.floor(session.rtt + 0.5))
        local client = state.active == "match" and session.client
        if client then
            text = text .. string.format("  delay %d  rollbacks %d  waits %d", client.delay or 0, client.stats.rollbacks,
                client.stats.stalls)
        end
        if session.spectator then text = text .. "  " .. i18n.tr("watching") end
        font.gdi(context, text, constants.screen.width - font.gdi_width(text) - 4, 0x213 - 14, 0x9fd0ff)
    end
    if state.active == "match" then draw_panels(state, context) end
    local connection, fighting = online_connection(state)
    if fighting and state.chat then chat.draw(state.chat, context, connection) end
    if state.fight_menu then fight_menu.draw(state.fight_menu, context, menu_env(state)) end
    if fighting and connection.catch_fraction then
        draw_catch_up(context, connection.catch_fraction)
    elseif fighting and connection.drops and next(connection.drops) then
        draw_drops(state, context, connection)
    end
    if state.speed_menu then speed_menu.draw(state.speed_menu, context) end
    if state.quit_dialog then quit_dialog.draw(state.quit_dialog, context) end
    -- The pointer: where the screen drew one, or for a while after the mouse moved. A menu of Dear ImGui that takes
    -- clicks (the settings menu, an open chat line) draws its own pointer.
    local recent = engine.network_time() - (state.pointer_moved_at or -pointer_shown_ms) < pointer_shown_ms
    if state.local_pointer_x and (pointer_drawn or (recent and not imgui_screens[state.active]))
       and not state.fight_menu and not state.chat_open then
        local x, y = pointer_position(state)
        if context.overlay then context.overlay(true) end
        draw_image("pe/lf2_cursor", x, y, true)
    end
end
-- Whether Escape (and Android's back button, which the platform reports as Escape) is free to ask about leaving
-- the game: not in a network game, where it disconnects, not on the network and versions screens, where it goes back,
-- and not on the launch screen's pages that use it.
local function escape_free(state)
    if state.session or state.active == "network" or state.active == "versions" or imgui_screens[state.active] then
        return false
    end
    if state.active == "match" and state.match.online then return false end
    if state.active == "launch" then return state.launch.page == "menu" end
    return true
end
local function merged_letters(into, from)
    for letter in from:gmatch(".") do
        if not into:find(letter, 1, true) then into = into .. letter end
    end
    return into
end
-- The keys of a player slot, for fight_due, in a fixed order so that two states compare as strings.
local key_letters = {"u", "d", "l", "r", "c", "b", "f"}
-- Changes at most this many frames after the previous one merge into one state ("pressed together").
local merge_frames = 1
-- The most states that wait; more merge the two oldest, so the lag stays under this many key reads.
local state_queue_limit = 3
local function key_state(held)
    local letters = {}
    for _, letter in ipairs(key_letters) do
        if held:find(letter, 1, true) then letters[#letters + 1] = letter end
    end
    return table.concat(letters)
end
-- The game speed menu's setting (base/ui/speed_menu): a fight runs on `speed.tenths` of every ten frames, spread
-- evenly, and it reads the players' keys on every second frame that runs (input_phase in base/game/match). The keys
-- reach it through a queue of whole key states per player slot, like lf2-arena's: each change of a slot's keys is
-- queued with its frame, a change at most one frame after the previous one merges into it (keys pressed together,
-- such as defend, up and attack, stay one state), and each read takes the oldest state. A merge that would erase a
-- change (a press and release in two frames) queues it instead, so a short tap still counts. More than three
-- waiting states merge the two oldest, so the lag stays under three reads. Function keys of skipped frames are added
-- to the next frame that runs. F4 always runs a frame, so a stopped fight can still be left. A network game runs
-- the host's speed from the exchanged input, so both peers skip the same frames and queue the same keys.
local function fight_due(state, input)
    local tenths = state.session and (input.speed_tenths or 10) or speed.tenths
    -- While the flow waits for the keys to be let go (a screen has just changed), the fight does not run: the keys
    -- pass through as they are, so the wait can end, and the buffer starts afresh after it.
    -- A fight of a server program runs on the server's ticks (base/game/online), not on this computer's speed.
    if state.active ~= "match" or tenths >= 10 or state.wait_release or state.match.online then
        state.speed_progress, state.speed_held, state.speed_input = 0, nil, nil
        return true
    end
    state.speed_progress = (state.speed_progress or 0) + tenths
    local due = state.speed_progress >= 10 or input.functions:find("4", 1, true) ~= nil
    local keys = state.speed_input
    if not keys then
        keys = {frame = 0, slots = {}}
        for slot = 0, 7 do keys.slots[slot] = {given = key_state(input[slot] or ""), queue = {}} end
        state.speed_input = keys
    end
    keys.frame = keys.frame + 1
    for slot = 0, 7 do
        local entry = keys.slots[slot]
        local queue = entry.queue
        local now = key_state(input[slot] or "")
        local tail = queue[#queue]
        if now ~= (tail and tail.keys or entry.given) then
            local before = queue[#queue - 1]
            before = before and before.keys or entry.given
            if tail and keys.frame - tail.frame <= merge_frames and now ~= before then
                tail.keys, tail.frame = now, keys.frame
            else
                queue[#queue + 1] = {keys = now, frame = keys.frame}
                if #queue > state_queue_limit then table.remove(queue, 1) end
            end
        end
    end
    local held = state.speed_held or {}
    local fields = {"functions", "function_presses"}
    if due then
        state.speed_progress = math.max(state.speed_progress - 10, 0)
        local reads = (state.match.match.input_phase + 1) % 2 == 0
        for slot = 0, 7 do
            local entry = keys.slots[slot]
            if reads and #entry.queue > 0 then entry.given = table.remove(entry.queue, 1).keys end
            input[slot] = entry.given
        end
        for _, field in ipairs(fields) do
            if held[field] then input[field] = merged_letters(input[field] or "", held[field]) end
        end
        -- The fight reads function keys on every second tick (base/game/match "note_function_keys"): on a tick that
        -- does not read them, they stay for the next one that runs.
        local waiting = input.functions ~= "" or (input.function_presses or "") ~= ""
        state.speed_held = not reads and waiting and {functions = input.functions,
            function_presses = input.function_presses} or nil
    else
        for _, field in ipairs(fields) do held[field] = merged_letters(held[field] or "", input[field] or "") end
        state.speed_held = held
    end
    return due
end
-- The settings menu's function keys (F1, F5, F6 to F9) are held for three frames: the fight reads the function keys
-- on every second tick, and a release clears a key that it has not read (base/game/match "note_function_keys").
local function hold_functions(state, input, again)
    local hold = state.function_hold
    if not hold then return end
    for letter in hold.keys:gmatch(".") do
        if not input.functions:find(letter, 1, true) then input.functions = input.functions .. letter end
    end
    -- A frame that waits for the server runs again: it does not count.
    if again then return end
    hold.frames = hold.frames - 1
    if hold.frames <= 0 then state.function_hold = nil end
end
-- A player's choice for a dropped player (base/game/server "drop_choice").
local function drop_choices(state, events)
    local session = state.session
    for slot in pairs(session.drops or {}) do
        local choice, to
        if events.clicked["drop_wait_" .. slot] then choice = "wait" end
        if events.clicked["drop_computer_" .. slot] then choice = "computer" end
        if events.clicked["drop_stop_" .. slot] then choice = "stop" end
        for _, player in ipairs(session.lobby and session.lobby.players or {}) do
            if events.clicked["drop_give_" .. slot .. "_" .. player.id] then choice, to = "give", player.id end
        end
        if choice then online.send(session, {type = "drop_choice", slot = slot, choice = choice, to = to}) end
    end
end
-- raw: the host's input; screens get it per player slot, with the last known pointer position
-- and `click`, a fresh press of the left button.
local update_frame
function flow.update(state, raw, context)
    local result = update_frame(state, raw, context)
    -- A return to a server's session, or a resumed one, runs the session's final ticks so far: the menus take up to
    -- 40 of them a frame, each through the whole update as on any frame, without keys and sounds (a fight catches up
    -- in base/game/rollback_client).
    local session = state.session
    if result == false or not (session and session.online) or online.backlog(session) <= 3 then return result end
    -- The held keys stay (Escape held through the catch-up toggles nothing); key presses and menu clicks count once.
    local quiet_raw = raw:sub(1, 1) == "k" and raw:gsub(" [pu][^ ]*", "") or raw:gsub("=[%w_]+:?%d*", "")
    -- Only actions pass: a frame takes each flag (speed, fullscreen and the others) once, and sounds would pile up.
    local quiet = {}
    for key, value in pairs(context) do quiet[key] = type(value) == "function" and function() end or value end
    quiet.action = context.action
    for _ = 1, 40 do
        if state.session ~= session or (state.active == "match" and state.match.online) or online.backlog(session) <= 3 then
            break
        end
        if update_frame(state, quiet_raw, quiet) == false then break end
    end
    -- The extra runs may wait for ticks; the next frame is no repeat of this one.
    state.exchange_waited = nil
    return result
end
update_frame = function(state, raw, context)
    if state.server then
        for _, line in ipairs(require("base/game/server").update(state.server, raw)) do context.action("log " .. line) end
        return
    end
    local input = controls.read(controls.current(), raw)
    i18n.host(input.filters and input.filters.text)
    -- Alt+Enter, from any screen: the fullscreen option flips (and is saved like the options page does).
    if input.toggle_fullscreen and input.filters and input.filters.window then
        local values = user_options.current()
        values.fullscreen = not values.fullscreen
        user_options.save(values)
        input.fullscreen_set = values.fullscreen
    end
    local shown_options = user_options.current()
    -- Local presentation data stays outside network and replay inputs.
    if shown_options.battlefield_layout ~= "classic" then
        state.window_bounds = input.screen or state.window_bounds
    else
        state.window_bounds = nil
    end
    -- The on-screen gamepad drives player 1's slot, merged here before a networked match sends
    -- input[0]. It only reads fingers on screens it drives, releasing/hiding otherwise.
    local mode = gamepad_mode(state)
    local active_screen = mode ~= nil
    -- Mouse-as-touch stays active after release, like a held touch; real input or touch ends it.
    -- The "Show gamepad" option shows the gamepad when a screen first drives it and lets the mouse
    -- press it; keyboard or controller input hides it again until the mouse is used.
    local always_gamepad = shown_options.show_gamepad
    if not always_gamepad then
        state.gamepad_shown = false
    elseif active_screen and not state.gamepad_shown then
        state.gamepad_shown = true
        state.mouse_touch = true
    end
    local mouse_driven = state.mouse_touch_enabled or always_gamepad
    if mouse_driven and not input.touch_active then
        -- Presses are the key-downs since the last frame, so a tap that came and went still counts.
        local keyboard_or_pad = next(input.keys) ~= nil or next(input.gamepad) ~= nil or #(input.presses or {}) > 0
        for _, pad in ipairs(input.pads or {}) do
            if next(pad.dirs) ~= nil or next(pad.buttons) ~= nil then keyboard_or_pad = true end
        end
        if keyboard_or_pad then
            state.mouse_touch = nil
        elseif active_screen and input.button and input.pointer_x and input.pointer_y
               and not (input.pointer_x == -1 and input.pointer_y == -1) then
            state.mouse_touch = true
        end
    end
    if not mouse_driven then state.mouse_touch = nil end
    local gamepad_input = input
    if active_screen and state.mouse_touch and not input.touch_active then
        gamepad_input = {touch_active = true, screen = input.screen,
            touches = input.button and {{id = 0, x = input.pointer_x, y = input.pointer_y}} or {}}
    end
    -- Chord buttons are enabled by what player 1's fighter can do right now.
    local fighter = state.active == "match" and state.match and state.match.match and state.match.match.items[0] or nil
    local available = {}
    for _, chord in ipairs({"da", "dj", "daj"}) do available[chord] = control.chord_available(fighter, chord) end
    touch_gamepad.set_available(state.touch_gamepad, available)
    local touched, pause_held, fast_held = touch_gamepad.update(state.touch_gamepad,
        active_screen and gamepad_input or {touch_active = false, screen = input.screen}, mode)
    -- The pause button is F1; the match toggles on its press.
    if pause_held and state.active == "match" and not input.functions:find("1", 1, true) then
        input.functions = input.functions .. "1"
    end
    -- The fast-forward button is F5.
    if fast_held and state.active == "match" and not input.functions:find("5", 1, true) then
        input.functions = input.functions .. "5"
    end
    for _, letter in ipairs({"u", "d", "l", "r", "c", "b", "f"}) do
        if touched:find(letter, 1, true) and not input[0]:find(letter, 1, true) then input[0] = input[0] .. letter end
    end
    local local_keys = input.keys
    -- The camera's own keys of the new fight screen (this computer only, base/ui/camera_view): the mouse wheel, Page
    -- Up and Page Down zoom, Home goes back to the automatic camera. config.json keeps the zoom, written once the
    -- zoom rests for a second.
    if state.active == "match" and shown_options.battlefield_layout == "modern" then
        local held = state.camera_keys or {}
        local function fresh(code) return local_keys[code] and not held[code] end
        local view = state.match.camera_view or camera_view.create(shown_options.camera_zoom)
        state.match.camera_view = view
        local steps = (input.wheel or 0) * -1 + (fresh(0x21) and 1 or 0) - (fresh(0x22) and 1 or 0)
        if camera_view.keys(view, steps, fresh(0x24)) then state.zoom_rest = 30
        elseif not state.zoom_rest then
            -- A zoom set in the settings menu (its Automatic camera button).
            local saved = shown_options.camera_zoom > 0 and shown_options.camera_zoom or nil
            if view.zoom ~= saved then view.zoom = saved end
        end
        state.camera_keys = {[0x21] = local_keys[0x21], [0x22] = local_keys[0x22], [0x24] = local_keys[0x24]}
        if state.zoom_rest then
            state.zoom_rest = state.zoom_rest - 1
            if state.zoom_rest <= 0 then
                state.zoom_rest = nil
                local values = user_options.current()
                values.camera_zoom = view.zoom or 0
                user_options.save(values)
            end
        end
    end
    -- This computer's mouse, for drawing the pointer (see flow.draw); -1,-1 is a mouse outside the window.
    if input.pointer_x and input.pointer_y and not (input.pointer_x == -1 and input.pointer_y == -1) then
        if input.pointer_x ~= state.local_pointer_x or input.pointer_y ~= state.local_pointer_y then
            state.pointer_moved_at = engine.network_time()
        end
        state.local_pointer_x, state.local_pointer_y = input.pointer_x, input.pointer_y
    else
        state.local_pointer_x, state.local_pointer_y = nil, nil
    end
    -- The chat of a server program (base/ui/chat), in its lobby and its fights: while its line is open, it takes the
    -- keys, and the players' keys are held back.
    local connection, fighting = online_connection(state)
    state.chat_open = false
    if connection then
        state.chat = state.chat or chat.create()
        state.chat_open = fighting and chat.update(state.chat, input, connection)
        if state.chat_open then
            state.escape_held = true
            for slot = 0, 7 do input[slot] = "" end
            input.functions, input.function_presses, input.keys, input.presses, input.text = "", "", {}, {}, ""
        end
    end
    -- The panels (base/ui/panels) follow the local mouse, before a network game exchanges input; V shows or hides
    -- the input timeline.
    if state.active == "match" then
        if input_timeline.toggled(state.timeline, input) then panels.toggle(state.panels, "timeline") end
        -- F10 shows or hides the development view of the AI (base/ui/ai_view).
        require("base/ui/ai_view").toggled(input)
        local layout = panel_layout(state)
        if layout then panels.pointer(state.panels, input, layout, panel_ids(state)) end
    end
    -- In a network game the match screen's camera follows this computer's fighters, and Tab picks whom to follow
    -- once they are all down (base/ui/match_screen, drawing only).
    if state.active == "match" then
        local follow = nil
        if state.session then follow = state.session.host and {0, 1, 2, 3} or {4, 5, 6, 7} end
        if state.session and state.session.online then follow = {state.session.slot} end
        state.match.follow = follow
        local tab = input.keys[virtual_keys.tab] == true
        if tab and not state.tab_held then state.match.follow_next = (state.match.follow_next or 0) + 1 end
        state.tab_held = tab
    end
    if state.session and not state.session.online then
        -- The game speed menu in a network game works on the local keys before they are sent. The game below keeps
        -- running (both peers must run the same frames), so the local players' keys are held back instead, while
        -- the menu is open and until the keys that closed it are let go; Escape closes it without disconnecting.
        local speed_keys = speed_menu.observe(state.speed_keys, input)
        -- The pointer and click are worked out further down only for the exchanged input, so the menu gets its own.
        local menu_input = {}
        for key, value in pairs(input) do menu_input[key] = value end
        if not (input.pointer_x and input.pointer_x >= 0 and input.pointer_y >= 0) then
            menu_input.pointer_x, menu_input.pointer_y = state.pointer_x, state.pointer_y
        end
        menu_input.click = input.button and not state.speed_button
        state.speed_button = input.button
        if state.speed_menu then
            if speed_menu.update(state.speed_menu, menu_input, context, speed_keys) == "close" then
                state.speed_menu, state.speed_release = nil, true
            end
        elseif speed_keys then
            state.speed_menu = speed_menu.create(not state.session.host)
        end
        if state.speed_release and controls.idle(input) and not input.keys[virtual_keys.escape]
           and not input.keys[virtual_keys.enter] then
            state.speed_release = nil
        end
        if state.speed_menu or state.speed_release then
            for slot = 0, 7 do input[slot] = "" end
            input.functions, input.function_presses = "", ""
        end
    end
    if state.session and state.session.online then
        -- A server's session: the server ended it, or the connection failed.
        local session = state.session
        if session.phase == "lobby" then
            back_to_lobby(state)
            return
        elseif session.phase ~= "session" then
            disconnect(state, session.problem or i18n.tr("Network game disconnected"))
            return
        end
        -- This run of the frame repeats one that waited for the server's tick (its menu clicks repeat in traces).
        local again = state.exchange_waited
        state.exchange_waited = nil
        -- Escape opens the settings menu (base/ui/fight_menu), with this computer's keys held back. Escape closes it
        -- again, or its question first. The menu does not stop the fight, and closing it does not resume a paused
        -- one: only F1 (also the menu's Pause button) pauses, as the original's pause key.
        local escape = input.keys[virtual_keys.escape] == true and not state.chat_open
        if escape and not state.escape_held then
            if not state.fight_menu then state.fight_menu = fight_menu.create()
            elseif state.fight_menu.confirm then state.fight_menu.confirm = nil
            else state.fight_menu = nil end
        end
        state.escape_held = input.keys[virtual_keys.escape] == true
        if state.fight_menu then
            local answer = fight_menu.update(state.fight_menu, input, menu_env(state))
            if answer and answer.leave then
                disconnect(state, nil)
                return
            end
            if answer and answer.control then state.control_request = {letter = answer.control[2], frames = 3} end
            if answer and answer.speed and not again then online.send(session, {type = "set_speed", tenths = answer.speed}) end
            if answer and answer.functions then state.function_hold = {keys = answer.functions, frames = 3} end
            if answer and answer.close then state.fight_menu = nil end
            for slot = 0, 7 do input[slot] = "" end
            input.functions, input.function_presses = "", ""
        end
        hold_functions(state, input, again)
        drop_choices(state, imgui.events(input))
        session.catch_fraction = online.catch_up(session)
        -- A fight runs with rollback in its screen (base/ui/match_screen); the menus take one final tick a frame.
        if not (state.active == "match" and state.match.online) then
            -- This computer's clicks stay with the input: the setup screen sends them to the server as commands. The
            -- clicks of runs that wait for a tick collect until a tick comes (a repeated click counts once).
            if input.ui then
                local pending = state.pending_ui or {clicked = {}, changed = {}, submitted = {}}
                for kind, list in pairs(input.ui) do
                    for id, value in pairs(list) do pending[kind][id] = value end
                end
                state.pending_ui = pending
            end
            local combined, problem = online.exchange(session, input)
            if problem then
                disconnect(state, problem)
                return
            elseif not combined then
                state.exchange_waited = true
                return false
            else
                combined.ui, state.pending_ui = state.pending_ui, nil
                input = combined
                state.menu_tick = session.next_tick - 1
            end
        end
    elseif state.session then
        unlock.observe(input)
        if not state.session.pending then input.unlock_bits = unlock.take_pending() end
        if input.keys[virtual_keys.escape] and not (state.speed_menu or state.speed_release) then
            disconnect(state, i18n.tr("Network game disconnected"))
        else
            local hp = state.active == "match" and recording.hp_sum(state.match.match) or 0
            local combined, problem = network.exchange(state.session, input, hp)
            if problem then
                disconnect(state, problem)
            elseif not combined then return false
            else input = combined end
        end
    end
    speed.network_tenths = state.session and input.speed_tenths or nil
    local joining_cli = state.network_cli and state.active == "network"
    if input.pointer_x and input.pointer_x >= 0 and input.pointer_y >= 0 then
        state.pointer_x, state.pointer_y = input.pointer_x, input.pointer_y
    end
    input.pointer_x, input.pointer_y = state.pointer_x, state.pointer_y
    -- Renderer capability flags are kept for frames that don't repeat them.
    if input.filters then state.filters = input.filters end
    input.filters = state.filters or {}
    input.click = input.button and not state.previous_button
    state.previous_button = input.button
    -- Unlock words: typed marks are taken before the screen runs, except during a replay
    -- (recorded bits act instead); a recording match stores the frame's bits.
    if not state.session then unlock.observe(input) end
    local current = state.active == "match" and state.match and state.match.match
    if not (current and current.replay and not current.replay_ended) then
        local bits, played
        if input.network then
            bits = input.unlock_bits or 0
            played = unlock.apply_recorded(bits)
        else bits, played = unlock.take_marks() end
        for _, sound in ipairs(played) do context.sound(sound.resource, sound.volume, sound.pan) end
        -- A fight through the simulated network (base/game/netsim) changes only in its ticks; it records nothing.
        if current and not (state.match.netsim or state.match.online) then current.unlock_bits = bits end
    end
    local escape_pressed = false
    for _, code in ipairs(input.presses or {}) do
        if code == virtual_keys.escape then escape_pressed = true end
    end
    if input.keys[virtual_keys.escape] and not state.escape_held then escape_pressed = true end
    state.escape_held = input.keys[virtual_keys.escape] == true
    local closed_now = false
    -- The game speed is a value of the settings menu (base/ui/fight_menu); the secret keys M, F, D of the speed menu
    -- stay only in the old two-computer game (above).
    local speed_keys = false
    if state.quit_dialog then
        -- While the question is open the screen below is frozen.
        local answer = quit_dialog.update(state.quit_dialog, input, context)
        if answer == "exit" and state.quit_dialog.kind == "leave" then
            -- Leaving the fight is F4, held for two frames after this one so that the match sees it on a frame that
            -- reads the keys (no wait for released keys here: a held F4 would never count as idle).
            state.pending_leave = 3
            state.quit_dialog, state.swallow_pointer, closed_now = nil, true, true
        elseif answer == "exit" then
            context.action("quit")
        elseif answer == "close" then
            -- The press that closed it must not reach the screen below: it skips this frame and then ignores the
            -- pointer button until it is released.
            state.quit_dialog, state.wait_release, state.swallow_pointer, closed_now = nil, true, true, true
        end
    elseif state.speed_menu and not state.session then
        -- Like the question above, the screen below is frozen while the menu is open.
        if speed_menu.update(state.speed_menu, input, context, speed_keys) == "close" then
            state.speed_menu, state.wait_release, state.swallow_pointer, closed_now = nil, true, true, true
        end
    elseif state.fight_menu and not state.session then
        -- The settings menu (base/ui/fight_menu) does not stop a local fight either: only F1 pauses it. The keys of
        -- this computer's players are held back while it is open; Escape closes it.
        local answer = fight_menu.update(state.fight_menu, input, menu_env(state))
        if escape_pressed then
            if state.fight_menu.confirm then state.fight_menu.confirm = nil else answer = {close = true} end
        end
        if answer then
            if answer.end_fight then state.pending_leave = 3 end
            if answer.control then state.control_request = {slot = answer.control[1], letter = answer.control[2], frames = 3} end
            if answer.functions then state.function_hold = {keys = answer.functions, frames = 3} end
            if answer.speed then speed.tenths = answer.speed end
            if answer.cheat_keys then unlock.mark_function_keys() end
            if answer.close then state.fight_menu, state.swallow_pointer = nil, true end
        end
        if state.fight_menu then
            for slot = 0, 7 do input[slot] = "" end
        end
    elseif speed_keys then
        state.speed_menu = speed_menu.create()
    elseif escape_pressed and escape_free(state) and state.active == "match" and not state.match.match.replay then
        state.fight_menu = fight_menu.create()
        for slot = 0, 7 do input[slot] = "" end
    elseif escape_pressed and escape_free(state) then
        state.quit_dialog = quit_dialog.create(state.active == "match" and "leave" or "exit")
    end
    if not state.session then hold_functions(state, input) end
    if state.pending_leave and not state.quit_dialog then
        if state.active == "match" and not input.functions:find("4", 1, true) then input.functions = input.functions .. "4" end
        state.pending_leave = state.pending_leave > 1 and state.pending_leave - 1 or nil
    end
    if state.swallow_pointer and not state.quit_dialog then
        if input.button then input.button, input.click = false, false else state.swallow_pointer = nil end
    end
    -- The input timeline watches this computer's first player with a fighter: the keys as held, and as the fight
    -- read them.
    local fight = state.active == "match" and state.match.match
    -- The old two-computer game gives the joiner slots 4 to 7; a server's session keeps this computer's keys in
    -- player 1's place of the input (its fight runs in base/game/online).
    local first_local = state.session and not state.session.online and not state.session.host and 4 or 0
    local watched = first_local
    if not (state.session and state.session.online) then
        for slot = first_local, first_local + 3 do
            if fight and fight.items[slot] and fight.items[slot].human then watched = slot; break end
        end
    end
    local held_keys, frame_before = input[watched], fight and fight.frame_number
    local reads = fight and (fight.input_phase + 1) % 2 == 0
    -- A held tick of a server session (a player dropped): the screens wait.
    if not state.quit_dialog and (state.session or not state.speed_menu) and not closed_now and not input.hold
       and fight_due(state, input) then
        -- The settings menu's "let the computer play": the control letter goes with the slot's keys for a few frames
        -- (base/game/match "read_control"), so a frame that runs no tick does not lose it. A server's session sends
        -- this computer's player 1 as its own slot.
        local request = state.active == "match" and state.control_request
        if request then
            local slot = state.session and state.session.online and 0 or request.slot
            input[slot] = (input[slot] or "") .. request.letter
            -- A paused fight reads no keys: the letter waits until it runs.
            local current = state.match.match
            if not (current and current.paused) then request.frames = request.frames - 1 end
            if request.frames <= 0 then state.control_request = nil end
        elseif state.active ~= "match" then
            state.control_request = nil
        end
        route(state, input, context)
        -- The menus' desync check: the shared state after this session tick goes to the server.
        local session = state.session and state.session.online and state.session
        if state.menu_tick and session and session.phase == "session" and state.active ~= "match" then
            online.menu_check(session, state.menu_tick, shared_summary(state))
        end
    end
    state.menu_tick = nil
    if fight and state.active == "match" and state.match.match == fight then
        local stepped = fight.frame_number ~= frame_before
        local waiting = state.speed_input and #state.speed_input.slots[watched].queue or nil
        input_timeline.record(state.timeline, fight, held_keys, stepped and reads and input[watched] or nil, stepped,
            waiting)
    end
    -- A fight through the simulated network shows the chart of its final ticks (base/game/netsim).
    if state.active == "match" then damage_chart.observe(state.chart, state.match.overlay_match or state.match.match) end
    if joining_cli then
        if state.network.session.error then error(state.network.session.error) end
        -- CLI traces start at the title; the handshake consumes no trace frames.
        return false
    end
    -- F11 and F12: a press changes the music volume by 10; a held key goes on by 2 a frame after a third second.
    local step = 0
    local direction = local_keys[virtual_keys.f11] and -1 or local_keys[virtual_keys.f12] and 1 or 0
    if direction ~= 0 then
        state.volume_held = (state.volume_held or 0) + 1
        if state.volume_held == 1 then step = 10 * direction
        elseif state.volume_held > 10 then step = 2 * direction end
    else
        state.volume_held = nil
    end
    if direction ~= 0 then
        if step ~= 0 then music.change_volume(step) end
        state.volume_frames = 100
        state.volume_changed = true
    elseif state.volume_changed then
        -- F11 and F12 change the music volume of this computer's configuration, saved once the keys are let go.
        local values = user_options.current()
        values.music_volume = music.master
        user_options.save(values)
        state.volume_changed = nil
    end
    state.volume_text = nil
    if state.volume_frames > 0 then
        state.volume_text = i18n.tr("Music volume: %d", music.master)
        state.volume_frames = state.volume_frames - 1
    end
    music.flush(context)
    -- Taunts play here: the commands of a frame that waits for the server are not used, and its sounds would be lost.
    local taunting = online_connection(state)
    if taunting and state.chat then chat.play_taunts(taunting, context) end
    if state.options.probe then
        state.probe_frames = (state.probe_frames or 0) + 1
        if state.probe_frames % 15 == 0 then context.action("log " .. flow.probe(state)) end
    end
    -- The AI log, here for the same reason as the taunts.
    ai_trace.flush(context, state.active ~= "match" or state.match.match.finished)
    if state.options.ai_book and not state.ai_book_written then
        state.ai_book_written = true
        for _, line in ipairs(flow.move_book_lines(state.options.ai_book)) do context.action("log " .. line) end
    end
    recording.tick_status(state.active == "match" and state.match.match.paused)
    context.speed(speed.fast)
    -- Show FPS (OpenLF2 extension): measured FPS, nil for a trace unless given; drawn in flow.draw.
    state.fps = input.fps
end
return flow
