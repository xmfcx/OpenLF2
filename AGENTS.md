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

- A comma ends a frame. `udlrcbf` are the keys of player 1 (up, down, left, right, attack, jump, defend), `#N` holds virtual key N, `@X_Y` moves the pointer and `!` holds the left button. `--seed` makes runs repeat.
- To a VS fight: `W=$(printf ',%.0s' $(seq 1 40)); C=$(printf ',%.0s' $(seq 1 170))`, then `",,#13,,#13,,,,c,,,,c,,,,c$W,c,,,,c,,,,c,,,,c$C,c,,,,c,,,,c,,,,c$W,u,,,,u,,,,c$W$W"`. Item 0 in the output is player 1.
- Game speed 0.4 first: `L=$(printf '#37,,%.0s' $(seq 1 6))`, then prefix `",,#77,,#70,,#68,,$L#13,,,"`.
- Network: start one program with `--host 127.0.0.1 --port N` and one with `--join 127.0.0.1 --port N`, each with a headless trace of the same length. Both must print the same state. In a network trace, a frame that waits for the other computer runs its trace frame again, so held keys repeat.
- Windows builds run in Wine: `WINEPREFIX=<scratch prefix> wine build/windows/openlf2.exe ...`. Pass Windows paths, for example `Z:\home\...`.
- For screenshots, run the game under `Xvfb :97` with `SDL_VIDEODRIVER=x11` and `--renderer software`, drive it with xdotool (focus the window first) and capture with `import`.

Do not use port 12345 for tests when a real game hosts on this machine.

## Architecture

- src/app/application.cpp parses the arguments, opens the window, loads the installer and runs the frame loop. src/app/versions.cpp installs and switches game versions.
- src/adapters/ holds the libraries behind small interfaces: SDL3 (window, input, sound), LuaJIT (script runtime), curl (downloads), FFmpeg (music), the TCP transport.
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
