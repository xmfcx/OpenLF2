#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Lists the moves of every LF2 fighter from the original data files.

The input is a folder that holds data/data.txt and the data/*.dat files of LF2 v2.0a. The .dat files can be the
encoded originals or decoded text. The output is a Markdown table for each fighter (docs/ai-moves.md), or JSON with
--json. The AI plan (docs/ai-plan.md) uses the same facts: the game builds them at run time from the frames.

    tools/lf2_moves.py ~/games/LF2 > docs/ai-moves.md
"""
import argparse
import json
import os
import re
import sys

KEY = b"SiuHungIsAGoodBearBecauseHeIsVeryGood"
BLOCKS = {"itr", "bdy", "opoint", "cpoint", "wpoint", "bpoint"}
# The sequences of base/game/control: Defend, then a direction or Jump, then Attack or Jump.
INPUTS = [("Fa", "D>A"), ("Ua", "D^A"), ("Da", "DvA"), ("Fj", "D>J"), ("Uj", "D^J"), ("Dj", "DvJ"), ("ja", "DJA")]
# Frames that the engine enters without a frame field (base/game/control, the original's fixed numbers).
BASIC = [(60, "A", "punch"), (65, "A", "punch 2"), (70, "A on a dizzy enemy", "super punch"),
         (80, "A in a jump", "jump attack"), (85, "A while running", "run attack"), (90, "A in a dash", "dash attack"),
         (110, "D", "defend"), (102, "D in the air after a hit", "rowing"), (120, "walk into a dizzy enemy", "catch"),
         (20, "A with a light weapon", "weapon attack"), (30, "A in a jump with a light weapon", "jump weapon attack"),
         (35, "A while running with a light weapon", "run weapon attack"), (40, "A in a dash with a light weapon", "dash weapon attack"),
         (45, "throw a light weapon", "light weapon throw"), (50, "throw a heavy weapon", "heavy weapon throw")]
ITR_KINDS = {0: "hit", 1: "catch dizzy", 2: "pick weapon", 3: "catch", 4: "thrown body", 5: "weapon hit", 6: "super punch",
             7: "roll pick", 8: "heal", 9: "shield", 10: "sonata", 11: "sonata", 14: "wall", 15: "whirlwind", 16: "freeze wind"}
EFFECTS = {1: "sharp", 2: "fire", 3: "ice", 20: "fire", 21: "fire", 22: "fire", 23: "fire", 30: "ice"}
# effect 4 hits only objects (balls and weapons), constants.effects.skip_characters.
OBJECTS_ONLY = 4
STATES = {7: "defending", 9: "catching", 18: "burning", 19: "burning run", 100: "dash attack state",
          301: "sword dash", 400: "teleport to enemy", 401: "teleport to ally", 500: "transform",
          501: "transform back", 1700: "heal self", 9995: "transform to Louis EX"}


def decode(raw):
    text = raw.lstrip()
    if text.startswith(b"<bmp_begin>") or text.startswith(b"<frame>") or b"<frame>" in raw[:4096]:
        return raw.decode("latin-1")
    return bytes((raw[i] - KEY[i % len(KEY)]) & 255 for i in range(123, len(raw))).decode("latin-1")


def number(token):
    try:
        value = float(token)
    except ValueError:
        match = re.match(r"-?\d+(\.\d+)?", token)
        if not match:
            return 0
        value = float(match.group(0))
    return int(value) if value == int(value) else value


def parse(text):
    header = re.search(r"<bmp_begin>(.*?)<bmp_end>", text, re.S)
    head = header.group(1) if header else ""
    info = {"name": (re.search(r"name:\s*(\S+)", head) or [None, "?"])[1], "movement": {}}
    for key, value in re.findall(r"^\s*([a-z_]+(?:speed|speedz|height|distance|distancez|rate))\s+(-?[\d.]+)", head, re.M):
        info["movement"][key] = number(value)
    frames = {}
    for match in re.finditer(r"<frame>\s*(\d+)\s+(\S*)(.*?)<frame_end>", text, re.S):
        frame = {"id": int(match.group(1)), "name": match.group(2), "itr": [], "bdy": [], "opoint": [], "cpoint": []}
        tokens = match.group(3).split()
        block, index = None, 0
        while index < len(tokens):
            token = tokens[index]
            index += 1
            if token.endswith("_end:"):
                block = None
                continue
            if token.endswith(":") and token[:-1] in BLOCKS:
                block = {}
                frame.setdefault(token[:-1], []).append(block)
                continue
            if not token.endswith(":") or index >= len(tokens):
                continue
            key, value = token[:-1], tokens[index]
            index += 1
            target = block if block is not None else frame
            target[key] = value if key == "sound" else number(value)
        frames[frame["id"]] = frame
    info["frames"] = frames
    return info


def catalog(root):
    text = open(os.path.join(root, "data", "data.txt"), encoding="latin-1").read()
    section = re.search(r"<object>(.*?)<object_end>", text, re.S).group(1)
    entries = []
    for line in section.splitlines():
        line = line.split("#")[0]
        match = re.search(r"id:\s*(\d+)\s+type:\s*(\d+)\s+file:\s*(\S+)", line)
        if match:
            entries.append((int(match.group(1)), int(match.group(2)), match.group(3).replace("\\", "/")))
    return entries


def load(root, path):
    for candidate in (os.path.join(root, path), os.path.join(root, path.lower())):
        if os.path.exists(candidate):
            return parse(decode(open(candidate, "rb").read()))
    return None


def chain(frames, start, limit=60, character=True):
    """Follows `next` from a start frame until the move ends (999, standing, a jump frame or a loop)."""
    seen, order, current = set(), [], start
    while current not in seen and len(order) < limit:
        frame = frames.get(current)
        if not frame:
            break
        seen.add(current)
        order.append(frame)
        following = abs(frame.get("next", 0))
        if following in (0, 999, 1000) or character and following < 20 and following != start:
            return order, False
        current = following
    return order, current in seen


def summarize_move(frames, objects, start):
    order, loops = chain(frames, start)
    if not order:
        return None
    ticks, first_hit, hits, spawns, follow, states = 0, None, [], [], {}, []
    cost = order[0].get("mp", 0)
    hold_cost = 0
    for frame in order:
        if frame is not order[0] and frame.get("mp", 0) < 0:
            hold_cost = min(hold_cost, frame["mp"])
        state = frame.get("state", 0)
        if state in STATES and STATES[state] not in states:
            states.append(STATES[state])
        for itr in frame["itr"]:
            if first_hit is None:
                first_hit = ticks + 1
            reach = itr.get("x", 0) + itr.get("w", 0) - frame.get("centerx", 0)
            hits.append((itr.get("kind", 0), itr.get("injury", 0), itr.get("fall", 0), itr.get("bdefend", 0),
                         itr.get("effect", 0), reach, itr.get("zwidth", 0)))
        for point in frame["opoint"]:
            spawns.append((point.get("oid", 0), point.get("action", 0), point.get("dvx", 0)))
        for field, label in [("hit_a", "A"), ("hit_j", "J"), ("hit_d", "D")] + [("hit_" + f, l) for f, l in INPUTS]:
            target = abs(frame.get(field, 0))
            if target and target not in (0, 999) and target not in [f["id"] for f in order[:1]]:
                follow.setdefault(label, target)
        ticks += frame.get("wait", 0) + 1
    damage = [h for h in hits if h[0] in (0, 4, 5, 6, 10, 11, 15, 16) and h[4] != OBJECTS_ONLY]
    objects_only = any(h[4] == OBJECTS_ONLY for h in hits)
    best = max(damage, key=lambda h: h[1]) if damage else None
    heal = [h[1] for h in hits if h[0] == 8]
    projectiles = []
    for oid, action, dvx in spawns:
        info = objects.get(oid)
        if not info:
            projectiles.append(f"object {oid}")
            continue
        frame = info["frames"].get(action) or {}
        # A ball often starts in a frame without a hit box: the strongest hit box of its chain counts.
        flight, _ = chain(info["frames"], action, character=False)
        damage_here = max([i.get("injury", 0) for f in flight for i in f["itr"] if i.get("kind", 0) in (0, 8)] or [0])
        speed = dvx or frame.get("dvx", 0)
        chase = " chases" if frame.get("hit_Fa", 0) else ""
        label = os.path.splitext(os.path.basename(info["path"]))[0]
        projectiles.append(f"{label} (dvx {speed}, dmg {damage_here}{chase})")
    unique = []
    for item in projectiles:
        if item not in unique:
            unique.append(item)
    counted = [f"{item} x{projectiles.count(item)}" if projectiles.count(item) > 1 else item for item in unique]
    hp_cost = cost // 1000 * 10 if cost >= 1000 else 0
    return {"start": start, "name": order[0]["name"], "mp": cost % 1000 if cost >= 1000 else cost, "hp": hp_cost,
            "hold_mp": -hold_cost, "ticks": ticks, "loops": loops, "first_hit": first_hit,
            "damage": best[1] if best else 0, "fall": best[2] if best else 0, "bdefend": best[3] if best else 0,
            "effect": EFFECTS.get(best[4], "") if best else "", "reach": best[5] if best else 0,
            "hits": len(damage), "kinds": sorted({ITR_KINDS.get(h[0], str(h[0])) for h in hits} - {"hit"}),
            "heal": max(heal) if heal else 0, "objects_only": objects_only, "spawns": counted, "follow": follow, "states": states,
            "frames": [f["id"] for f in order]}


def source_label(frames, source):
    name = frames[source]["name"]
    if source in (0, 1, 2, 3, 4):
        return "stand"
    if 5 <= source <= 8:
        return "walk"
    if 9 <= source <= 11:
        return "run"
    if 210 <= source <= 212:
        return "jump"
    if 213 <= source <= 214:
        return "dash"
    if source == 110 or name == "defend":
        return "defend"
    return name


def fighter_moves(info, objects):
    frames = info["frames"]
    specials = {}
    for source in sorted(frames):
        frame = frames[source]
        for field, label in INPUTS:
            target = abs(frame.get("hit_" + field, 0))
            if target and target in frames:
                entry = specials.setdefault((label, target), [])
                where = source_label(frames, source)
                if where not in entry:
                    entry.append(where)
    moves = []
    for (label, target), sources in sorted(specials.items(), key=lambda item: (item[0][1], item[0][0])):
        summary = summarize_move(frames, objects, target)
        if summary:
            summary.update({"input": label, "from": sources})
            moves.append(summary)
    basics = []
    for frame_id, how, label in BASIC:
        if frame_id in frames:
            summary = summarize_move(frames, objects, frame_id)
            if summary:
                summary.update({"input": how, "label": label})
                basics.append(summary)
    return moves, basics


def describe(move):
    notes = []
    if move["damage"]:
        hit = f"{move['damage']} dmg"
        if move["hits"] > 1:
            hit += f", {move['hits']} hit boxes"
        if move["fall"] >= 60:
            hit += ", knocks down"
        if move["bdefend"] >= 60:
            hit += ", breaks defense"
        if move["effect"]:
            hit += ", " + move["effect"]
        notes.append(hit)
    if move["objects_only"]:
        notes.append("hits balls")
    if move["heal"]:
        notes.append(f"heals {move['heal']}")
    if move["kinds"]:
        notes.append(", ".join(move["kinds"]))
    if move["spawns"]:
        notes.append("spawns " + ", ".join(move["spawns"]))
    if move["states"]:
        notes.append(", ".join(move["states"]))
    if move["hold_mp"]:
        notes.append(f"holds for {move['hold_mp']} mp a frame")
    if move["follow"]:
        notes.append("then " + ", ".join(f"{key}: {value}" for key, value in move["follow"].items()))
    if move["loops"]:
        notes.append("loops")
    return "; ".join(notes)


def markdown(fighters):
    lines = ["# Moves of the LF2 fighters", "",
             "This file is generated by `tools/lf2_moves.py` from the data files of LF2 v2.0a. Do not edit it by hand.", "",
             "How to read the tables:", "",
             "- Input: `D>A` is Defend, then forward, then Attack. `^` is up, `v` is down, `J` is Jump. `DJA` is Defend, Jump, Attack.",
             "- From: the frames where the input starts the move: `stand`, `walk`, `run`, `jump`, `dash`, `defend`, or the name of another move (a follow-up).",
             "- Cost: the mp (and hp) that the first frame takes. A move does not start without it.",
             "- Ticks: the length of the frame chain at 30 ticks a second (`wait + 1` for each frame). `hit@` is the tick of the first hit box.",
             "- Reach: how far the strongest hit box goes in front of the fighter's center, in pixels.",
             "- Effect: the strongest hit box. `then A: 275` means that Attack in the move goes to frame 275 (a follow-up or a hold).",
             "- Spawns: the objects of the move with their `dvx` and the strongest hit box of their frame chain. A chasing ball shows `dmg 0` when its hit frames come after a change that the tool does not follow.", ""]
    for fighter in fighters:
        move_info = fighter["movement"]
        lines += [f"## {fighter['name']} (id {fighter['id']})", ""]
        lines.append(f"Walk {move_info.get('walking_speed', '?')}, run {move_info.get('running_speed', '?')}, "
                     f"jump {move_info.get('jump_distance', '?')} x {move_info.get('jump_height', '?')}, "
                     f"dash {move_info.get('dash_distance', '?')} x {move_info.get('dash_height', '?')}.")
        lines += ["", "| Input | From | Move (frame) | Cost | Ticks | hit@ | Reach | Effect |", "|---|---|---|---|---|---|---|---|"]
        for move in fighter["moves"]:
            cost = f"{move['mp']} mp" + (f" {move['hp']} hp" if move["hp"] else "")
            lines.append(f"| {move['input']} | {', '.join(move['from'])} | {move['name']} ({move['start']}) | {cost} | "
                         f"{move['ticks']} | {move['first_hit'] or '-'} | {move['reach'] or '-'} | {describe(move)} |")
        if not fighter["moves"]:
            lines.append("| - | - | no special moves | | | | | |")
        lines += ["", "<details><summary>Basic moves</summary>", "",
                  "| Input | Move (frame) | Ticks | hit@ | Reach | Effect |", "|---|---|---|---|---|---|"]
        for move in fighter["basics"]:
            lines.append(f"| {move['input']} | {move['label']}: {move['name']} ({move['start']}) | {move['ticks']} | "
                         f"{move['first_hit'] or '-'} | {move['reach'] or '-'} | {describe(move)} |")
        lines += ["", "</details>", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("root", help="folder with data/data.txt and the .dat files")
    parser.add_argument("--json", action="store_true", help="print JSON instead of Markdown")
    arguments = parser.parse_args()
    entries = catalog(arguments.root)
    objects = {}
    for object_id, kind, path in entries:
        if kind != 0:
            info = load(arguments.root, path)
            if info:
                info["path"] = path
                objects[object_id] = info
    fighters = []
    for object_id, kind, path in sorted(entries):
        if kind != 0 or object_id == 0:
            continue
        info = load(arguments.root, path)
        if not info:
            print(f"missing {path}", file=sys.stderr)
            continue
        moves, basics = fighter_moves(info, objects)
        fighters.append({"id": object_id, "name": info["name"], "movement": info["movement"], "moves": moves, "basics": basics})
    if arguments.json:
        json.dump(fighters, sys.stdout, indent=1)
    else:
        print(markdown(fighters))


if __name__ == "__main__":
    main()
