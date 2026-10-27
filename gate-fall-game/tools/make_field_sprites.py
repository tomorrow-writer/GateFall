#!/usr/bin/env python3
"""Makes the FIELD-size sprite strips for generals from their 48px duel strips.

On the battlefield a general is drawn at troop scale (like Dragon Force: the
general stands out by colour, cape and marks, not by being a giant). The 48px
strips stay for the duel close-up and the cut-in; this writes a smaller copy to
assets/units/<id>_field/ that BattleView uses while phase == "field".

    python3 tools/make_field_sprites.py            (run from gate-fall-game/)

Each frame is shrunk by HEIGHT/48 with area averaging, alpha is cut back to
hard pixels and a 1px dark inner outline is redrawn. The result is a starting
point: touch it up in Aseprite (faces and trim get soft when shrunk).
Prints the frame/foot/height to put in "sprites.<id>.field" in battle_config.json.
"""
import json
import os
import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..")
CFG = os.path.join(ROOT, "data", "battle_config.json")
UNITS = ["general_knight", "general_slime"]
HEIGHT = 34  # field frame height (troop frames are 32; generals a touch taller)
OUTLINE = (24, 18, 30, 255)


def shrink(frame, nw, nh):
    p = np.asarray(frame).astype(float)
    al = p[..., 3:] / 255
    pm = np.dstack([p[..., :3] * al, p[..., 3]]).astype(np.uint8)
    sm = np.asarray(Image.fromarray(pm, "RGBA").resize((nw, nh), Image.BOX)).astype(float)
    a = sm[..., 3]
    rgb = np.clip(sm[..., :3] / np.maximum(a[..., None] / 255, 1e-3), 0, 255)
    mask = a > 110
    out = np.zeros((nh, nw, 4), np.uint8)
    out[mask, :3] = rgb[mask]
    out[mask, 3] = 255
    # inner outline: mask pixels that touch a transparent pixel (4-neighbour)
    pad = np.pad(mask, 1)
    edge = mask & ~(pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:])
    out[edge] = OUTLINE
    return Image.fromarray(out, "RGBA")


cfg = json.load(open(CFG))
for unit in UNITS:
    d = cfg["sprites"][unit]
    fw, fh = d["frame"]
    s = HEIGHT / fh
    nw, nh = round(fw * s), HEIGHT
    src_dir = os.path.join(ROOT, d["dir"].replace("res://", ""))
    dst_dir = src_dir + "_field"
    os.makedirs(dst_dir, exist_ok=True)
    for anim in d["anims"]:
        path = os.path.join(src_dir, anim + ".png")
        if not os.path.exists(path):
            continue
        img = Image.open(path).convert("RGBA")
        n = img.width // fw
        strip = Image.new("RGBA", (nw * n, nh))
        for i in range(n):
            strip.paste(shrink(img.crop((i * fw, 0, (i + 1) * fw, fh)), nw, nh), (i * nw, 0))
        strip.save(os.path.join(dst_dir, anim + ".png"))
    fx, fy = d["foot"]
    foot = [round(fx * s), min(nh - 1, round(fy * s))]
    height = round(d.get("height", fh) * s)
    print(unit, json.dumps({"dir": d["dir"] + "_field", "frame": [nw, nh], "foot": foot, "height": height}))
