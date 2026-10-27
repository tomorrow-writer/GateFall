#!/usr/bin/env python3
"""Generates PLACEHOLDER sprite strips at the agreed sprite sizes, so the
sprite pipeline and the on-screen size can be checked before real art exists.
Replace the PNGs in assets/units/<id>/ with real art of the same frame size
(see "sprites" in data/battle_config.json). Run from gate-fall-game/:
    python3 tools/make_placeholder_sprites.py
"""
from PIL import Image, ImageDraw
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "units")
OUTLINE = (20, 18, 28, 255)


def strip(n, w, h):
    return Image.new("RGBA", (w * n, h), (0, 0, 0, 0))


def save(img, unit, anim):
    d = os.path.join(OUT, unit)
    os.makedirs(d, exist_ok=True)
    img.save(os.path.join(d, anim + ".png"))


def box(dr, x0, y0, x1, y1, fill):
    dr.rectangle([x0, y0, x1, y1], fill=fill, outline=OUTLINE)


def ell(dr, x0, y0, x1, y1, fill):
    dr.ellipse([x0, y0, x1, y1], fill=fill, outline=OUTLINE)


# ---- knight 32x32, feet at y=30 -------------------------------------------------
def knight(dr, ox, bob=0, swing=0, lean=0, dead=0):
    S, D, P = (170, 180, 200, 255), (90, 100, 120, 255), (200, 68, 60, 255)
    if dead:
        box(dr, ox + 4, 24 + dead, ox + 27, 29, S)
        return
    y = -bob
    box(dr, ox + 11 + lean, 17 + y, ox + 15, 30, D)  # legs
    box(dr, ox + 17 + lean, 17 + y, ox + 21, 30, D)
    box(dr, ox + 10 + lean, 9 + y, ox + 22, 21 + y, S)  # body
    box(dr, ox + 11 + lean, 2 + y, ox + 21, 10 + y, S)  # helm
    dr.line([ox + 17 + lean, 5 + y, ox + 20 + lean, 5 + y], fill=OUTLINE)  # visor
    box(dr, ox + 15 + lean, 0 + y, ox + 17 + lean, 2 + y, P)  # plume
    hx, hy = ox + 22 + lean, 14 + y
    tip = [(hx + 3, hy - 12), (hx + 9, hy - 6), (hx + 9, hy + 2)][swing]
    dr.line([hx, hy, tip[0], tip[1]], fill=(235, 235, 245, 255), width=2)


# ---- big slime 32x32, feet at y=29 ----------------------------------------------
def slime(dr, ox, squash=0, thrust=0, dead=0, w=32, h=32, mini=False):
    G = (140, 225, 140, 255) if mini else (79, 194, 79, 255)
    s = 1 if mini else 2
    if dead:
        ell(dr, ox + 3 * s, h - 4 - dead, ox + w - 3 * s, h - 2, G)
        return
    top = (h - 19) + squash if not mini else h - 10 + squash
    ell(dr, ox + (6 if not mini else 2), top, ox + w - (7 if not mini else 3), h - 3, G)
    ey = top + (3 if mini else 5)
    dr.rectangle([ox + w // 2 + 1, ey, ox + w // 2 + 1, ey + 1], fill=OUTLINE)
    dr.rectangle([ox + w // 2 + (3 if mini else 5), ey, ox + w // 2 + (3 if mini else 5), ey + 1], fill=OUTLINE)
    if not mini:
        dr.line([ox + 18, top + 9, ox + 28 + thrust, top + 6], fill=(201, 164, 106, 255), width=1)


# ---- generals 48x48, feet at y=46 -----------------------------------------------
def general(dr, ox, slime_gen, bob=0, swing=0, cast=0, dead=0):
    A = (47, 138, 82, 255) if slime_gen else (143, 155, 179, 255)
    C = (160, 42, 42, 255) if slime_gen else (42, 74, 160, 255)
    T = (216, 180, 64, 255)
    if dead:
        box(dr, ox + 6, 38 + dead, ox + 41, 45, A)
        return
    y = -bob
    dr.polygon([(ox + 14, 12 + y), (ox + 22, 12 + y), (ox + 26, 44), (ox + 9, 44)], fill=C, outline=OUTLINE)  # cape
    box(dr, ox + 16, 34 + y, ox + 21, 46, A)  # legs
    box(dr, ox + 25, 34 + y, ox + 30, 46, A)
    box(dr, ox + 15, 14 + y, ox + 31, 36 + y, A)  # body
    dr.rectangle([ox + 16, 25 + y, ox + 30, 26 + y], fill=T)
    head = (232, 200, 168, 255) if slime_gen else A
    box(dr, ox + 17, 3 + y, ox + 29, 14 + y, head)
    if slime_gen:
        dr.rectangle([ox + 17, 1 + y, ox + 29, 4 + y], fill=(122, 79, 176, 255))
    else:
        dr.rectangle([ox + 17, 1 + y, ox + 29, 4 + y], fill=T)
        box(dr, ox + 22, 0, ox + 24, 2, (200, 68, 60, 255))
    dr.rectangle([ox + 25, 7 + y, ox + 26, 8 + y], fill=OUTLINE)  # eye (faces right)
    hx, hy = ox + 32, 24 + y
    if slime_gen:
        lean = [0, 4, 7][swing] if not cast else 0
        top_y = hy - 22 - (4 if cast else 0)
        dr.line([hx, hy + 12, hx + lean, top_y], fill=(201, 164, 106, 255), width=2)
        r = 4 + (2 if cast else 0)
        dr.ellipse([hx + lean - r, top_y - r - 2, hx + lean + r, top_y + r - 2], fill=(115, 255, 140, 255), outline=OUTLINE)
    else:
        tip = [(hx + 4, hy - 20), (hx + 14, hy - 12), (hx + 15, hy + 3)][swing] if not cast else (hx + 2, hy - 22)
        dr.line([hx, hy, tip[0], tip[1]], fill=(240, 240, 255, 255), width=2)


# Units that already have real art: never overwrite them with placeholders.
REAL_ART = {"general_slime", "general_knight", "slime_big", "slime_mini", "knight"}


def make_unit(unit, w, h, draw_fn, troop=False):
    if unit in REAL_ART:
        print("skip", unit, "(real art)")
        return
    anims = {
        "idle": [dict(bob=0), dict(bob=1)],
        "walk": [dict(bob=0), dict(bob=1), dict(bob=0), dict(bob=1)],
        "attack": [dict(swing=0), dict(swing=1), dict(swing=2)],
        "cast": [dict(cast=1, bob=0), dict(cast=1, bob=1)],
        "die": [dict(dead=1), dict(dead=2), dict(dead=3)],
    }
    if troop:
        del anims["cast"]  # only generals channel specials
    for name, frames in anims.items():
        img = strip(len(frames), w, h)
        dr = ImageDraw.Draw(img)
        for i, kw in enumerate(frames):
            draw_fn(dr, i * w, **kw)
        save(img, unit, name)


def kn(dr, ox, bob=0, swing=0, cast=0, dead=0):
    knight(dr, ox, bob=bob, swing=swing, dead=dead)


def sb(dr, ox, bob=0, swing=0, cast=0, dead=0):
    slime(dr, ox, squash=bob, thrust=[0, 3, 6][swing], dead=dead)


def sm(dr, ox, bob=0, swing=0, cast=0, dead=0):
    slime(dr, ox, squash=bob, dead=dead, w=16, h=16, mini=True)


make_unit("knight", 32, 32, kn, troop=True)
make_unit("slime_big", 32, 32, sb, troop=True)
make_unit("slime_mini", 16, 16, sm, troop=True)
make_unit("general_slime", 48, 48, lambda dr, ox, **k: general(dr, ox, True, **k))
make_unit("general_knight", 48, 48, lambda dr, ox, **k: general(dr, ox, False, **k))
print("placeholder sprites written to", os.path.abspath(OUT))
