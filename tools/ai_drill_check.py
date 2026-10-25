#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Sums up the logs of the brain `drill` (docs/ai-plan.md phase 6): which special moves the actuator started.

Each input file is the output of one arena run with a drill and --ai-log, for example:

    openlf2 --installer ... --fight "davis/drill|firen/sentry;mp=500;time=20000;difficulty=crazy;mirror=0" --ai-log 10

The tool prints, for each file, the fighter, the rate, the moves that started with their latency, and each failure.
It fails (exit 1) when a move fails that is not in KNOWN, or when a run did not finish.
"""
import re
import sys

# Moves that need a condition that the drill does not make, by fighter name and start frame.
KNOWN = {
    ("louis", 300): "the transform needs hp of 177 or less without free_transform",
    ("rudolf", 235): "the transform needs a caught fighter",
    ("rudolf", 295): "the transform needs a fighter that Rudolf caught before",
}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    failed = False
    for path in sys.argv[1:]:
        text = open(path, encoding="latin-1").read()
        fighter = re.search(r"side1=(\w+)/drill", text)
        fighter = fighter.group(1) if fighter else "?"
        tests = re.findall(r"ev=drill n=\d+ move=(\d+) name=(\S+) input=(\S+) from=(\w+) rate=(\w+) result=(\w+) (.*)", text)
        done = re.search(r"ev=drill_done total=(\d+) ok=(\d+) fail=(\d+)", text)
        rate = tests[0][4] if tests else "?"
        latencies = sorted({int(m) for m in re.findall(r"latency=(\d+)", text)})
        print(f"{fighter} ({rate}): {done.group(2) if done else '?'} of {done.group(1) if done else '?'} started, "
              f"latency {latencies}")
        if not done:
            print("  FAIL: the drill did not finish")
            failed = True
        for move, name, input_, source, _, result, detail in tests:
            if result != "ok":
                reason = KNOWN.get((fighter, int(move)))
                print(f"  {'known' if reason else 'FAIL'}: {input_} {name} ({move}) from {source}: {detail}"
                      + (f" ({reason})" if reason else ""))
                failed = failed or not reason
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
