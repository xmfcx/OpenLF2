# Plan for OpenLF2 network play

This plan collects the requested features for network play with friends and puts them in an order. The design is in two documents. docs/ui-network-architecture.md describes a shared session model that changes only through commands, a local UI on each computer, and a server program that is always the authority of a network game. docs/netcode.md describes the fight over UDP with prediction and rollback, the handling of bad connections, rooms, spectators and chat. docs/network.md describes the network code as it is today.

## Where the game is now

### The network game

- A network game connects exactly two computers over one TCP connection (src/adapters/network/transport.cpp, with `TCP_NODELAY`). Each computer has four player slots: 0 to 3 on the host, 4 to 7 on the joining computer.
- The handshake (scripts/base/game/network.lua) compares a profile: a SHA-256 of the scripts, bootstrap.lua and the JIT setting. If the profiles differ, the host can offer its scripts, and it names its game version. Then follow a greeting, the player names and the random table of the host.
- The two computers run the fight in lockstep. On each frame, each computer sends a 22-byte packet with its keys and waits for the packet of the other computer (`network.exchange`). Both computers then run the same frame with the same keys.
- The packet also carries checks from the original protocol: a sequence number, the recording version, the HP sum of items 0 to 19 (mod 100) and a checksum of the game data. A difference ends the connection at once. Bytes 17 to 22 are fixed.
- Local keys go into the frame on which they were sent, with no input delay. The wait for the other packet is the delay. In steady state, a frame takes the longer of 33 ms and the time that a packet needs to reach the other computer.
- While a frame waits, the engine polls every millisecond (`waiting_network` in src/app/application.cpp). In a game, a computer gives up 30 seconds after it sent a packet without an answer. The handshake has its own limits (120 seconds for the script question). A host that listens waits until the player cancels it.
- If a computer closes the connection, the other one sees the closed socket on its next poll and goes back to the launch menu with a message.
- The exchanged input has no mouse: the combined input has the pointer at 0, 0 and no button.

### The screens and the fight

- Both computers run every screen on the combined input, frame by frame. The screens are part of the shared simulation, so anything that they read must go through the network.
- ui/flow.lua routes the screens. The title Quit ends the session and opens the launch menu (done, 81bf33c). Escape asks the quit question, except in a network game, where Escape ends the connection.
- The fight (game/match.lua) uses items 0 to 7 for human fighters and items 10 and up for computer fighters. `read_input` gives the keys to the human items on every second fight frame (`input_phase == 0`), as the original does. Then `ai.control` runs for each computer fighter (items 10 to 399).
- `ai.control` (game/ai.lua) treats an item under 20 as a fighter from the character selection, so it works for items 0 to 7 too. It uses only the shared random generator.

### The engine input

- Each script frame gets one text with the held keys, the pointer and the key-downs since the last frame, in order (" p"), with no times. The scripts ignore sections that they do not know, so a new section does not break older scripts.
- The sandbox cannot write files. The only writes are the settings (`engine.write_settings`) and recordings (`engine.save_recording`).

## The requests

1. Quit brings the player back to the launch menu with a clean state, also from a network game. The program closes only through Exit.
2. The mouse works on almost all menus.
3. A server that is separate from the game clients. A player can open a lobby, other players join it, and a player starts the game. The lobby stays up when its creator leaves, and a player who drops does not stop the game of the others.
4. A player can hand the control of their fighter to the AI and take it back later, without a pause. For example, a player goes away for a moment in a survival stage and the game goes on.
5. A player who drops can come back to the same game. The game pauses when a player drops, the state stays, and the player continues from where the game stopped when they connect again. The other players do not have to do anything.
6. The other players can give the fighter of a dropped player to the AI. The player takes the fighter back when they return.
7. Key presses reach the fight with less delay. The client merges key changes like lf2-arena did, and the server gets cleaner input.
8. The delay between a key press and its action is measured and logged, so that it can be reduced. Differences between the computers are logged too.
9. Network play is as smooth as possible: responsive at any ping, resilient against slow and dropping connections, and true to the real result.
10. A server holds many clients at the same time, with modern multiplayer features such as chat.

## Decisions

- Every network game uses the server program as its authority, also when it runs on the computer of a player.
- Each computer shows its own screen. Only commands change the shared state.
- Key quirks of the original menus (release before a key acts again, repeat while held) belong to the local controllers. Rules that change a result stay in the models.
- The input delay is automatic (0 to 2 ticks). The player can fix it.
- A long drop pauses the match and makes an autosave. Then the players choose what happens (docs/netcode.md, "A dropped player").
- ENet is the UDP library.

## Phase 0: Quit (done)

The title Quit ends the session and opens the launch menu (81bf33c). With the server program, Quit sends `leave` instead, and the other players stay (Phase 5).

## Phase 1: measure

Measure first, so that later changes can show what they improve. This phase needs a new engine, so it ships as a game version.

- src/app/application.cpp: collect the time of each key-down and key-up event (SDL gives each event a timestamp) and pass them in a new input section, for example " q" with code, up or down, and milliseconds.
- A new engine function `engine.log(name, line)` appends a line to a file in a log folder of the configuration directory. Scripts check `if engine.log then` before they use it. An option turns the logs on, and they are off by default.
- The delay log: for each key press of a local player, one CSV line with the time of the key event, the frame on which the scripts saw it, the frame on which the fight read it, and the frame on which the fighter reacted.
- The input timeline shows the median and the largest delay of the last presses.

Known sources of delay:

- Frame sampling: the scripts see the keys once per frame, up to 33 ms after the key event.
- The fight reads keys on every second frame: up to 66 ms more at normal speed, and longer at slow speeds.
- The lockstep waits for the packet of the other computer on every frame.
- The input buffer at slow speeds holds key changes until a read.

Make sure that a local game at normal speed shows a delay between key event and fight read of at most about 100 ms (one frame plus one read interval).

## Phase 2: models, commands and the local UI

Split each menu into a shared model and a local UI (see docs/ui-network-architecture.md), first in a local game with a local authority.

1. A small command layer: a command has a sender, a type and fields. The local authority gives each command a tick and applies it to the model.
2. The character selection first: a model with `apply(command)` and `tick()`, a view that draws it with the original bitmaps, and a controller that turns keys into commands. The look and the result stay the same.
3. Widgets: when a view draws an entry, it registers its area and its command. The controller tests the pointer against these widgets, so the mouse works without separate rectangles.
4. Then the title choices, the battle setup and the championship.

Make sure that headless traces of the menus give the same results as before the split.

## Phase 3: rollback foundation

Step 1 of docs/netcode.md. Done, except the championship check and a faster hash for battle mode (results in docs/netcode.md, Measurements):

- A hash of the match state.
- Save and restore of the match state, including the random generator of the engine and the module state that the fight changes. The fixed game data is shared and not copied.
- The rollback test: save at tick N, run M ticks, restore, run them again, compare the hashes. Run it over many seeds and every mode.
- Measure the cost of a tick and of a save in each mode, battle mode included.

## Phase 4: local rollback

Step 2 of docs/netcode.md: two simulated clients in one program, with a network simulator between them (delay, jitter, loss). The rollback engine, the sound rules and the overlays on confirmed ticks are built and tuned here, without a real network.

Built: the rollback client, the server logic, the simulated links and `--net-sim`. Every hash check matches at round trips up to 390 ms with 15 % loss (results in docs/netcode.md). The overlays read the final ticks, and the rollback window follows the round trip. Open: tuning by play.

## Phase 5: the server program

Steps 3 and 4 of docs/netcode.md, with the session model of docs/ui-network-architecture.md:

1. Engine: ENet (UDP with a reliable and an unreliable channel) behind the transport interface, many connections, and a headless server mode that follows the clock (`openlf2 --server`).
2. The framed messages: hello (profile and version), lobby, command, input, confirmed tick, acknowledgment, hash, snapshot.
3. The lobby and the menus on commands. Host starts the server program on the same computer and joins it at 127.0.0.1. Each computer shows its own screen.
4. The fight: the clock lead, the input delay, the redundant inputs, the deadlines of the server, the rollback client, the hash checks and the snapshots. Pause, game speed and AI control are commands.
5. The merge rule with real times on the client (the key times of Phase 1).
6. The current two-computer protocol goes away.

Make sure that three clients and a server on one machine, with the network simulator on, end a fight with the same state hash as a run without the simulator.

Built so far: sessions that run the whole game (the original title menu, character selection, all modes) on the server's final ticks, the menus in lockstep and the fights with rollback; the clients' state hashes compared by the server; the tests tools/test-online.sh and tools/test-online-ui.sh. Before that: ENet in the engine (`engine.messages`), the server mode (`--server`), the client option `--connect`, the message encoding (base/game/wire.lua), the server with a lobby and the authority (base/game/server.lua), the client (base/game/online.lua), a keyboard lobby screen (base/ui/online_lobby.lua), and fights with rollback over UDP. Host on the network screen starts the server program on this computer, and join connects to it. Two clients on one machine passed every hash check. The network menu, the lobby and the chat are drawn with Dear ImGui (mouse and keyboard); chat and taunts work. Open: versus only (no stage or battle setup yet), the server stops only when its host program quits normally, and UDP port forwarding (the UPnP script maps TCP).

## Phase 6: drops, returns and AI control

Step 5 of docs/netcode.md:

- AI control: each human item (0 to 7) gets a control mode, player or AI. `read_input` skips an item in AI mode, and `ai.control` runs for it before the computer fighters. The item stays human for the camera, the results, the recording and the end of a stage. The command `set_control(slot, mode)` changes it on the same tick for everyone.
- Short drops: after 500 ms without input, the server predicts no keys for that player.
- Long drops: the match pauses and the server makes an autosave. The players choose to wait, let the AI take over, give the fighter to another person, or stop and resume later from the autosave. Every pause ends with a countdown of 3 seconds.
- Returns: the player key gives the slots back, and a snapshot with the ticks since then brings the client to the current tick.
- The server writes the confirmed ticks, so that it can go on after a restart.

Make sure that a client that quits during a survival stage and starts again returns to the same stage, at the same frame, with the same HP for all fighters.

## Phase 7: rooms, spectators and chat

Step 6 of docs/netcode.md: many rooms on one server, spectators with a delayed stream, text chat and short signals, presence, the ready check, invites with a room code.

## Phase 8: tuning

Step 7 of docs/netcode.md: the automatic input delay, the clock lead, the connection line and the logs.

## Order and size

| Phase | Size | Needs a new engine |
| --- | --- | --- |
| 0 Quit to the launch menu | small, done | no |
| 1 Delay log | medium | yes (key times, log files) |
| 2 Models, commands, local UI | large | no |
| 3 Rollback foundation | medium, mostly done | yes (random position) |
| 4 Local rollback | large | no |
| 5 Server program | large | yes |
| 6 Drops, returns, AI control | large | no for AI control, yes for the rest |
| 7 Rooms, spectators, chat | large | yes |
| 8 Tuning | medium | maybe |

Phases 2 and 3 do not depend on each other. The versions feature delivers engine changes, so each phase can ship when it is ready.

## Open work from the versions feature

- Create the public link of the versions folder on Nextcloud, then publish the first version with publish-version.sh.
- Give the friend one new Windows download with the new engine. Later versions arrive through the Versions screen.

## Rules for all phases

- Everything that changes a fight goes through the authority, so that all computers run the same ticks. The UI and the overlays are local.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
