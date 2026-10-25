# Plan for OpenLF2 network play and menus

This plan collects the requested features for network play with friends and the new menus, and puts the remaining work in an order. The designs are in these documents:

- docs/ui-network-architecture.md: a shared session model that changes only through commands, a local UI on each computer, and a server program that is always the authority of a network game.
- docs/netcode.md: the fight over UDP with prediction and rollback, bad connections, rooms, spectators and chat, with measurements.
- docs/pregame-ui-redesign.md: one match setup screen in Dear ImGui, local music, no locks, the game speed as a setting, and one settings menu. docs/pregame-ui-current.md describes the menus of today and their problems.
- docs/network.md: the old two-computer network code.
- docs/architecture.md: the parts of the game, one frame, the network game and the game versions, with diagrams.

## Where the game is now

- Network Game opens a menu (Dear ImGui): host a game, or join one by its address or from the saved servers. Host starts the server program (`openlf2 --server --stop-with-parent --upnp`, UDP with ENet) on this computer and joins it. The server opens UDP 12345 on the home router with UPnP, and the lobby shows the public address.
- The server holds a main room and private rooms (a code of four characters). The lobby lists the players and the open rooms. They say ready, and the room role starts a session. The lobby has a chat, and a message that is only a number from 1 to 42 plays a taunt on every computer.
- A session runs the whole game on the server's final ticks: the title menu and the match setup screen (or the classic menus with `--server --classic-menus`), every mode and the results run in lockstep, and the fights run with rollback. Clicks on the setup screen go through the server as commands in the ticks. The server makes each tick final at its deadline and never waits for a player. The clients send a hash of their fight state every 30 ticks, and the server compares them. The round trip on one machine is about 7 to 21 ms.
- During a session, Enter (or T) opens a chat window, and Escape opens the settings menu (the game goes on). Any player sets the game speed. A player who drops holds the game until the room role decides (wait, the computer plays, another player takes the fighter, stop and resume later). A returning player, a spectator and a resumed session run the session's final ticks again to catch up. A line shows the ping, the input delay and the rollbacks.
- Local games: the title's VS, Stage and Battle open the match setup screen (portraits, arenas, difficulty, speed, start with a countdown, Results buttons after the fight). "Classic menus" keeps the original screens. Escape opens the settings menu in a fight, where the computer can play a player's fighter. The music is local, and the game starts unlocked.
- The old two-computer TCP game stays for `--host` and `--join` only.
- Game versions: players install complete builds and switch between them on the Versions screen.
- Tests: tools/test-online.sh (headless: versus with a second fight, stage mode, Quit back to the lobby, the game speed, a player who leaves, a drop with the computer taking over, a return, stop and resume, a spectator, two rooms, the setup screen in a session) and tools/test-online-ui.sh (two windows on Xvfb: host and join, the chat, taunts, the setup screen, the settings menu, the computer control on both computers, the leave question, the server stopping with a crashed host).

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
- Rollback foundation: save, restore and hash of a fight, `--rollback-check` (24f7506).
- Local rollback with a simulated network, `--net-sim` (ba70510, 1016a8c).
- The server program: ENet, `--server`, `--connect`, the lobby, chat and taunts, the ImGui network menus, sessions that run the whole game, the clients' hashes compared by the server, and the online tests (b4a651d to ba757dc).
- The game's own audio stream name (ac31547).
- Work of 2026-10-25 (one commit per step, 1d60443 to the end of the night):
  - Network polish: a server frame on each message, sends at once, the server stops with its host (also after a crash), the game's own audio role.
  - AI control (the letters `A` and `P`), the settings menu on Escape, local music and volumes, no locks, the game speed as a setting and in sessions (base/game/speed_gate), `--game-speed`, input traces with `=ID` menu clicks.
  - UPnP with miniupnpc, the public address in the lobby.
  - The match setup screen (base/game/setup, base/ui/setup_screen) with Stage and Battle modes and the Results buttons; in server sessions through commands in the ticks.
  - Drops, returns, stop and resume, spectators and private rooms, all from the server's log of final ticks.
  - The input delay setting and the connection line.
  - Fixes from a review: the classic two-computer game handed every fighter to the computer, keys of frames that ran no tick were lost (the cause of a random test failure), a catching-up client lost final ticks, and others.

## Remaining work

### 1. Play with the friend

1. Publish the version (the owner): create the public link of the versions folder, then run `~/programs/openlf2-windows/publish-version.sh`. A dry run of the night packed both builds (see the report).
2. Play a real game over the internet and note what to tune.

### 2. Pre-game menus

- The settings menu does not replace the launch options page yet: Display (filter, layout, shading, shadows), Controls and Language stay there.
- The arena cards show the first layer of each background, not a picture made from all layers. The stage cards have no boss portraits and no best result.
- The setup screen marks a ready player's panel with ">" in front of its title, not with a colored frame. It has no tooltips, and it does not show who changed a value in a network game.
- Battle mode's troop panel and the championships keep their classic screens.
- New texts have no German or Chinese translations yet.

### 3. Drops and returns

- The server does not run the game. A return, a spectator and a resume run the session's ticks again from its start, about 8 times faster than real time in a fight and 40 ticks a frame in the menus. A session of an hour takes some minutes to catch up. A snapshot would need a way to copy the whole game state.
- One saved session for each server computer (in its config.json); a second stopped session replaces the first, and every room can resume it.
- If the room role itself drops, only the 30-second rule decides (the other players see no buttons).
- Spectators who turn into lobby players after a stop keep the resume from showing until they leave (the names must match).
- A return in a Stage survival run is not tested.

### 4. Rooms

- No presence, no invites beyond the code, no player rotation between matches.

### 5. Measure and tune

- The delay log (the time of each key event, the tick that read it, the frame on which the fighter reacted) is not built.
- Tuning needs a real game over the internet: the automatic input delay, the clock lead.

### 6. Leftovers

- The championship rollback check, and a faster hash for battle mode.
- Remove the old two-computer protocol once every player has the new engine.
- The web build has no UDP and no network game.

## Rules for all work

- Everything that changes a fight goes through the authority, so that all computers run the same ticks. The UI, the music and the overlays are local.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
- In a session, a frame that waits for the server runs the scripts again: code before the exchange must not count frames, and its sounds and draw commands are lost.
- Before a feature is called done, run tools/test-online.sh and tools/test-online-ui.sh, and add checks for its new behavior.
