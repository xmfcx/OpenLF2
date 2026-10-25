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
    timeout 120 "$GAME" --server --installer "$INSTALLER" --scripts scripts --port "$port" > "$WORK/$name.server" 2>&1 &
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
    ! grep -q "difference" "$WORK/$1.server"; check "$1: the server finds no state difference" $? "$(grep difference "$WORK/$1.server")"
    if [ "$2" = 1 ]; then
        grep -q "hashes agree" "$WORK/$1.server"; check "$1: the server compared the clients' hashes" $? "no comparison"
    fi
}

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

exit $FAILED
