# Plan for OpenLF2 network play

This plan collects the requested features for network play with friends and puts them in an order. Each phase lists what changes, where in the code, and how to make sure that it works. Phase 0 is small and changes only scripts. The later phases build on each other.

## Where the game is now

### The network game

- A network game connects exactly two computers over one TCP connection (src/adapters/network/transport.cpp, with `TCP_NODELAY`). Each computer has four player slots: 0 to 3 on the host, 4 to 7 on the joining computer.
- The connection starts with a handshake (scripts/base/game/network.lua): a profile (SHA-256 of the scripts), then a greeting, the player names and the random table of the host.
- The two computers run the fight in lockstep. On each frame, each computer sends a 22-byte packet with its keys and waits for the packet of the other computer (`network.exchange`). Both computers then run the same frame with the same keys.
- The packet also carries checks from the original protocol: a sequence number, the recording version, the HP sum of all fighters (mod 100) and a checksum of the game data. A difference in one of them ends the connection at once. Bytes 17 to 22 are fixed today.
- Local keys go into the frame on which they were sent, with no input delay. The wait for the other packet is the delay. In steady state, a frame takes the longer of 33 ms and the time that a packet needs to reach the other computer.
- While a frame waits, the engine polls every millisecond (`waiting_network` in src/app/application.cpp). After a connection, a computer gives up after 30 seconds without a packet. A host that listens waits until the player cancels it.
- If a computer closes the connection, the other one sees the closed socket on its next poll and goes back to the launch menu with a message.
- The exchanged input has no mouse: the combined input has the pointer at 0, 0 and no button (`network.exchange`).

### The screens and the fight

- ui/flow.lua routes the screens. The title menu entry Quit sends the action `quit` to the engine, and the engine closes the program. Escape asks the quit question, except in a network game, where Escape ends the connection (`disconnect`).
- The fight (game/match.lua) uses items 0 to 7 for human fighters and items 10 and up for computer fighters. `read_input` gives the keys to the human items, on every second fight frame (`input_phase == 0`), as the original does. Then `ai.control` runs for each computer fighter (items 10 to 399).
- `ai.control` (game/ai.lua) treats an item under 20 as a fighter from the character selection, so it works for items 0 to 7 too. It uses only the shared random generator.
- Script sharing, game versions, the game speed menu, the input buffer at slow speeds and the input timeline (V) work as described in AGENTS.md.

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

## Phase 0: scripts only

These changes need no new engine. A host can send them to the friend with script sharing.

### 0.1 Quit goes back to the launch menu

- In `route` (ui/flow.lua), handle the `quit` request of the title menu. Do not pass it to the engine. The launch menu Exit and a replay opened from a file still close the program.
- End the session with a function like `disconnect`: close the connection, clear the player names, the unlocked characters of a replay, the game speed of the host, the speed menu and the input buffer. Then open the launch menu.
- In a network game, both computers choose Quit on the same frame, because the title menu runs on the combined input. Each one closes its side, so neither computer waits for the other.
- Make sure that a local game, a replay and a network game each end in the launch menu, and that a new network game starts from there without a restart.

### 0.2 The mouse on all menus

The launch menu, the network screens, the Versions screen, the speed menu and the quit question use the mouse. These screens do not:

- The title menu. A click on the menu shows the key list for 15 seconds, as in the original. A click never chooses an entry.
- The character selection.
- The battle setup.
- The championship screens.
- The summary after a fight.

Steps:

1. Title menu: a click on an entry chooses it, and pointing at an entry moves the selection. A click on the menu panel outside the entries still shows the key list.
2. Other screens: add mouse targets for the entries that the keys can choose. A click acts as the key presses of one player. On the character selection, a click acts for the first local player.
3. Network game: the click must reach the other computer. Bytes 17 to 20 of the packet carry the position of a click (0 for no click). The combined input then has a list of clicks, each with the computer that made it. The two computers run the same scripts (the profile makes sure of that), so they agree on the new packet.

## Phase 1: measure

Measure first, so that later changes can show what they improve. This phase needs a new engine, so it ships as a game version.

### 1.1 Engine support

- src/app/application.cpp: collect the time of each key-down and key-up event (SDL gives each event a timestamp) and pass them in a new input section, for example " q" with code, up or down, and milliseconds.
- A new engine function `engine.log(name, line)` appends a line to a file in a log folder of the configuration directory. Scripts check `if engine.log then` before they use it.
- A new option turns the logs on. The logs are off by default.

### 1.2 The delay log

For each key press of a local player, one CSV line with:

- The time of the key event.
- The frame on which the scripts saw the press.
- The frame on which the input buffer gave it to the fight, and the frame on which the fight read it.
- The frame on which the fighter reacted (its frame or state changed).
- In a network game, the time at which the packet with the press left and the time at which the packet of the other computer arrived.

The input timeline gets a summary line: the median and the largest delay of the last presses.

### 1.3 The difference log

Today a difference between the computers shows only when the HP sum differs, and then the connection ends with "Network HP synchronization mismatch". A difference can start many frames earlier.

- Both computers compute a hash of the match state (positions, HP, MP, frames and states of all items, and the random state) on each frame. Each one keeps the hashes of the last frames.
- The packet carries the low bits of the hash in place of the HP sum (byte 14) or in bytes 21 and 22.
- On the first frame where the hashes differ, each computer writes the full state of that frame and the inputs of the last frames to the log. The game then ends the connection with a message that names the frame.

### Known sources of delay

- Frame sampling: the scripts see the keys once per frame, up to 33 ms after the key event.
- The fight reads keys on every second frame: up to 66 ms more at normal speed, and longer at slow speeds.
- The lockstep waits for the packet of the other computer on every frame. If a packet needs more than 33 ms, each frame waits, and the game slows down.
- The input buffer at slow speeds holds key changes until a read.

### Make sure that it works

- A local game at normal speed shows a delay between key event and fight read of at most about 100 ms (one frame plus one read interval).
- A network game on one machine (127.0.0.1) shows the same.
- A test that changes one random number on one computer finds the difference on the frame where it happens.

## Phase 2: less input delay

This phase uses the measurements of Phase 1. It works for the current two-computer game, and the server of Phase 3 uses the same rules.

- Merge rule with real times: with the key times of Phase 1, a change less than 50 ms after the previous one merges into the same state, as in lf2-arena. Today the buffer merges by frames (33 ms) and only at slow speeds.
- Each computer applies the rule to its own keys before it sends them. The packet then carries the state for the next read, so both computers still run the same keys.
- Decision for the owner: the original reads keys on every second frame. A host option can read them on every frame. This halves the largest delay, but it changes how the game feels, so it is off by default.

### Make sure that it works

The delay log shows a lower median than before. A three-key combo (defend, up, attack) pressed within 50 ms still starts the move.

## Phase 3: a separate server

### Design

The server is a mode of the same program without a window (`openlf2 --server`). It can run next to the game on the computer of a player, or on another computer. It is a relay for lockstep input:

1. Clients connect to the server and get player slots. The server keeps the lobby: the players, their names, their game versions and the settings, such as the game speed.
2. A player with the lobby role starts the game. Any player can leave. The lobby stays as long as the server runs, and the role goes to another player.
3. On each frame, each client sends its keys to the server. The server combines the keys of all players for the frame and sends the result to all clients.
4. All clients run the same frames with the same keys, as today. The server also runs the fight without a window, so that it has the true state for checks and for players who come back.
5. If the keys of a client are late, the server waits until a short limit. Then it uses the last known keys of that player, or the AI (Phase 4), so that one slow client does not stop the others. This choice is part of the combined input, so all clients run it the same way.

### What changes in the engine

- The transport has one connection today. The server needs a listener with many connections and a poll per connection.
- The headless mode runs the scripts without a window today, but only for a trace. The server needs a headless loop that follows the frame clock and the network.
- The packet and the slots must allow more than two computers. Each client gets one or more of the 8 slots.

### The delay through a server

A relay adds a step: the keys go to the server and then to the other clients. If the server runs on the computer of a player, that player has no extra delay, and the others have about the same delay as today. If the server runs on another computer, all players get the delay of two trips. To keep the game smooth, the clients can send keys for a frame one or two frames ahead. This adds a fixed delay but removes the stutter. Phase 1 measures which choice is better.

### Compatibility

- The current two-computer mode stays for players with older versions.
- The server protocol has its own version number. The lobby shows players with another game version and offers the version switch.

### Make sure that it works

- Three clients on one machine join one server, play a fight, and their game states stay the same (the checks of Phase 1).
- A client that leaves during a fight does not stop the others.

## Phase 4: drops, returns and AI control

### AI control of a player fighter

- Each human item (0 to 7) gets a control mode: player or AI. In game/match.lua, `read_input` skips an item in AI mode, and `ai.control` runs for it before the computer fighters.
- The item stays human for everything else: the camera, the results, the recording and the end of a stage.
- A change of the mode must happen on the same frame on all computers, so it travels as a command in the combined input (a packet byte for commands).
- A player hands over with a key or a menu entry and takes the fighter back the same way. The other players can switch the fighter of a dropped player to AI.
- This part also works in the current two-computer mode and in a local game, so it can ship before the server.

### Drops

- The server finds a drop when a client sends nothing for a short time (for example 2 seconds).
- The server then pauses the match for all players and shows who dropped. The players choose to wait or to go on with the AI for that fighter. A lobby setting can choose one of these without a question.

### Returns

- A client that connects again with the same player name and session gets its slot back.
- To catch up, the client gets the setup of the match and the combined input of all frames since the match started (the same data as a recording), then runs these frames without drawing. Measure the speed of this replay first. Snapshots of the state can make it shorter later.
- The server then gives the fighter back to the player (AI mode off), and the match goes on.

### Saved matches

The server writes the combined input of a match as it goes. After a server restart, it can run the match up to the last frame and go on from there.

### Make sure that it works

- A client that quits during a survival stage and starts again returns to the same stage, at the same frame, with the same HP for all fighters.
- A fighter in AI mode fights, and the player takes it back without a pause.

## Order and size

| Phase | Size | Needs a new engine |
| --- | --- | --- |
| 0.1 Quit to the launch menu | small | no |
| 0.2 Mouse on all menus | medium | no |
| 1 Delay log and difference log | medium | yes (key times, log files) |
| 2 Less input delay | medium | yes (key times) |
| 3 Separate server | large | yes |
| 4 AI control | medium | no |
| 4 Drops and returns | large | yes |

The versions feature delivers engine changes, so each phase can ship when it is ready.

## Open work from the versions feature

- Create the public link of the versions folder on Nextcloud, then publish the first version with publish-version.sh.
- Give the friend one new Windows download with the new engine. Later versions arrive through the Versions screen.

## Rules for all phases

- Everything that changes a fight goes through the combined input, so that all computers run the same frames. Screens and overlays that only draw can use local data.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts that a host sends can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
