# The pre-game menus today

This document describes how a player gets from the title menu into a fight in VS mode and Stage mode, as the code works today. It also covers the parts of Battle mode and the championships that use the same screens, and the network cases. docs/pregame-ui-redesign.md proposes a new design.

The port copies the original LF2 v2.0a. Most of the rules below are rules of the original, not choices of OpenLF2.

## The screens in order

A player goes through these screens:

1. The launch menu (base/ui/launch.lua): game start, network game, control settings, recording info, official website, options. The mouse drives it.
2. The title menu (base/ui/title.lua): VS mode, Stage mode, 1 on 1 Championship, 2 on 2 Championship, Battle mode, Demo, Playback Recording, Quit. Up and down move the highlight, attack opens the entry. A click on the menu only shows the key list.
3. The character selection (base/ui/character_select.lua). VS mode, Stage mode and Battle mode use it. It has four steps inside one screen: the human slots, the number of computers, the computer slots, and the options panel.
4. Battle mode only: the battle setup (base/ui/battle_setup.lua), with the troops of each side and its own options panel.
5. The fight (base/ui/match_screen.lua, base/game/match.lua).

The championships use their own screen (base/ui/championship.lua) with a bracket. ui/flow.lua routes the screens: each screen asks for the next one with `context.action(name)`, for example `start_match` or `title`.

## Who controls what

The character selection has eight slots, in two rows of four. Slot N belongs to key set N in the control settings. On one computer, up to four players use the four key sets, so they own slots 0 to 3. A slot shows the player name of its key set.

Each player uses the seven keys of the original: up, down, left, right, attack, jump and defend. The mouse does nothing on this screen. The character selection reads only the held keys of each slot.

A key acts once when the player presses it. The slot then waits until the player releases all keys (the `latched` flag). Because of this, a held key does not repeat on this screen.

## Step 1: the human slots

Each slot goes through phases (`constants.character_slot_phases`): empty, choosing a fighter, choosing a team, ready.

### Join

An empty slot shows a blinking "Press Attack to join!" picture and "Join?". The player of the slot presses attack to join. If all slots are empty, jump goes back to the title menu.

### Fighter

After the join, the slot shows the portrait and the name of the fighter, which blinks. These keys work:

- Right and left step through the fighters in the order of data.txt. The list wraps through Random.
- Up jumps to Random.
- Attack accepts the fighter.
- Jump leaves the slot (empty again).

The player sees one fighter at a time. To reach the last fighter of the list, the player steps through all the others, or steps left from Random. Hidden fighters show only after an unlock.

Random stays Random until the screen leaves the human slots. Then the game picks a fighter for each Random slot from the fighters that nobody took (`resolve_random`, with the shared random generator).

### Team

After the fighter, the team name blinks under it. Right and left step through Independent, Team 1, Team 2, Team 3 and Team 4. Attack accepts, jump goes back to the fighter.

The mode changes the team rules:

- VS mode: all five choices. If seven slots are ready, the eighth slot cannot join the team that all the others are on, so the fight cannot start with one side only. The screen skips that team without a message.
- Stage mode: no team step. Every slot is on Team 1, and the computers fight next to the players.
- Battle mode: only Team 1 and Team 2. The top row starts on Team 1, the bottom row on Team 2.
- Championship: Independent, and the screen accepts it at once.

The team of each slot stays from the last visit, except where the mode sets it.

### Ready and the countdown

A ready slot shows its fighter and team in white. If a ready player presses jump before the countdown starts, the slot goes back to its last choice.

The countdown starts when at least one slot is ready and all other slots are empty or ready. It runs 150 frames (about five seconds) and shows the numbers 5 to 1. During the countdown:

- If a ready player presses jump, the countdown loses 31 frames (about one second).
- If a new player joins, the countdown stops and starts again later from the full time.
- If all eight slots are ready, the countdown ends at once.

Nobody presses a "start" key. The time runs out, and the screen goes on to the number of computers.

## Step 2: the number of computers

A box asks "How many Computer Players?" and shows the digits 0 to 7. Any ready player moves the choice with left and right and accepts it with attack. The players share this one choice.

- The highest number is the number of free slots.
- In VS mode and Battle mode, the lowest number is 1 if the ready players form fewer than two sides. Otherwise it is 0. Stage mode allows 0.
- The digits that the choice cannot reach are gray.
- The number stays for the next visit.

In the championships, the screen fills all free slots with computers and does not wait.

## Step 3: the computer slots

The computers take the free slots in order. The ready players then choose the fighter and the team of each computer, one computer after the other. All ready players control the same cursor: any of them can press a key.

- Right and left step the fighter, up chooses Random, attack accepts.
- In VS mode and Battle mode, the team step follows, with the same keys. The last computer follows the same "not everyone on one team" rule as the last human.
- In Stage mode, the computer has no team step.
- Jump goes back one step. From the first computer, jump goes back to the number of computers.

The computer names show in red. After the last computer, the Random slots get their fighters and the options panel opens.

## Step 4: the options panel

The options panel opens in the top-left corner, over the slots. In Battle mode, the battle setup opens first, and its own options panel comes after it.

The panel has six rows:

| Row | VS mode | Stage mode |
|---|---|---|
| Fight! | Starts the fight | Starts the stage |
| Reset All | All slots become empty, back to step 1 | Same |
| Reset Random | New fighters for the slots that were Random | Same |
| Background / Stage | Steps to the next background | Steps to the next stage |
| Difficulty | Steps to the next difficulty | Same |
| Exit | Back to the title menu | Same |

The panel starts on Reset Random. All ready players move one shared highlight with up and down, and attack runs the highlighted row. Jump does nothing on this panel.

### Background (VS mode and Battle mode)

The background row shows a name. Each attack press steps forward through this list: Random, Lee On Road (a built-in background, row 99), then each background of data.txt, then Random again. The list has no backward step. To go back one background, the player steps through the whole list.

The player sees only the name, not a picture. The background loads when the fight starts.

Random picks the background when the fight starts, with the shared random generator. Random never picks the last two backgrounds of data.txt.

### Stage (Stage mode)

In Stage mode, the same row shows "Stage" with the values 1, 2, 3, 4, 5 and Survival. Attack steps forward and wraps. Each stage uses a fixed background: stage 1 uses background row 1, Survival uses row 6.

A stage group has several parts. The fight goes from one part to the next by itself (the shutter effect between the parts). The stage data comes from data/stage.dat (base/game/stage.lua).

After the last part of a group, the next group starts at once, without the menus. After stage 5, the ending plays. If the players lose, or a player leaves at the end, the game goes back to the options panel. The Stage row then shows the group that the players reached.

### Difficulty

The values are Easy, Normal, Difficult and CRAZY!. The panel starts on Difficult. Each attack press steps Difficult, Easy, Normal, then Difficult again. CRAZY! comes after Difficult only after the unlock. Battle mode has no CRAZY!.

In Stage mode, the difficulty changes the enemies: Easy and CRAZY! change their hit points, and CRAZY! sends about 1.5 times as many enemies. In VS mode, the difficulty sets the skill of the computers.

### Music

The music choice is not a row of the panel. While the panel shows, a line in the top-right corner shows "Music: ..." and "(Press Left/Right to change)". Any ready player changes it with left and right.

- VS mode: Random, Main Theme, Stage 1 to Stage 5, Boss, Final Boss, and OFF. The track plays when the fight starts.
- Stage mode: only ON and OFF. The stage data chooses the music of each part.
- Battle mode: the battle options panel has no music line. The fight plays the last track that VS mode chose, if there is one.

OFF stops the music at once and keeps it off, also in the menus. The choice stays for the next visit. A recording stores the chosen track in its header, and a replay plays that track.

The music volume is separate. F11 and F12 change it, on each computer for itself. The flow reads these keys from the local keyboard only.

### The values that stay

The original keeps the options in global variables. The port keeps them in the state of the character selection, and the next visit copies them (`previous` in `selection.create`). The background, the stage, the difficulty, the music, the number of computers and the teams stay. The fighters and the phases start over.

## After the fight

- VS mode: the result screen, then the options panel again, with the same fighters. The players choose Fight! for a rematch, or Reset All for new fighters.
- Stage mode: see the Stage section.
- Battle mode: the options panel of the battle setup.
- Championship: back to the bracket.

## Battle mode

Battle mode uses the character selection with two sides (Team 1 and Team 2). After the computers, the battle setup screen shows a panel for each side. The panel has the troops of the side: nine soldier types plus milk and beer, each with a number in the first wave and a number in reserve. It also has a strategy preset (for example Balanced, Giant, Full), a size (S, M, L) and a defense value. Its options panel has the rows of VS mode without the music line.

## Locks, the game speed and the keys of the fight

### The unlock words

The original has two secret words. A player types them on the keyboard on any screen (base/game/unlock.lua):

- `lf2.net` sets `unlock.flags.characters`. The hidden fighters then show in the fighter list, and CRAZY! shows in the difficulty list. The options page of the launch menu has the same switch as "Unlock hidden characters" (base/ui/launch.lua, `unlock_characters` in config.json).
- `herofighter.com` sets `unlock.flags.function_keys`. Then the cheat keys F6 to F9 work in all modes. Without it, they work only in VS mode.

A second time, the word turns its flag off again. A sound plays each time.

The characters flag also changes three rules of the fight:

- Louis can change into Louis EX with his jump-attack combination only below 178 hit points. With the flag, the limit is gone (base/game/control.lua).
- Firen and Freeze can merge into Firzen only below a hit-point limit. With the flag, the limit is gone (base/game/merge.lua).
- At the end of a round, Louis EX changes back into Louis. With the flag, he stays Louis EX (base/game/frame_rules.lua).

A recording stores both flags in its header, and a frame of the recording stores a typed word. A replay sets the flags from the header and toggles them on the recorded frames. A network session starts with both flags off on all computers (`unlock.reset_session`), and the typed words travel in the combined input.

### The game speed (MFD)

The game speed menu is an OpenLF2 extension (base/ui/speed_menu.lua). A player opens it with the keys M, F and D in this order, on any screen. It is not in any menu, so a player finds it only from the documentation.

The menu is a slider from 0 to 1 with a notch every 0.1. It sets `speed.tenths`. A fight then runs on that share of the frames: 0.4 runs four frames of ten. The menus and the window keep the full frame rate. The value 0 stops the fight, and 1 is the normal speed. The slider marks 0.4 as the "sweet spot". Fairy dust drifts around the window.

The speed never goes above the normal speed. F5 is the fast mode of the original, and it is separate.

At a low speed, the keys of the players go into a queue (`fight_due` in base/ui/flow.lua), so a short press still counts on the next frame that runs.

- Local game: the speed is local, and the game does not record it.
- Two-computer network game: the host sets the speed, and it travels in the combined input. The joining computer sees the value, but cannot change it.
- Server program: the server runs the fight on its own ticks, so the flow hides the speed menu.

The input traces in AGENTS.md set the speed with the keys M, F and D.

### The keys of the fight

The function keys of the original work in the fight (base/game/match.lua):

- F1 pauses and resumes. F2 runs one frame while the fight pauses.
- F4 ends the round, or leaves a replay or a championship.
- F5 turns the fast mode on and off.
- F6 turns off the mana cost of moves (unlimited mana), F7 heals all fighters, F8 drops weapons from the sky, F9 removes the weapons (and in Stage mode, the enemies). These are the cheat keys.
- F11 and F12 change the music volume.

Escape opens the dialog "Leave the fight?" (base/ui/quit_dialog.lua) in a local game. In a server session, Escape opens a leave dialog in Dear ImGui while the fight goes on. The touch gamepad has a pause button and a fast button.

The fight has no settings menu. To change the language, the fullscreen mode or the shadows, the player leaves to the launch menu. To change the music, the player goes back to the options panel of the character selection.

## The network cases

The menus run in lockstep in a network game. Each computer runs the same screens on the combined keys of all players. Because of this, every choice in the menus is shared, and every player sees the same screen.

- The two-computer game (base/ui/network.lua): the host owns slots 0 to 3, the joining computer owns slots 4 to 7.
- The server program (base/game/online.lua): the lobby first (base/ui/online_lobby.lua, drawn with Dear ImGui), then the title menu of the session. Each client owns one slot, and the keys of its player 1 drive that slot. The menus run on the final ticks of the server.

Playback Recording is not available in a network game.

These rules follow from the lockstep:

- The music choice is shared. One player who turns the music off turns it off for all players.
- The random music track comes from the shared random generator (`engine.random` in `music_option`). The panel draws a new random track on each frame while the choice is Random. So the music choice uses up shared random numbers, and it must stay the same on all computers.
- The options panel has one highlight for all players. Two players who press keys at the same time move the same highlight.
- Each slot has its own keys, but the computer slots and the options panel take keys from every ready slot.
- A slow packet stops the menus too.

## Problems for the players

These problems come from the design of the original, and the redesign tries to fix them:

1. One fighter at a time. The player steps through a list of more than 20 entries and sees no overview.
2. No mouse. The mouse works on the launch menu, but not on the title menu, the character selection or the options panel.
3. Hidden rules. The team that the last player cannot take, the countdown, and the skip with jump have no text on the screen.
4. The countdown starts the game. Nobody says "start", and a new player who joins late stops it.
5. The number of computers comes before their fighters, as a separate question. To change one computer, the players go back through all of them.
6. The background has a name only, no picture, and steps in one direction only.
7. The stage has a number only. The screen does not say what a stage holds.
8. The music hides outside the panel, and it is shared in a network game.
9. The options are a modal panel over the slots, with one shared highlight.
10. After a fight, a change of one fighter needs Reset All, which empties every slot.
11. Hidden fighters and CRAZY! need a secret word, and the cheat keys need another one.
12. The game speed needs a secret key sequence, and the fight has no settings menu.
