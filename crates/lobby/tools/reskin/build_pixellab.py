"""Map the reviewed PixelLab character and TV into lobby runtime assets.

Run with Python + Pillow. Source exports remain untouched in docs/art.
All poses share one scale and a common foot baseline; missing action poses use
explicit stand/stretch/crouch fallbacks until a full animation set is authored.
Faces remain separate so the character studio can replace them.
"""
from pathlib import Path
import colorsys
import re
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / 'docs/art/pixellab-benchmark'
ASSETS = ROOT / 'crates/lobby/assets'
SCALE = 54 / 71
SKINS = {'fishy': 0, 'pescy': .48, 'sharky': .18, 'orcy': -.23}


def source(name):
    return Image.open(SOURCE / (name + '.png')).convert('RGBA')


def pose(name, hue, center=None):
    im = source(name)
    bbox = im.getbbox()
    # Cream pixels bound the face. Fill only between its edges, preserving hood
    # and chin shading. This removes the baked eyes from every animation pose.
    px = im.load()
    for y in range(30, 59):
        xs = [x for x in range(16, 75) if (lambda p: p[3] > 200 and p[0] > 210 and p[1] > 180 and p[2] < p[1])(px[x, y])]
        if len(xs) >= 7:
            for x in range(min(xs), max(xs) + 1):
                px[x, y] = (245, 233, 190, 255)
    # Distinct outfit colours retain the same animation and silhouette.
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a and g > r * 1.15 and g > b * 1.08:
                h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
                rgb = colorsys.hsv_to_rgb((h + hue) % 1, s, v)
                px[x, y] = tuple(round(c * 255) for c in rgb) + (a,)
    # Align the artist's drifting walk frame to the standing body centre.
    if center is None:
        center = 47 if name == 'walk-1' else 42
    scaled = im.resize((round(96 * SCALE), round(96 * SCALE)), Image.Resampling.NEAREST)
    cell = Image.new('RGBA', (96, 80))
    cell.alpha_composite(scaled, (round(48 - center * SCALE), round(64 - bbox[3] * SCALE)))
    return cell


def build():
    for skin, hue in SKINS.items():
        folder = ASSETS / 'player/skins' / skin
        sheet = Image.new('RGBA', (96 * 14, 80 * 7))
        stand = pose('character-1', hue)
        frames = {i: stand for i in range(98)}
        for i in range(4):
            frames[14 + i] = pose(f'walk-{i}', hue)
            frames[20 + i] = pose(f'sleep-{i}', hue)
            frames[24 + i] = pose(f'wake-{i}', hue)
        frames[28] = pose('wake-2', hue)
        frames[42] = pose('walk-2', hue)
        frames[56] = frames[58] = pose('sleep-3', hue)
        for start, direction in ((70, 1), (84, -1)):
            for i in range(7):
                frames[start + i] = stand.rotate(direction * i * 15, Image.Resampling.NEAREST, center=(48, 53))
        for idx, frame in frames.items():
            sheet.alpha_composite(frame, (idx % 14 * 96, idx // 14 * 80))
        sheet.save(folder / f'{skin}-body.png')
        face = Image.new('RGBA', (46 * 11, 32 * 8))
        for variant in range(8):
            for col in range(11):
                draw = ImageDraw.Draw(face)
                cx, cy = col * 46 + 23, variant * 32 + 16
                for dx in (-4, 4):
                    height = 1 if col in (4, 5) else 4
                    draw.rectangle((cx + dx, cy - 3, cx + dx + 1, cy - 4 + height), fill=(42, 30, 32, 255))
        face.save(folder / f'{skin}-face.png')
        yaml = folder / f'{skin}.player.yaml'
        text = yaml.read_text()
        body, rest = text.split('  fin:', 1)
        body = re.sub(r'      walk:\n.*?(?=      crouch:)', '      walk:\n        frames: [{idx: 14}, {idx: 15}, {idx: 16}, {idx: 17}]\n        fps: 9\n        repeat: true\n', body, flags=re.S)
        rest = re.sub(r'(  face:\n    atlas:.*?\n    offset:) \[[^\]]+\]', r'\1 [5, 5]', rest)
        yaml.write_text(body + '  fin:' + rest)
        assert sheet.size == (1344, 560)
        assert all(sheet.crop((i % 14 * 96, i // 14 * 80, i % 14 * 96 + 96, i // 14 * 80 + 80)).getbbox() for i in frames)
    tv = source('tv-1')
    tv = tv.crop(tv.getbbox())
    dest = ASSETS / 'elements/environment/next_game/pixellab-tv.png'
    tv.save(dest)
    print('Mapped four player skins, four-frame walk cycles, action fallbacks, separate faces and TV.')

if __name__ == '__main__':
    build()
