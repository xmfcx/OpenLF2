#!/bin/bash
# Headless tests of the AI (docs/ai-plan.md "Logs, metrics and tests"): the classic AI stays exact, every brain passes
# the rollback check (with the memory validator) and the simulated network, the move book matches the data files, and
# the prediction keeps its accuracy.
#
# Usage: tools/test-ai.sh [build directory, default build/debug]
# Needs the LF2 installer in ~/.local/share/OpenLF2/LF2_v2.0a.exe (or $LF2_INSTALLER). The move book check also needs a
# folder with data/data.txt and the .dat files ($LF2_DATA, default ~/games/LF2) and skips without it.
# UPDATE=1 writes the stored descriptions of the classic AI again (tools/ai-tests/) after an intended change of the
# fights. KEEP=1 keeps the outputs. The checks run at the same time.
set -u
BUILD=${1:-build/debug}
GAME="$BUILD/openlf2"
INSTALLER=${LF2_INSTALLER:-$HOME/.local/share/OpenLF2/LF2_v2.0a.exe}
DATA=${LF2_DATA:-$HOME/games/LF2}
STORED=tools/ai-tests
WORK=$(mktemp -d)
FAILED=0
trap '[ "${KEEP:-}" = 1 ] && echo "outputs in $WORK" || rm -rf "$WORK"' EXIT

frames() { printf ',%.0s' $(seq 1 "$1"); }
check() { # name, condition result (0 = pass), details
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAILED=1; fi
}
run() { # output name, then the arguments of the game
    local name=$1; shift
    timeout 300 "$GAME" --headless --installer "$INSTALLER" "$@" > "$WORK/$name.out" 2>&1
}
description() { grep -m1 "^screen=" "$WORK/$1.out"; }

# The traces: a VS fight with three computers on the setup screen, the same fight with the classic menus and one
# computer, and Stage mode from the setup screen's Stage tab.
WAIT=$(frames 40)
VERSUS=",,#13,,#13,,$WAIT,c,,,r,,,c,,,r,,,c,,,u,,,c,,,c,,,c,,,d,,,c$(frames 1500)"
CLASSIC=",,#13,,#13,,,,c,,,,c,,,,c$WAIT,c,,,,c,,,,c,,,,c$(frames 170),c,,,,c,,,,c,,,,c$WAIT,u,,,,u,,,,c$WAIT$WAIT$(frames 1500)"
STAGE=",,#13,,#13,,$WAIT,=mode_1$(frames 10)c$(frames 16)c$(frames 16)c$(frames 16)f$(frames 160)$(frames 1500)"
LONG=",,#13,,#13,,$WAIT,c,,,r,,,c,,,r,,,c,,,u,,,c,,,c,,,c,,,d,,,c$(frames 3000)"

# Scripts with a rollback check on almost every tick (rollback.interval 9).
cp -r scripts "$WORK/scripts9"
sed -i 's/^rollback.interval, rollback.span = 45, 8/rollback.interval, rollback.span = 9, 8/' "$WORK/scripts9/base/game/rollback.lua"

run classic_versus --scripts scripts --seed 1234 --input-trace "$VERSUS" &
run classic_menus --scripts scripts --seed 1234 --classic-menus --input-trace "$CLASSIC" &
run rollback_idle --scripts "$WORK/scripts9" --seed 1234 --ai-brain idle --rollback-check --input-trace "$VERSUS" &
run rollback_sentry --scripts "$WORK/scripts9" --seed 1234 --ai-brain sentry --rollback-check --input-trace "$VERSUS" &
run rollback_stage --scripts "$WORK/scripts9" --seed 1234 --ai-brain sentry --rollback-check --input-trace "$STAGE" &
run netsim_idle --scripts scripts --seed 1234 --ai-brain idle --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run netsim_sentry --scripts scripts --seed 1234 --ai-brain 11=sentry --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run book --scripts scripts --seed 1 --ai-book --input-trace ",," &
for seed in 1234 1 2 3 4 5 6 7; do
    run "predict_$seed" --scripts scripts --seed "$seed" --ai-brain 11=sentry --ai-log 11 --input-trace "$LONG" &
done
wait

# The classic AI: the same descriptions as the stored ones.
for name in classic_versus classic_menus; do
    if [ "${UPDATE:-}" = 1 ]; then
        mkdir -p "$STORED"; description "$name" > "$STORED/$name.txt"; echo "UPDATED $STORED/$name.txt"
    else
        [ -n "$(description "$name")" ] && [ "$(description "$name")" = "$(cat "$STORED/$name.txt" 2>/dev/null)" ]
        check "classic: $name gives the stored description" $? "$(description "$name" | cut -c1-200)"
    fi
done

# Rollback: no failure, and no error of the memory validator.
for name in rollback_idle rollback_sentry rollback_stage; do
    line=$(grep -o "rollback=checks:[0-9]*,failures:[0-9]*" "$WORK/$name.out" | tail -1)
    echo "$line" | grep -qE "checks:[1-9][0-9]*,failures:0$"; check "rollback: $name" $? "${line:-$(grep -m1 -i error "$WORK/$name.out")}"
done
grep -q "screen=match.*stage=" "$WORK/rollback_stage.out"; check "rollback: the Stage trace reaches a stage fight" $? "$(description rollback_stage | cut -c1-120)"

# The simulated network: both clients agree on every hash.
for name in netsim_idle netsim_sentry; do
    hashes=$(grep -o "hashes=[0-9]*/[0-9]*" "$WORK/$name.out" | tr '\n' ' ')
    echo "$hashes" | grep -qE "hashes=[1-9][0-9]*/0 hashes=[1-9][0-9]*/0"; check "net-sim: $name" $? "${hashes:-$(grep -m1 -i error "$WORK/$name.out")}"
done

# The move book against the data files.
if [ -f "$DATA/data/data.txt" ]; then
    result=$(python3 -I tools/lf2_moves.py "$DATA" --check "$WORK/book.out" | tail -1)
    echo "$result" | grep -q " 0 differences"; check "move book: the same moves as tools/lf2_moves.py" $? "$result"
else
    echo "SKIP move book: no data folder at $DATA (set LF2_DATA)"
fi

# Prediction: at least 85% of the hit-box hits on a sentry had their exact tick predicted, over 8 seeds.
cat "$WORK"/predict_*.out > "$WORK/predict.all"
summary=$(for seed in 1234 1 2 3 4 5 6 7; do python3 -I tools/ai_prediction_check.py "$WORK/predict_$seed.out" | tail -1; done)
total=$(echo "$summary" | grep -o "hits=[0-9]*" | cut -d= -f2 | paste -sd+ | bc)
exact=$(echo "$summary" | grep -o "exact=[0-9]*" | cut -d= -f2 | paste -sd+ | bc)
[ "${total:-0}" -gt 100 ] && [ $((exact * 100)) -ge $((total * 85)) ]
check "prediction: $exact of $total hits had the exact tick (85% needed)" $? "$summary"

[ "$FAILED" = 0 ] && echo "All AI checks passed" || echo "Some AI checks failed"
exit "$FAILED"
