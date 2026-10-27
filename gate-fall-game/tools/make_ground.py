#!/usr/bin/env python3
"""Battle ground backgrounds in the Dragon Force manner: a plain, strongly
coloured ground that fills the screen (the camera only shows y 76-256 of it),
a thin far horizon under the top HUD, light texture so the troops read clearly.

Original art, generated: no source images. 480x270 like every background
(horizon at y 104, ground to y 240, dark strip below for the bottom HUD).

    python3 tools/make_ground.py                 # every palette
    python3 tools/make_ground.py grass           # one palette
Writes assets/backgrounds/field_<name>.png. Point field.background in
data/battle_config.json at the one to use.

Each palette: sky (top, horizon), far (tree line / hills colour), ground
(far, near) gradient, specks (darker, lighter), tufts colour, patch colour
(worn ground), seed. Ground is kept darker / less saturated than the green
slimes and warmer than the blue knights so both armies stand out.
"""
import random
import sys
from pathlib import Path

from PIL import Image

W, H = 480, 270
HORIZON = 104
GROUND_END = 240

PALETTES = {
    # deep meadow: darker than the slimes, cooler than dirt
    "grass": {
        "sky": ((92, 140, 196), (176, 206, 226)),
        "far": (52, 84, 62), "far_hi": (70, 106, 74),
        "ground": ((52, 86, 50), (70, 110, 58)),
        "specks": ((44, 74, 44), (88, 128, 70)),
        "tuft": (96, 140, 74), "patch": (96, 104, 62),
        "seed": 11,
    },
    # dry steppe: warm earth, both armies pop on it
    "steppe": {
        "sky": ((120, 150, 190), (214, 206, 184)),
        "far": (110, 96, 80), "far_hi": (138, 120, 96),
        "ground": ((122, 104, 70), (156, 132, 86)),
        "specks": ((106, 90, 60), (176, 152, 104)),
        "tuft": (150, 140, 80), "patch": (138, 112, 76),
        "seed": 23,
    },
    # castle hall: dark red stone floor for siege battles
    "hall": {
        "sky": ((30, 24, 30), (54, 40, 44)),
        "far": (70, 52, 50), "far_hi": (92, 70, 64),
        "ground": ((84, 30, 32), (122, 44, 42)),
        "specks": ((70, 24, 26), (142, 60, 54)),
        "tuft": None, "patch": (100, 36, 38),
        "seed": 5,
    },
}


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make(name, p):
    rnd = random.Random(p["seed"])
    img = Image.new("RGB", (W, H))
    px = img.load()
    # sky (mostly behind the top HUD)
    for y in range(HORIZON):
        c = lerp(p["sky"][0], p["sky"][1], y / (HORIZON - 1))
        for x in range(W):
            px[x, y] = c
    # far band: a rolling tree line / wall sitting on the horizon
    top = []
    h = 8.0
    for x in range(W):
        h += rnd.uniform(-1.2, 1.2)
        h = max(4.0, min(13.0, h))
        top.append(HORIZON - int(h))
    for x in range(W):
        for y in range(top[x], HORIZON):
            hi = y - top[x] < 2 and (x // 3 + y) % 2 == 0
            px[x, y] = p["far_hi"] if hi else p["far"]
    # ground: far to near gradient in 6 flat bands (pixel-art, no smooth ramp),
    # with an ordered dither on the band edges
    bands = 6
    for y in range(HORIZON, GROUND_END):
        t = (y - HORIZON) / (GROUND_END - HORIZON - 1)
        b = min(bands - 1, int(t * bands))
        frac = t * bands - b
        for x in range(W):
            bb = b
            if frac > 0.75 and (x + y) % 2 == 0 and b < bands - 1:
                bb = b + 1
            px[x, y] = lerp(p["ground"][0], p["ground"][1], bb / (bands - 1))
    # worn patches: flat ellipses, wider than tall (perspective)
    for _ in range(9):
        cx, cy = rnd.randrange(W), rnd.randrange(HORIZON + 12, GROUND_END - 6)
        rx, ry = rnd.randint(18, 46), rnd.randint(4, 9)
        for y in range(cy - ry, cy + ry + 1):
            for x in range(cx - rx, cx + rx + 1):
                if 0 <= x < W and HORIZON < y < GROUND_END and ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1:
                    if (x + y) % 3:  # broken edge
                        px[x, y] = lerp(px[x, y], p["patch"], 0.55)
    # specks: denser and bigger near the camera
    for _ in range(2600):
        y = rnd.randrange(HORIZON + 1, GROUND_END)
        x = rnd.randrange(W)
        near = (y - HORIZON) / (GROUND_END - HORIZON)
        c = p["specks"][rnd.random() < 0.45]
        px[x, y] = c
        if near > 0.5 and rnd.random() < near - 0.4 and x + 1 < W:
            px[x + 1, y] = c
    # grass tufts: little "v" shapes, sparse
    if p["tuft"]:
        for _ in range(140):
            y = rnd.randrange(HORIZON + 6, GROUND_END - 2)
            x = rnd.randrange(1, W - 1)
            px[x, y] = p["tuft"]
            px[x - 1, y - 1] = p["tuft"]
            px[x + 1, y - 1] = p["tuft"]
            if (y - HORIZON) > 70:
                px[x, y - 2] = p["tuft"]
    # dark strip under the field, behind the bottom HUD
    for y in range(GROUND_END, H):
        c = lerp((24, 22, 28), (14, 13, 18), (y - GROUND_END) / (H - GROUND_END))
        for x in range(W):
            px[x, y] = c
    for x in range(W):
        px[x, GROUND_END] = lerp(p["ground"][1], (24, 22, 28), 0.5)
    return img


def main():
    out = Path(__file__).resolve().parent.parent / "assets" / "backgrounds"
    names = sys.argv[1:] or list(PALETTES)
    for n in names:
        path = out / f"field_{n}.png"
        make(n, PALETTES[n]).save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()
