#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Compares the threats that the brain `sentry` predicts with the hits that it takes (docs/ai-plan.md phase 3).

The input is the output of a headless run with a sentry and --ai-log, for example:

    openlf2 --headless ... --ai-brain 11=sentry --ai-log 11 --input-trace ... > run.log
    tools/ai_prediction_check.py run.log

For each hit, the tool looks at the newest prediction of each source before the hit tick. A hit is "exact" when one
of them named the hit tick, "near" when one named a tick 1 away, and "missed" otherwise. A prediction is "false" when
its tick passed without a hit within 1 tick and no newer prediction of the same source replaced it.
"""
import re
import sys
from collections import defaultdict


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    threats = defaultdict(list)  # fighter -> [(made, source, impact)]
    hurts = defaultdict(list)    # fighter -> [hit tick]
    other = defaultdict(int)  # hits by a grab or a throw
    for line in open(sys.argv[1], encoding="latin-1"):
        match = re.search(r"ai t=(\d+) i=(\d+) ev=(\w+)(.*)", line)
        if not match:
            continue
        tick, fighter, event = int(match.group(1)), int(match.group(2)), match.group(3)
        fields = dict(re.findall(r"(\w+)=(-?\d+)", match.group(4)))
        if event == "threat":
            threats[fighter].append((tick, int(fields["src"]), int(fields["impact"])))
        elif event == "hurt":
            # A grab and a throw hurt by the catch rules and the fall damage, not by a hit box: prediction does not
            # cover them.
            cause = re.search(r"cause=(\w+)", match.group(4))
            cause = cause.group(1) if cause else "hit"
            if cause != "hit":
                other[cause] += 1
            else:
                hurts[fighter].append(int(fields["hit"]))
    exact = near = missed = 0
    for fighter, hits in hurts.items():
        for hit in hits:
            newest = {}
            for made, source, impact in threats[fighter]:
                if made <= hit:
                    newest[source] = impact
            distances = [abs(impact - hit) for impact in newest.values()]
            best = min(distances) if distances else None
            if best == 0:
                exact += 1
            elif best == 1:
                near += 1
            else:
                missed += 1
                print(f"missed: fighter {fighter} hit at {hit}, newest predictions {sorted(newest.items())}")
    false = 0
    for fighter, entries in threats.items():
        hits = set(hurts[fighter])
        for position, (made, source, impact) in enumerate(entries):
            replaced = any(later_source == source and later_made <= impact
                           for later_made, later_source, _ in entries[position + 1:])
            if not replaced and not ({impact - 1, impact, impact + 1} & hits):
                false += 1
    total = exact + near + missed
    print(f"hits={total} exact={exact} near={near} missed={missed} grabs={other['grab']} throws={other['throw']} "
          f"predictions={sum(len(v) for v in threats.values())} false={false}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
