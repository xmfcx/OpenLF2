# Plan for OpenLF2 network play and menus

This plan collects the requested features for network play with friends and the new menus, and puts the remaining work in an order. The designs are in these documents:

- docs/ui-network-architecture.md: a shared session model that changes only through commands, a local UI on each computer, and a server program that is always the authority of a network game.
- docs/netcode.md: the fight over UDP with prediction and rollback, bad connections, rooms, spectators and chat, with measurements.
- docs/pregame-ui-redesign.md: one match setup screen in Dear ImGui, local music, no locks, the game speed as a setting, and one settings menu. It marks the steps that are built. docs/pregame-ui-current.md describes the menus before the redesign and their problems.
- docs/fight-screen.md: the new fight screen of each computer: a card for each fighter, panels anywhere in the window, a camera with a saved zoom up to the whole stage, Stage mode's enemies and bosses, and the player colors of Age of Empires II.
- docs/camera.md: the camera design, with the versions that are built and the steps that stay open.
- docs/network.md: the old two-computer network code.
- docs/architecture.md: the parts of the game, one frame, the network game and the game versions, with diagrams.

## Where the game is now

- Network Game opens a menu (Dear ImGui): host a game, or join one by its address or from the saved servers. Host starts the server program (`openlf2 --server --stop-with-parent --upnp`, UDP with ENet) on this computer and joins it. The server opens UDP 12345 on the home router with UPnP, and the lobby shows the public address. The server stops when the hosting game ends, also after a crash.
- The server holds a main room and private rooms (a code of four letters and digits). The lobby lists the players and the open rooms, with Join, or Watch when the room plays. The players say ready, and any player starts the session when everybody is ready. The lobby has a chat, and a message that is only a number from 1 to 42 plays a taunt on every computer.
- No player has more rights than the others. Any player starts a session from the lobby, resumes a stopped session, starts the fight on the setup screen and chooses for a dropped player.
- A session runs the whole game on the server's final ticks. It opens the match setup screen in place of the title menu (or the classic title menu and screens with `--server --classic-menus`). The menus and the results run in lockstep, and the fights run with rollback. Clicks on the setup screen go through the server as commands in the ticks. The server makes each tick final at its deadline and never waits for a player. The clients send a hash of their fight state every 30 ticks, and the server compares them. The round trip on one machine is about 7 to 21 ms.
- The server keeps the values of the last match (mode, difficulty, arena, stage group, game speed) in its config.json (`last_setup`). The next session on this server starts with them.
- During a session, Enter (or T) opens a chat window, and Escape opens the settings menu. In a fight, the open menu holds the fight for everybody (the letter `M` in the keys), and the fight goes on when every menu is closed. In the menus, the game goes on. Any player sets the game speed. A line shows the ping, and in a fight also the input delay, the rollbacks and the waits. The settings menu sets the input delay of this computer: automatic, or 0, 1 or 2 ticks.
- A player who drops holds the game (each final tick carries `hold`). The game waits for the player without a time limit. Any player can also let the computer play, give the fighter to another player, or stop and resume later. The server saves a stopped session in its config.json as hex text.
- A returning player, a spectator and a resumed session run the session's final ticks again to catch up (up to 40 menu ticks a frame). The game waits meanwhile, and every player sees a progress bar. A spectator then watches 30 ticks (one second) behind.
- Local games: "game start" opens the match setup screen in place of the title menu (portraits, arenas, difficulty, speed, start with a countdown, Results buttons after the fight). Its buttons open Championship, Teams (the team championship), Demo and Replay, and Exit goes back to the launch menu. "Classic menus" keeps the title menu and the original screens. Escape opens the settings menu in a fight, where the computer can play a player's fighter. The game starts unlocked.
- Sound: the music is local to each computer, with a Music switch, the VS track, the music volume and the sound effects volume. F11 and F12 change the music volume by 10 per press.
- The fight screen is local too: Classic, or the new screen (the default) on the Display page of the settings menu. The new screen has a card for each fighter, panels anywhere in the window (damage share, input timeline, stage panel, minimap), boss bars and the player colors. Its camera frames the fighters of this computer, or holds the player's zoom (mouse wheel, Page Up, Page Down; Home: automatic), up to the whole stage. Page Up, Page Down and Home zoom in a fight.
- The old two-computer TCP game stays for `--host` and `--join` only.
- Game versions: players install complete builds and switch between them on the Versions screen. `publish-version.sh` uploads each version to the Nextcloud versions folder, and the game reads `versions.json` through the public link of that folder (docs/upload-to-nextcloud.md). The latest version is 2026.10.25-37 (29fdd48).
- Tests: tools/test-online.sh has 87 checks (headless: versus with a second fight, stage mode, Quit back to the lobby, the game speed, a player who leaves, a drop with the computer taking over, "give the fighter", a return, stop and resume, a spectator, two rooms, the setup screen in a session with the values of the last match, a click and then keys on the setup screen). tools/test-online-ui.sh has 43 checks (two windows on Xvfb: host and join, the session at the setup screen, the chat, taunts, the settings menu that holds the fight for both players (also after a fast Escape, Escape, and until both menus close), the computer control on both computers, the leave question, the server stopping with a crashed host).

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

Later decisions of 2026-10-25 (723d449, 60216e1):

- No player has more rights than the others. The room role no longer starts, resumes or chooses alone.
- A dropped player: the game waits for them by default. The 30-second rule is gone.
- Escape in a network fight pauses the fight for everybody, and closing the menu resumes it.
- "game start" and a network session open the match setup screen in place of the title menu. The classic title menu stays behind "Classic menus".

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
- The public link of the versions folder, and the versions 2026.10.25-30 (c1d1b40) and 2026.10.25-37 (29fdd48).
- docs/architecture.md: the parts of the game in diagrams (78b8532).
- Work of the day of 2026-10-25 (723d449 to 29fdd48):
  - Equal players: anyone starts from the lobby, resumes, starts the fight and chooses for a dropped player.
  - A dropped player: the game waits by default, with no 30-second rule.
  - Catch-up progress: the game waits while a returning player or a resumed session catches up, and every player sees a progress bar (the server messages `progress` and `caught_up`).
  - Escape in a network fight pauses it for everybody (F1), and closing the menu resumes it.
  - The setup screen: a compact player list with "Set ready" and "Ready" buttons, an "I am ready" button, a hint for the next step, all arenas in two rows, the speed of the session, a Settings button. The reason why a fight cannot start replaces the summary.
  - The setup screen in place of the title menu, in local games and in sessions, with buttons for Championship, Teams, Demo and Replay. The server keeps the values of the last match (`last_setup`), and it saves a stopped session as hex text.
  - Sound: the Music switch on the launch options page and in the settings menu, and F11 and F12 by 10 per press.
  - The engine draws progress bars and colored buttons.
  - The camera design (docs/camera.md) and its first version: the dynamic camera (base/ui/camera_view.lua) through a scaled render area of the engine.
  - The new fight screen (docs/fight-screen.md): cards, panels with anchors, boss bars, the stage panel, the minimap, the saved zoom and the mouse wheel, the player colors. The settings menu holds a network fight by a state, so a fast Escape, Escape cannot lose the pause. The damage chart follows the fight time.

## Remaining work

### 1. Play with the friend

1. Play a real game over the internet and note what to tune.

### 2. Pre-game menus

- The settings menu does not replace the launch options page yet: the upscaling filter, the shading, the shadows, Controls and Language stay there. The settings menu has the pages Game, Sound and Display, without Overlays, Controls and Language.
- The arena cards show the first layer of each background, not a picture made from all layers. The stage cards have no boss portraits and no best result.
- The setup screen marks a ready player's panel with ">" in front of its title, not with a colored frame. It has no tooltips, and it does not show who changed a value in a network game.
- Battle mode's troop panel and the championships keep their classic screens.
- New texts have no German or Chinese translations yet.

### 3. Drops and returns

- The server does not run the game. A return, a spectator and a resume run the session's ticks again from its start, about 8 times faster than real time in a fight and 40 ticks a frame in the menus. The others wait with a progress bar meanwhile. A session of an hour takes some minutes to catch up. A snapshot would need a way to copy the whole game state.
- One saved session for each server computer (in its config.json). A second stopped session replaces the first, and every room can resume it.
- Spectators who turn into lobby players after a stop keep the resume from showing until they leave (the names must match).
- A return in a Stage survival run is not tested.

### 4. Rooms

- No presence, no invites beyond the code, no kick and no player rotation between matches.

### 5. Measure and tune

- The delay log (the time of each key event, the tick that read it, the frame on which the fighter reacted) is not built.
- Tuning needs a real game over the internet: the automatic input delay, the clock lead.

### 6. Camera

The new fight screen is built (docs/fight-screen.md, docs/camera.md "The new fight screen"). These steps stay open:

- The damage chart and the input timeline draw with the bitmap font, so their text is soft at 4K. They can move to Dear ImGui like the cards.
- A Battle mode panel (the troops of each side), like the stage panel.

- The test tools: `frame_hash=`, `--window WxH`, `view=` in the match description and `--camera-check`.
- The engine's `world_view` block, the sky above row 128, `scale_y` and the `sharp` filter.
- The middle drag, the Tab cycle and the follow choices, the edge indicators, and the camera of spectators and replays.
- The sound listener of the view, for the dynamic mode only.
- A HUD scale (`hud_scale`) and the clamps of the names and the markers to the view.
- The item culling and a separate world budget, measured in Battle mode on Linux and in Wine.
- A case in tools/test-online.sh where the two clients use different camera configurations.
- Split screen and the room limit (both optional).

### 7. Leftovers

- The championship rollback check, and a faster hash for battle mode.
- Remove the old two-computer protocol once every player has the new engine.
- The web build has no UDP and no network game.

## Rules for all work

- Everything that changes a fight goes through the authority, so that all computers run the same ticks. The UI, the music and the overlays are local.
- Game scripts run in a sandbox. A new engine function needs a check (`if engine.name then`), because scripts can run on older engines.
- The engine stops a frame with too many drawing commands. ui/flow.lua keeps the drawing under the limit of the engine.
- In a session, a frame that waits for the server runs the scripts again: code before the exchange must not count frames, and its sounds and draw commands are lost.
- Before a feature is called done, run tools/test-online.sh and tools/test-online-ui.sh, and add checks for its new behavior.
