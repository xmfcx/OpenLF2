#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Tunes the persona numbers of a tactician with the arena (docs/ai-plan.md "Learning", self-play tuning).

A random search: each round changes one or two numbers of the best persona so far by a step, runs the arena
(tools/ai-arena.py) with the change (the arena option `tune=`), and keeps it when it scores better. Every candidate
plays the same seeds, so a change is compared on equal fights. The tool prints the best numbers as a Lua table to
paste into the fighter's kit (scripts/base/ai/kits.lua).

    tools/ai-tune.py "davis/tactician/brawler|davis;difficulty=crazy" --rounds 12 --fights 40
"""
import argparse
import json
import os
import random
import subprocess
import sys

# The numbers that the tuner changes, with their limits and steps.
SPACE = {"aggression": (0, 100, 10), "risk": (0, 100, 10), "mp_thrift": (0, 100, 10), "combo_greed": (0, 100, 10),
         "mobility": (0, 100, 10), "spacing": (20, 200, 10), "depth_offset": (0, 20, 3), "adapt": (0, 100, 10)}
DEFAULTS = {"aggression": 85, "risk": 40, "mp_thrift": 30, "combo_greed": 60, "mobility": 30, "spacing": 38,
            "depth_offset": 0, "adapt": 50}


def score(spec, values, arguments):
    tune = ".".join(f"{name}:{value}" for name, value in sorted(values.items()))
    command = [sys.executable, "-I", os.path.join(os.path.dirname(__file__), "ai-arena.py"), f"{spec};tune={tune}",
               "--fights", str(arguments.fights), "--json", "--build", arguments.build]
    output = subprocess.run(command, capture_output=True, text=True, timeout=7200).stdout
    report = json.loads(output)[0]
    # The score, and the damage share as a tie breaker (a loss with more damage is still better).
    damage = report["damage_per_minute"]
    share = damage[0] / max(damage[0] + damage[1], 1)
    return report["score"] + share / 100, report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("spec", help="a fight of openlf2 --fight, with the tuned tactician on side 1")
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--fights", type=int, default=40)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--build", default="build/debug")
    arguments = parser.parse_args()
    rng = random.Random(arguments.seed)
    best = dict(DEFAULTS)
    best_score, report = score(arguments.spec, best, arguments)
    print(f"start: score {report['score']:.3f}, damage {report['damage_per_minute'][0]:.0f}/{report['damage_per_minute'][1]:.0f}")
    for round_number in range(1, arguments.rounds + 1):
        candidate = dict(best)
        for name in rng.sample(sorted(SPACE), rng.choice([1, 2])):
            low, high, step = SPACE[name]
            candidate[name] = max(low, min(high, candidate[name] + rng.choice([-step, step])))
        value, report = score(arguments.spec, candidate, arguments)
        kept = value > best_score
        if kept:
            best, best_score = candidate, value
        changed = ", ".join(f"{k} {best[k] if kept else candidate[k]}" for k in candidate if candidate[k] != DEFAULTS.get(k))
        print(f"round {round_number}: score {report['score']:.3f} ({'kept' if kept else 'dropped'}) {changed}")
    numbers = ", ".join(f"{name} = {value}" for name, value in sorted(best.items()) if value != DEFAULTS[name])
    print(f"best score {best_score:.3f}; for the kit: {{{numbers}}}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
