# UI and network architecture

This document describes a new split between the game state, the user interface (UI) and the network. It replaces the first approach to mouse clicks in the menus, where clicks traveled through the network as screen positions (reverted in 99e0cdd). Nothing here is built yet. plan.md lists the work in phases.

## The problem today

Both computers run every screen, frame by frame, on the combined raw input. The title menu, the character selection and the battle setup are part of the shared simulation, the same as the fight.

This causes these problems:

- Everything that a screen reads must travel through the network. A mouse click must go into the packet as a screen position, and the shared code must decide what that position means. That is why the click code has fixed rectangles and owner checks inside the screens.
- The network carries device input (keys per player slot, function keys, now clicks), not what the player wants to do.
- Each computer must show the same screen. One player cannot look at the options while the other one picks a fighter.
- The menus run in lockstep. A slow packet stops the menus too, not only the fight.
- The local game, the network game and the planned server take different paths through ui/flow.lua.
- A screen mixes three jobs in one `update` function: it reads keys, it changes the state, and it builds the drawing list.

## Principles

1. The shared state changes only through commands. A command says what a player wants, for example "slot 4 chooses Davis", not which key or pixel the player used.
2. The UI is local to each computer. It draws the shared state, and it owns the focus, the hover, the layout, the language and the pointer. It turns keys, mouse, touch and gamepad into commands. Nothing of the UI goes through the network.
3. One authority puts the commands in order. In a network game, the authority is always the server program, also when it runs on the computer of a player. In a local game, a local authority runs in the same program. All computers apply the same commands in the same order, so they get the same state.
4. The fight stays a simulation that reads key states on each tick, because the original fight works this way and recordings store these keys. The commands that change a fight (pause, speed, AI control) go in the same tick stream as the keys.

## The layers

```
 Each client                                     The authority (server program, or local)
 ---------------------------------------         -------------------------------------
 Devices (keyboard, mouse, pad, touch)
   |
 UI screens: view + controller (local)
   |  commands, and key states in a fight
   v
 Session link  --------------------------------> orders and validates commands,
                                                  combines the key states per tick
 Session link  <-------------------------------- ordered stream: (tick, commands, keys)
   |
 Session model (shared): lobby, menus, match <-- the authority runs the same model
   |
 UI screens draw the model
```

### The session model (shared)

The session model holds everything that must be the same on all computers:

- The lobby: the players (id, name, game version, owned slots, control mode of each slot) and the settings (game speed, the role that starts a game).
- One model for each menu: the title choice, the character selection (slots with phase, fighter and team, the countdown, the number of computers, the options), the battle setup and the championship.
- The match, as today (game/match.lua).

Each model has an `apply(command)` function and a `tick()` function. The model checks each command against its state. A command that the state does not allow does nothing, and it does nothing on all computers alike. Timers, such as the countdown of the character selection, run in `tick()` on the ticks of the authority, so they stay the same everywhere.

Examples of commands for the character selection: `join(slot)`, `step_fighter(slot, 1)`, `choose_fighter(slot, id)`, `choose_team(slot, team)`, `confirm(slot)`, `back(slot)`, `set_computers(n)`, `set_option(name, value)`, `start()`. With `choose_fighter`, a UI can show a grid of fighters for the mouse, and the keys can still step one fighter at a time. The model does not change for this.

### Commands and ownership

Each command carries its sender (a player id). The lobby says which slots each player owns. The authority drops a command for a slot that the sender does not own. Today the slots belong to fixed positions in the packet (0 to 3 for the host, 4 to 7 for the joining computer). With the lobby, a player can own any slots.

### The UI (local)

A screen has two parts:

- The view draws the model and the local UI state. The local UI state is the focus, the hover, the pointer, scroll positions and animations. It is never shared.
- The controller turns local input into commands. For the keyboard, it maps the keys of each local player to commands, as the original does (right on a fighter slot is `step_fighter(slot, 1)`). For the mouse, it uses the widgets that the view drew.

The network menus use Dear ImGui (base/ui/imgui.lua): the view describes its widgets each frame, the engine draws them at the window's resolution and returns the clicks, so the hit areas come from the widgets themselves. Widgets solve the fixed rectangles: when the view draws an entry, it also registers a widget with the area of that drawing and the command of the entry. The controller tests the pointer against the widgets of the last drawn frame. The rectangles then come from the drawing itself, in one place.

The views keep the original look: they draw the original bitmaps at the original positions.

### The network

- The messages are framed: a length, a type and a body. The fixed 22-byte packet of the original goes away. Both computers must run the same scripts anyway (the profile check), and the game versions feature updates the friend.
- Message types: hello (profile and version), lobby changes, command, tick input (key states of the fight), acknowledgment, state hash, snapshot.
- In the menus, the authority sends ordered commands with their tick. The menus do not wait for each frame of the other computer.
- In a fight, the authority combines the key states of all players for each tick and sends them to all clients. Clients send their keys a few ticks ahead, so a late packet does not stop the fight at once (see the delay notes in plan.md).
- Every few ticks, each computer sends a hash of the model. The first difference goes to the log.

### The local game

A local game uses the same model and the same commands, with a local authority in the same program and no network. A replay is a recorded stream of ticks. The .lfr recordings of the original keep the key states of the fight, as today.

## How the requests fit

- Quit: the client sends `leave` and goes back to its launch menu. The other players stay in the lobby.
- The mouse on all menus: a controller and widgets for each screen. The network does not change.
- A separate server: the authority as its own program, which runs the model without a window.
- AI control: the command `set_control(slot, "ai")`, on the same tick for everyone.
- Drops and returns: the authority marks a player as dropped and pauses the match with a command. A returning player gets a snapshot or the stream since the start.
- Less input delay: the client decides the key state of each tick before it sends it, with the lf2-arena merge rule.
- The logs: the ordered stream and the hashes give the difference log.

## The server program

- The server is the same program in a mode without a window (`openlf2 --server`). It runs the authority and the session model, including the fight, so it needs the LF2 installer too.
- To host a game, the game starts the server program on the same computer (as a child process, like the version switch starts a program) and joins it at 127.0.0.1. A player can also start a server on another computer and everybody joins it.
- The server keeps running when the player who started it leaves, as long as its process runs. The lobby gives the role that starts games to another player.
- The current two-computer protocol goes away. Both computers must run the same game version anyway, and the versions feature gives the friend the new one.

## Each computer has its own screen

Each client shows its own screen of the current session phase. For example, in the character selection one player can open the options while another one picks a fighter. Only the commands change the shared state, and each client draws it in its own way. The session phase (lobby, character selection, match, results) is shared, so all clients move to a match together.

## Steps

1. Model and commands for one screen (the character selection), with a local authority, and the look unchanged. Make sure that a headless trace gives the same result as before. The mouse comes with the controller and the widgets of the screen.
2. The server program: a listener with many connections, the framed protocol, the lobby, and the host button that starts the server and joins it. The menus run on commands through the server.
3. The title choices, the battle setup and the championship as models and commands.
4. The fight through the server: the tick stream, the input delay, the merge rule, pause, speed and AI control as commands, and the hashes for the difference log.
5. Drops and returns.

## Decisions

1. Authority: every network game uses the server program (owner's decision).
2. Screens: each computer shows its own screen (owner's decision).
3. Original key quirks: a key must be released before it acts again, and directions repeat while held. This is input handling, so the controllers keep it, and the models do not see it. The rules that change a result, such as the countdown of the character selection, stay in the models. The owner can change this.
4. The click commits: reverted (owner's decision, 99e0cdd).
