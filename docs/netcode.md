# Netcode design

This document designs how the fight runs over the network: smooth, responsive, true to the real result, and resilient against slow or dropping connections. It builds on docs/ui-network-architecture.md (the session model, commands, the local UI and the server program as the authority). docs/network.md describes the current two-computer lockstep, which this design replaces. Nothing here is built yet.

## Goals

1. Responsive: a key press shows its effect on the next frame on the computer of the player, at any ping.
2. Smooth: the game never stops because of one slow packet or one slow player.
3. True: every computer ends up with the same state, the state that the server computes. A client cannot change the result of another player.
4. Resilient: lost packets, jitter (changes in packet travel time), short drops and long drops each have a planned behavior.
5. Many players: one server holds many rooms at the same time, with spectators and chat.
6. Visible: the game shows and logs the connection quality, so that problems can be found and tuned.

## Why the current lockstep is not enough

- Each frame waits for the packet of the other computer. A single late packet stops the game on both computers.
- TCP delivers bytes in order. When one packet is lost, all later packets wait for its resend (head-of-line blocking). On a connection with loss, this causes stalls of 200 ms and more.
- The game cannot go on without the keys of every player, so one slow player stops everybody.

## The main idea: prediction and rollback

The game is deterministic: the same start state and the same keys give the same result on every computer. Modern fighting games use this with rollback (the GGPO method):

- Prediction: a client runs the fight at once with its own keys. For the other players it guesses that they still hold the keys of their last known tick.
- Rollback: when the true keys of a tick arrive and differ from the guess, the client goes back to its saved state of that tick and runs the ticks again up to now, with the true keys. Then it draws the corrected state.

Most guesses are right, because players hold keys for many ticks. This game helps more: the fight reads the keys only on every second tick (`input_phase` in game/match.lua). A wrong guess on a tick that does not read keys changes nothing, so the client compares the keys only on read ticks.

The cost is low. A release build runs one tick of a two-fighter fight in about 0.15 ms (measured with a headless trace of 3000 ticks). Running 10 ticks again costs about 1.5 ms of the 33 ms frame. Busy fights (battle mode with many soldiers) cost more, so the work starts with measurements.

## The parts

```
 Client                                              Server program
 ------                                              --------------
 keys --> input sampler (key times, merge rule)
            |
            v
 input for tick T+d  ---- UDP, redundant ---->   input buffer per player and tick
                                                  |
                                                  | at the deadline of each tick:
                                                  | final input = received, else predicted
                                                  v
 confirmed inputs   <--- UDP, redundant -----   confirmed tick stream (all players)
   |                                              |
   v                                              v
 rollback engine:                               server simulation (the true state):
  saved states of recent ticks                   hashes, snapshots, results,
  predict, compare, run again                    recordings, returning players
   |
   v
 draw the newest predicted tick
```

### Transport

- UDP in place of TCP, so that a lost packet does not hold back the later ones.
- Two channels on one UDP socket: an unreliable channel for inputs and confirmed ticks, which repeat their data anyway, and a reliable ordered channel for lobby messages, commands of the menus and snapshots.
- A library gives both channels: ENet (small, written in C, used by many games, builds with MinGW for Windows). The engine gets it behind the existing transport interface (src/adapters/network), so the scripts do not see it.
- The web build cannot use UDP. It keeps a WebSocket path with the same messages, without the gain of UDP.
- The port: UDP 12345, opened with UPnP as today.

### The clock

- The server runs the session at a fixed tick rate (30.3 ticks per second, 33 ms, as the original). The game speed menu changes the tick rate of the server, and all clients follow it.
- Each client measures the round-trip time (RTT, the time for a message to go to the server and back) and the jitter. It runs its own tick a little ahead of the server: half the RTT plus a margin for jitter. Then its input for a tick arrives at the server just before the server needs it.
- To change its lead, a client runs its ticks a little faster or slower (up to about 3 %), never in jumps. Players do not see this.
- The server program runs a frame on each arriving message and at least every 4 ms, and a message leaves at once (no wait for the next frame). The server tells how long it kept the echo of the client's time, and the client takes that off its round trip. On one machine the round trip went from 99 ms (one 33 ms frame on each side and at the server) to about 21 ms.

### Input from the client

- Input delay: a client sends the keys of its current tick for tick T + d. A small delay d (0 to 2 ticks) means fewer rollbacks. The client chooses d from the RTT and the jitter, and the player can fix it in the options. At d = 2, connections with up to about 66 ms of extra travel time show no rollbacks.
- Each packet holds the inputs of all ticks that the server has not acknowledged yet, not only the newest. A lost packet then loses nothing, because the next packet repeats its inputs.
- An input is the key state of a player slot for a tick: 7 bits, as today. The merge rule of lf2-arena runs on the client before it sends: with the key times of the engine, changes less than 50 ms apart become one state.

### The server

- The server keeps the inputs of each player for each tick.
- Each tick has a deadline on the clock of the server. At the deadline, the server makes the input of each player final: the received input, or, if none arrived, its prediction (the last known keys).
- The server never waits for a player. One slow or lost player cannot stop the others.
- After the deadline, the server sends the confirmed tick (the final inputs of all players and the commands of that tick) to all clients, again with the unacknowledged ticks repeated in each packet.
- The server runs the fight itself on the confirmed ticks. Its state is the true state.
- The server checks every input: a player can only send keys for the slots that the lobby gives them.

### The rollback engine on the client

- The client saves the match state of each tick in a ring of the last N ticks (N about 12, 400 ms).
- It keeps the newest confirmed tick C. For each tick after C, it runs the fight with confirmed inputs where it has them and predicted ones elsewhere.
- When a confirmed tick arrives, the client compares it with its prediction on the read ticks. If they differ, it restores the state of the first wrong tick and runs again up to its current tick.
- If the client gets more than N ticks ahead of the confirmed tick, it slows its clock (see the clock) instead of guessing further.
- The saved state must contain everything that the fight changes: the match table, the random generator of the engine (`engine.random_state` and its sequence position), and any module state that the fight changes. The fixed game data (the object records, the frames) is shared and not copied.

### Effects during rollback

- Drawing: the client draws only the newest tick after all runs of a frame.
- Sounds: a sound plays when a tick first produces it. If the rollback runs the tick again and the same sound comes again for the same item within one tick, it does not play again. If the corrected run has no such sound, the sound that already played is not taken back. Short sounds make this hard to hear.
- The camera follows the fighter with its smoothing, so that a small correction of a position does not jump the view.
- Overlays (damage chart, combo counter, input timeline) read the state of confirmed ticks, so that they never show a hit that a rollback took back.
- The input timeline shows each rollback and its length.

### Truth

- Every computer converges on the state of the server, because every computer runs the same confirmed inputs.
- Every 30 ticks, each client sends a hash of its confirmed state for a tick, and the server compares it with its own. On a difference, the server sends a snapshot of the true state, the client takes it, and the client writes both states and the last inputs to the log. The game heals itself and the bug can be found.
- The profile check stays: all clients and the server must run the same scripts and engine version. The versions feature delivers them.

### A session (built)

The server program does not run the game itself yet. After the lobby, a session starts: the server sends its random state and the players' slots, and from then on it makes every tick of the whole game final, in the menus and in the fights. The clients run the original menus in lockstep on the final ticks (base/game/online `exchange`): each frame takes the next final tick, like the original's network game, so the menus have the delay of one round trip. A fight runs with rollback on the same ticks, counted from its first tick; once the tick that ends it is final, the menus go on from the next tick. Every 30 ticks of a fight, each client sends a hash of its final state, and the server compares the clients and logs a difference. To run the game on the server (for returning players and saved matches), the server needs the flow without a window.

## Bad connections

| Problem | What happens |
| --- | --- |
| Lost packets | The next packet repeats the data. No stop, no resend wait. |
| Jitter | The client lead and the input delay grow to cover it. More rollback, no stop. |
| A slow player | The server uses the predictions for that player. The others see that fighter hold its keys. The slow player sees corrections. |
| A short drop (under about 2 seconds) | The server predicts the keys of the player. After 500 ms without input, it predicts no keys, so that the fighter does not run off. When the player comes back, the client gets the confirmed ticks it missed and runs them to catch up. |
| A long drop (over about 2 seconds) | The server pauses the match and makes an autosave. The other players choose what happens next (see "A dropped player"). |
| A return | The client connects again with its player key. The server sends a snapshot of the current state and the ticks since then. The client takes the snapshot and joins at the current tick. If the match is paused, it goes on after a countdown. |
| A server stop | The server writes the confirmed ticks as it goes. After a restart, it runs them up to the last tick and the clients join again. |

## A dropped player

When a player drops for more than about 2 seconds:

1. The server pauses the match for everybody and shows who dropped and for how long.
2. The server makes an autosave: a snapshot of the match state and the confirmed ticks, with the setup of the room. The autosave lets the match go on later, also after a server restart or after everybody left.
3. The players who are still there choose one of these:
   - Wait for the player. A timer shows how long they waited. When the player returns, the match goes on after a countdown of 3 seconds.
   - Let the AI take over the fighter. The match goes on after the countdown. When the player returns, they take the fighter back without a pause.
   - Give the fighter to another person in the room, for example a spectator. That person controls the fighter until the player returns and takes it back.
   - Stop and resume later. The match ends now, and the autosave stays. A player can open it again from the room, and the match goes on from the paused tick when the players are back.
4. Who decides: the player with the room role chooses, and the others see the choice. A room setting can choose without a question (for example "always wait 60 seconds, then let the AI take over").

Every pause, for a drop or for the pause key, ends with the same countdown, so that nobody loses a fighter to a sudden start.

## What players see

- A connection line, which a key turns on: the RTT, the jitter, the lost packets, the input delay and the rollback length of each player.
- A small mark on a fighter whose keys are predicted, so that players know why that fighter stands still.
- Logs (with `engine.log`, Phase 1 of plan.md): the RTT, the rollbacks and the hash checks, so that the settings can be tuned.

## Testing

- A network simulator in the transport: an option adds delay, jitter and loss to every packet, for example `--net-sim delay=80,jitter=20,loss=5`. It needs no system tools.
- Headless tests: two clients and a server on one machine, with the simulator on, must end with the same state hash as a run without the simulator.
- A rollback test without network: run a fight, save the state at tick N, run M more ticks, restore tick N, run the same M ticks again, and compare the hashes. A difference shows state that the save does not contain. Run this over many seeds and every mode.
- Linux `tc netem` on the loopback interface can test real UDP behavior. It needs root, so the owner runs it.

## Measurements

The rollback check (`--rollback-check`, base/game/rollback.lua) runs in a fight: every 45 ticks it saves the state, keeps the next 8 inputs, goes back, runs them again and compares the hashes. It passes in versus, stage, survival, battle mode and the demo, on several seeds. The championship is not checked yet.

The state of a fight is the match table and the position of the random streams (`engine.random_position`, new in this engine). The object records, the record cache, the stage description, the background animation counters and the last drawn snapshot are shared, not copied.

Costs in the release build, per operation:

| Mode | Save | Hash | One tick |
| --- | --- | --- | --- |
| Versus, 2 fighters | 0.16 ms | 0.69 ms | 0.19 ms |
| Battle mode, many soldiers | 1.39 ms | 8.2 ms | 0.59 ms |

A save on every tick fits in the 33 ms frame, also in battle mode. A rollback of 8 ticks in battle mode costs about 5 ms. The hash of battle mode is too slow to run often: it must get faster (a fixed field order instead of sorting, numbers without text) or cover fewer fields, before the hash checks of step 4.

### The simulated network

With `--net-sim`, two clients and the server run in one program over simulated links. In a two-player versus fight of 765 ticks, with keys that change every few ticks, every hash check of both clients matched the server:

| Link (each way) | Round trip | Input delay | Rollbacks of client A (count, ticks, longest) | Waits |
| --- | --- | --- | --- | --- |
| 0 ms | 33 ms | 0 | 300, 600, 2 | 0 |
| 40 ms, jitter 10 ms | 132 ms | 2 | 300, 900, 3 | 0 |
| 80 ms, jitter 30 ms, loss 5 % | 223 ms | 2 | 266, 1810, 9 | 0 |
| 150 ms, jitter 60 ms, loss 15 % | 390 ms | 2 | 229, 2666, 12 | 320 |

The round trip includes one frame of 33 ms on each side, because the simulation passes messages once per frame. At a round trip of 390 ms, the clients waited at a fixed rollback window of 12 ticks. The window now follows the round trip (12 to 20 ticks), and the waits went from 320 to 1.

Two causes of differences showed up and are fixed: the flow wrote the unlock bits into the shown fight outside its ticks, and only the shown fight had the function that advances the hit sparks at the end of a tick.

## Many clients, rooms and chat

### Rooms

- One server program holds many rooms at the same time. A room is one session: its lobby, its menus and its match. The room list replaces the "waiting for you" status of today's server list.
- A match has at most 8 fighters, as the original. A room can hold more people than that: the others are spectators, and the room can rotate players between matches (for example, the winner stays).
- Each room runs its own sandboxed script runtime (its own Lua state), so that rooms cannot change each other. The server runs the rooms on a few worker threads. A two-fighter tick costs about 0.15 ms, so one computer can run hundreds of rooms. Busy modes cost more, and the measurements of step 1 set the limit.
- Network use is small: a confirmed tick with 8 players is about 8 bytes of keys. With the repeats and the packet headers, a player needs about 3 to 6 KB per second in each direction.

### Spectators

- A spectator gets the confirmed tick stream, a short time behind (for example 1 second). It needs no prediction and no rollback, and it never sees a correction.
- A spectator who joins late gets a snapshot and the ticks since then, the same as a returning player.
- The delay also keeps spectators from telling players what the others do.

### Chat and presence

- Text chat in each room, in the lobby and during a match, on the reliable channel. A key opens the chat line, and the messages show over the game for a few seconds. The server limits the length and the rate of messages.
- Short signals without typing: a few fixed messages ("Good game", "Wait", "Ready") on keys.
- Presence: the room list shows each room with its players, its mode and its state (lobby, match, results). A player sees who is online on the server.
- Ready check: the room starts a match when the players with fighters are ready. The role that starts games can kick a player.

### Identity

- Each player has a name and a random player key that the game makes once and keeps in the configuration. The server uses the key to give a returning player their slots back, and to keep the same name across sessions.
- Invites: a room has a short code. A player types the code or opens a link to join that room.

### Later

- Match history: the server keeps the results and the tick streams of finished matches, so that players can watch them again (a tick stream is a recording).
- Voice chat is not in this design. Players use their own voice tools.

## Steps

1. Foundation: a hash of the match state, save and restore of the match state, the rollback test above for all modes, and measurements of the cost of a tick and of a save in each mode. Done except the championship check and a faster hash (see Measurements).
2. Local rollback: two simulated clients in one program, with the simulator between them and no real network. The rollback engine, the sound rules and the overlays on confirmed ticks are built and tuned here. Built: base/game/rollback_client.lua, base/game/authority.lua, base/game/net_link.lua and base/game/netsim.lua (`--net-sim`), with the overlays on final ticks and a rollback window that follows the round trip. Open: tuning by play.
3. Transport and server: ENet in the engine, the server program (docs/ui-network-architecture.md), the clock, the redundant inputs and the deadlines. Built: `engine.messages`, `--server`, `--connect`, base/game/server.lua, base/game/online.lua and the lobby screen. Versus fights work with rollback over UDP.
4. The rollback client against the server, with the hash checks and the snapshots.
5. Drops and returns: the 500 ms rule, pause or AI, the session token, the return with a snapshot.
6. Rooms, spectators, chat, presence, ready check and invites.
7. Tuning: the automatic input delay, the clock lead, the connection line and the logs.

## Decisions

1. Input delay: automatic, from 0 to 2 ticks, from the RTT and the jitter. The player can fix it in the options (owner's decision).
2. A long drop: the match pauses, the server makes an autosave, and the players choose to wait, let the AI take over, give the fighter to another person, or stop and resume later (owner's decision, with the last two options added).
3. ENet is the UDP library (owner's decision).
