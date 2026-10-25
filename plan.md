# Plan for OpenLF2 network play and menus

This plan collects the requested features for network play with friends and the new menus, and puts the remaining work in an order. The designs are in these documents:

- docs/ui-network-architecture.md: a shared session model that changes only through commands, a local UI on each computer, and a server program that is always the authority of a network game.
- docs/netcode.md: the fight over UDP with prediction and rollback, bad connections, rooms, spectators and chat, with measurements.
- docs/pregame-ui-redesign.md: one match setup screen in Dear ImGui, local music, no locks, the game speed as a setting, and one settings menu. docs/pregame-ui-current.md describes the menus of today and their problems.
- docs/network.md: the old two-computer network code.

## Where the game is now

- Network Game opens a menu (Dear ImGui): host a game, or join one by its address or from the saved servers. Host starts the server program (`openlf2 --server`, UDP with ENet) on this computer and joins it.
- The lobby lists the players, each with a slot. They say ready, and the room role starts a session. The lobby has a chat, and a message that is only a number from 1 to 42 plays a taunt on every computer.
- A session runs the whole game on the server's final ticks: the original title menu, character selection, every mode and the results run in lockstep, and the fights run with rollback. The server makes each tick final at its deadline and never waits for a player. The clients send a hash of their fight state every 30 ticks, and the server compares them.
- During a session, Enter (or T) opens a chat window, and Escape asks before leaving. The title's Quit brings everybody back to the lobby.
- The old two-computer TCP game stays for `--host` and `--join` only.
- Game versions: players install complete builds and switch between them on the Versions screen.
- Tests: tools/test-online.sh (headless sessions: versus with a second fight, stage mode, Quit back to the lobby, a player who leaves) and tools/test-online-ui.sh (two windows on Xvfb: host and join, the chat, taunts, the leave question).

## The requests

1. Quit brings the player back to the launch menu with a clean state, also from a network game.
2. The mouse works on all menus.
3. A server that is separate from the game clients, with a lobby. A player who drops does not stop the game of the others.
4. A player can hand the control of their fighter to the AI and take it back later, without a pause.
5. A player who drops can come back to the same game.
6. The other players can give the fighter of a dropped player to the AI.
7. Key presses reach the fight with less delay.
8. The delay between a key press and its action is measured and logged. Differences between the computers are logged too.
9. Network play is as smooth as possible: responsive at any ping, resilient against slow and dropping connections, and true to the real result.
10. A server holds many clients at the same time, with modern multiplayer features such as chat.
11. Modern, intuitive menus before the fight (docs/pregame-ui-redesign.md): one setup screen with portraits, local music, nothing locked, the game speed as a setting, a settings menu in the fight.

## Decisions

- Every network game uses the server program as its authority, also when it runs on the computer of a player.
- Each computer shows its own screen. Only commands change the shared state.
- Key quirks of the original menus belong to the local controllers. Rules that change a result stay in the models.
- The input delay is automatic (0 to 2 ticks). The player can fix it.
- A long drop pauses the match and makes an autosave. Then the players choose what happens (docs/netcode.md, "A dropped player").
- ENet is the UDP library. Dear ImGui draws the new menus.
- The decisions of the pre-game redesign are in docs/pregame-ui-redesign.md, "Decisions": the new setup screen is the default and the classic screens stay behind "Classic menus"; any player sets the shared values and the game speed; the game starts unlocked; the cheat keys get a button.

Decisions of 2026-10-25 (the owner's answers before the work of the night):

- Order: the small and safe parts first (network polish, AI control, local music, no locks, the settings menu, the game speed), then the setup screen, then the server snapshot with drops and returns, then rooms.
- Releases: build and pack only (`publish-version.sh --dry-run`), no upload and no public link. The owner publishes.
- The server runs the game itself (the scripts without a window, on the final ticks). Returns, spectators, autosaves and resume use its snapshot.
- After the setup commands go through the server, network games use only the new setup screen. The classic screens stay for local games.
- A long drop: the match pauses after 3 s without the player. The room role chooses (wait, AI, give the fighter to a person, stop and resume later). With no choice in 30 s, the AI takes over, and the player gets the fighter back on return.
- Escape opens the settings menu in all games. It has "Leave game" (online) or "End fight" (local), with a confirmation. The game keeps running online.
- AI control: "Let the AI play" and "Take control" are buttons in that menu.
- UPnP: the game maps UDP 12345 with miniupnpc when it hosts, and the lobby shows the public address.
- Rooms: the server lobby lists the open rooms, and a private room joins by a short code.
- Spectators run the final ticks 1 s behind, without rollback. They can chat and send taunts.
- Resume: the server keeps the autosave. Its lobby shows "Resume" when the same player names are back, and the room role starts it.
- The setup screen uses the theme of the network menus with the blue and gold of LF2.
- The old TCP game stays until every player has the new engine.
- Work: one commit per step on `arena`, each with passing tests. A fresh agent reviews each large part.

## Done

- Quit to the launch menu (81bf33c).
- Rollback foundation: save, restore and hash of a fight, `--rollback-check` (24f7506). Open: the championship check and a faster hash for battle mode.
- Local rollback with a simulated network, `--net-sim` (ba70510, 1016a8c).
- The server program: ENet, `--server`, `--connect`, the lobby, chat and taunts, the ImGui network menus, sessions that run the whole game, the clients' hashes compared by the server, and the online tests (b4a651d to ba757dc).
- The game's own audio stream name (ac31547).

## Remaining work

### 1. Play with the friend

1. Build the Windows version with the new engine and the taunts (tools: ~/programs/openlf2-windows/publish-version.sh).
2. Create the public link of the versions folder on Nextcloud (needs the owner's approval), then publish the version. The friend downloads the new Windows build once; later versions arrive through the Versions screen.
3. Done: a hosting game opens UDP 12345 with UPnP (miniupnpc), and the lobby shows the public address.
4. Play a real game over the internet and note what to tune.

### 2. Network polish

Done: a frame on each message at the server and sends at once (the round trip on one machine went from 99 ms to 21 ms), the server stops with its hosting game also after a crash, and the game has its own audio role (its own stored volume).

### 3. The pre-game redesign

The steps of docs/pregame-ui-redesign.md, in its order. Done: steps 1 to 4 (local music, no locks, the settings menu on Escape with the game speed, AI control and the cheat keys, the game speed in server sessions) and the image and slider widgets of step 5. Open from step 3: the settings menu does not replace the launch options page yet (its Display, Controls and Language values).

1. Local sound and music: configuration values, a local random track, the music out of the shared options. Small; it also fixes the shared music in network games.
2. No locks: all fighters and difficulties from the start, the `lf2.net` word off in live games, replays unchanged.
3. The settings menu (Dear ImGui) with the game speed and the cheat keys button, in the menus and in the fight. Then remove the M, F, D sequence and the old options page.
4. The game speed in fights of the server program, as a command in the tick stream.
5. Engine work: an image widget, arena pictures, cursor frames over widgets.
6. The setup model and its commands for VS mode with a local authority, drawn by the new screen; the classic screen stays. This is step 1 of docs/ui-network-architecture.md and replaces the old plan for models and commands.
7. Stage mode on the new screen.
8. The Results buttons (rematch, change fighters, setup, title).
9. The network game: the setup commands through the server program; then the menus of a session no longer run in lockstep.
10. Battle mode, then the championships.

Each step needs headless traces with the player keys, and the online tests must still pass.

### 4. Drops, returns and AI control

Step 5 of docs/netcode.md:

- Done: AI control. The letters `A` and `P` in a slot's keys switch its fighter to the computer and back (base/game/match `read_control`), from the settings menu; a fresh key press takes it back after a second.
- Long drops: the match pauses and the server makes an autosave. The players choose to wait, let the AI take over, give the fighter to another person, or stop and resume later.
- Returns: a returning player gets a snapshot and the ticks since then. For this, the server must run the game itself (the flow without a window on the final ticks), or ask a client for a snapshot.
- The server writes the final ticks, so that it can go on after a restart.

Make sure that a client that quits during a survival stage and starts again returns to the same stage, at the same frame, with the same HP for all fighters.

### 5. Rooms and spectators

Step 6 of docs/netcode.md: many rooms on one server, spectators with a delayed stream, presence, invites with a room code. The chat is done.

### 6. Measure and tune

- The delay log: the time of each key event from the engine, the frame on which the fight read it and the frame on which the fighter reacted (a new `engine.log` and key times in the input).
- Tuning (step 7 of docs/netcode.md): the automatic input delay, the clock lead, a connection line on the screen, and the logs.

### 7. Leftovers

- The championship rollback check, and a faster hash for battle mode.
- Remove the old two-computer protocol once every player has the new engine.
- The web build has no UDP and no network game.

## Order and size

| Work | Size | Needs a new engine |
| --- | --- | --- |
| 1 Play with the friend | small | no (the build exists) |
| 2 Network polish | small to medium | yes |
| 3 Pre-game redesign | large | yes (step 5) |
| 4 Drops, returns, AI control | large | no for AI control, yes for the rest |
| 5 Rooms and spectators | large | yes |
| 6 Measure and tune | medium | yes |
| 7 Leftovers | small | no |

Parts 2 and 3 do not depend on each other. The versions feature delivers engine changes, so each part can ship when it is ready.

## Rules for all work

- Everything that changes a fight goes through the authority, so that all computers run the same ticks. The UI, the music and the overlays are local.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
- In a session, a frame that waits for the server runs the scripts again: code before the exchange must not count frames, and its sounds and draw commands are lost.
- Before a feature is called done, run tools/test-online.sh and tools/test-online-ui.sh, and add checks for its new behavior.
