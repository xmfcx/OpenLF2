# The fight screen

This document describes the new fight screen: the HUD, the panels, the camera and the colors. It replaces the classic HUD only as an option. The classic screen stays. The design is local to each computer and only reads the fight, so it cannot change a network game or a recording.

## What the screenshots show

The screenshots are from Xvfb at 1280x720, 1920x1080 and 3840x2160 with the dynamic camera, in VS mode, Stage mode and Survival.

1. The top panel always has 8 frames, also in a fight of one or two fighters. It keeps the 794-unit width of the original, so a 16:9 window has black bars at both sides of it.
2. A black strip lies under the panel (the Stage status text) and another below the world.
3. The damage share and the input timeline stay inside the classic 794 x 550 box. They cannot move to the sides of a wide window.
4. The dynamic camera never shows less than the classic scale of the window, and it zooms out only when the fighters spread apart. In Stage mode it never shows more than the open section, so Survival never zooms out. Page Up multiplies the automatic view, and nothing saves it. At 4K the picture is the 1080p picture scaled up.
5. The colors disagree. In the 4K VS shot the second fighter has a red name and a red flag, but a green band in the damage chart. In Stage mode all players have the same team color.
6. Stage mode shows only "Man: 1 HP: 50" for the enemies. Nothing shows which enemies and bosses are left.
7. Pause bug: the settings menu sends F1, which toggles the pause. When the fight is paused and Escape closes and opens the menu quickly, the menu sends F1 to resume. It opens again while the fight is still paused, so it sends no F1 to pause. Then the resume arrives, and the fight runs behind the open menu.
8. The damage chart takes a sample every 15 frames of `frame_number`, and `frame_number` counts the paused frames too. So the chart goes on during a pause.

## Principles

- The whole window is the canvas. The HUD and the panels use the full width and height of the window, at the resolution of the window, so they are sharp at 4K.
- The screen shows only what exists: one card for each fighter in the fight.
- Everything reads the fight state. Every computer runs the same final ticks, so every player sees the same enemy counts and boss bars at the same time, with no new network messages.
- The classic screen (`classic` layout) stays as it is.

## Layout

A 16:9 window, zoomed out:

```
+----------------------------------------------------------------------------------+
| [P1 mfc  ######-- ####--] [P2 ali ########] | [Com ####----]  [Com #######-]      |  cards, grouped by team
|                    BOSS  Julian  ##########################------  1320/1500     |  boss bars (Stage)
| [Damage share     ]                                         [Stage 2-3  phase 2/4]|
| [  ~~~~~~~~~~~~~~ ]                                         [Bandit x7 Hunter x3 ]|  panels in the free rows
|..................................................................................|
|                                                                                  |
|   world: the camera fills the width; a wider view is less tall                   |
|                                                                                  |
|..................................................................................|
| [Input timeline]                                          VS mode (Difficult)    |
+----------------------------------------------------------------------------------+
```

### Fighter cards

```
|#| [face] mfc            x2  K3 |
|#| HP ###############----  457  |   red, the dark HP lighter behind it
|#| MP #########----------  210  |   blue
```

- `|#|` is the color strip of the player (the colors section that follows).
- One card for each fighter. The cards sit in slot order and in groups by team, with a gap between the teams. 1 to 4 cards are wide, 5 to 8 cards are compact.
- A card shows the face, the name, HP (with the dark HP and the healing flash of the original), MP, the lives left in Stage mode, and the kills.
- A fighter who is out shows a dim card. A computer controlled player shows "CPU".

### Stage mode

- A stage panel shows "Stage 2-3" (or "Survival 7"), the phase, and the enemies that are left, by type: a small face and "x7". The count includes the enemies that are on the field and the ones that still wait to come.
- Each boss has a large bar under the cards, with its face, name and HP. Several bosses stack.
- All of it comes from the stage data and the fight state (base/game/stage `run.runtime`), so it is the same on all computers.

### Panels

- The panels are the damage share, the input timeline and the stage panel (and a minimap if you want one).
- You can drag a panel anywhere in the window and resize it. The panel keeps its nearest corner as an anchor, so it stays in place at another window size. config.json saves the places.
- The settings menu (Display page) shows or hides each panel.

### The world band

- The camera fills the width of the window. A wider view is less tall, because the art has a fixed height. The world sits in the middle of the rows under the cards, and the free rows above and below it go to the panels.
- The free rows show a dark gradient, not black.

## Camera

- The camera frames the fighters automatically (Auto) or holds the zoom that you pick. The mouse wheel, Page Up and Page Down change the zoom, and Home goes back to Auto. config.json saves the zoom.
- The widest view is the whole stage. In Stage mode the closed part past the open section shows darker, so you see the whole map and what comes next.
- The camera never writes to the fight (docs/camera.md).

## Colors

The default colors of Age of Empires II, by player slot (the colorblind sets are not used):

| Slot | Color | Value |
| --- | --- | --- |
| 1 | Blue | `#3e59f8` |
| 2 | Red | `#eb0000` |
| 3 | Green | `#00fe00` |
| 4 | Yellow | `#ffff01` |
| 5 | Cyan | `#00ffff` |
| 6 | Purple | `#bd2bbb` |
| 7 | Grey | `#797979` |
| 8 | Orange | `#f99200` |

The same color shows on the card, on the name under the fighter, in the damage chart and on the minimap. Stage enemies keep the original look.

## Minimap

A panel like the others: the whole stage as a thin strip, the open section, the view of the camera, a dot in the player color for each fighter, small marks for enemies and a large mark for a boss.

## Pause

- The settings menu pauses by a state, not by a toggle. While your menu is open, your keys carry a letter, like the letter `A` of the computer control. The fight stays paused while the keys of any player carry it. Every player sees "Paused by mfc".
- A fast Escape, Escape cannot lose a pause, because each tick carries the state again.
- The fight goes on only when all menus are closed.
- F1 keeps its own toggle, as in the original.

## Damage chart

The chart takes its samples by fight time (`elapsed`), which stops during a pause, at game speed 0.4 and while the menu holds the fight.

## Decisions

- Modern cards at the resolution of the window, not the LF2 frame art.
- Auto zoom plus a saved zoom of your own, up to the whole stage.
- The player colors in all modes, by slot.
- In Stage mode the closed part shows darker.
- The fight stays paused while any menu is open.
- The world sits in the middle.
- A minimap panel.
- The new screen is the default. Configs with the old Wide or dynamic layouts change to it, and a config with the classic layout keeps it.

## Steps

1. Fix the pause and the chart time.
2. Add the player colors.
3. Let the panels use the whole window, with anchors.
4. Camera: the saved zoom, the mouse wheel, the whole stage, the darker closed part.
5. Add the fighter cards.
6. Add the stage panel and the boss bars.
7. Add the minimap.
8. Test at 1280x720, 1920x1080 and 3840x2160, locally and in a network game, and run both online test suites.
