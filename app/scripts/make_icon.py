#!/usr/bin/env python3
"""Generate the Health Access app icon (1024 px) and the launch mark PNGs with Pillow.

The mark (docs/brand.md, "The mark"): a heartbeat that leaves as an arrow. On a 64 x 64 grid the stroke path is
    M6 34 H20 L26 20 L34 48 L40 34 H52      (the heartbeat)
    M46 26 L56 34 L46 42                    (the arrowhead)
white, round caps and joins, stroke width 4.2 on 64, on #0D366B. The SwiftUI `MarkShape` draws the same path.

Usage: python3 scripts/make_icon.py   (run from app/)
"""
import os
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "HealthAccess", "Resources", "Assets.xcassets")

GROUND = (13, 54, 107)   # #0D366B
INK = (255, 255, 255)
STROKE_ON_64 = 4.2
HEARTBEAT = [(6, 34), (20, 34), (26, 20), (34, 48), (40, 34), (52, 34)]
ARROWHEAD = [(46, 26), (56, 34), (46, 42)]


def draw_polyline(draw, points, scale, offset, width, colour):
    """A stroked polyline with round joins (Pillow's `joint="curve"`) and round caps (a disc on each end)."""
    pts = [(offset + x * scale, offset + y * scale) for x, y in points]
    draw.line(pts, fill=colour, width=width, joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=colour)


def draw_mark(size, with_background=True, supersample=4):
    s = size * supersample
    glyph = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glyph)
    scale = s / 64
    width = max(1, round(STROKE_ON_64 * scale))
    draw_polyline(draw, HEARTBEAT, scale, 0, width, INK + (255,))
    draw_polyline(draw, ARROWHEAD, scale, 0, width, INK + (255,))
    if with_background:
        img = Image.new("RGBA", (s, s), GROUND + (255,))
        img.alpha_composite(glyph)
    else:
        img = glyph
    return img.resize((size, size), Image.LANCZOS)


def main():
    icon = draw_mark(1024, with_background=True).convert("RGB")
    icon.save(os.path.join(ASSETS, "AppIcon.appiconset", "AppIcon.png"), optimize=True)
    for scale in (1, 2, 3):
        mark = draw_mark(160 * scale, with_background=False)
        mark.save(os.path.join(ASSETS, "LaunchMark.imageset", f"LaunchMark@{scale}x.png"), optimize=True)
    print("wrote AppIcon.png and LaunchMark@1x/2x/3x.png")


if __name__ == "__main__":
    sys.exit(main())
