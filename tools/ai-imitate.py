#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Learns the play of fighters from `--ai-log observe` logs and writes the network of the brain `imitator`.

The logs come from any fight with `--ai-log INDICES,observe`: a replay of human play, an arena run of a strong brain,
or a headless trace. Each `ev=obs` line holds the ten features of base/ai/features and the action (the keys). The
tool keeps the most common actions, trains a network of one hidden layer (numpy, softmax), turns its weights into
integers (base/ai/net: fixed point with `scale`), checks that the integer network gives the same choices, and writes
scripts/base/ai/imitation.lua.

    openlf2 --installer ... --fight "davis/tactician|davis" --fights 40 --ai-log 10,observe > play.log
    tools/ai-imitate.py play.log --out scripts/base/ai/imitation.lua
"""
import argparse
import re
import sys
from collections import Counter

import numpy as np

SCALE = 256


def load(paths):
    rows, actions = [], []
    for path in paths:
        for line in open(path, encoding="latin-1"):
            match = re.search(r"ev=obs f=([-\d,]+) a=(\d+)", line)
            values = match and match.group(1).split(",")
            if values and len(values) == 10:
                rows.append([int(value) for value in values])
                actions.append(int(match.group(2)))
    return np.array(rows, dtype=np.float64), actions


def integer_forward(layers, x):
    """The same arithmetic as base/ai/net: fixed point with SCALE, floor division."""
    current = [int(value) * SCALE for value in x]
    for number, (weights, biases) in enumerate(layers):
        following = []
        for out in range(len(biases)):
            total = sum(int(weights[out][i]) * current[i] for i in range(len(current)))
            value = total // SCALE + int(biases[out])
            if number < len(layers) - 1 and value < 0:
                value = 0
            following.append(value)
        current = following
    best = 0
    for position in range(1, len(current)):
        if current[position] > current[best]:
            best = position
    return best


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--out", default="scripts/base/ai/imitation.lua")
    parser.add_argument("--actions", type=int, default=12, help="the most common actions to keep (12)")
    parser.add_argument("--hidden", type=int, default=24)
    parser.add_argument("--epochs", type=int, default=300)
    parser.add_argument("--seed", type=int, default=1)
    arguments = parser.parse_args()
    x, raw_actions = load(arguments.logs)
    if len(x) < 50:
        print(f"only {len(x)} observations: run more fights with --ai-log INDICES,observe", file=sys.stderr)
        return 1
    common = [action for action, _ in Counter(raw_actions).most_common(arguments.actions)]
    keep = [position for position, action in enumerate(raw_actions) if action in common]
    x = x[keep]
    y = np.array([common.index(raw_actions[position]) for position in keep])
    rng = np.random.default_rng(arguments.seed)
    order = rng.permutation(len(x))
    split = int(len(x) * 0.8)
    train, test = order[:split], order[split:]
    features, classes = x.shape[1], len(common)
    w1 = rng.normal(0, 0.1, (arguments.hidden, features))
    b1 = np.zeros(arguments.hidden)
    w2 = rng.normal(0, 0.1, (classes, arguments.hidden))
    b2 = np.zeros(classes)
    scale_in = np.maximum(np.abs(x).max(axis=0), 1)
    rate = 0.05
    for _ in range(arguments.epochs):
        for start in range(0, len(train), 256):
            batch = train[start:start + 256]
            xb = x[batch] / scale_in
            hidden = np.maximum(w1 @ xb.T + b1[:, None], 0)
            logits = w2 @ hidden + b2[:, None]
            logits -= logits.max(axis=0)
            probabilities = np.exp(logits) / np.exp(logits).sum(axis=0)
            target = np.zeros_like(probabilities)
            target[y[batch], np.arange(len(batch))] = 1
            grad_logits = (probabilities - target) / len(batch)
            grad_w2 = grad_logits @ hidden.T
            grad_hidden = (w2.T @ grad_logits) * (hidden > 0)
            grad_w1 = grad_hidden @ xb
            w2 -= rate * grad_w2
            b2 -= rate * grad_logits.sum(axis=1)
            w1 -= rate * grad_w1
            b1 -= rate * grad_hidden.sum(axis=1)

    def float_choice(samples):
        hidden = np.maximum(w1 @ (samples / scale_in).T + b1[:, None], 0)
        return np.argmax(w2 @ hidden + b2[:, None], axis=0)

    # The integer network takes the raw features: the input scaling goes into the first layer's weights.
    layers = [(np.round(w1 / scale_in * SCALE).astype(int), np.round(b1 * SCALE).astype(int)),
              (np.round(w2 * SCALE).astype(int), np.round(b2 * SCALE).astype(int))]
    float_accuracy = float((float_choice(x[test]) == y[test]).mean())
    integer_choices = [integer_forward(layers, row) for row in x[test]]
    integer_accuracy = float(np.mean(np.array(integer_choices) == y[test]))
    agreement = float(np.mean(np.array(integer_choices) == float_choice(x[test])))
    majority = Counter(y[test].tolist()).most_common(1)[0][1] / len(test)
    print(f"{len(x)} observations, {classes} actions; test accuracy {float_accuracy:.3f} (float), "
          f"{integer_accuracy:.3f} (integer), majority {majority:.3f}; integer and float agree on {agreement:.3f}")

    def lua_list(values):
        return "{" + ", ".join(str(int(value)) for value in values) + "}"
    lines = ["-- SPDX-License-Identifier: MIT", "-- Copyright (c) 2026 OpenLF2 contributors", "",
             "-- The network of the brain `imitator` (base/ai/brains/imitator), written by tools/ai-imitate.py from "
             f"{len(x)} observations.", "-- Do not edit it by hand: run the tool again.",
             "return {actions = " + lua_list(common) + ", network = {scale = " + str(SCALE) + ", layers = {"]
    for weights, biases in layers:
        lines.append(f"    {{inputs = {weights.shape[1]}, outputs = {weights.shape[0]}, weights = {lua_list(weights.flatten())},")
        lines.append(f"     biases = {lua_list(biases)}}},")
    lines.append("}}}")
    open(arguments.out, "w").write("\n".join(lines) + "\n")
    print(f"wrote {arguments.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
