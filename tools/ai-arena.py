#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Runs arena fights of computer fighters (docs/ai-plan.md "Arena") and sums up the results.

Each SPEC is a fight of `openlf2 --fight` (for example "davis/tactician|davis;difficulty=crazy"). The tool runs chunks
of fights in parallel processes, reads their `ai-result` and `ai-moves` lines, and prints for side 1 the score (a win
is 1, a draw 1/2) with its 95% margin, the damage per minute, the length, the AI time and the move use. With --sprt it
stops when a sequential probability ratio test (5% errors) decides between the two score rates.

    tools/ai-arena.py "davis|firen" --fights 200
    tools/ai-arena.py "davis/tactician|davis" "firen/tactician|firen" --sprt 0.5,0.7 --fights 400
"""
import argparse
import concurrent.futures
import json
import math
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict


def run_chunk(arguments, spec, first, count):
    command = [arguments.game, "--installer", arguments.installer, "--scripts", arguments.scripts,
               "--fight", f"{spec};first={first}", "--fights", str(count)]
    output = subprocess.run(command, capture_output=True, text=True, timeout=3600).stdout
    results, moves = [], []
    for line in output.splitlines():
        if line.startswith("ai-result "):
            results.append(dict(re.findall(r"(\w+)=(\S+)", line)))
        elif line.startswith("ai-moves "):
            moves.append(dict(re.findall(r"(\w+)=(\S+)", line)))
    if len(results) != count:
        raise RuntimeError(f"{spec} first={first}: {len(results)} of {count} results\n{output[-2000:]}")
    return results, moves


def llr(score, games, low, high):
    """The log-likelihood ratio of a score rate `high` against `low` (draws count as half a win)."""
    if games == 0:
        return 0.0
    return score * math.log(high / low) + (games - score) * math.log((1 - high) / (1 - low))


def summary(spec, results, moves):
    games = len(results)
    score = sum(1.0 if r["winner"] == "1" else 0.5 if r["winner"] == "0" else 0.0 for r in results)
    rate = score / games if games else 0.0
    margin = 1.96 * math.sqrt(max(rate * (1 - rate), 1e-9) / games) if games else 0.0
    ticks = sum(int(r["ticks"]) for r in results)
    minutes = ticks / 30 / 60
    timing = defaultdict(list)
    for r in results:
        for part in r.get("us", "-").split(","):
            if ":" in part:
                name, value = part.split(":")
                timing[name].append(float(value))
    usage = {1: Counter(), 2: Counter()}
    for m in moves:
        for part in m["moves"].split(","):
            if ":" in part:
                frame, count = part.split(":")
                usage[int(m["side"])][f"{m['id']}:{frame}"] += int(count)
    return {"spec": spec, "fights": games, "wins": sum(r["winner"] == "1" for r in results),
            "draws": sum(r["winner"] == "0" for r in results), "losses": sum(r["winner"] == "2" for r in results),
            "score": rate, "margin": margin,
            "damage_per_minute": [sum(int(r["dmg1"]) for r in results) / max(minutes, 1e-9),
                                  sum(int(r["dmg2"]) for r in results) / max(minutes, 1e-9)],
            "mean_ticks": ticks / games if games else 0,
            "ai_us": {name: sum(values) / len(values) for name, values in timing.items()},
            "moves": {side: {key: count / games for key, count in usage[side].most_common(12)} for side in (1, 2)}}


def evaluate(arguments, spec, pool):
    low, high = (float(value) for value in arguments.sprt.split(",")) if arguments.sprt else (None, None)
    upper, lower = math.log((1 - 0.05) / 0.05), math.log(0.05 / (1 - 0.05))
    results, moves, verdict = [], [], None
    first = 1
    while first <= arguments.fights and verdict is None:
        chunks = []
        for _ in range(arguments.jobs):
            if first > arguments.fights:
                break
            count = min(arguments.chunk, arguments.fights - first + 1)
            chunks.append(pool.submit(run_chunk, arguments, spec, first, count))
            first += count
        for future in chunks:
            chunk_results, chunk_moves = future.result()
            results += chunk_results
            moves += chunk_moves
        if low is not None:
            score = sum(1.0 if r["winner"] == "1" else 0.5 if r["winner"] == "0" else 0.0 for r in results)
            ratio = llr(score, len(results), low, high)
            if ratio >= upper:
                verdict = f"H1 (score {high})"
            elif ratio <= lower:
                verdict = f"H0 (score {low})"
    result = summary(spec, results, moves)
    result["sprt"] = verdict if low is not None else None
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("specs", nargs="+", help="fights of openlf2 --fight")
    parser.add_argument("--fights", type=int, default=100, help="the most fights for each SPEC (100)")
    parser.add_argument("--chunk", type=int, default=10, help="fights in one process (10)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4, help="processes at once")
    parser.add_argument("--sprt", help="LOW,HIGH: stop when the score rate is clearly LOW or HIGH, e.g. 0.5,0.7")
    parser.add_argument("--build", default="build/debug")
    parser.add_argument("--scripts", default="scripts")
    parser.add_argument("--installer", default=os.environ.get("LF2_INSTALLER",
                        os.path.expanduser("~/.local/share/OpenLF2/LF2_v2.0a.exe")))
    parser.add_argument("--json", action="store_true", help="print JSON")
    arguments = parser.parse_args()
    arguments.game = os.path.join(arguments.build, "openlf2")
    reports = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=arguments.jobs) as pool:
        for spec in arguments.specs:
            reports.append(evaluate(arguments, spec, pool))
    if arguments.json:
        json.dump(reports, sys.stdout, indent=1)
        print()
        return
    for report in reports:
        print(f"{report['spec']}: {report['fights']} fights, side 1 {report['wins']} won, {report['draws']} drawn, "
              f"{report['losses']} lost, score {report['score']:.3f} +- {report['margin']:.3f}"
              + (f", SPRT: {report['sprt']}" if report["sprt"] else ""))
        print(f"  damage per minute {report['damage_per_minute'][0]:.0f} / {report['damage_per_minute'][1]:.0f}, "
              f"mean length {report['mean_ticks']:.0f} ticks, AI time "
              + ", ".join(f"{name} {value:.1f} us" for name, value in sorted(report["ai_us"].items())))
        for side in (1, 2):
            used = ", ".join(f"{key} {count:.1f}" for key, count in report["moves"][side].items())
            print(f"  side {side} moves per fight (id:frame): {used}")


if __name__ == "__main__":
    main()
