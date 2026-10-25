#!/bin/bash
# Window tests of a server game (docs/netcode.md): two game windows on two virtual X displays, driven with xdotool,
# host and join a game through the network menu, play the original menus to a fight, and test the chat, the taunts
# and the leave question. Each window logs a probe line every 15 frames (OPENLF2_PROBE=1) and the sounds it plays
# (OPENLF2_LOG_SOUNDS=1); the checks read these logs.
#
# Usage: tools/test-online-ui.sh [build directory, default build/debug]
# Needs Xvfb, xdotool and the LF2 installer in ~/.local/share/OpenLF2/LF2_v2.0a.exe (or $LF2_INSTALLER).
# The players use the keys of ~/.local/share/OpenLF2/config.json (Enter free for the chat), or the default keys.
set -u
BUILD=${1:-build/debug}
GAME="$BUILD/openlf2"
INSTALLER=${LF2_INSTALLER:-$HOME/.local/share/OpenLF2/LF2_v2.0a.exe}
PORT=${PORT:-23700}
WORK=$(mktemp -d)
FAILED=0
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    pkill -f -- "--server --port $PORT " 2>/dev/null
    [ "${KEEP:-}" = 1 ] && echo "outputs in $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

check() { # name, result (0 = pass), details
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAILED=1; fi
}
probe() { grep "^probe" "$WORK/$1.log" | tail -1; }
expect() { # name, window, pattern: waits a moment for the next probe lines, then checks the newest
    sleep 1
    local line
    line=$(probe "$2")
    echo "$line" | grep -qE "$3"
    check "$1" $? "$line"
}
expect_not() { # name, window, pattern: the newest probe line must not have it
    sleep 1
    local line
    line=$(probe "$2")
    ! echo "$line" | grep -qE "$3"
    check "$1" $? "$line"
}
xdo() { local display=$1; shift; DISPLAY=:$display xdotool "$@"; }
shot() { [ "${KEEP:-}" = 1 ] && DISPLAY=":$1" import -window root "$WORK/$2.png"; } # display, name (KEEP=1 only)
focus() { xdo "$1" windowfocus "$(xdo "$1" search --name OpenLF2 | head -1)"; sleep 0.2; }
press() { # display, key: held for 0.12 s (a frame sees it even when the game waits for the network)
    xdo "$1" keydown "$2"; sleep 0.12; xdo "$1" keyup "$2"; sleep 0.25
}
click() { xdo "$1" mousemove "$2" "$3" click 1; sleep 0.4; }
# Game coordinates (794 x 550) to the virtual screen: the window sits in the middle of the 1024 x 768 display.
gx() { echo $((115 + $1)); }
gy() { echo $((109 + $1)); }

# The players' keys: a copy of this computer's controls, or the defaults.
for name in host join; do mkdir -p "$WORK/$name"; done
if [ -f "$HOME/.local/share/OpenLF2/config.json" ]; then
    python3 -I - "$HOME/.local/share/OpenLF2/config.json" "$WORK" <<'EOF'
import json, sys
source, work = sys.argv[1:]
controls = json.load(open(source)).get("controls")
for name in ("host", "join"):
    document = {"controls": controls} if controls else {}
    if controls: document["controls"]["players"][0]["name"] = name
    json.dump(document, open(f"{work}/{name}/config.json", "w"))
EOF
fi
# Player 1's attack, defend and up keys, and whether Enter opens the chat (else T).
read -r ATTACK DEFEND UP CHAT < <(python3 -I - "$WORK/host/config.json" <<'EOF'
import json, sys
try:
    players = json.load(open(sys.argv[1]))["controls"]["players"]
except Exception:
    players = None
names = {38: "Up", 40: "Down", 37: "Left", 39: "Right", 13: "Return", 16: "Shift_L", 17: "Control_L", 32: "space",
         96: "KP_0", 101: "KP_5", 104: "KP_8", 107: "KP_Add"}
def key(code): return names.get(code, chr(code).lower() if 48 <= code <= 90 else "Return")
if players:
    first = players[0]
    used = {player.get(name) for player in players for name in ("up", "down", "left", "right", "attack", "jump", "defend")}
    print(key(first["attack"]), key(first["defend"]), key(first["up"]), "t" if 13 in used else "Return")
else:
    print("KP_5", "KP_Add", "KP_8", "t")
EOF
)
echo "keys: attack=$ATTACK defend=$DEFEND up=$UP chat=$CHAT"

for display in 95 96; do
    Xvfb ":$display" -screen 0 1024x768x24 > /dev/null 2>&1 &
    PIDS+=($!)
done
sleep 1
start_window() { # display, name
    DISPLAY=":$1" SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy OPENLF2_PROBE=1 OPENLF2_LOG_SOUNDS=1 OPENLF2_NO_UPNP=1 \
        "$GAME" --installer "$INSTALLER" --scripts scripts --renderer software --config-dir "$WORK/$2" --port "$PORT" \
        > "$WORK/$2.log" 2>&1 &
    PIDS+=($!)
    [ "$2" = host ] && HOST_PID=$!
}
start_window 95 host
start_window 96 join
sleep 6

# Host: Network Game, then Host a game. Join: Network Game, the address, Enter.
focus 95; click 95 "$(gx 398)" "$(gy 259)"; click 95 "$(gx 395)" "$(gy 216)"
expect "host: the lobby opens" host "screen=online_lobby"
sleep 6
expect "host: connected to its own server" host "online=lobby"
focus 96; click 96 "$(gx 398)" "$(gy 259)"; click 96 "$(gx 352)" "$(gy 352)"
xdo 96 type --delay 80 "127.0.0.1"; press 96 Return
expect "join: connected to the server" join "online=lobby"

# Both ready (attack), the host starts (defend): the title menu of the session.
focus 96; press 96 "$ATTACK"; focus 95; press 95 "$ATTACK"; sleep 1; press 95 "$DEFEND"
expect "host: the session starts at the title" host "screen=title online=session"
expect "join: the session starts at the title" join "screen=title online=session"

# The chat in the menus: Enter (or T) opens it, it stays open, Enter sends and closes it, it does not open again.
focus 96; press 96 "$CHAT"
expect "join: the chat opens" join "chat_open=true"
sleep 1
expect "join: the chat stays open (the opening key does not send)" join "chat_open=true"
xdo 96 type --delay 80 "30"; press 96 Return
expect "join: Enter sends and closes the chat" join "chat_open=false chat_lines=1"
sleep 1
expect "join: the chat does not open again by itself" join "chat_open=false"
expect "host: the message arrives and its taunt plays" host "chat_lines=1 taunts_played=1"
grep -q "sound mods/base/taunts/30.wav" "$WORK/host.log"
check "host: the engine plays the taunt's sound" $? "no sound line"
focus 95; press 95 "$CHAT"; sleep 0.3; shot 95 title-chat; sleep 0.2; press 95 Escape
expect "host: Escape closes the chat" host "chat_open=false"
expect_not "host: Escape in the chat does not open the settings" host "settings="

# To a fight: Versus opens the match setup screen; both join, choose a fighter and get ready with attack (three
# times), and the host (the room role) starts with defend; the countdown takes three seconds.
press 95 "$ATTACK"; sleep 1.5
expect "both: the match setup screen" host "screen=setup"
expect "join: the match setup screen" join "screen=setup"
for round in 1 2 3; do focus 96; press 96 "$ATTACK"; focus 95; press 95 "$ATTACK"; sleep 0.6; done
sleep 1; shot 95 setup
focus 96; press 96 "$DEFEND"; sleep 1
expect "join: the other player's defend does not start" join "screen=setup"
focus 95; press 95 "$DEFEND"; sleep 4.5
expect "host: the fight starts" host "screen=match online=session"
expect "join: the fight starts" join "screen=match online=session"

# The chat in a fight, and the leave question.
press 95 "$CHAT"; sleep 0.1; shot 95 fight-chat-0; sleep 0.3; shot 95 fight-chat-1; xdo 95 type --delay 80 "gg"; shot 95 fight-chat-2
press 95 Return
expect "host: chat in a fight sends and closes" host "screen=match .*chat_open=false chat_lines=2"
press 95 Escape
expect "host: Escape opens the settings menu" host "settings=game"
expect "host: the fight goes on behind the menu" host "screen=match online=session"
press 95 Escape
expect_not "host: Escape again closes the menu" host "settings="
press 95 Escape; sleep 0.5; shot 95 settings; click 95 "$(gx 395)" "$(gy 78)"
expect_not "host: Resume closes the menu" host "settings="
expect "host: still in the fight after Resume" host "screen=match online=session"
expect "join: the other player is still in the fight" join "screen=match online=session"

# The computer plays the host's fighter, on both computers, and a key of the host takes it back.
press 95 Escape; sleep 0.5; click 95 "$(gx 395)" "$(gy 156)"
expect "host: the computer plays the host's fighter" host "computer_controls="
expect "join: the computer plays the host's fighter there too" join "computer_controls="
sleep 1.5; press 95 "$ATTACK"
expect_not "host: a key takes the control back" host "computer_controls="
expect_not "join: the control is back there too" join "computer_controls="

# Leave asks first; No keeps the game.
press 95 Escape; sleep 0.5; click 95 "$(gx 395)" "$(gy 501)"
expect "host: Leave asks first" host "settings=game:leave"
shot 95 leave; press 95 Escape
expect "host: Escape closes the question, not the menu" host "settings=game"
press 95 Escape
expect_not "host: the menu closes" host "settings="

! grep -qiE "traceback|attempt to|error" "$WORK/host.log" "$WORK/join.log"
check "no script errors" $? "$(grep -iE 'traceback|attempt to|error' "$WORK/host.log" "$WORK/join.log" | head -2)"

# The host's game crashes: its server program stops too (--stop-with-parent).
kill -9 "$HOST_PID"; wait "$HOST_PID" 2>/dev/null; sleep 2
! ps -eo args | grep -v grep | grep -q -- "--server --stop-with-parent --port $PORT "
check "the server stops when the hosting game crashes" $? "$(ps -eo pid,args | grep -- "--server --stop-with-parent --port $PORT " | grep -v grep)"
exit $FAILED
