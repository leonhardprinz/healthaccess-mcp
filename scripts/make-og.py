#!/usr/bin/env python3
"""Draws site/og.png (1200x630): the mark, the wordmark and headline in IBM Plex Sans Condensed,
and the Export tab screenshot (site/img/app-export.jpg, synthetic data). Run after new screenshots."""
import pathlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONTS = ROOT / "app/HealthAccess/Resources/Fonts"
BLUE = (13, 54, 107)
W, H = 1200, 630
img = Image.new("RGB", (W, H), BLUE)
d = ImageDraw.Draw(img)

def font(name, size): return ImageFont.truetype(str(FONTS / name), size)
bold = lambda s: font("IBMPlexSansCondensed-Bold.ttf", s)
semi = lambda s: font("IBMPlexSansCondensed-SemiBold.ttf", s)

# the mark, same path as app/scripts/make_icon.py, on a 64 grid
def mark(x, y, size, width, color):
    s = size / 64
    p = lambda a, b: (x + a * s, y + b * s)
    beat = [p(6, 34), p(20, 34), p(26, 20), p(34, 48), p(40, 34), p(52, 34)]
    arrow = [p(46, 26), p(56, 34), p(46, 42)]
    for line in (beat, arrow):
        d.line(line, fill=color, width=width, joint="curve")
        for pt in (line[0], line[-1]):
            r = width / 2
            d.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r], fill=color)

mark(64, 62, 72, 7, "white")
d.text((150, 76), "Health Access", font=semi(34), fill="white")
w = d.textlength("Health Access", font=semi(34))
d.text((150 + w + 10, 90), "MCP", font=semi(18), fill=(107, 164, 234))

d.text((64, 200), "Your Apple Health", font=bold(68), fill="white")
d.text((64, 272), "data, for your AI.", font=bold(68), fill="white")
d.text((64, 380), "Workouts and daily data as files you own.", font=semi(28), fill=(200, 214, 232))
d.text((64, 418), "AI-written plans back to your Apple Watch.", font=semi(28), fill=(200, 214, 232))
d.text((64, 548), "healthaccessmcp.com  ·  npx -y healthaccess-mcp", font=semi(24), fill=(150, 175, 210))

# phone screenshot, cropped to the top, rounded, with a soft shadow
shot = Image.open(ROOT / "site/img/app-export.jpg").convert("RGB")
sw = 300
shot = shot.resize((sw, int(shot.height * sw / shot.width)))
shot = shot.crop((0, 0, sw, 560))
mask = Image.new("L", shot.size, 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, shot.width - 1, shot.height + 40], radius=34, fill=255)
x, y = 840, 70
shadow = Image.new("L", (W, H), 0)
ImageDraw.Draw(shadow).rounded_rectangle([x + 6, y + 14, x + sw + 6, H + 40], radius=34, fill=120)
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.paste(Image.new("RGB", (W, H), (5, 25, 55)), (0, 0), shadow)
img.paste(shot, (x, y), mask)
img.save(ROOT / "site/og.png", optimize=True)
print("site/og.png", img.size)
