"""Map the reviewed PixelLab character and TV into lobby runtime assets.

Run with Python + Pillow. Source exports remain untouched in docs/art.
All poses share one scale and a common foot baseline; missing action poses use
explicit stand/stretch/crouch fallbacks until a full animation set is authored.
Faces remain separate so the character studio can replace them.
"""
from pathlib import Path
import re
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / 'docs/art/pixellab-benchmark'
ASSETS = ROOT / 'crates/lobby/assets'
SKINS = ('fishy', 'pescy', 'sharky', 'orcy')


def source(name):
    return Image.open(SOURCE / (name + '.png')).convert('RGBA')


def build():
    for skin in SKINS:
        folder = ASSETS / 'player/skins' / skin
        # One hat-free base across all seats. Keep the prepared atlas in native
        # pixels; rebuilding must not restore the old hooded character.
        sheet = Image.open(ROOT / 'docs/art/bald-character/body.png').convert('RGBA')
        mask = Image.new('RGBA', sheet.size)
        for y in range(sheet.height):
            for x in range(sheet.width):
                r, g, b, a = sheet.getpixel((x, y))
                if not a:
                    continue
                if r > 200 and g > 170 and b < g:
                    v = round(r / 245 * 255)
                    mask.putpixel((x, y), (v, v, v, a))
                else:
                    v = min(255, round(max(r, g, b) / 229 * 255))
                    sheet.putpixel((x, y), (v, v, v, a))
        if skin == 'fishy':
            mask.save(ASSETS / 'player/skin-mask.png')
        frames = range(98)
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
