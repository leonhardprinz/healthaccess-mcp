#!/usr/bin/env python3
"""App Store screenshots: brand ground, caption in IBM Plex Sans Condensed, the app screen below.
Input: raw 1206x2622 simulator captures (synthetic data). Output: appstore/screenshots/*.png at 1320x2868 (iPhone 6.9")."""
import sys, os
from PIL import Image, ImageDraw, ImageFont
RAW = sys.argv[1] if len(sys.argv) > 1 else '.'
OUT = os.path.join(os.path.dirname(__file__), '..', 'appstore', 'screenshots')
FONTS = os.path.join(os.path.dirname(__file__), '..', 'app', 'HealthAccess', 'Resources', 'Fonts')
W, H = 1320, 2868
GROUND, INK, SUB = (13, 54, 107), (255, 255, 255), (205, 226, 251)
SHOTS = [
    ('01-export', 'raw-export.png', 'Your Watch data, as files\nyour AI can read', 'Workouts, sleep and heart rate, in a folder you own.'),
    ('02-import', 'raw-import.png', 'Workout plans from your AI,\nonto your Watch', 'Your AI writes it. One tap puts it on your Watch.'),
    ('03-plans', 'raw-plans.png', 'On your wrist at the time\nthe plan says', 'Step names on the Watch, or Automatic with no tap.'),
    ('04-prompts', 'raw-prompts.png', 'Ideas for your AI,\nfor any sport', 'Eleven prompts, from check-ins to training weeks.'),
    ('05-privacy', 'raw-privacy.png', 'No account. No server.\nYour folder.', 'Usage statistics off by default, never health data.'),
]
bold = ImageFont.truetype(os.path.join(FONTS, 'IBMPlexSansCondensed-Bold.ttf'), 96)
semi = ImageFont.truetype(os.path.join(FONTS, 'IBMPlexSansCondensed-SemiBold.ttf'), 50)

def wrap(draw, text, font, width):
    if '\n' in text: return text.split('\n')
    words, lines, line = text.split(), [], ''
    for w in words:
        t = (line + ' ' + w).strip()
        if draw.textlength(t, font=font) <= width: line = t
        else: lines.append(line); line = w
    lines.append(line); return lines

os.makedirs(OUT, exist_ok=True)
for name, raw, head, sub in SHOTS:
    img = Image.new('RGB', (W, H), GROUND); d = ImageDraw.Draw(img)
    y = 150
    for line in wrap(d, head, bold, W - 180):
        d.text((W / 2, y), line, font=bold, fill=INK, anchor='ma'); y += 110
    y += 30
    for line in wrap(d, sub, semi, W - 220):
        d.text((W / 2, y), line, font=semi, fill=SUB, anchor='ma'); y += 64
    shot = Image.open(os.path.join(RAW, raw)).convert('RGB')
    sw = 1000; sh = round(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    top = max(y + 70, H - sh - 60)
    mask = Image.new('L', (sw, sh), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, sw - 1, sh - 1), radius=118, fill=255)
    frame = Image.new('RGB', (sw + 16, sh + 16), (40, 84, 140))
    fmask = Image.new('L', frame.size, 0); ImageDraw.Draw(fmask).rounded_rectangle((0, 0, sw + 15, sh + 15), radius=126, fill=255)
    x = (W - sw) // 2
    img.paste(frame, (x - 8, top - 8), fmask); img.paste(shot, (x, top), mask)
    img.save(os.path.join(OUT, name + '.png'), optimize=True)
    print(name, img.size, 'caption ends', y, 'screen top', top, 'screen bottom', top + sh)
