#!/bin/bash
# Headless tests of the server program (docs/netcode.md): a server and clients on this machine run scripted sessions,
# and the test fails when a client reports an error, a state difference or a missing step.
#
# Usage: tools/test-online.sh [build directory, default build/debug]
# Needs the LF2 installer in ~/.local/share/OpenLF2/LF2_v2.0a.exe (or $LF2_INSTALLER).
set -u
BUILD=${1:-build/debug}
GAME="$BUILD/openlf2"
INSTALLER=${LF2_INSTALLER:-$HOME/.local/share/OpenLF2/LF2_v2.0a.exe}
WORK=$(mktemp -d)
FAILED=0
trap '[ "${KEEP:-}" = 1 ] && echo "outputs in $WORK" || rm -rf "$WORK"' EXIT

# Frames: a comma ends one 33 ms frame. A connected headless client paces its frames in real time.
wait_frames() { printf ',%.0s' $(seq 1 "$1"); }

check() { # name, condition result (0 = pass), details
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAILED=1; fi
}

# run_session NAME PORT TRACE1 TRACE2: starts a server and two clients, then leaves the outputs in $WORK/NAME.*.
run_session() {
    local name=$1 port=$2
    mkdir -p "$WORK/server-config"
    timeout 120 "$GAME" --server --installer "$INSTALLER" --scripts scripts --config-dir "$WORK/server-config" --port "$port" \
        ${SERVER_FLAGS---classic-menus} \
        > "$WORK/$name.server" 2>&1 &
    local server=$!
    sleep 2
    timeout 110 "$GAME" --headless --installer "$INSTALLER" --scripts scripts --connect 127.0.0.1 --port "$port" \
        --input-trace "$3" > "$WORK/$name.one" 2>&1 &
    local one=$!
    timeout 110 "$GAME" --headless --installer "$INSTALLER" --scripts scripts --connect 127.0.0.1 --port "$port" \
        --input-trace "$4" > "$WORK/$name.two" 2>&1
    wait "$one"
    kill "$server" 2>/dev/null
    wait "$server" 2>/dev/null
}

# Common parts of the traces. The room role goes to the client that joins first, so both press start (the other
# one's press does nothing).
L=$(wait_frames 30)
START="${L}c$(wait_frames 15)f$(wait_frames 70)"   # ready, start, then the session starts and the title shows
PICK="c$(wait_frames 15)c$(wait_frames 15)c$(wait_frames 200)"  # join, fighter, team, then the countdown
MENU="c$(wait_frames 30)u$(wait_frames 15)u$(wait_frames 15)c$(wait_frames 60)"  # no computers, Fight!
FIGHT=$(printf 'r,r,rc,,c,,rb,,c,c,rc,,lf,,%.0s' $(seq 1 20))

client_checks() { # scenario, side, screen pattern
    local out="$WORK/$1.$2"
    grep -qE "$3" "$out"; check "$1: client $2 ends at $3" $? "$(grep -oE 'screen=[a-z_]+' "$out" | tail -1)"
    ! grep -qiE "traceback|attempt to|error" "$out"; check "$1: client $2 has no script error" $? "$(grep -iE 'traceback|attempt to|error' "$out" | head -1)"
}
server_checks() { # scenario, whether the clients' hashes must have been compared (1 = yes)
    ! grep -qE "desync|difference" "$WORK/$1.server"; check "$1: the server finds no state difference" $? "$(grep -E "desync|difference" "$WORK/$1.server")"
    if [ "$2" = 1 ]; then
        grep -q "hashes agree" "$WORK/$1.server"; check "$1: the server compared the clients' hashes" $? "no comparison"
    fi
}

# Most scenarios use the classic character selection (the server's --classic-menus); scenario 9 the setup screen.
# 1. A whole versus game: lobby, start, the original title menu and character selection, a fight with rollback;
#    F4 ends it, the character selection comes back, and a second fight starts (rollback, then lockstep, then rollback).
TITLE="c$(wait_frames 30)"                           # Versus
# F4 held for three frames: the fight reads the function keys on every second tick, and a release clears the key.
AGAIN="4,4,4$(wait_frames 118)c$(wait_frames 60)"  # F4, the options of the character selection, Fight! again
run_session versus 23601 "$START$TITLE$PICK$MENU$FIGHT$AGAIN$FIGHT" \
    "$START$(wait_frames 31)$PICK$(wait_frames 136)$FIGHT$(wait_frames 180)$FIGHT"
for side in one two; do
    client_checks versus $side "screen=match"
    sent=$(grep -oE 'sent=[0-9]+' "$WORK/versus.$side" | tail -1)
    [ -n "$sent" ] && [ "${sent#sent=}" -gt 0 ]; check "versus: client $side sends state hashes in the second fight ($sent)" $? "${sent:-none}"
done
for side in one two; do
    grep -q "fights=2" "$WORK/versus.$side"; check "versus: client $side plays the second fight" $? "$(grep -oE 'fights=[0-9]+' "$WORK/versus.$side" | tail -1)"
done
server_checks versus 1
grep -q "hashes agree (10 checks" "$WORK/versus.server"; check "versus: hashes agree over both fights (10 checks)" $? "$(grep 'hashes agree' "$WORK/versus.server" | tail -1)"

# 2. Stage mode: both players against the stage's enemies (the computer fighters run on every client alike).
STAGE="d$(wait_frames 15)c$(wait_frames 30)"           # down to Stage mode
STAGE_PICK="c$(wait_frames 15)c$(wait_frames 200)"     # join, fighter (stage mode has no team), the countdown
run_session stage 23602 "$START$STAGE$STAGE_PICK$MENU$FIGHT" "$START$(wait_frames 46)$STAGE_PICK$(wait_frames 120)$FIGHT"
for side in one two; do client_checks stage $side "screen=match.*stage="; done
server_checks stage 1

# 3. The title's Quit brings both back to the lobby, still connected, and a new session starts.
QUIT="u$(wait_frames 15)c$(wait_frames 60)"            # up from VS mode to Quit
run_session quit 23603 "$START${QUIT}c$(wait_frames 15)f$(wait_frames 90)" "$START$(wait_frames 76)c$(wait_frames 15)f$(wait_frames 90)"
for side in one two; do client_checks quit $side "screen=title"; done
grep -c "session started" "$WORK/quit.server" | grep -q "^2$"; check "quit: the server started a second session" $? "$(grep -c 'session started' "$WORK/quit.server") sessions"

# 4. The game speed in a fight: client one sets 0.4 in the settings menu; both fights skip the same ticks.
SPEED="#27,,,=speed:4,,,#27,,,"
run_session speed 23605 "$START$TITLE$PICK$MENU$SPEED$FIGHT$FIGHT" "$START$(wait_frames 31)$PICK$(wait_frames 145)$FIGHT$FIGHT"
for side in one two; do client_checks speed $side "screen=match"; done
server_checks speed 1
grep -q "set the speed to 0.4" "$WORK/speed.server"; check "speed: the server took the speed" $? "no speed line"
line=$(grep -oE "screen=match frame=[0-9]+" "$WORK/speed.one" | tail -1); ticks=$(grep -oE "online=tick=[0-9]+" "$WORK/speed.one" | tail -1)
frame=${line##*=}; tick=${ticks##*=}
[ -n "$frame" ] && [ -n "$tick" ] && [ $((frame * 10)) -lt $((tick * 6)) ]; check "speed: the fight runs on fewer ticks (frame $frame of tick $tick)" $? "frame=$frame tick=$tick"

# 5. A player leaves during a fight: the other one goes on (the server predicts the missing keys as none).
LONG=$(printf 'r,,rc,,c,,%.0s' $(seq 1 60))
run_session leave 23604 "$START$TITLE$PICK$MENU$FIGHT$LONG" "$START$(wait_frames 31)$PICK$(wait_frames 136)$(printf 'r,,%.0s' $(seq 1 30))"
client_checks leave one "screen=match"
grep -q "left" "$WORK/leave.server"; check "leave: the server saw the player leave" $? "no leave"

# 6. A dropped player: client two leaves during a fight; the game waits, and client one (the room role now) lets the
#    computer play the fighter (one of the two slots is the dropped one).
DROP="$(wait_frames 150)=drop_computer_0,,,=drop_computer_1,,,$(wait_frames 150)"
run_session drop 23606 "$START$TITLE$PICK$MENU$FIGHT$DROP" "$START$(wait_frames 31)$PICK$(wait_frames 136)$(printf 'r,,%.0s' $(seq 1 30))"
client_checks drop one "screen=match"
grep -q "dropped: " "$WORK/drop.server"; check "drop: the server saw the drop" $? "no drop"
grep -q "the computer plays" "$WORK/drop.server"; check "drop: the computer plays the dropped fighter" $? "$(tail -3 "$WORK/drop.server")"
grep -qE "item[0-7]\{[^}]*computer=1" "$WORK/drop.one"; check "drop: client one sees the computer play it" $? "no computer=1"

# 6b. Give the fighter to another player: client one takes the dropped fighter and plays it with its player 2's keys
#     (the ids of the peers and slots are 1 or 2 and 0 or 1; the clicks that do not fit do nothing).
GIVE="$(wait_frames 150)=drop_give_0_1,,=drop_give_0_2,,=drop_give_1_1,,=drop_give_1_2,,$(printf 'r/l,,%.0s' $(seq 1 60))"
run_session give 23612 "$START$TITLE$PICK$MENU$FIGHT$GIVE" "$START$(wait_frames 31)$PICK$(wait_frames 136)$(printf 'r,,%.0s' $(seq 1 30))"
client_checks give one "screen=match"
grep -q "plays the fighter of" "$WORK/give.server"; check "give: client one took the dropped fighter" $? "$(tail -3 "$WORK/give.server")"

# 7. The dropped player comes back: a new client with the same name joins during the fight, runs the session's final
#    ticks to catch up, and plays on with the same state (the server compares its hashes with client one's).
start_server() { mkdir -p "$WORK/server-config"; timeout 150 "$GAME" --server --installer "$INSTALLER" --scripts scripts \
    --config-dir "$WORK/server-config" --port "$1" --classic-menus > "$WORK/$2.server" 2>&1 & SERVER=$!; }
client() { timeout 140 "$GAME" --headless --installer "$INSTALLER" --scripts scripts --connect 127.0.0.1 --port "$1" --input-trace "$2" > "$3" 2>&1; }
start_server 23607 return; sleep 2
client 23607 "$START$TITLE$PICK$MENU$FIGHT$LONG$LONG" "$WORK/return.one" &
one=$!
client 23607 "$START$(wait_frames 31)$PICK$(wait_frames 136)$(printf 'r,,%.0s' $(seq 1 30))" "$WORK/return.two"
sleep 2
client 23607 "$(wait_frames 30)$LONG" "$WORK/return.three"
wait "$one"; kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
grep -q "is back" "$WORK/return.server"; check "return: the server gave the slot back" $? "$(tail -3 "$WORK/return.server")"
client_checks return three "screen=match"
! grep -qE "desync|difference" "$WORK/return.server"; check "return: no state difference after the return" $? "$(grep -E "desync|difference" "$WORK/return.server")"
grep -c "hashes agree (1 checks" "$WORK/return.server" | grep -q "^2$"; check "return: the hashes agree with the returning player" $? "$(grep 'hashes agree' "$WORK/return.server")"

# 8. Stop and resume later: both players leave during a fight, the server saves the session, two clients with the
#    same names come back, the room role resumes, both run the saved ticks to catch up, and the fight goes on.
start_server 23608 resume; sleep 2
client 23608 "$START$TITLE$PICK$MENU$FIGHT" "$WORK/resume.one" &
one=$!
client 23608 "$START$(wait_frames 31)$PICK$(wait_frames 136)$(printf 'r,,%.0s' $(seq 1 25))" "$WORK/resume.two"
wait "$one"; sleep 2
RESUME="$L=resume$(wait_frames 15)=resume$(wait_frames 300)$FIGHT"
client 23608 "$RESUME" "$WORK/resume.three" &
one=$!
client 23608 "$RESUME" "$WORK/resume.four"
wait "$one"; kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
grep -q "session saved" "$WORK/resume.server"; check "resume: the server saved the session" $? "$(tail -3 "$WORK/resume.server")"
grep -q "session resumed" "$WORK/resume.server"; check "resume: the session went on" $? "$(tail -3 "$WORK/resume.server")"
for side in three four; do client_checks resume $side "screen=match"; done
! grep -qE "desync|difference" "$WORK/resume.server"; check "resume: no state difference" $? "$(grep -E "desync|difference" "$WORK/resume.server")"
grep -c "hashes agree (1 checks" "$WORK/resume.server" | grep -q "^2$"; check "resume: the hashes agree after the resume" $? "$(grep 'hashes agree' "$WORK/resume.server")"

# 10. A spectator: a third client joins during the fight, runs the session's ticks to catch up and watches a second
#     behind; the server compares its hashes with the players'.
start_server 23610 watch; sleep 2
client 23610 "$START$TITLE$PICK$MENU$FIGHT$LONG" "$WORK/watch.one" &
one=$!
client 23610 "$START$(wait_frames 31)$PICK$(wait_frames 136)$LONG" "$WORK/watch.two" &
two=$!
sleep 25
client 23610 "$(wait_frames 30)$(printf 'r,,%.0s' $(seq 1 120))" "$WORK/watch.three"
wait "$one" "$two"; kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null
grep -q "watching: " "$WORK/watch.server"; check "watch: the server took a spectator" $? "$(tail -3 "$WORK/watch.server")"
client_checks watch three "screen=match"
tick=$(grep -oE "online=tick=[0-9]+" "$WORK/watch.three" | tail -1); tick=${tick##*=}
[ -n "$tick" ] && [ "$tick" -gt 100 ]; check "watch: the spectator's fight runs (tick $tick)" $? "tick=${tick:-none}"
! grep -qE "desync|difference" "$WORK/watch.server"; check "watch: no state difference" $? "$(grep -E "desync|difference" "$WORK/watch.server")"
grep -c "hashes agree (1 checks" "$WORK/watch.server" | grep -q "^2$"; check "watch: the spectator's hashes agree" $? "$(grep 'hashes agree' "$WORK/watch.server")"

# 11. Rooms: client one makes a private room, and each client starts a session alone in its room; both sessions run
#     on the server at the same time.
run_session rooms 23611 "$L=create_room$(wait_frames 30)c$(wait_frames 15)f$(wait_frames 70)$TITLE" "$L$(wait_frames 31)c$(wait_frames 15)f$(wait_frames 100)"
grep -q "room created" "$WORK/rooms.server"; check "rooms: the server made a private room" $? "$(head -5 "$WORK/rooms.server")"
grep -c "session started with 1 players" "$WORK/rooms.server" | grep -q "^2$"; check "rooms: two sessions run at once" $? "$(grep session "$WORK/rooms.server")"
for side in one two; do client_checks rooms $side "screen=(title|characters|setup)"; done

# 9. The match setup screen in a session (it replaces the title menu): both join, choose a fighter and get ready with
#    their keys, a player starts (defend), and the fight runs with rollback.
#    Client one first clicks the Stage tab: the click goes through the server, so both clients play a stage fight.
SETUP="c$(wait_frames 15)c$(wait_frames 15)c$(wait_frames 15)f$(wait_frames 140)"
SERVER_FLAGS= run_session setup 23609 "$START=mode_1$(wait_frames 10)$SETUP$FIGHT" "$START$(wait_frames 11)$SETUP$FIGHT"
for side in one two; do client_checks setup $side "screen=match.*stage="; done
python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])).get("last_setup") or {}; sys.exit(0 if s.get("mode") == 1 else 1)' \
    "$WORK/server-config/config.json"; check "setup: the server keeps the values of the last match (Stage)" $? "$(grep -o '"last_setup"[^}]*' "$WORK/server-config/config.json")"
server_checks setup 1

# 10. Clicks and keys on the setup screen (the desync of 2026-10-25): client one clicks a portrait, then picks with
#     its keys from there. A click once moved the cursor of the keys only on the clicking computer, so the two clients
#     picked different fighters. Both clients must play the same fight, and the menus' and the fight's checks agree.
CLICKS="c$(wait_frames 15)=fighter_5$(wait_frames 15)r$(wait_frames 15)c$(wait_frames 15)c$(wait_frames 15)f$(wait_frames 140)"
KEYS="c$(wait_frames 15)c$(wait_frames 15)c$(wait_frames 15)$(wait_frames 60)$(wait_frames 140)"
SERVER_FLAGS= run_session clicks 23611 "$START$CLICKS$FIGHT" "$START$(wait_frames 11)$KEYS$FIGHT"
for side in one two; do client_checks clicks $side "screen=match"; done
grep -q "hashes agree" "$WORK/clicks.server"; check "clicks: the server compared the fight hashes" $? "no comparison"
! grep -qE "desync|difference" "$WORK/clicks.server"; check "clicks: the menus and the fight stay the same on both clients" $? "$(grep -E "desync|difference" "$WORK/clicks.server")"

exit $FAILED
