#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Measures the reflexes of the brain `guard` (docs/ai-plan.md phase 7) from arena logs with --ai-log.

An answer (`ev=reflex answer=defend|sidestep|jump ... in=R`) works when the guard takes no hit in the R + 2 ticks
after it, or takes it while it defends (a blocked hit). The tool prints, for each file, the answers that worked, and
the hits by the guard's class (free: no answer, defending: blocked or broken, dizzy: after a combo).

    tools/ai_reflex_check.py run.log [more.log ...]
"""
import re
import sys
from collections import Counter


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    total_answers = total_worked = 0
    for path in sys.argv[1:]:
        answers, hurts = [], []
        for line in open(path, encoding="latin-1"):
            match = re.search(r"ai t=(\d+) i=(\d+) ev=(\w+) (.*)", line)
            if not match:
                continue
            tick, fighter, event, rest = int(match.group(1)), match.group(2), match.group(3), match.group(4)
            fields = dict(re.findall(r"(\w+)=(\S+)", rest))
            if event == "reflex":
                answers.append((fighter, tick, int(fields["in"]), fields["answer"]))
            elif event == "hurt":
                hurts.append((fighter, int(fields["hit"]), fields["class"]))
            elif event == "start":
                # A new fight starts the ticks again: keep the files one fight each, or the fights apart by start.
                answers.append(("start", tick, 0, ""))
        worked = 0
        counted = 0
        for position, (fighter, tick, remaining, answer) in enumerate(answers):
            if fighter == "start":
                continue
            counted += 1
            window = [h for h in hurts if h[0] == fighter and tick <= h[1] <= tick + remaining + 2]
            if all(h[2] == "defending" for h in window):
                worked += 1
        classes = Counter(h[2] for h in hurts)
        total_answers += counted
        total_worked += worked
        print(f"{path}: {worked} of {counted} answers worked; hits by class: "
              + ", ".join(f"{name} {count}" for name, count in classes.most_common()))
    if total_answers:
        print(f"all: {total_worked} of {total_answers} answers worked ({100 * total_worked / total_answers:.0f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
