# Notes for coding agents

OpenLF2 reimplements Little Fighter 2 v2.0a. A C++23 engine (src/) runs the game, and Lua scripts (scripts/) hold the gameplay, the AI, the modes and the menus. The game reads the original data from the LF2 installer in memory and never runs it. The plan for network play is in plan.md.

This checkout is local only. Do not push it, and do not open pull requests from it: the `arena` branch holds private notes (this file, docs/upload-to-nextcloud.md) and paths of this machine.

## Build

Linux, debug (dependencies from the system, SDL3_ttf fetched by CMake):

```sh
cmake --preset debug -DOPENLF2_FETCH_SDL3_TTF=ON
cmake --build --preset debug
```

The build copies scripts/ next to the program (build/debug/scripts). After a script change, build again, or run with `--scripts scripts`.

Windows, cross-compiled on this machine (MinGW-w64, dependencies in ~/programs/openlf2-windows/prefix, built by build-deps.sh there):

```sh
W=~/programs/openlf2-windows
export PKG_CONFIG_LIBDIR=$W/prefix/lib/pkgconfig
cmake -S . -B build/windows -G Ninja -DCMAKE_TOOLCHAIN_FILE=$W/mingw-toolchain.cmake -DCMAKE_BUILD_TYPE=Release \
    -DOPENLF2_DEPENDENCY_PROVIDER=system -DOPENLF2_FETCH_SDL3_TTF=ON -DCMAKE_PREFIX_PATH=$W/prefix \
    -DOPENSSL_ROOT_DIR=$W/prefix -DZLIB_ROOT=$W/prefix "-DCMAKE_EXE_LINKER_FLAGS=-static-libgcc -static-libstdc++" \
    "-DCMAKE_CXX_STANDARD_LIBRARIES=$W/prefix/lib/libSDL3.dll.a"
cmake --build build/windows
```

`~/programs/openlf2-windows/publish-version.sh` builds both platforms, packs them and publishes a game version (`--dry-run` packs without upload).

All targets build with `-Werror`. Fix warnings, do not turn them off. A known GCC 13 false positive in src/app/versions.cpp has a local pragma with the reason.

## Run and test

The LF2 installer is in ~/.local/share/OpenLF2/LF2_v2.0a.exe on this machine. A headless input trace runs frames without a window and prints the state of the active screen (`describe`) at the end:

```sh
I=~/.local/share/OpenLF2/LF2_v2.0a.exe
build/debug/openlf2 --headless --installer $I --scripts scripts --seed 1234 --input-trace ",,#13,,#13,,,,c"
```

- A comma ends a frame. `udlrcbf` are the keys of player 1 (up, down, left, right, attack, jump, defend), `#N` holds virtual key N, `@X_Y` moves the pointer and `!` holds the left button. `=ID` clicks the menu element ID (Dear ImGui) and `=ID:N` sets slider ID to N, also in headless runs. `--seed` makes runs repeat.
- The title's VS, Stage and Battle open the match setup screen (base/ui/setup_screen, base/game/setup). With keys: attack joins, the arrows move on the fighter grid, attack chooses, left and right set the team, attack is ready; then up and down move between the arena, the difficulty, the computers (attack adds one) and the start, and defend starts a countdown of 90 frames. A VS fight with one computer: `W=$(printf ',%.0s' $(seq 1 40))`, then `",,#13,,#13,,,,c$W,c,,,r,,,c,,,r,,,c,,,u,,,c,,,d,,,c"` and 120 frames. `--classic-menus` keeps the classic character selection. In a server session the server decides for every client: the setup screen, or the classic selection with `openlf2 --server --classic-menus` (tools/test-online.sh uses it for the traces of the original menus). There a click becomes a command that the server puts into the next final tick (`commands`), keys act on every client through the combined input, and only the room role starts.
- To a VS fight with the classic menus (`--classic-menus`): `W=$(printf ',%.0s' $(seq 1 40)); C=$(printf ',%.0s' $(seq 1 170))`, then `",,#13,,#13,,,,c,,,,c,,,,c$W,c,,,,c,,,,c,,,,c$C,c,,,,c,,,,c,,,,c$W,u,,,,u,,,,c$W$W"`. Item 0 in the output is player 1.
- Game speed 0.4: `--game-speed 0.4`. In a game, the speed is a slider of the settings menu (Escape); in a server session any player sets it for everybody (`set_speed`), and the fights skip ticks by it (base/game/speed_gate).
- Network: start one program with `--host 127.0.0.1 --port N` and one with `--join 127.0.0.1 --port N`, each with a headless trace of the same length. Both must print the same state. In a network trace, a frame that waits for the other computer runs its trace frame again, so held keys repeat.
- Rollback: `--rollback-check` makes each fight save its state every 45 ticks, run 8 ticks, go back and run them again. The headless description of the match then shows `rollback=checks:N,failures:F,...`. F must be 0. `differ=` names the fields of the first failure.
- Simulated network: `--net-sim delay=80,jitter=30,loss=5,seed=1` runs each fight through two rollback clients and a server in one program (base/game/netsim). Player 1 is client A (shown), the other players are client B (`c/r` in a trace gives player 2 the keys after the slash). The match description shows `netsim=a:...,hashes=CHECKS/FAILURES;b:...;server:...`. FAILURES must be 0.
- Server program: `openlf2 --server --installer $I --scripts scripts --port N` runs the server (UDP, ENet) without a window and prints its log. A client joins with `--connect 127.0.0.1 --port N` (or Network Game in the game: host starts a server on this computer). In the lobby, player 1's attack is ready and the room role's defend starts a session. A session runs the whole game on the server's final ticks: the menus in lockstep (base/game/online `exchange`), the fights with rollback. The server runs a frame on each message and at least every 4 ms. With `--upnp` (a hosting game passes it, unless `OPENLF2_NO_UPNP=1`) it opens its UDP port on the home router, and the lobby shows the public address. A game that hosts starts it with `--stop-with-parent`, so it stops when the game ends, also by a crash. With `--headless --input-trace`, a connected client paces its trace frames at 33 ms. The fight description shows `online=...,sent=HASHES,fights=N`; the server logs `hashes agree` and, on a difference, `difference at tick T`. A player who is silent for 3 s or leaves holds the ticks (`hold`), and the room role chooses in a window (`=drop_computer_SLOT`, `=drop_wait_SLOT`, `=drop_give_SLOT_PEER`, `=drop_stop_SLOT`). The server keeps all final ticks: a returning player and a resumed session (`=resume` in the lobby) run them again to catch up (flow.update runs up to 40 menu ticks a frame). A client that catches up runs far behind its newest final tick, so nothing may drop ticks that it has not run yet. A new name in a running session watches it (a spectator, 30 ticks behind). The server has a main room and private rooms (`create_room`, `join_room` with a code of four characters; `=create_room` in a lobby trace); its log prefixes a private room's lines with `[CODE]`.
- Online tests: `tools/test-online.sh` (headless: a versus game with a second fight, stage mode, the title's Quit back to the lobby, a player who leaves) and `tools/test-online-ui.sh` (two windows on Xvfb: host and join through the menus, the chat in the menus and in a fight, taunts, the leave question). Run both after a change to the network code, the chat or the menus; `KEEP=1` keeps the logs and screenshots. A frame that waits for the server runs the scripts again: code before the exchange must not count frames, and its sounds and draw commands are lost (play them after the exchange).
- Escape opens the settings menu (base/ui/fight_menu) in a fight and in a network game: a local fight stops behind it, a network game goes on. Its "let the computer play" button puts the letter `A` into the player's keys (base/game/match `read_control`), so a trace can test it with `#27` and then `=control_0`. The fight description shows `computer=1` on such a fighter.
- Menus with Dear ImGui (the network menu, the lobby, the chat during fights): a screen describes its menu in draw() with base/ui/imgui.lua, the engine draws it at the window's resolution (src/adapters/sdl/platform.cpp `draw_ui`), and the clicks and typed text come back in the next frame's input (`input.ui`). Headless runs draw no menus.
- Windows builds run in Wine: `WINEPREFIX=<scratch prefix> wine build/windows/openlf2.exe ...`. Pass Windows paths, for example `Z:\home\...`.
- For screenshots, run the game under `Xvfb :97` with `SDL_VIDEODRIVER=x11` and `--renderer software`, drive it with xdotool (focus the window first) and capture with `import`.

Do not use port 12345 for tests when a real game hosts on this machine.

## Architecture

- src/app/application.cpp parses the arguments, opens the window, loads the installer and runs the frame loop. src/app/versions.cpp installs and switches game versions.
- src/adapters/ holds the libraries behind small interfaces: SDL3 (window, input, sound, and Dear ImGui for the network menus), LuaJIT (script runtime), curl (downloads), FFmpeg (music), the TCP transport and ENet (UDP messages).
- scripts/runtime/bootstrap.lua is trusted. It loads the game modules into a sandbox (no files, no OS and no native code, only the `engine` table) and passes frame commands to the engine.
- scripts/base/ holds the game. ui/flow.lua routes the screens and runs the network exchange, the speed menu, the input buffer and the overlays. game/match.lua runs a fight. game/network.lua is the network protocol, including script sharing and the version line.
- The network game is a lockstep of two computers: on each frame both send their keys and run the same frame with the combined keys.

## Rules

- Determinism: everything that changes a fight (keys, speed, random numbers) must be the same on all computers. It comes through the combined input or the shared random generator (`engine.random`). Never use `math.random` (the sandbox removes it). Screens and overlays that only draw can use local data, such as the local mouse.
- The network profile is a SHA-256 of the script bytes and bootstrap.lua. Keep LF line endings, or two computers do not match.
- Script sharing sends the sandboxed modules, never bootstrap.lua or the engine. A host can send scripts to an older engine, so check new engine functions before use (`if engine.versions then`).
- The engine allows 1048576 frame commands (src/adapters/luajit/runtime.cpp, bootstrap.lua). The released Windows build allows 4096. ui/flow.lua counts the commands and keeps them under `engine.frame_command_limit`.
- Overlays (damage chart, input timeline, fight effects) only read the match state.
- Comments: follow the style of the file. Explain why, and name the original behavior when a rule copies it.
- Commits: conventional commits (`type(scope): description`). The commit body ends with the `Signed-off-by:` line of the owner.
