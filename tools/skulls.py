#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 OpenLF2 contributors
"""Makes the personal death skulls of scripts/base/ui/skulls.lua with a Logo Craft Bench.

    tools/skulls.py setup [--lf2 DIR]      make the bench: a face print and a Prompt card for each fighter
    tools/skulls.py generate [KEY...]      generate one skull image for each card that has none (or for KEY...)
    tools/skulls.py lua [--preview PNG]    reduce the images to pixel skulls and write scripts/base/ui/skulls.lua

The bench "LF2 death skulls" holds one column for each fighter: the fighter's face (the `head:` picture of its data,
from an LF2 folder, scaled 4x) is tied to a Prompt card, so the image model gets it as the reference image. Each card
generates one image. To replace a skull, generate again on its card and star the image you want: `lua` takes the
newest starred image of a card, or its newest image when none is starred.

The bench server (http://localhost:8790 by default, LCB_URL) must run, and its token must be in
~/.config/logo-craft-bench/token. Generation costs money on the bench's OpenAI key, and the bench allows Claude one
image per action. `lua` needs Pillow and NumPy.
"""
import argparse
import io
import json
import os
import sys
import urllib.request
import uuid

BASE = os.environ.get("LCB_URL", "http://localhost:8790")
BENCH_NAME = "LF2 death skulls"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(ROOT, "scripts", "base", "ui", "skulls.lua")
# The size of a skull in cells (its longer side), the most colors of one skull, and the closest two colors may be.
CELLS, COLORS, MERGE_DISTANCE = 24, 8, 28

# Key, name, the `head:` picture of the fighter's data, and the signature features for the prompt.
FIGHTERS = [
    ("bandit", "Bandit", "sprite/sys/bandit_f.bmp", "a red bandana tied over the top of the skull, with two short knot tails at the side, and black sunglasses over the eye sockets"),
    ("bat", "Bat", "sprite/sys/bat_f.bmp", "messy dark brown spiky hair, small glowing red dots in the eye sockets, and a hint of a red collar under the jaw"),
    ("davis", "Davis", "sprite/sys/davis_f.bmp", "brown spiky hair swept up and back, determined eyebrows, and a hint of a blue collar under the jaw"),
    ("deep", "Deep", "sprite/sys/deep_f.bmp", "tall brown spiky hair, an angry brow, a clenched-teeth grin, and a hint of a yellow-orange collar under the jaw"),
    ("dennis", "Dennis", "sprite/sys/dennis_f.bmp", "messy black spiky hair with strands over the forehead, and a hint of a green scarf under the jaw"),
    ("firen", "Firen", "sprite/sys/firen_f.bmp", "olive-blond hair swept back, a hint of a red scarf under the jaw, and two tiny orange pixel flames beside the skull"),
    ("firzen", "Firzen", "sprite/sys/firzen_f.bmp", "wild green spiky hair with a thin yellow glow outline, small red dots in the eye sockets, one tiny orange flame on one side and one tiny pale blue ice crystal on the other"),
    ("freeze", "Freeze", "sprite/sys/freeze_f.bmp", "spiky dark blue hair, a hint of a blue collar under the jaw, and two tiny pale blue ice crystals beside the skull"),
    ("henry", "Henry", "sprite/sys/henry_f.bmp", "brown hair with bangs, a hint of an orange-brown collar under the jaw, and one tiny arrow sticking up behind the skull like a quiver"),
    ("hunter", "Hunter", "sprite/sys/hunter_f.bmp", "a red headband with dark red-brown hair above it, a black visor band across the eye sockets, and one tiny arrow behind the skull"),
    ("jack", "Jack", "sprite/sys/jack_f.bmp", "neat dark gray-green hair with a side part, and a hint of a white shirt collar with brown suspender straps under the jaw"),
    ("jan", "Jan", "sprite/sys/jan_f.bmp", "dark blue hair with a side ponytail and a pink hair ribbon, softer round eye sockets with a pink blush dot under each, and a tiny pink heart beside the skull"),
    ("john", "John", "sprite/sys/john_f.bmp", "chestnut brown hair with a side sweep, a hint of a blue scarf under the jaw, and a tiny purple sparkle beside the skull"),
    ("julian", "Julian", "sprite/sys/julian_f.bmp", "a dark blue-violet skull like a mask, glowing red eye sockets, and wild dark spiky hair with red tips, so it looks like a cute boss"),
    ("justin", "Justin", "sprite/sys/justin_f.bmp", "a dark navy mask over the lower half of the skull, glowing red eye slits, and brown hair with bangs"),
    ("knight", "Knight", "sprite/sys/knight_f.bmp", "a steel gray knight helmet over the skull with a dark visor slit for the eyes, and a red plume on top"),
    ("louisEX", "Louis EX", "sprite/sys/louisEX_f.bmp", "spiky golden-blond hair, a steel shoulder-armor rim under the jaw with a small red gem, and a tiny blue sparkle beside the skull"),
    ("louis", "Louis", "sprite/sys/louis_f.bmp", "spiky golden-blond hair, and a steel and blue armor rim under the jaw"),
    ("mark", "Mark", "sprite/sys/mark_f.bmp", "slicked-back black hair, black sunglasses over the eye sockets, a tough square jaw, and a hint of white tank-top straps under the jaw"),
    ("monk", "Monk", "sprite/sys/monk_f.bmp", "a bald, shiny skull with one white highlight pixel, thick stern eyebrows, and a hint of a brown robe under the jaw"),
    ("rudolf", "Rudolf", "sprite/sys/rudolf_f.bmp", "dark brown hair tied in a small high ponytail like a ninja, and a hint of a blue ninja collar under the jaw"),
    ("sorcerer", "Sorcerer", "sprite/sys/sorcerer_f.bmp", "a pointed green hood around the skull, the skull in the hood's shadow, and a hint of a beige collar under the jaw"),
    ("woody", "Woody", "sprite/sys/woody_f.bmp", "brown spiky hair with strands over the forehead, and a hint of a green collar under the jaw"),
    ("template", "Template", "sprite/template1/face.bmp", "a smooth gray mannequin skull like an unfinished drawing, with thin light-gray construction lines on it (one circle on the cranium, one line down the middle and one line across the eyes), and plain empty eye sockets"),
]

STYLE = (
    "Style: a cute, minimalist pixel-art skull icon. One sprite on a 16x16 pixel grid, scaled up with crisp hard square pixels. "
    "No anti-aliasing, no gradients, no dithering. Flat colors from a palette of 4 to 6 colors, with a 1-pixel dark outline. "
    "Chibi proportions: a big round skull, large dark eye sockets, a tiny nose hole and a short row of teeth. "
    "Front view, centered, with wide empty space around it. Transparent background. No text, no ghost tail, no shadow, no body. "
    "The skull flies out of a defeated fighter in a retro 2D fighting game, so it must read clearly at 32 pixels. "
    "Use the reference face only for the colors and the signature features named here, not for its realistic drawing style."
)

BRIEF = (
    "Brief: a personal death skull for each Little Fighter 2 fighter (OpenLF2).\n\n"
    "When a fighter's HP reaches 0, a small skull pops up above its head, sways up and fades away (scripts/base/ui/fight_effects.lua). "
    "Each fighter gets its own skull here, with the signature features of its face.\n\n"
    "- Simple, pixelated, minimalist and cute.\n"
    "- One Prompt card per fighter, one image per card.\n"
    "- The face print above each card is the reference image (the `head:` picture of the fighter's data, scaled 4x).\n"
    "- Transparent background. The game draws the wispy tail itself.\n"
    "- Star the image to use. OpenLF2's tools/skulls.py lua turns the images into scripts/base/ui/skulls.lua."
)

# The bench layout: one column of face, card and image for each fighter.
COLS, COL_W, ROW_H = 6, 420, 1150


def token():
    with open(os.path.expanduser("~/.config/logo-craft-bench/token")) as file:
        return file.read().strip()


def request(method, path, body=None, headers=None, raw=False):
    req = urllib.request.Request(BASE + path, data=body, method=method,
                                 headers={"Authorization": f"Bearer {token()}", **(headers or {})})
    with urllib.request.urlopen(req) as response:
        data = response.read()
    return data if raw else json.loads(data)


def rest(method, path, obj=None):
    return request(method, path, json.dumps(obj).encode() if obj is not None else None, {"Content-Type": "application/json"})


def mcp(tool, **args):
    """One tool call on the bench's MCP endpoint (stateless, JSON answers); the bench then shows Claude as the author."""
    message = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}}
    answer = request("POST", "/mcp", json.dumps(message).encode(),
                     {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    if "error" in answer:
        sys.exit(f"{tool}: {answer['error']}")
    result = answer["result"]
    text = "\n".join(part.get("text", "") for part in result["content"])
    if result.get("isError"):
        sys.exit(f"{tool}: {text}")
    return text


def find_bench(create=False):
    for bench in rest("GET", "/api/benches"):
        if bench["name"] == BENCH_NAME:
            return rest("GET", f"/api/benches/{bench['id']}")
    if not create:
        sys.exit(f'No bench "{BENCH_NAME}". Run tools/skulls.py setup first.')
    return rest("POST", "/api/benches", {"name": BENCH_NAME})


def live(bench):
    return [paper for paper in bench["papers"] if not paper.get("discarded")]


def card_of(bench, name):
    return next((p for p in live(bench) if p["type"] == "prompt" and p.get("title") == f"{name} skull"), None)


def images_of(bench, card):
    """The finished images of a card, newest first, the starred ones before the others."""
    images = [p for p in live(bench) if p["type"] == "image" and (p.get("origin") or {}).get("promptPaperId") == card["id"]
              and p.get("asset") and (p.get("job") or {}).get("status") in (None, "done")]
    images.sort(key=lambda p: p["createdAt"], reverse=True)
    return sorted(images, key=lambda p: not p.get("starred"))


def import_face(bench_id, key, png, x, y):
    boundary = uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
             for name, value in (("x", x), ("y", y))]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="files"; filename="{key}.png"\r\n'
                 'Content-Type: image/png\r\n\r\n'.encode() + png + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    answer = request("POST", f"/api/benches/{bench_id}/import", b"".join(parts),
                     {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return answer["paperIds"][0]


def face_png(lf2, head):
    """The face bitmap scaled 4x without smoothing, so the image model sees its details."""
    from PIL import Image
    face = Image.open(os.path.join(lf2, head)).convert("RGB")
    face = face.resize((face.width * 4, face.height * 4), Image.NEAREST)
    out = io.BytesIO()
    face.save(out, "PNG")
    return out.getvalue()


def setup(args):
    bench = find_bench(create=True)
    if not any(p["type"] == "note" and p.get("isBrief") for p in live(bench)):
        mcp("add_paper", benchId=bench["id"], type="note", title="Brief", text=BRIEF, isBrief=True, x=-460, y=0)
    for index, (key, name, head, features) in enumerate(FIGHTERS):
        if card_of(bench, name):
            continue
        x, y = index % COLS * COL_W, index // COLS * ROW_H
        face = import_face(bench["id"], key, face_png(args.lf2, head), x + 150, y + 145)
        text = f"A personal death skull for {name}, a fighter from the game Little Fighter 2. Signature features: {features}.\n\n{STYLE}"
        added = mcp("add_paper", benchId=bench["id"], type="prompt", title=f"{name} skull", text=text,
                    imageSettings={"count": 1, "size": "1024x1024", "background": "transparent"}, x=x, y=y + 330)
        card = added.split(" with ID ")[1].split(" ")[0]
        mcp("connect", benchId=bench["id"], **{"from": face, "to": card})
        print(f"{name}: face {face}, card {card}")


def generate(args):
    bench = find_bench()
    for key, name, _, _ in FIGHTERS:
        card = card_of(bench, name)
        if not card or (args.keys and key not in args.keys) or (not args.keys and images_of(bench, card)):
            continue
        print(mcp("generate_images", benchId=bench["id"], paperId=card["id"], count=1).splitlines()[0])


def pixel_grid(png):
    """The image reduced to CELLS cells: each cell takes the most common palette color of its pixels, or stays
    see-through when less than about half of them are opaque. One palette from the opaque pixels keeps it crisp."""
    import numpy as np
    from PIL import Image
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    image = image.crop(image.getchannel("A").point(lambda a: 255 if a > 128 else 0).getbbox())
    pixels = np.array(image)
    opaque = pixels[:, :, 3] > 128
    rgb = Image.fromarray(pixels[:, :, :3])
    palette = Image.fromarray(pixels[:, :, :3][opaque].reshape(1, -1, 3)).quantize(COLORS, method=Image.Quantize.MEDIANCUT)
    index = np.array(rgb.quantize(palette=palette, dither=Image.Dither.NONE))
    colors = np.array(palette.getpalette()[:COLORS * 3]).reshape(-1, 3)
    height, width = opaque.shape
    scale = CELLS / max(width, height)
    rows, cols = max(1, round(height * scale)), max(1, round(width * scale))
    grid = []
    for y in range(rows):
        y0, y1 = y * height // rows, (y + 1) * height // rows
        row = []
        for x in range(cols):
            x0, x1 = x * width // cols, (x + 1) * width // cols
            cell = opaque[y0:y1, x0:x1]
            if cell.mean() < 0.45:
                row.append(None)
                continue
            values, counts = np.unique(index[y0:y1, x0:x1][cell], return_counts=True)
            row.append(tuple(int(v) for v in colors[values[counts.argmax()]]))
        grid.append(row)
    # Colors closer than MERGE_DISTANCE become the more common one.
    counts = {}
    for row in grid:
        for cell in row:
            if cell:
                counts[cell] = counts.get(cell, 0) + 1
    kept, merged = [], {}
    for color in sorted(counts, key=lambda c: -counts[c]):
        near = next((k for k in kept if sum((a - b) ** 2 for a, b in zip(color, k)) < MERGE_DISTANCE ** 2), None)
        merged[color] = near or color
        if not near:
            kept.append(color)
    return kept, [[merged[cell] if cell else None for cell in row] for row in grid]


def lua(args):
    bench = find_bench()
    out = [
        "-- SPDX-License-Identifier: MIT",
        "-- Copyright (c) 2026 OpenLF2 contributors",
        "",
        "-- The personal death skulls (OpenLF2 extension): one small pixel skull for each fighter, with the signature features",
        "-- of its face (Davis's spiky brown hair, Bandit's bandana and sunglasses, the Knight's helmet and plume, and so on).",
        "-- base/ui/fight_effects draws the skull of a fighter whose HP reaches 0, found by the `head:` picture of its data.",
        "-- Each skull is a palette of 0xRRGGBB colors and rows of one character a cell: \".\" is see-through, \"1\" to \"8\" are",
        "-- the palette's colors. tools/skulls.py writes this file: an image model draws each skull from the original face,",
        f"-- and the tool reduces it to {CELLS} cells and {COLORS} colors. Make the skulls again with the tool, do not edit them here.",
        "local skulls = {}",
        "",
    ]
    previews = []
    for key, name, head, _ in FIGHTERS:
        card = card_of(bench, name)
        images = images_of(bench, card) if card else []
        if not images:
            print(f"{name}: no image, left out")
            continue
        palette, grid = pixel_grid(request("GET", f"/api/assets/{images[0]['asset']}", raw=True))
        digit = {color: str(i + 1) for i, color in enumerate(palette)}
        out.append(f'skulls["{key}"] = {{')
        out.append(f'    head = "{head}",')
        out.append("    palette = {" + ", ".join("0x%02x%02x%02x" % color for color in palette) + "},")
        out.append("    rows = {")
        out.extend(f'        "{"".join(digit[cell] if cell else "." for cell in row)}",' for row in grid)
        out.append("    },")
        out.append("}")
        previews.append(grid)
        print(f"{name}: {len(grid[0])}x{len(grid)} cells, {len(palette)} colors, image {images[0]['id']}")
    out += ["", "return skulls", ""]
    with open(OUTPUT, "w", newline="\n") as file:
        file.write("\n".join(out))
    print(f"Wrote {os.path.relpath(OUTPUT, ROOT)}")
    if args.preview:
        from PIL import Image
        tile, cols = CELLS + 4, 6
        sheet = Image.new("RGB", (cols * tile, (len(previews) + cols - 1) // cols * tile), (85, 85, 85))
        for i, grid in enumerate(previews):
            ox = i % cols * tile + 2 + (CELLS - len(grid[0])) // 2
            oy = i // cols * tile + 2 + (CELLS - len(grid)) // 2
            for y, row in enumerate(grid):
                for x, cell in enumerate(row):
                    if cell:
                        sheet.putpixel((ox + x, oy + y), cell)
        sheet.resize((sheet.width * 6, sheet.height * 6), Image.NEAREST).save(args.preview)
        print(f"Wrote {args.preview}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("setup", help="make the bench")
    command.add_argument("--lf2", default=os.path.expanduser("~/games/LF2"), help="an LF2 v2.0a folder (default ~/games/LF2)")
    command.set_defaults(run=setup)
    command = commands.add_parser("generate", help="generate the missing skull images")
    command.add_argument("keys", nargs="*", help="generate for these fighters even when they have an image")
    command.set_defaults(run=generate)
    command = commands.add_parser("lua", help="write scripts/base/ui/skulls.lua")
    command.add_argument("--preview", help="also write a preview sheet of the pixel skulls to this PNG")
    command.set_defaults(run=lua)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
