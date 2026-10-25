# A new pre-game UI

This document proposes a new design for the menus between the title menu and the fight, for VS mode and Stage mode first. docs/pregame-ui-current.md describes the menus before the redesign and lists their problems. Most of this design is built. The "Steps" section marks what is built, and a "Built" note in a section says where the code differs from the design.

The design uses Dear ImGui (base/ui/imgui.lua), as the network menu and the lobby do. It follows the split of docs/ui-network-architecture.md: the shared state changes only through commands, and each computer draws its own UI.

## Goals

1. One setup screen shows everything that the fight needs: the players, the fighters, the teams, the computers, the arena or the stage, and the difficulty.
2. The mouse, touch, the keyboard and the gamepad all work. Several players on one keyboard still work, each with a cursor.
3. The screen says its rules. A choice that the rules do not allow shows why.
4. A player starts the fight with a button or a key. No countdown starts the fight without a request.
5. Music and sound are local to each computer. They are never part of the shared state.
6. After a fight, a rematch or a change of one fighter takes one step.
7. The rules of the original stay where they change a fight. The fight, the stage data, the random fighters, and the difficulty effects do not change. The one exception is the unlock (see "No locks").
8. Nothing is locked. All fighters and all difficulties of a mode are available from the first start, without a secret word. The cheat keys are not a lock: they keep their word, and the settings menu adds a button for them (see "The cheat keys").
9. The game speed is a normal setting in the menus and in the fight, not a secret key sequence.
10. The fight has a settings menu.

## What is shared and what is local

| Shared (the session model, the same on all computers) | Local (each computer, never on the network) |
|---|---|
| The mode (VS, Stage, Battle) | The cursors, the hover, the focus, the scroll positions |
| The slots: owner, human or computer, fighter, team, ready | Which panel is open, the tooltips |
| The arena (background) or the stage group | Music on or off, the music track, the volumes |
| The difficulty | The language, the layout for the window size |
| The game speed | The display configuration (fullscreen, shadows, filter, FPS) |
| The cheat keys flag (see "The cheat keys") | The overlays (damage chart, input timeline) |
| The random picks (with `engine.random`) | The random music track (with a local random source) |
| The start of the fight | The preview pictures of the arenas |

The rule is the one in AGENTS.md: everything that changes a fight is shared, and the rest is local. The music does not change the fight, so it moves to the local side.

## The flow

```
Title menu
  VS mode / Stage mode / Battle mode
        |
        v
Match setup  (one screen: roster, fighter grid, arena or stage, difficulty, start)
        |  Start
        v
Fight
        |
        v
Results  (Rematch / Change fighters / Setup / Title)
```

The championships and Demo keep their screens for now. Battle mode gets the new setup screen for the fighters, and its troop panel stays as a second step (see "Battle mode").

The title menu gets mouse support: a hover highlights an entry and a click opens it.

Built differently (60216e1): "game start" on the launch menu, and the start of a network session, open the match setup screen in place of the title menu. Its top buttons are the mode tabs (VS, Stage, Battle), Championship, Teams (the team championship), Demo and Replay (local games only), Settings and Exit. Exit goes back to the launch menu, or to the lobby in a network game. The title menu stays behind "Classic menus".

## The match setup screen

### Layout

The screen draws at the resolution of the window, as the lobby does. This layout is for a window of 1280 by 720 pixels or more:

```
+------------------------------------------------------------------------------------+
|  [ VS ]  [ Stage ]  [ Battle ]                                 (settings)  [Exit]  |
+-----------------------------------------------+------------------------------------+
|  FIGHTERS                                     |  ROSTER                            |
|  +----+----+----+----+----+----+----+         |  1 mfc       [Davis  ] [Team 1] OK |
|  | ?? |Bndt|Deep|John|Hnry|Rdlf|Lous|         |  2 Ann       [Random ] [Team 2] .. |
|  +----+----+----+----+----+----+----+         |  3 CPU       [Firen  ] [Team 2] x  |
|  |Firz|Fire|Dvis|Dnis|Wody|Jack|... |         |  4 (empty)   [ + Computer ]        |
|  +----+----+----+----+----+----+----+         |  5 (empty)   Press Attack to join  |
|   cursors: [1] red   [2] blue                 |  ...                               |
|                                               |  Teams: Team 1 (1)  vs  Team 2 (2) |
+-----------------------------------------------+------------------------------------+
|  ARENA                                                     DIFFICULTY              |
|  [Random] [Lee On Road] [Forbidden Tower] [Great Wall] ... (Easy|Normal|Difficult| |
|   picture   picture       picture           picture         CRAZY!)                |
|                                                            SPEED  [====|------] 0.4|
+------------------------------------------------------------------------------------+
|  VS - 3 fighters - Great Wall - Difficult - speed 0.4      [  Start the fight  ]   |
+------------------------------------------------------------------------------------+
```

On a narrow window (a phone, or a small window), the panels stack in one column: the roster, the fighters, the arena, the difficulty, then the start bar. The start bar stays at the bottom of the window. Buttons are at least 44 pixels high, so touch works.

Built: one ImGui window over the 794 x 550 picture of the game, with the fighter grid on the left, the players on the right, and the arena, the rules and the start bar below. It has no layout for narrow windows yet.

### The roster

The roster has one card for each of the eight slots. A card shows:

- The player name, or "Computer".
- The portrait and the name of the fighter.
- The team, as a colored chip: Independent (gray), Team 1 to Team 4 (four colors).
- The state: choosing, ready, or waiting to join.
- In a network game, the owner of the slot and the round-trip time of that player.

An empty card shows "Press Attack to join" for the keyboard and gamepad players of this computer, and a "+ Computer" button. A computer card has a remove button.

A click on a chip opens the list of the teams. The rule of the original about the last team becomes a text under the roster: "All fighters are on one team. Change a team, or add a computer." The start button stays off until the teams are valid. The roster does not skip a team without a message, as the original does.

The team line under the roster shows the sides, for example "Team 1 (2) vs Team 2 (1) vs Independent (1)". In Stage mode it says "Everybody fights on Team 1", and the chips are hidden.

Built: a compact list with one row for each slot that plays: the number, the portrait, the name and the fighter, a team button (a click takes the next team), an amber "Set ready" or a green "Ready" button for a human, and a remove button. Under it are a row to join ("Press Attack to join" and Join) and a row with "+ Computer". In a network game, the join row is only for this computer's own slot. The cards have no owner and no round-trip time. A hint line under the panels says what the player in focus does next.

### The fighter grid

The grid shows all fighters as portraits, in the order of data.txt, with Random first. The fighters that the original hid until the `lf2.net` word are in the grid from the start. The name shows under the portrait or in a tooltip. A fighter that a slot took has a small marker with the color of that slot. Two slots can still take the same fighter, as in the original.

- Mouse and touch: a click on a portrait gives the fighter to the slot that is in focus. The focus is the card that the player clicked last. On one computer with one mouse, this is the way to set the fighters of computers too.
- Keyboard and gamepad: each local player has a cursor on the grid, drawn as a frame in the color of the slot. The arrow keys move it in two directions, attack accepts, jump goes back. Up from the top row reaches Random.

After a fighter, the player chooses a team with left and right on the chips, then attack. In Stage mode the team step does not exist.

Random stays Random on the card ("Random" and a question mark) until the fight starts. Then the game picks the fighters, as `resolve_random` does today. A "Reroll random" button and the old Reset Random entry are not necessary, because the pick happens at the start. After a fight, the Results screen offers "Same random fighters" or "New random fighters".

Built: a grid of seven columns with Random first. A cursor is a frame in the color of its slot, and a taken fighter has a gray frame. The names show on the roster, not under the portraits. "Same random fighters" and "New random fighters" are not built.

### The computers

A "+ Computer" click on an empty card makes a computer slot. The new computer starts as Random on the next free team. Then any player can set its fighter and team: click the card to give it the focus, then pick on the grid.

With keys, a ready player moves the cursor down from the roster cards to an empty card and presses attack to add a computer. On a computer card, the same player sets the fighter and the team with the same keys as for a human slot. Defend on a computer card removes it.

This replaces the question "How many Computer Players?" and the pick of the computers one after the other. A change of one computer does not need a walk back through the others.

### The arena (VS mode and Battle mode)

The arena panel shows a card for each background: Random, Lee On Road, then the backgrounds of data.txt. Each card has a small picture and the name. A tooltip shows the width of the arena (narrow or wide). A click chooses the arena. With keys, left and right move in both directions.

Random keeps its rule of the original: it picks when the fight starts, with `engine.random`, and never picks the last two backgrounds of data.txt.

The pictures are local: each computer draws them from its own copy of the data. The engine makes each picture once (see "Engine work").

Built: all arenas show in two rows. A card shows the first layer of the background, not a picture of all layers, and it has no tooltip. The name of the chosen arena shows above the cards.

### The stage (Stage mode)

In Stage mode, the arena panel becomes the stage panel. It has six cards: Stage 1 to Stage 5 and Survival. A card shows:

- The name and the background picture of the stage.
- The number of parts of the group, from data/stage.dat.
- The portraits of the bosses of the group, from the stage data.
- On this computer only: the best result, for example "cleared on Difficult".

The stage data and the parts do not change. A stage starts at its first part, as in the original. After a lost stage, the setup screen opens with the stage that the players reached.

Built: six cards with the names only, without pictures, parts, bosses and best results. The return to the stage that the players reached is built.

### The difficulty

The difficulty is a row of four buttons: Easy, Normal, Difficult, CRAZY!. A click chooses one, and left and right move with keys. The buttons no longer cycle in the odd order of the original (Difficult, Easy, Normal).

All four buttons are available from the start. A tooltip says what each difficulty does. In Stage mode, for example: "CRAZY!: enemies have more hit points and come in larger groups." Battle mode hides CRAZY!, as in the original.

Built, without the tooltips.

### Ready and start

The start replaces the countdown:

1. A human slot is ready when it has a fighter and a team.
2. The start bar shows a summary line and the button "Start the fight".
3. The button is on when at least one slot is ready, nobody is still choosing, and the teams are valid. If the button is off, the bar says why, for example "Ann is still choosing".
4. With keys, a ready player presses defend to start. This matches the lobby, where defend starts the game.
5. In a network game, only the room role starts. The other players see "Waiting for mfc to start". Changed (owner's decision, 723d449): any player starts.

When the button starts the fight, a short countdown of three seconds shows on all screens. Any player can stop it with jump or a click on "Wait". This keeps the chance of the original to change a choice at the last moment, but a player asks for it.

Built: "Start the fight (Defend)" and the countdown with "Wait (Jump)". When the fight cannot start, the reason shows in place of the summary. A player in focus who is not ready also sees an "I am ready" button in the start bar.

### The mode tabs

The tabs at the top switch between VS, Stage and Battle without the title menu. The fighters stay on the cards. The mode sets the team rules: Stage puts every slot on Team 1, Battle allows Team 1 and Team 2 only. A tab change that breaks a rule shows it on the roster, as the teams text does.

## Sound and music on each computer

### The local configuration

The music becomes part of the configuration of each computer (config.json, next to the language and the window). It has these values:

- Music: on or off.
- VS track: Random, or one of the eight tracks (Main Theme, Stage 1 to Stage 5, Boss, Final Boss).
- Music volume, which F11 and F12 change today.
- Sound effects volume (new).

The settings button in the corner of every menu opens the settings menu (see "The settings menu"). Its Sound page has these values. A change acts at once on this computer only, and it saves the configuration.

Built (87bf8b4, 723d449): the options `music`, `music_track`, `music_volume` and `sound_volume` in config.json. The Music switch is on the launch options page and on the Sound page of the settings menu. The Settings button of the setup screen opens the Sound page. F11 and F12 change the music volume by 10 per press and save it.

### What changes in the code

- The options panel of the character selection no longer calls `music_option`. `options.music` and `options.track` leave the shared state.
- base/game/music.lua reads `enabled` and the VS track from the local configuration.
- The random track uses a local random source, not `engine.random`. The flow can seed a small generator from `options.menu_seed`, which the title already uses for its local choice of a picture. Today the options panel calls `engine.random` on each frame while the choice is Random, so this change also stops the menu from using up shared random numbers.
- Stage mode needs no change in the fight. base/game/stage.lua calls `music.play` for the music of each part. That call only sends a request to the engine, and it does nothing when the music is off.
- A recording keeps writing the music field of its header, with the track of the recording computer, so the original can still read the file. A replay ignores that field and plays the music of the viewer's own configuration (owner's decision). base/ui/flow.lua `start_replay` then no longer sets `music.selected` from the recording.

### A test for the change

The change of the random track changes the random numbers of a VS fight that a trace starts. Headless traces with a fixed `--seed` that pass the options panel then give other fighters for Random slots. Update the expected results of these tests. Old .lfr recordings must still replay the same. Make sure of this with a replay test before and after the change.

## No locks

Built (87bf8b4).

The game starts unlocked. All fighters and all difficulties are available from the first start. The `lf2.net` word goes away, and so does the "Unlock hidden characters" switch of the launch options.

The reason is the moment of the choice. The `lf2.net` flag changes the fight list and three fight rules, and the players see this before the fight starts. A player who picks a hidden fighter decides at the start how the game plays.

Battle mode keeps its rule of the original: Easy, Normal and Difficult, no CRAZY! (owner's decision). This is a rule of the mode, not a lock.

### What changes in the code

- `unlock.flags.characters` is 1 for every new game. `unlock.reset_session` sets it to 1, not to 0, so all computers of a network session start with the same value.
- The `lf2.net` word no longer acts in a live game. `unlock.observe` stops to look for it. The `herofighter.com` word stays (see "The cheat keys").
- `catalog.selectable` and the difficulty row no longer read the flag. They allow everything.
- The `unlock_characters` value leaves the options page and config.json. An old config.json with the value still loads, and the game ignores the value.

### The fight rules change too

The flag is not only a list filter. It also changes three rules of the fight: the Louis EX change at any hit points, the Firen and Freeze merge at any hit points, and Louis EX after the end of a round (docs/pregame-ui-current.md has the details). With the flag always on, every new fight uses these rules. This is the game of the original after `lf2.net`, not the game without it.

### Old recordings

A replay must still use the flags of its recording, or an old fight plays out in another way. `unlock.begin_replay` keeps setting the flags from the header, and `unlock.apply_recorded` keeps toggling them on the recorded frames. Only the live game drops the `lf2.net` word. A new recording writes 1 in the characters field of the header.

### The cheat keys

The `herofighter.com` word is different from `lf2.net`, and it stays (owner's decision). A player can type it in the middle of a fight. In Stage mode, for example, it then changes a long run that started without cheats. The game cannot ask for that choice at the start, so the cheat keys keep their own switch.

- The cheat keys F6 to F9 work in VS mode, as in the original. In the other modes, they work after the word.
- The word keeps its rules: it toggles `unlock.flags.function_keys`, it plays its sound, it travels in the network input, and a recording stores it on its frame.
- The Game page of the settings menu adds a button "Turn on cheat keys". A confirmation asks first: "Cheat keys F6 to F9 then work in all modes, also in the fight that runs now. Turn them on?" The same button turns them off again, without a question.
- The button acts the same as the typed word. It puts the unlock bit of the word into the input of the next frame. So a network game, a recording and a replay see no difference between the button and the word.
- The Game page shows the state: "Cheat keys: VS mode only" or "Cheat keys: all modes".

### Tests

The headless description prints `unlock=` when a flag is set. With the characters flag always on, the description of each trace changes. Update the expected results, and make sure that old .lfr recordings replay the same as before.

## The game speed

The game speed leaves the secret keys M, F and D. It becomes a normal setting with the same rules as today:

- A slider from 0.1 to 1.0, with a notch every 0.1. The value 1.0 is the normal speed, and the slider never goes above it. A stopped fight is the pause, so the slider has no 0.
- 0.4 has a marker: "recommended". The slider can keep the fairy dust of the MFD window as its look.
- With keys, left and right move one notch. The mouse drags the knob or clicks a notch.
- F5, the fast mode of the original, stays a separate key.

### Where the slider is

- In the match setup, in the rules area next to the difficulty. The start bar shows the speed in its summary.
- In the fight, on the Game page of the settings menu. A change acts on the next frame of the fight.
- The launch options do not have it, because the speed belongs to a match.

Built: the slider is in the rules area of the setup screen and on the Game page of the settings menu. `--game-speed 0.4` sets it for traces. The keys M, F and D stay only in the old two-computer TCP game.

### Who sets it

The speed changes which frames of the fight run and how the queued keys merge, so in a network game it is shared.

- Local game: any player sets it. It stays for the next fight, as the other values of the setup stay.
- Network game: any player sets it, in the setup and during the fight, with the command `set_speed(tenths)` (owner's decision). The last change wins. A short line on all screens says who changed it, for example "Ann set the speed to 0.4".
- In a fight of the server program, the command goes into the tick stream with its tick. The server keeps its ticks of 33 ms. At a speed of N tenths, the fight runs on N of each ten ticks, with the same even spread and the same key queue that `fight_due` in base/ui/flow.lua uses today. All clients count the same ticks, so the rollback stays the same on all of them. This does not need a change of the tick time or of the clocks.
- Built (9115dd6): `set_speed` goes to the server, which puts the speed into every final tick and sends a line to every screen. base/game/speed_gate.lua skips the ticks. The server also keeps the speed with the values of the last match.

### What goes away

- `speed_menu.observe` and the sequence M, F, D.
- The separate code for the speed menu in the two-computer network game. The setting goes through the same command as in the other cases.
- The recipe for the speed in AGENTS.md, which types M, F and D. A command-line value, for example `--game-speed 0.4`, sets the speed for traces instead.

## The settings menu

One settings menu serves the whole game. The launch menu opens it with its options entry, every setup screen opens it with the settings button, and the fight opens it with Escape. It draws with Dear ImGui, in a window over the screen.

### Pages

The menu has pages on the left. Each page shows only the values that apply where the menu opens.

Built (base/ui/fight_menu.lua): the pages Game, Sound and Display, as tabs under the Resume button. Game has the computer control of this computer's fighters, pause, fast mode (local games), the cheat keys, the game speed, the input delay (network games) and the cheat keys button. Display has the camera (Classic, Wide, Dynamic zoom), the widest view of the dynamic camera, fullscreen, Show FPS, "Show the connection in network games" and "Classic menus". The upscaling filter, the shading and the shadows stay on the launch options page. The Overlays, Controls and Language pages are not built.

| Page | Values | Shared or local |
|---|---|---|
| Game (in a setup screen and in a fight) | Game speed, the cheat keys button | Shared, any player |
| Sound | Music on or off, VS track, music volume, sound effects volume | Local |
| Display | Fullscreen, upscaling filter, character shading, projected shadows, battlefield layout, show FPS | Local |
| Overlays (in a fight) | Damage chart, input timeline, fight effects | Local |
| Controls | The key sets, rumble, the on-screen gamepad | Local |
| Language | Language, font antialiasing | Local |

A small mark on each value says "for everyone" or "only on this computer".

### In the fight

Escape, the Start button of a gamepad, or the pause button of the touch gamepad opens the menu. These buttons are under the pages:

- Resume.
- Pause for everyone and Step one frame: the same as F1 and F2.
- Fast mode: the same as F5.
- The cheat keys, when they work in this mode: unlimited mana, heal all, weapons from the sky, remove the weapons. The same as F6 to F9.
- End the round: the same as F4.
- Leave the fight. In a network game, this leaves the session, as the leave dialog does today.

The buttons put the function key into the input of the next frame, the same as a key press. The fight, the recording and the network see no difference between a click and a key.

The pause depends on the game:

- Local game: the menu pauses the fight while it is open, and the fight resumes when the menu closes. This replaces the dialog "Leave the fight?".
- Network game: one player cannot stop the fight for the others. The fight goes on, and the keys of this computer are held back while the menu is open, as the leave dialog does today. "Pause for everyone" sends F1, so all computers pause on the same tick.
- Changed (723d449): in a network fight, the menu sends F1 when it opens, so the fight pauses for everybody, and it sends F1 again when it closes. A fight that was paused before stays paused. In the menus of a network game, the game goes on. Step one frame (F2) and End the round (F4) have no button. A local fight has "End the fight" (F4) with a question.

The Controls page shows the keys in a fight, but a change of the keys waits until the fight ends. A change in the middle of a fight can make a held key stick.

### Rules for the menu

- The menu never changes the fight state directly. A shared value goes as a command or a function key into the input. A local value changes only the configuration of this computer.
- The menu replaces the options page of the launch menu (base/ui/launch.lua `option_rows`), the speed menu, and the leave dialogs of the fight. The exit dialog of the launch menu ("Exit OpenLF2?") stays.
- Every value works with keys, so headless traces can test the menu, and the menu has a `describe` line.

## Keyboard and gamepad with several players

Dear ImGui has one keyboard focus. Four players on one keyboard need four cursors, so the setup screen does not use the keyboard navigation of ImGui for the player keys.

- Each local slot has its own cursor state: the panel (grid, roster, arena, difficulty, start) and the position in it. This state is local UI state.
- The keys of each slot move its own cursor. The rules of the original for keys stay: a key acts once per press, and the controllers keep this rule, not the model (decision 3 of docs/ui-network-architecture.md).
- A cursor is a colored frame that the screen draws over the ImGui widget. Two cursors on the same widget show both colors.
- Before a player joins, the cursor of that slot does not exist. Attack joins and puts the cursor on the grid.
- Up and down move between the panels after the player is ready: from the roster down to the arena, the difficulty and the start bar.

The mouse acts for the slot in focus, or for the shared values. Touch acts like the mouse.

Headless runs do not draw ImGui. All actions on the setup screen must work with the seven keys of each slot, so that input traces can test the screen. The screen gives a `describe` line with the mode, the slots, the arena or the stage, and the difficulty.

## The network game

The setup screen uses the session model and the commands of docs/ui-network-architecture.md. These are the commands:

| Command | Who can send it |
|---|---|
| `join(slot)`, `leave(slot)` | The owner of the slot |
| `choose_fighter(slot, id)`, `choose_team(slot, team)` | The owner of the slot. For a computer slot, the player who added it, or the room role |
| `set_ready(slot, value)` | The owner of the slot |
| `add_computer(slot)`, `remove_computer(slot)` | Any player (owner's decision) |
| `set_mode(mode)`, `set_arena(row)`, `set_stage(group)`, `set_difficulty(value)` | Any player (owner's decision). The last change wins |
| `set_speed(tenths)` | Any player, also during a fight (owner's decision) |
| `start()`, `wait()` | `start`: the room role (changed: any player). `wait`: any player during the countdown |

The model checks each command against its state. A command that the rules do not allow does nothing, on all computers alike.

Each computer shows its own screen of the setup. One player can look at the arenas while another one picks a fighter. A slow packet no longer stops the menus, because the menus wait for commands, not for each frame.

When a player changes the mode, the arena, the stage or the difficulty, the control shows the name of that player for a moment, so the others see who changed it.

In the setup, the room role only starts the fight and can set the fighter and the team of any computer. All other shared values are open to every player.

Built (4d55484, 723d449): a click becomes a command (`join`, `leave`, `fighter`, `team`, `ready`, `add_computer`, `remove_computer`, `mode`, `arena`, `stage`, `difficulty`, `start`, `wait` and the screen's buttons), which the server puts into the next final tick. A command acts for the sender's own slot or for a computer slot, so any player sets the computers. The keys of the players reach every client through the combined input. There is no room role: any player starts. The name of the player who changed a value does not show yet, except for the game speed.

## After the fight

The Results screen of the original stays (the table of kills, damage and the rest). Under it, a row of buttons adds:

- Rematch: the same setup again. With keys, attack.
- Change fighters: the setup screen with all values kept. Only the player who presses it goes back to the grid. The other slots stay ready.
- Setup: the setup screen with everything kept.
- Title: back to the title menu.

In Stage mode, the buttons are "Try again" (the same stage group), "Setup" and "Title". After a cleared group, the next group still starts by itself, as in the original. After stage 5, the ending plays.

Built: the setup screen comes back after the fight with the buttons Rematch, Change fighters, Setup and Close, in every mode. "Change fighters" sends every human slot back to the grid, not only the player who pressed it.

## Battle mode

Built as described: the setup screen, then the classic troop panel.

Battle mode uses the new setup screen for the fighters, with Team 1 and Team 2 only. The troop panel stays a second step. Later, it can become an ImGui panel too: one column for each side with a number field for each soldier type, the strategy preset as a list, the size and the defense. This design does not cover the troop panel in detail.

## Engine work

The design needs these additions to the engine and to base/ui/imgui.lua:

1. An image widget: ImGui draws a game bitmap (a portrait from the data, a part of a sprite sheet) as a button that a click can choose. Today the scripts have text, buttons, inputs, selectables and child areas only.
2. Arena pictures: the engine draws the layers of a background once into a small picture and keeps it. The `--preview-backgrounds` code already draws the backgrounds.
3. Overlay frames: the screen draws colored frames over ImGui widgets for the cursors of the players. ImGui returns the rectangle of each widget, or the scripts give the frame to the widget as a flag.
4. A check for older engines: a host can send scripts to an older engine. The scripts must check `if engine.<function> then` before they use a new function, and fall back to the classic screens.

Built (bfa1e93, 723d449): the image widget (also as a button), frames in the colors of the players' cursors on images, the slider, progress bars and colored buttons. The scripts check `context.ui_kinds`. The arena pictures from all layers are not built. Panels without images mark a cursor with ">" in front of the title.

## The classic screens

The new screen is the default (owner's decision). The classic screens stay. A value of the configuration, "Classic menus", chooses them. They give the look of the original for the players who want it, and the fallback for older engines. The existing input traces can keep the classic screens until the new screen has its own traces.

Built: "Classic menus" on the Display page of the settings menu, and `--classic-menus`. In a server session the server decides for every client: `openlf2 --server --classic-menus` runs the classic screens, which the traces of tools/test-online.sh use.

## Steps

1. Local sound and music: the configuration values, the local random track, and the removal of the music from the shared options. This step is small and stands alone. It also fixes the shared music in network games now. Built (87bf8b4).
2. No locks: the characters flag on for new games, the `lf2.net` word off in live games, the replays unchanged. Built (87bf8b4).
3. The settings menu in Dear ImGui, with the game speed and the cheat keys button on the Game page, in the menus and in the fight. Then remove the M, F, D sequence and the old options page. Built (8a7cdc6, 9115dd6), except the removal of the old options page. The M, F, D sequence stays only in the old two-computer TCP game.
4. The game speed in fights of the server program, through the tick stream. Built (9115dd6).
5. The engine work: the image widget, the arena pictures and the overlay frames. Built (bfa1e93), except the arena pictures from all layers.
6. The setup model and its commands for VS mode, with a local authority (step 1 of docs/ui-network-architecture.md). The new screen draws it. The classic screen stays. Built (dce58ad).
7. Stage mode on the new screen: the stage cards and the Stage rules. Built (dce58ad), with stage cards that show the names only.
8. The Results buttons. Built (dce58ad).
9. The network game: the commands through the server program, and the start by the room role. Built (4d55484). Any player starts since 723d449.
10. Battle mode, then the championships. Battle mode is built (the setup screen, then the classic troop panel). The championships open from the buttons of the setup screen and keep their classic screens.
11. The setup screen in place of the title menu, after "game start" and at the start of a network session (not in the first plan). Built (60216e1).

## Decisions

These are the decisions of the owner:

1. The new setup screen is the default. The classic screens stay behind "Classic menus".
2. In a network game, any player chooses the mode, the arena, the stage and the difficulty. The last change wins.
3. In a network game, any player adds and removes computers.
4. Start shows a countdown of three seconds, and any player can stop it.
5. The `lf2.net` word goes away, and the game starts unlocked. The `herofighter.com` word stays, and the settings menu adds a button for it with a confirmation.
6. Battle mode keeps the difficulties of the original, without CRAZY!.
7. In a network game, any player changes the game speed at any time, also during the fight.
8. A replay plays the music of the viewer, not the track of the recording.
9. No player of a network game has more rights than the others: any player starts the fight (723d449).
10. "game start" opens the setup screen in place of the title menu. The title menu stays behind "Classic menus" (60216e1).
