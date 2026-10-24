# Plan for OpenLF2 network play

This plan collects the requested features for network play with friends and puts them in an order. The design is in docs/ui-network-architecture.md: a shared session model that changes only through commands, a local UI on each computer, and a server program that is always the authority of a network game. docs/network.md describes the network code as it is today.

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

## Decisions

- Every network game uses the server program as its authority, also when it runs on the computer of a player.
- Each computer shows its own screen. Only commands change the shared state.
- Key quirks of the original menus (release before a key acts again, repeat while held) belong to the local controllers. Rules that change a result stay in the models.

## Phase 0: Quit (done)

The title Quit ends the session and opens the launch menu (81bf33c). With the server program, Quit sends `leave` instead, and the other players stay (Phase 3).

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

## Phase 3: the server program

1. Engine: a listener with many connections and a poll per connection (the transport has one connection today), and a headless mode that follows the frame clock and the network (the headless mode runs only a trace today).
2. The framed protocol: a length, a type and a body for each message. Types: hello (profile and version), lobby, command, tick input, acknowledgment, state hash, snapshot.
3. The lobby: players with names, game versions and owned slots, the settings, and the role that starts games. The role goes to another player when its owner leaves.
4. The game: Host starts `openlf2 --server` on the same computer and joins it at 127.0.0.1. Join connects to a server. The server list of the network screen stays.
5. The menus run on commands through the server. Each computer shows its own screen.
6. The current two-computer protocol goes away.

Make sure that three clients on one machine join one server, choose fighters on their own screens, and get the same model.

## Phase 4: the fight through the server

1. The tick stream: each client sends its key states for a tick a few ticks ahead. The server combines the key states of all players for each tick and sends them with the commands of that tick to all clients.
2. If the keys of a client are late, the server waits until a short limit, then uses the last key states of that player, so that one slow client does not stop the others.
3. Pause and game speed become commands.
4. The merge rule with real times: with the key times of Phase 1, a change less than 50 ms after the previous one merges into the same state, as in lf2-arena. Each client applies it before it sends a tick.
5. Hashes: every few ticks, each client and the server compare a hash of the match state. On the first difference, each one writes the state and the last inputs to the log.
6. Decision for the owner later: the original reads keys on every second frame. A server setting can read them on every frame, which halves the largest delay but changes how the game feels.

Make sure that a fight with three clients stays the same on all of them, and that a client that leaves does not stop the others.

## Phase 5: AI control, drops and returns

- AI control: each human item (0 to 7) gets a control mode, player or AI. `read_input` skips an item in AI mode, and `ai.control` runs for it before the computer fighters. The item stays human for the camera, the results, the recording and the end of a stage. The command `set_control(slot, mode)` changes the mode on the same tick for everyone.
- Drops: the server finds a drop when a client sends nothing for a short time (for example 2 seconds). It pauses the match with a command and shows who dropped. The players choose to wait or to give the fighter to the AI.
- Returns: a client that connects again with the same player name and session gets its slots back. It gets the match setup and the stream of ticks since the start, then runs them without drawing. Measure the speed of this replay first. Snapshots can make it shorter later.
- Saved matches: the server writes the tick stream as it goes. After a restart, it runs the match up to the last tick and goes on.

Make sure that a client that quits during a survival stage and starts again returns to the same stage, at the same frame, with the same HP for all fighters.

## Order and size

| Phase | Size | Needs a new engine |
| --- | --- | --- |
| 0 Quit to the launch menu | small, done | no |
| 1 Delay log | medium | yes (key times, log files) |
| 2 Models, commands, local UI | large | no |
| 3 Server program | large | yes |
| 4 Fight through the server | large | yes |
| 5 AI control, drops, returns | large | no for AI control, yes for the rest |

The versions feature delivers engine changes, so each phase can ship when it is ready.

## Open work from the versions feature

- Create the public link of the versions folder on Nextcloud, then publish the first version with publish-version.sh.
- Give the friend one new Windows download with the new engine. Later versions arrive through the Versions screen.

## Rules for all phases

- Everything that changes a fight goes through the authority, so that all computers run the same ticks. The UI and the overlays are local.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
