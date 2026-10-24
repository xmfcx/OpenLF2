# Plan for OpenLF2 network play

This plan collects the requested features for network play with friends and puts them in an order. Each phase lists what changes, how, and how to make sure that it works. Phase 0 is small and independent. Phases 1 to 3 build on each other.

## Where the game is now

- A network game connects exactly two computers. Each computer has four player slots (1 to 4 on the host, 5 to 8 on the joining computer).
- The two computers run the fight in lockstep: on each frame, each computer sends a 22-byte packet with its keys and waits for the packet of the other computer. Both computers then run the same frame with the same keys.
- If one computer stops sending, the other one waits. After 30 seconds without input, the game ends the connection.
- Script sharing: the host can send its game scripts to a joining computer. The scripts stay in memory until the game restarts.
- Game versions: a player can install complete builds, switch between them on the Versions screen and delete them. A joining computer can switch to the version of the host.
- The game speed menu (M, F, D) slows the fights. An input buffer at slow speeds keeps taps, double taps and combos. The input timeline (V) shows the keys as held and as the fight read them.
- The fight reads the player keys on every second fight frame, as the original game does. At normal speed, that is up to 66 ms between two reads.

## The requests

1. Quit brings the player back to the launch menu with a clean state, also from a network game. The program closes only through Exit.
2. The mouse works on almost all menus.
3. A server that is separate from the game clients. A player can open a lobby, other players join it, and a player starts the game. The lobby stays up when its creator leaves, and a player who drops does not stop the game of the others.
4. A player can hand the control of their fighter to the AI and take it back later, without a pause. For example, a player goes away for a moment in a survival stage and the game goes on.
5. A player who drops can come back to the same game. The game pauses when a player drops, the state stays, and the player continues from where the game stopped when they connect again. The other players do not have to do anything.
6. The other players can give the fighter of a dropped player to the AI. The player takes the fighter back when they return.
7. Key presses reach the fight with less delay. The client merges key changes like lf2-arena did, and the server gets cleaner input.
8. The delay between a key press and its action is measured and logged, so that it can be reduced.

## Phase 0: small changes

### 0.1 Quit goes back to the launch menu

- Change the Quit entry of the title menu so that it ends the current session (network connection, match, replay) and opens the launch menu.
- Reset the state that a session leaves behind: player names, unlocked characters of a replay, the speed of a network host, the input buffer.
- Keep the Exit entry of the launch menu as the only way to close the program. The quit question (Escape) keeps its current behavior.
- Make sure that a network game, a replay and a local game each end in the launch menu, and that a new network game starts from there without a restart.

### 0.2 The mouse on all menus

The launch menu, the network screens, the Versions screen, the speed menu and the quit question use the mouse. These screens do not:

- The title menu (it shows the pointer, but a click does not choose an entry in a network game).
- The character selection.
- The battle setup.
- The championship screens.
- The summary after a fight.

For each screen, add mouse targets for the entries that the keys can choose, as base/ui/navigation does for the launch menu. In a network game, a click must reach the other computer like a key, so a click becomes a key press of the local player before the exchange.

### 0.3 Open work from the versions feature

- Create the public link of the versions folder on Nextcloud, then publish the first version with publish-version.sh.
- Give the friend one new Windows download with the new engine. Later versions arrive through the Versions screen.
- Commit the pointer fix (ui/flow.lua) and the other open changes as separate commits.

## Phase 1: measure the input delay

Measure first, so that later changes can show what they improve.

### What to log

For each key press of a local player:

- The time of the key event. SDL gives each event a timestamp. The engine must pass key-downs and key-ups with these timestamps to the scripts. Today the scripts get only the held keys of each frame and the order of the key-downs.
- The frame on which the scripts saw the press.
- The frame on which the input buffer gave it to the fight, and the frame on which the fight read it.
- The frame on which the fighter reacted (its frame or state changed).
- In a network game, the time at which the packet with the press left and the time at which the packet of the other computer arrived for that frame.

### Where the log goes

- A CSV file in the recording folder, one line per press, written only when the option is on.
- A summary line in the input timeline: the median and the largest delay of the last presses.

### Known sources of delay

- The fight reads keys on every second frame: up to 66 ms at normal speed, and longer at slow speeds.
- The lockstep waits for the packet of the other computer on every frame. With a round trip above 33 ms, each frame waits, and the game stutters.
- The input buffer at slow speeds holds key changes until a read.
- Frame sampling: the scripts see the keys once per frame (33 ms).

### Make sure that it works

The CSV file of a local game at normal speed shows a delay between key event and fight read of at most one read interval (66 ms). A network game on one machine (127.0.0.1) shows the same.

## Phase 2: a separate server

### Design

The server is a mode of the same program without a window (`openlf2 --server`). It can run next to the game on the computer of a player, or on another computer. It is a relay for lockstep input:

1. Clients connect to the server and get player slots. The server keeps the lobby: the players, their names, their game versions and the settings, such as the game speed.
2. A player with the lobby role starts the game. Any player can leave. The lobby stays as long as the server runs, and the role goes to another player.
3. On each frame, each client sends its keys to the server for a frame a few frames ahead (an input delay that follows the round trip). The server combines the keys of all players for each frame and sends the result to all clients.
4. All clients run the same frames with the same keys, as today. The server also runs the fight without a window, so that it has the true state for checks and for players who come back.
5. If the keys of a client are late, the server waits until a short limit, then uses the last known keys of that player or the AI (Phase 3), so that one slow client does not stop the others.

### Input merging on the client

- The client sends key events with their timestamps, not frame samples.
- The server applies the lf2-arena rule for each player at each read: changes less than 50 ms apart merge into one state, and each other change gets its own read. This uses real times instead of the 33 ms frames of the current buffer.

### Compatibility

- The current two-computer mode stays for players with older versions.
- The server protocol has its own version number. The lobby shows players with another game version and offers the version switch.

### Make sure that it works

- Three clients on one machine join one server, play a fight, and their game states stay the same (the existing data and HP checks).
- A client that leaves during a fight does not stop the others.

## Phase 3: drops, returns and AI control

### AI control of a player fighter

- Each player slot gets a control mode: player or AI. The fight already moves computer fighters with base/game/ai. It must also do that for a player slot in AI mode.
- A change of the mode must happen on the same frame on all computers, so it travels as a command in the combined input.
- A player hands over with a key or a menu entry and takes the fighter back the same way. The other players can switch the fighter of a dropped player to AI.

### Drops

- The server finds a drop when a client sends nothing for a short time (for example 2 seconds).
- The server then pauses the match for all players and shows who dropped. The players choose to wait or to go on with the AI for that fighter. A lobby setting can choose one of these without a question.

### Returns

- A client that connects again with the same player name and session gets its slot back.
- To catch up, the client gets the setup of the match and the combined input of all frames since the match started (the same data as a recording), then runs these frames without drawing. At about 570 frames per second, a 30-minute match (54,000 frames) takes about 100 seconds. Snapshots of the state can make this shorter later.
- The server then gives the fighter back to the player (AI mode off) and the match goes on.

### Saved matches

- The server writes the combined input of a match as it goes. After a server restart, it can run the match up to the last frame and go on from there.

### Make sure that it works

- A client that quits during a survival stage and starts again returns to the same stage, at the same frame, with the same HP for all fighters.
- A fighter in AI mode fights, and the player takes it back without a pause.

## Order and size

| Phase | Size | Needs a new build for the friend |
| --- | --- | --- |
| 0.1 Quit to the launch menu | small | no (scripts) |
| 0.2 Mouse on all menus | medium | no (scripts) |
| 1 Input delay log | medium | yes (key timestamps) |
| 2 Separate server | large | yes |
| 3 Drops, returns, AI control | large | yes |

The versions feature delivers engine changes, so each phase can ship when it is ready.

## Rules for all phases

- Everything that changes a fight goes through the combined input, so that all computers run the same frames. Screens and overlays that only draw can use local data.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts that a host sends can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
