#!/usr/bin/env python3
"""Turns an AI-generated character image into a game sprite frame.

    python3 tools/ai_to_sprite.py SRC OUT.png [--scale S] [--frame 48] [--foot 24,46]

- Removes a solid or fake-checkerboard background (grey, low-saturation pixels
  connected to the image border) and keeps the largest shape.
- Shrinks with area averaging, adds a 1px dark outline, and places the result
  in a frame with the feet at --foot.
- --scale: output px per source px. The first image prints the scale it used
  (fits the character to 44px tall); pass that SAME scale for every later frame
  of the same character so all frames stay the same size.
Result is a starting point: clean up in Aseprite (gold trim, face, palette).
"""
import argparse
import numpy as np
from PIL import Image, ImageEnhance
from scipy import ndimage as nd

ap = argparse.ArgumentParser()
ap.add_argument("src"); ap.add_argument("out")
ap.add_argument("--scale", type=float, default=0.0)
ap.add_argument("--frame", type=int, default=48)
ap.add_argument("--foot", default="24,46")
ap.add_argument("--height", type=int, default=44)
o = ap.parse_args()
FX, FY = (int(v) for v in o.foot.split(","))

a = np.asarray(Image.open(o.src).convert("RGB")).astype(int)
mx, sat = a.max(2), a.max(2) - a.min(2)
lab, _ = nd.label((sat < 22) & (mx > 100))
edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
fg = nd.binary_opening(~np.isin(lab, list(edge)), iterations=2)
lab2, n2 = nd.label(fg)
fg = nd.binary_fill_holes(lab2 == np.argmax(nd.sum(fg, lab2, range(1, n2 + 1))) + 1)
fg &= ~((sat < 40) & (mx > 150))  # leftover grey halo
ys, xs = np.where(fg)
rgba = np.dstack([a, fg * 255]).astype(np.uint8)[ys.min():ys.max() + 1, xs.min():xs.max() + 1]

s = o.scale or o.height / rgba.shape[0]
print("scale", round(s, 6))
w, h = max(1, round(rgba.shape[1] * s)), max(1, round(rgba.shape[0] * s))
p = rgba.astype(float); al = p[..., 3:] / 255
pm = np.dstack([p[..., :3] * al, al * 255]).astype(np.uint8)
sm = np.asarray(Image.fromarray(pm).resize((w, h), Image.BOX)).astype(float)
A = sm[..., 3]
rgb = np.clip(sm[..., :3] / np.maximum(A[..., None] / 255, 1e-3), 0, 255).astype(np.uint8)
mask = np.pad(A > 110, 1)
rgb = np.pad(rgb, ((1, 1), (1, 1), (0, 0)))
rgb = np.asarray(ImageEnhance.Contrast(ImageEnhance.Color(Image.fromarray(rgb)).enhance(1.25)).enhance(1.15))
out = np.dstack([rgb, mask * 255]).astype(np.uint8)
out[nd.binary_dilation(mask) & ~mask] = [24, 18, 30, 255]

# feet = midpoint of the left/right extremes of the leftmost shapes on the bottom rows
bottom = mask[-3:].any(0)
blab, bn = nd.label(bottom)
spans = [np.where(blab == i)[0] for i in range(1, bn + 1)]
feet = spans if len(spans) < 2 else spans[:2]
foot_x = (feet[0].min() + feet[-1].max()) // 2
spr = Image.fromarray(out)
F = Image.new("RGBA", (o.frame, o.frame))
F.alpha_composite(spr, (max(0, FX - foot_x), max(0, FY + 1 - spr.height)))
F.save(o.out)
print("sprite", spr.size, "feet at x", foot_x, "->", o.out)
