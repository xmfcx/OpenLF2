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
# The setup screen's brain buttons and Superhuman (two tactician computers), and Stage mode with the Stage AI on.
BRAINS=",,#13,,#13,,$WAIT,c,,,r,,,c,,,r,,,c,,,u,,,c,,,c,,$WAIT,=brain_1,,,,=brain_2,,,,=superhuman,,,,d,,,c$(frames 6000)"
STAGE_AI=",,#13,,#13,,$WAIT,=mode_1$(frames 10)=stage_ai$(frames 10)c$(frames 16)c$(frames 16)c$(frames 16)f$(frames 1700)"

# Scripts with a rollback check on almost every tick (rollback.interval 9).
cp -r scripts "$WORK/scripts9"
sed -i 's/^rollback.interval, rollback.span = 45, 8/rollback.interval, rollback.span = 9, 8/' "$WORK/scripts9/base/game/rollback.lua"

run classic_versus --scripts scripts --seed 1234 --input-trace "$VERSUS" &
run classic_menus --scripts scripts --seed 1234 --classic-menus --input-trace "$CLASSIC" &
run rollback_idle --scripts "$WORK/scripts9" --seed 1234 --ai-brain idle --rollback-check --input-trace "$VERSUS" &
run rollback_sentry --scripts "$WORK/scripts9" --seed 1234 --ai-brain sentry --rollback-check --input-trace "$VERSUS" &
run rollback_drill --scripts "$WORK/scripts9" --seed 1234 --ai-brain 11=drill,12=sentry --rollback-check --input-trace "$VERSUS" &
run rollback_guard --scripts "$WORK/scripts9" --seed 1234 --ai-brain 11=guard --rollback-check --input-trace "$VERSUS" &
run netsim_guard --scripts scripts --seed 1234 --ai-brain 11=guard --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
for level in easy crazy; do
    for number in 1 2 3 4 5 6 7 8; do
        run "guard_${level}_$number" --scripts scripts --ai-log 10,11 --fight "davis/guard|firen;time=1800;difficulty=$level;first=$number" &
    done
done
run rollback_tactician --scripts "$WORK/scripts9" --seed 1234 --ai-brain tactician --rollback-check --input-trace "$VERSUS" &
run netsim_tactician --scripts scripts --seed 1234 --ai-brain tactician --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run rollback_stage_ai --scripts "$WORK/scripts9" --seed 1234 --rollback-check --input-trace "$STAGE_AI" &
mkdir -p "$WORK/record" && echo '{"recording": {"enabled": true}}' > "$WORK/record/config.json"
(run record --scripts scripts --config-dir "$WORK/record" --seed 1234 --input-trace "$BRAINS"
 run replay --scripts scripts --config-dir "$WORK/record" --replay "$(ls "$WORK"/record/recording/*.lfr 2>/dev/null | head -1)" \
     --input-trace "$(frames 3000)") &
run rollback_imitator --scripts "$WORK/scripts9" --seed 1234 --ai-brain imitator --rollback-check --input-trace "$VERSUS" &
run netsim_imitator --scripts scripts --seed 1234 --ai-brain imitator --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run tune --scripts scripts --fight "davis/tactician/brawler|davis;tune=aggression:60.spacing:80;time=600" &
run rollback_stage --scripts "$WORK/scripts9" --seed 1234 --ai-brain sentry --rollback-check --input-trace "$STAGE" &
run netsim_idle --scripts scripts --seed 1234 --ai-brain idle --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run netsim_sentry --scripts scripts --seed 1234 --ai-brain 11=sentry --net-sim delay=80,jitter=30,loss=5,seed=1 --input-trace "$VERSUS" &
run book --scripts scripts --seed 1 --ai-book --input-trace ",," &
run learning --scripts scripts --ai-log 10 --fight "davis/tactician/shoto|davis/jumper;learn=1;time=3600;mirror=0" --fights 2 &
run arena_batch --scripts scripts --fight "henry/sentry|dennis;seed=3" --fights 4 &
for number in 1 2 3 4; do run "arena_$number" --scripts scripts --fight "henry/sentry|dennis;seed=3;first=$number" & done
FIGHTERS="deep john henry rudolf louis firen freeze dennis woody davis bandit hunter mark jack sorcerer monk jan knight bat justin louisex firzen julian"
for fighter in $FIGHTERS; do
    for level in crazy superhuman; do
        run "drill_${fighter}_$level" --scripts scripts --ai-log 10 \
            --fight "$fighter/drill|bandit/sentry;mp=500;time=20000;difficulty=$level;mirror=0" &
    done
done
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
for name in rollback_idle rollback_sentry rollback_drill rollback_guard rollback_tactician rollback_imitator rollback_stage rollback_stage_ai; do
    line=$(grep -o "rollback=checks:[0-9]*,failures:[0-9]*" "$WORK/$name.out" | tail -1)
    echo "$line" | grep -qE "checks:[1-9][0-9]*,failures:0$"; check "rollback: $name" $? "${line:-$(grep -m1 -i error "$WORK/$name.out")}"
done
grep -q "screen=match.*stage=" "$WORK/rollback_stage.out"; check "rollback: the Stage trace reaches a stage fight" $? "$(description rollback_stage | cut -c1-120)"

grep -q "ai=tactician" "$WORK/rollback_stage_ai.out"; check "setup: the Stage AI gives the stage's fighters the tactician" $? "$(description rollback_stage_ai | cut -c1-160)"

# Recordings: a fight with tactician computers from the setup screen replays to the same end (OpenLF2's AI block).
recorded=$(description record | grep -oE "round=[0-9]+ winner=[-0-9]+|ai=[^ }]*" | tr '\n' ' ')
replayed=$(description replay | grep -oE "round=[0-9]+ winner=[-0-9]+|ai=[^ }]*" | tr '\n' ' ')
grep -q "Recording saved" "$WORK/record.out" && echo "$recorded" | grep -q "ai=tactician" && [ "$recorded" = "$replayed" ]
check "recording: a tactician fight replays the same" $? "recorded: $recorded replayed: $replayed"

# The simulated network: both clients agree on every hash.
for name in netsim_idle netsim_sentry netsim_guard netsim_tactician netsim_imitator; do
    hashes=$(grep -o "hashes=[0-9]*/[0-9]*" "$WORK/$name.out" | tr '\n' ' ')
    echo "$hashes" | grep -qE "hashes=[1-9][0-9]*/0 hashes=[1-9][0-9]*/0"; check "net-sim: $name" $? "${hashes:-$(grep -m1 -i error "$WORK/$name.out")}"
done

# The arena: four fights, the same in a batch and in single runs.
batch=$(grep "^ai-result" "$WORK/arena_batch.out" | sed 's/ us=.*//')
single=$(for number in 1 2 3 4; do grep "^ai-result" "$WORK/arena_$number.out" | sed 's/ us=.*//'; done)
[ "$(echo "$batch" | grep -c .)" = 4 ] && [ "$batch" = "$single" ]
check "arena: a batch of 4 fights equals 4 single runs" $? "$(echo "$batch" | head -2)"

# The actuator: the drill starts every special move of every fighter, at the human and the fast rate.
result=$(python3 -I tools/ai_drill_check.py "$WORK"/drill_*.out)
check "actuator: the drill starts every special move ($(echo "$result" | grep -c "started") runs)" $? "$(echo "$result" | grep -B1 FAIL | head -8)"

# Reflexes: on Crazy, at least 80% of the guard's answers work. Easy answers fewer threats in time than Crazy.
crazy=$(python3 -I tools/ai_reflex_check.py "$WORK"/guard_crazy_*.out | tail -1)
easy=$(python3 -I tools/ai_reflex_check.py "$WORK"/guard_easy_*.out | tail -1)
worked=$(echo "$crazy" | grep -oE "^all: [0-9]+ of [0-9]+" | grep -oE "[0-9]+" | head -1)
answers=$(echo "$crazy" | grep -oE "^all: [0-9]+ of [0-9]+" | grep -oE "[0-9]+" | tail -1)
easy_answers=$(echo "$easy" | grep -oE "^all: [0-9]+ of [0-9]+" | grep -oE "[0-9]+" | tail -1)
[ "${answers:-0}" -gt 0 ] && [ $((worked * 100)) -ge $((answers * 80)) ] && [ "${easy_answers:-0}" -lt "$answers" ]
check "reflexes: $crazy (Crazy), ${easy_answers:-0} answers on Easy" $? "crazy: $crazy easy: $easy"

# Personas and levels (docs/ai-plan.md phase 11): Davis's personas use clearly different moves (a total variation
# distance of at least 0.25 between two of them), and Easy loses clearly to Crazy.
python3 -I tools/ai-arena.py "davis/tactician/brawler|davis/tactician" "davis/tactician/shoto|davis/tactician" \
    "davis/tactician@easy|davis/tactician@crazy" --fights 30 --json > "$WORK/personas.json" 2>/dev/null
result=$(python3 -I - "$WORK/personas.json" <<'PYTHON'
import json, sys
reports = json.load(open(sys.argv[1]))
def histogram(report):
    moves = report["moves"].get("1") or report["moves"].get(1) or {}
    total = sum(moves.values()) or 1
    return {key: value / total for key, value in moves.items()}
a, b = histogram(reports[0]), histogram(reports[1])
distance = 0.5 * sum(abs(a.get(key, 0) - b.get(key, 0)) for key in set(a) | set(b))
print(f"{distance:.2f} {reports[2]['score']:.2f}")
PYTHON
)
distance=${result% *}; easy=${result#* }
python3 -c "import sys; sys.exit(0 if float('$distance') >= 0.25 and float('$easy') <= 0.2 else 1)" 2>/dev/null
check "personas: brawler and shoto differ by $distance (0.25 needed), Easy scores $easy against Crazy (0.2 at most)" $? "$result"

# Learning (docs/ai-plan.md phase 12): against a fighter that jumps over every ball, a zoner throws fewer balls after
# its first 600 ticks, and the next fight starts with that knowledge (fewer balls in its first 600 ticks).
counts=$(awk '/ai-result/{f++} /ev=move m=ball1\/240/{match($0,/t=[0-9]+/); t=substr($0,RSTART+2,RLENGTH-2)+0;
    c[(f+1) (t<600?"early":"late")]++} END{print c["1early"]+0, c["1late"]+0, c["2early"]+0}' "$WORK/learning.out")
set -- $counts
[ "${1:-0}" -gt "${2:-0}" ] && [ "${1:-0}" -gt "${3:-0}" ]
check "learning: balls in fight 1 early $1, late $2, fight 2 early $3" $? "$counts"

# Learning from data (phase 13): the imitator plays (its integer network gives the same keys on every client, above),
# and the arena takes persona numbers to tune.
grep -q "ai=imitator/action" "$WORK/rollback_imitator.out"; check "imitator: the network brain plays" $? "$(description rollback_imitator | grep -o 'ai=[^ }]*' | head -2)"
grep -q "^ai-result" "$WORK/tune.out"; check "tuning: the arena takes persona numbers (tune=)" $? "$(grep -m1 -i error "$WORK/tune.out")"

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
