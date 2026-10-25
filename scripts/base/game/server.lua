-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 OpenLF2 contributors

-- The server program (OpenLF2 extension, docs/netcode.md and docs/ui-network-architecture.md; `openlf2 --server`).
-- It keeps a lobby of the connected players. When the player with the room role starts and everybody is ready, a
-- session begins: the whole game (title menu, character selection, fights, results) runs on every client from the
-- same ticks. The server is the authority of these ticks (base/game/authority): the clients send their keys, the
-- server makes each tick final at its deadline, never waiting for a client, and sends the final ticks to everybody.
-- The clients run the menus on final ticks and the fights with rollback. It runs without a window, a frame on each
-- message and at least every 4 ms.
local constants = require("base/game/constants")
local authority = require("base/game/authority")
local wire = require("base/game/wire")
local ticks = require("base/game/ticks")
local network = require("base/game/network")
local server = {}

-- The version of these messages; a client with another one cannot join.
server.protocol = 2
local reliable, unreliable = 0, 1
local max_players = 8
-- A session starts this long after the start command, so that every client has the session message first.
local start_delay_ms = 1000
-- Chat: printable text up to 120 characters, at most 5 messages in 5 seconds for each player.
local chat_length, chat_burst, chat_window_ms = 120, 5, 5000
-- A dropped player (plan.md "Drops, returns and AI control"): after this long without a message from a player of a
-- session, the ticks are held (nothing advances) and the room role chooses: wait, the computer plays, another player
-- takes the fighter, or stop and resume later. Without a choice, the computer plays after `decide_ms`.
local drop_ms, decide_ms = 3000, 30000
-- The final ticks of a session go to a returning player in parts of this many ticks.
local log_chunk = 300
local tick_ms = 33

-- Rooms (docs/netcode.md "Rooms"): each room has its own lobby and session; the functions below take the room as
-- `state`. The main room always exists; a player can make a private room, which others join with its code.
local function new_room(top, code, private)
    -- classic: the sessions use the classic character selection (--classic-menus, for the input traces of the
    -- original menus); otherwise they use the match setup screen.
    return {top = top, code = code, private = private, profile = top.profile, version = top.version, players = {},
        order = {}, phase = "lobby", hashes = {}, saved = server.load_saved(), classic = top.classic, spectators = {}}
end
-- options: the runtime settings (server_port, network_profile).
function server.create(options)
    local listening, problem = engine.messages("listen", "0.0.0.0", options.server_port, 64)
    assert(listening, problem)
    local top = {profile = options.network_profile, version = network.own_version() or "", classic = options.classic_menus == true,
        rooms = {}, peers = {}, log = {}, next_code = engine.network_time() % 1000003 + 7}
    top.rooms.main = new_room(top, "main", false)
    return top
end

local function log(state, text)
    local top = state.top or state
    top.log[#top.log + 1] = (state.code and state.code ~= "main" and "[" .. state.code .. "] " or "") .. text
end
local function send(peer, message, channel)
    engine.messages("send", peer, channel or reliable, wire.encode(message))
end
local function broadcast(state, message, channel)
    for _, peer in ipairs(state.order) do send(peer, message, channel) end
    for peer in pairs(state.spectators or {}) do send(peer, message, channel) end
end

-- The lobby as every client sees it.
local function lobby_message(state)
    local players = {}
    for position, peer in ipairs(state.order) do
        local player = state.players[peer]
        players[position] = {id = peer, name = player.name, slot = player.slot, ready = player.ready, role = position == 1}
    end
    local top = state.top or state
    local rooms = {}
    for code, room in pairs(top.rooms or {}) do
        if not room.private then
            local watching = 0
            for _ in pairs(room.spectators) do watching = watching + 1 end
            rooms[#rooms + 1] = {code = code, players = #room.order, watching = watching, phase = room.phase}
        end
    end
    table.sort(rooms, function(a, b) return a.code < b.code end)
    return {type = "lobby", players = players, phase = state.phase, public_address = top.public_address,
        upnp = top.upnp, resume = server.can_resume(state), room = state.code, private = state.private or nil, rooms = rooms}
end
-- Every room's lobby: the list of rooms changes for all of them.
local function broadcast_lobby(state)
    local top = state.top or state
    for _, room in pairs(top.rooms or {[1] = state}) do broadcast(room, lobby_message(room)) end
end

local function free_slot(state)
    for slot = 0, max_players - 1 do
        local taken = false
        for _, player in pairs(state.players) do
            if player.slot == slot then taken = true end
        end
        if not taken then return slot end
    end
    return nil
end

local function back_to_lobby(state, reason)
    state.phase, state.authority, state.hashes, state.session = "lobby", nil, {}, nil
    -- Spectators join the lobby as players while there are free slots.
    for peer, spectator in pairs(state.spectators) do
        local slot = free_slot(state)
        if slot then
            state.players[peer] = {name = spectator.name, slot = slot, ready = false}
            state.order[#state.order + 1] = peer
            state.spectators[peer] = nil
            send(peer, {type = "welcome", id = peer, slot = slot})
        end
    end
    for _, player in pairs(state.players) do player.ready = false end
    broadcast(state, {type = "end"})
    broadcast_lobby(state)
    log(state, "session over: " .. reason)
end

local drop_player, save_session
local function remove(state, peer)
    if state.spectators[peer] then
        log(state, "stopped watching: " .. state.spectators[peer].name)
        state.spectators[peer] = nil
        if state.authority then state.authority.clients[peer] = nil end
        return
    end
    if not state.players[peer] then return end
    local player = state.players[peer]
    log(state, "left: " .. player.name)
    state.players[peer] = nil
    for position, other in ipairs(state.order) do
        if other == peer then table.remove(state.order, position) break end
    end
    if state.phase == "session" and #state.order == 0 then
        -- Everybody left: the session is saved, and the same players can resume it from the lobby.
        save_session(state)
        back_to_lobby(state, "everybody left")
    elseif state.phase == "session" and state.session.slots[player.slot] and state.session.slots[player.slot].peer == peer then
        drop_player(state, player.slot, engine.network_time())
    end
    broadcast_lobby(state)
end

-- The start of a session as every client gets it: the player names and slots and the random state, so that all of
-- them start the same game. A returning player gets the same message again (`rejoin`).
local function session_message(state, rejoin)
    local session = state.session
    local owners = {}
    for slot, entry in pairs(session.slots) do owners[slot] = entry.peer end
    return {type = "session", owners = owners, names = session.names, role = state.order[1], role_slot = session.role_slot,
        random = session.random,
        rejoin = rejoin or nil, classic = state.classic or nil}
end
-- The final ticks so far, to a player who must run them to catch up (a return, or a resumed session).
local function send_log(state, peer)
    local session = state.session
    -- Parts of at most `log_chunk` ticks and about 40 KB (a message holds at most 64 KiB).
    local part, size, count = {}, 0, 0
    for tick = 0, session.logged do
        part[tick] = session.log[tick]
        size, count = size + #wire.encode(session.log[tick]), count + 1
        if count >= log_chunk or size > 40000 or tick == session.logged then
            send(peer, {type = "log", ticks = part})
            part, size, count = {}, 0, 0
        end
    end
end

-- Starts a session: every client gets the player names and slots and the server's random state. `saved`: a stopped
-- session that goes on (its random state, its slots by player name, and its final ticks, which every client runs
-- again to catch up). The keys of a player who leaves are predicted as none (authority).
local function start_session(state, now, saved)
    local owners, names, clients, slots = {}, {}, {}, {}
    local used = {}
    for position, peer in ipairs(state.order) do
        local player = state.players[peer]
        if saved then
            for slot, name in pairs(saved.slots) do
                if name == player.name and not used[slot] then player.slot, used[slot] = slot, true break end
            end
        end
        owners[player.slot] = peer
        names[player.slot + 1] = player.name
        slots[player.slot] = {name = player.name, peer = peer}
        clients[position] = peer
    end
    local random
    if saved then
        random = saved.random
    else
        engine.reset_random_sequence()
        local index, sequence, crt = engine.random_position()
        random = {table = engine.random_state(), index = index, sequence = sequence, crt = crt}
    end
    local first = saved and saved.length or 0
    state.authority = authority.create({owners = owners, clients = clients, all_functions = true, first_tick = first})
    state.authority.speed = saved and saved.speed or nil
    state.phase, state.hashes = "session", {}
    -- A resumed session goes on with its next tick, after the start delay.
    state.start_at = now + start_delay_ms - first * tick_ms
    -- role_slot: the slot whose keys start a fight on the setup screen, the same for the whole session.
    state.session = {names = names, random = random, slots = slots, log = saved and saved.log or {}, logged = first - 1,
        drops = {}, role_slot = state.players[state.order[1]].slot}
    broadcast(state, session_message(state))
    if first > 0 then
        for _, peer in ipairs(state.order) do send_log(state, peer) end
    end
    log(state, (saved and "session resumed with " or "session started with ") .. #state.order .. " players")
end

-- The stopped session in the configuration of this computer, or nil.
function server.load_saved()
    local document = engine.read_settings()
    local saved = type(document) == "table" and document.saved_session
    if type(saved) ~= "table" or type(saved.data) ~= "string" then return nil end
    local data = wire.decode(saved.data)
    if type(data) ~= "table" or type(data.slots) ~= "table" or type(data.runs) ~= "table" then return nil end
    -- The final ticks are stored in runs of equal ticks: each an encoded {count, encoded tick}.
    local log, tick = {}, 0
    for _, text in ipairs(data.runs) do
        local run = type(text) == "string" and wire.decode(text)
        local final = type(run) == "table" and type(run[2]) == "string" and wire.decode(run[2])
        if type(final) ~= "table" or type(run[1]) ~= "number" then return nil end
        for _ = 1, run[1] do
            log[tick] = final
            tick = tick + 1
        end
    end
    data.log, data.length, data.runs = log, tick, nil
    return data
end
-- Whether the players in the lobby are the players of the stopped session (by name), so that it can go on.
function server.can_resume(state)
    local saved = state.saved
    if not saved or state.phase ~= "lobby" then return nil end
    local wanted, count = {}, 0
    for _, name in pairs(saved.slots) do
        wanted[name] = (wanted[name] or 0) + 1
        count = count + 1
    end
    if count ~= #state.order then return nil end
    for _, peer in ipairs(state.order) do
        local name = state.players[peer].name
        if not wanted[name] or wanted[name] == 0 then return nil end
        wanted[name] = wanted[name] - 1
    end
    return true
end
-- Saves the session (stop and resume later, or everybody left): its random state, its slots, and its final ticks.
save_session = function(state)
    local session = state.session
    if not session or session.logged < 0 then return end
    local slots = {}
    for slot, entry in pairs(session.slots) do slots[slot] = entry.name end
    -- Runs of equal ticks, each as its own encoded text (a decoded message holds at most 65536 items).
    local runs, last, count = {}, nil, 0
    for tick = 0, session.logged + 1 do
        local text = tick <= session.logged and wire.encode(session.log[tick]) or nil
        if text == last then count = count + 1
        else
            if last then runs[#runs + 1] = wire.encode({count, last}) end
            last, count = text, 1
        end
    end
    local data = {slots = slots, random = session.random, speed = state.authority and state.authority.speed, runs = runs}
    local document = engine.read_settings()
    if type(document) ~= "table" then document = {} end
    document.saved_session = {data = wire.encode(data), ticks = session.logged + 1}
    local saved, problem = engine.write_settings(document)
    if saved then
        state.saved = server.load_saved()
        log(state, "session saved (" .. (session.logged + 1) .. " ticks)")
    else
        log(state, "cannot save the session: " .. tostring(problem))
    end
end

local function hold_update(state)
    if not state.authority then return end
    local held = false
    for _, drop in pairs(state.session.drops) do
        if not drop.decided then held = true end
    end
    state.authority.hold = held
end
-- A player of the session is gone (left, or silent for a while): the ticks are held until the room role decides.
drop_player = function(state, slot, now)
    local session = state.session
    if not session or not slot or session.drops[slot] then return end
    local entry = session.slots[slot]
    session.drops[slot] = {slot = slot, name = entry and entry.name or tostring(slot + 1), since = now}
    if entry then entry.peer = nil end
    hold_update(state)
    broadcast(state, {type = "drop", slot = slot, name = session.drops[slot].name, decide_ms = decide_ms})
    log(state, "dropped: " .. session.drops[slot].name)
end
local function end_drop(state, slot, text)
    state.session.drops[slot] = nil
    hold_update(state)
    broadcast(state, {type = "drop_end", slot = slot, text = text})
    log(state, text)
end
-- The computer plays a dropped fighter from the next tick (base/game/match "read_control").
local function computer_plays(state, slot)
    local drop = state.session.drops[slot]
    if not drop then return end
    drop.decided = true
    hold_update(state)
    state.authority.inject[slot] = "A"
    end_drop(state, slot, "the computer plays " .. drop.name)
end

local handlers = {}
function handlers.hello(state, peer, message)
    if state.players[peer] then return end
    if message.protocol ~= server.protocol or message.profile ~= state.profile then
        send(peer, {type = "refused", reason = "version", version = state.version})
        engine.messages("disconnect", peer)
        return
    end
    local name = type(message.name) == "string" and message.name:gsub("[^\32-\126]", "")
        :sub(1, constants.text_limits.player_name_bytes) or ""
    -- A player who comes back to a session: the slot of the dropped player with this name.
    if state.phase == "session" then
        local slot
        for dropped, entry in pairs(state.session.slots) do
            if not entry.peer and entry.name == (name ~= "" and name or tostring(dropped + 1)) then slot = dropped end
        end
        if not slot then
            server.watch(state, peer, name ~= "" and name or "?")
            return
        end
        server.rejoin(state, peer, slot)
        return
    end
    local slot = free_slot(state)
    if not slot or state.phase ~= "lobby" then
        send(peer, {type = "refused", reason = slot and "playing" or "full"})
        engine.messages("disconnect", peer)
        return
    end
    if name == "" then name = tostring(slot + 1) end
    state.players[peer] = {name = name, slot = slot, ready = false}
    state.order[#state.order + 1] = peer
    send(peer, {type = "welcome", id = peer, slot = slot})
    log(state, "joined: " .. name .. " (slot " .. (slot + 1) .. ")")
    broadcast_lobby(state)
end
function handlers.ready(state, peer, message)
    local player = state.players[peer]
    if not player or state.phase ~= "lobby" then return end
    player.ready = message.value == true
    broadcast_lobby(state)
end
function handlers.start(state, peer, message, now)
    if state.order[1] ~= peer or state.phase ~= "lobby" then return end
    if message.resume then
        -- The stopped session of these players goes on.
        if not server.can_resume(state) then return end
        local saved = state.saved
        state.saved = nil
        local document = engine.read_settings()
        if type(document) == "table" then
            document.saved_session = nil
            engine.write_settings(document)
        end
        state.agreed = 0
        start_session(state, now, saved)
        return
    end
    for _, other in ipairs(state.order) do
        if not state.players[other].ready then return end
    end
    start_session(state, now)
end
-- The room role's choice for a dropped player: "wait", "computer", "give" (to = the player who takes the fighter),
-- or "stop" (the session is saved and the players go back to the lobby, where they can resume it).
function handlers.drop_choice(state, peer, message, now)
    if state.phase ~= "session" or state.order[1] ~= peer then return end
    local slot = tonumber(message.slot)
    local drop = slot and state.session.drops[slot]
    if not drop then return end
    if message.choice == "wait" then
        drop.waiting = true
        broadcast(state, {type = "drop", slot = slot, name = drop.name, waiting = true})
    elseif message.choice == "computer" then
        computer_plays(state, slot)
    elseif message.choice == "give" then
        local to = tonumber(message.to)
        local player = to and state.players[to]
        if not player then return end
        state.authority.owners[slot] = to
        state.session.slots[slot].peer = to
        drop.decided = true
        -- The player's own slot stays first (its player 1 keys); the taken fighters follow (player 2 and on).
        local own = {player.slot}
        for owned, owner in pairs(state.authority.owners) do
            if owner == to and owned ~= player.slot then own[#own + 1] = owned end
        end
        table.sort(own, function(a, b) return (a == player.slot and -1 or a) < (b == player.slot and -1 or b) end)
        send(to, {type = "owners", slots = own})
        end_drop(state, slot, player.name .. " plays the fighter of " .. drop.name)
    elseif message.choice == "stop" then
        save_session(state)
        back_to_lobby(state, "stopped to resume later")
    end
end
-- The title's Quit runs on every client on the same tick; the first client that reports it ends the session.
-- The game speed of a session (docs/pregame-ui-redesign.md "Who sets it"): any player sets it, the last change wins,
-- and every screen shows who changed it. The fights skip ticks by it (base/game/speed_gate).
function handlers.set_speed(state, peer, message)
    local player, tenths = state.players[peer], tonumber(message.tenths)
    if state.phase ~= "session" or not player or not tenths then return end
    tenths = math.max(1, math.min(10, math.floor(tenths)))
    state.authority.speed = tenths
    local text = tenths == 10 and "1.0" or string.format("0.%d", tenths)
    broadcast(state, {type = "notice", text = player.name .. " set the speed to " .. text, speed = tenths})
    log(state, player.name .. " set the speed to " .. text)
end
-- A command of the menus (base/game/setup) from a click: it goes into the next final tick for every client. Only
-- small values pass: a type, a slot and a number or a flag.
local command_types = {join = true, leave = true, fighter = true, team = true, ready = true, add_computer = true,
    remove_computer = true, mode = true, arena = true, stage = true, difficulty = true, start = true, wait = true,
    exit = true, rematch = true, change_fighters = true, results_setup = true}
function handlers.command(state, peer, message)
    local command = message.command
    if state.phase ~= "session" or not state.players[peer] or type(command) ~= "table" or not command_types[command.type] then
        return
    end
    if #state.authority.commands >= 16 then return end
    local value = command.value
    if type(value) ~= "number" and type(value) ~= "boolean" then value = nil end
    state.authority.commands[#state.authority.commands + 1] = {type = command.type, slot = tonumber(command.slot),
        value = value, from = state.players[peer].slot, role = state.order[1] == peer or nil}
end
function handlers.lobby_return(state, peer)
    if state.phase == "session" and state.players[peer] then back_to_lobby(state, "quit") end
end
function handlers.chat(state, peer, message, now)
    local player = state.players[peer] or state.spectators[peer]
    if not player or type(message.text) ~= "string" then return end
    local text = message.text:gsub("[^\32-\126]", ""):sub(1, chat_length)
    if text:match("^%s*$") then return end
    local recent = {}
    for _, time in ipairs(player.chat_times or {}) do
        if now - time < chat_window_ms then recent[#recent + 1] = time end
    end
    if #recent >= chat_burst then return end
    recent[#recent + 1] = now
    player.chat_times = recent
    broadcast(state, {type = "chat", name = player.name, text = text})
    log(state, player.name .. ": " .. text)
end
function handlers.input(state, peer, message, now)
    -- A spectator's messages count for its acknowledgements and its round trip; authority.receive drops its keys.
    if state.phase ~= "session" or not (state.players[peer] or state.spectators[peer]) then return end
    message.from = peer
    authority.receive(state.authority, message, now - state.start_at)
end
-- A client's hash of its game state after a final tick (base/game/online): two different hashes for one tick mean
-- that the clients run different games. The server keeps the first report of each tick and compares the others.
function handlers.hash(state, peer, message)
    if state.phase ~= "session" or not (state.players[peer] or state.spectators[peer]) then return end
    local tick, hash = tonumber(message.tick), message.hash
    if not tick or type(hash) ~= "string" then return end
    local first = state.hashes[tick]
    if not first then
        state.hashes[tick] = {hash = hash, peer = peer}
    elseif first.hash == hash and first.peer ~= peer and not first.agreed then
        first.agreed = true
        state.agreed = (state.agreed or 0) + 1
        if state.agreed == 1 or state.agreed == 10 or state.agreed == 100 then
            log(state, string.format("hashes agree (%d checks, tick %d)", state.agreed, tick))
        end
    elseif first.hash ~= hash and not first.reported then
        first.reported = true
        local function name_of(id)
            local who = state.players[id] or state.spectators[id]
            return who and who.name or "?"
        end
        log(state, string.format("difference at tick %d: %s and %s", tick, name_of(first.peer), name_of(peer)))
        broadcast(state, {type = "difference", tick = tick})
    end
end

-- A dropped player who comes back: the slot again, the start of the session and every final tick so far, which the
-- client runs to catch up; the ticks go on meanwhile.
function server.rejoin(state, peer, slot)
    local session = state.session
    local entry = session.slots[slot]
    -- The old connection of this player, if ENet has not noticed yet that it is gone, leaves now.
    for other, player in pairs(state.players) do
        if player.slot == slot then
            state.players[other] = nil
            for position, id in ipairs(state.order) do
                if id == other then table.remove(state.order, position) break end
            end
            if state.authority.clients[other] then state.authority.clients[other] = nil end
            engine.messages("disconnect", other)
        end
    end
    state.players[peer] = {name = entry.name, slot = slot, ready = true}
    state.order[#state.order + 1] = peer
    entry.peer = peer
    state.authority.owners[slot] = peer
    authority.add_client(state.authority, peer)
    send(peer, {type = "welcome", id = peer, slot = slot})
    send(peer, session_message(state, true))
    -- The log tells again when the hashes agree, now with the returning player.
    state.agreed = 0
    send_log(state, peer)
    if session.drops[slot] then end_drop(state, slot, entry.name .. " is back")
    else log(state, entry.name .. " is back") end
    broadcast_lobby(state)
end

-- A player who joins a running session with a new name watches it (docs/netcode.md "Spectators"): the start of the
-- session and every final tick so far, then the final ticks as they come; the client stays a second behind and
-- runs no prediction. A spectator chats, but its keys and clicks do not count.
function server.watch(state, peer, name)
    state.spectators[peer] = {name = name}
    authority.add_client(state.authority, peer, true)
    send(peer, {type = "welcome", id = peer, spectator = true})
    local message = session_message(state, true)
    message.spectator = true
    send(peer, message)
    send_log(state, peer)
    state.agreed = 0
    broadcast(state, {type = "notice", text = name .. " watches the game"})
    log(state, "watching: " .. name)
end

-- One frame of a room's session: the due ticks, the log of final ticks and the dropped players.
local function room_update(state, now)
    if state.phase ~= "session" then return end
    -- The program runs a frame on each message and every few milliseconds; the clients hear from the server
    -- when a tick became final (and its message repeats the ticks they did not acknowledge yet).
    local messages = authority.update(state.authority, now - state.start_at)
    -- Every final tick stays in the session's log: a returning player and a resumed session run them again.
    local session = state.session
    for tick = session.logged + 1, state.authority.tick - 1 do session.log[tick] = state.authority.final[tick] end
    session.logged = math.max(session.logged, state.authority.tick - 1)
    -- A player without a message for a while has dropped; without a choice the computer plays it.
    for peer, player in pairs(state.players) do
        local client = state.authority.clients[peer]
        local plays = session.slots[player.slot] and session.slots[player.slot].peer == peer
        if plays and client and client.heard > 0 and now - state.start_at - client.heard > drop_ms then
            drop_player(state, player.slot, now)
        elseif client and client.heard > 0 and session.drops[player.slot] and not session.drops[player.slot].decided then
            -- Its messages arrive again (it was only slow).
            session.slots[player.slot].peer = peer
            end_drop(state, player.slot, player.name .. " is back")
        end
    end
    for slot, drop in pairs(session.drops) do
        if not drop.waiting and not drop.decided and now - drop.since > decide_ms then computer_plays(state, slot) end
    end
    if state.authority.tick ~= state.sent_tick then
        state.sent_tick = state.authority.tick
        for peer, message in pairs(messages) do
            message.type = "ticks"
            send(peer, message, unreliable)
        end
    end
    for tick in pairs(state.hashes) do
        if tick < state.authority.tick - 600 then state.hashes[tick] = nil end
    end
end

-- A player moves to another room (in the lobby): it leaves its room and arrives in the other one as a new player,
-- a returning one or a spectator, as with a hello.
local function move(top, peer, target)
    local room = top.peers[peer]
    local player = room and (room.players[peer] or room.spectators[peer])
    if not player or (room.phase == "session" and room.players[peer]) then return end
    remove(room, peer)
    if room ~= top.rooms.main and #room.order == 0 and next(room.spectators) == nil then top.rooms[room.code] = nil end
    top.peers[peer] = target
    handlers.hello(target, peer, {protocol = server.protocol, profile = target.profile, name = player.name})
    broadcast_lobby(target)
end
-- A private room with a new code of four letters and digits (no 0, O, 1 or I).
local code_letters = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
local function new_code(top)
    for _ = 1, 100 do
        top.next_code = (top.next_code * 16807 + engine.network_time()) % 2147483647
        local value, code = top.next_code, ""
        for _ = 1, 4 do
            local index = value % #code_letters + 1
            code = code .. code_letters:sub(index, index)
            value = math.floor(value / #code_letters)
        end
        if not top.rooms[code] then return code end
    end
    return nil
end
local room_handlers = {}
function room_handlers.create_room(top, peer, message)
    local room = top.peers[peer]
    if room.phase == "session" and room.players[peer] then return end
    local code = new_code(top)
    if not code then return end
    top.rooms[code] = new_room(top, code, message.private ~= false)
    log(top.rooms[code], "room created")
    move(top, peer, top.rooms[code])
end
function room_handlers.join_room(top, peer, message)
    local code = type(message.code) == "string" and message.code:upper():gsub("[^%w]", "") or ""
    if code == "MAIN" then code = "main" end
    local target = top.rooms[code]
    if not target then
        send(peer, {type = "notice", text = "There is no room " .. code})
        return
    end
    if target ~= top.peers[peer] then move(top, peer, target) end
end

-- One frame: the messages of the clients, then the due ticks of every room's session. Returns the lines to log.
-- raw: the program's input; "upnp:STATE[:ADDRESS]" while it opens the port on the home router (--upnp).
function server.update(top, raw)
    local upnp, address = (raw or ""):match("^upnp:(%a+):?([%d.]*)")
    if upnp and (upnp ~= top.upnp or address ~= (top.public_address or "")) then
        top.upnp, top.public_address = upnp, address ~= "" and address or nil
        broadcast_lobby(top.rooms.main)
    end
    local now = engine.network_time()
    local events = engine.messages("service") or {}
    for _, event in ipairs(events) do
        local room = top.peers[event.peer]
        if event.kind == "disconnected" then
            if room then
                remove(room, event.peer)
                if room ~= top.rooms.main and #room.order == 0 and next(room.spectators) == nil and room.phase == "lobby" then
                    top.rooms[room.code] = nil
                    broadcast_lobby(top.rooms.main)
                end
            end
            top.peers[event.peer] = nil
        elseif event.kind == "message" then
            local message = wire.decode(event.data)
            local kind = type(message) == "table" and message.type
            if kind == "hello" and not room then
                -- A new connection: the room of its code, or the main room.
                local code = type(message.room) == "string" and message.room:upper():gsub("[^%w]", "") or ""
                room = top.rooms[code ~= "" and code ~= "MAIN" and code or "main"]
                if not room then
                    send(event.peer, {type = "refused", reason = "room"})
                    engine.messages("disconnect", event.peer)
                else
                    top.peers[event.peer] = room
                    handlers.hello(room, event.peer, message, now)
                end
            elseif room_handlers[kind] and room then
                room_handlers[kind](top, event.peer, message, now)
            elseif handlers[kind] and room then
                handlers[kind](room, event.peer, message, now)
            end
        end
    end
    for _, room in pairs(top.rooms) do room_update(room, now) end
    local lines = top.log
    top.log = {}
    return lines
end

function server.describe(top)
    local main = top.rooms.main
    local count = 0
    for _ in pairs(top.rooms) do count = count + 1 end
    return string.format("server phase=%s players=%d tick=%d rooms=%d", main.phase, #main.order,
        main.authority and main.authority.tick or -1, count)
end

return server
