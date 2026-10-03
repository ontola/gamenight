"""Build seven aligned poses from ONE immutable 96x80 pixel drawing.
No frame generation, resampling or palette changes. Pillow is required.
"""
from pathlib import Path
from PIL import Image
import re
ROOT = Path(__file__).resolve().parents[4]
ART = ROOT / 'docs/art/bald-character'
ASSETS = ROOT / 'crates/lobby/assets/player'
SKINS = ('fishy', 'pescy', 'sharky', 'orcy')

def poses():
    stand = Image.open(ART / 'master.png').convert('RGBA')
    assert stand.size == (96, 80)
    upper = stand.copy()
    upper.paste((0, 0, 0, 0), (0, 55, 96, 80))
    left, right = stand.crop((0, 55, 49, 80)), stand.crop((49, 55, 96, 80))
    frames = [stand]
    # The upper body never morphs or shifts during walking.
    for left_x, left_y, right_x, right_y in [(-1, -1, 1, 0), (0, 0, 0, 0), (1, 0, -1, -1), (0, -1, 0, -1)]:
        frame = upper.copy()
        frame.alpha_composite(left, (left_x, 55 + left_y))
        frame.alpha_composite(right, (49 + right_x, 55 + right_y))
        frames.append(frame)
    jump = upper.copy()
    jump.alpha_composite(left, (-1, 52))
    jump.alpha_composite(right, (50, 52))
    frames.append(jump)
    # Seated sleep: same head and torso, lowered eight native pixels.
    sleep = Image.new('RGBA', stand.size)
    sleep.alpha_composite(upper, (0, 8))
    sleep.alpha_composite(left, (-2, 57))
    sleep.alpha_composite(right, (51, 57))
    frames.append(sleep)
    assert all(frame.crop((0, 0, 96, 52)).tobytes() == stand.crop((0, 0, 96, 52)).tobytes() for frame in frames[1:6])
    return frames

def build():
    frames = poses()
    sheet = Image.new('RGBA', (96 * 7, 80))
    for i, frame in enumerate(frames): sheet.alpha_composite(frame, (i * 96, 0))
    sheet.save(ART / 'body.png')
    mask = Image.new('RGBA', sheet.size)
    for y in range(sheet.height):
        for x in range(sheet.width):
            r, g, b, a = sheet.getpixel((x, y))
            if not a: continue
            if r > 200 and g > 170 and b < g:
                v = round(r / 245 * 255)
                mask.putpixel((x, y), (v, v, v, a))
            else:
                v = min(255, round(max(r, g, b) / 229 * 255))
                sheet.putpixel((x, y), (v, v, v, a))
    mask.save(ASSETS / 'skin-mask.png')
    sequences = {'idle':[0], 'walk':[1,2,3,4], 'rise':[5], 'fall':[5], 'sleep':[6], 'wake':[0], 'crouch':[6], 'slide':[6], 'ragdoll':[6], 'ragdoll_twitch':[6], 'death_spine':[6], 'death_belly':[6], 'death_ragdoll':[6]}
    for skin in SKINS:
        folder = ASSETS / 'skins' / skin
        sheet.save(folder / f'{skin}-body.png')
        (folder / f'{skin}-body.atlas.yaml').write_text(f'image: ./{skin}-body.png\ntile_size: [96, 80]\ncolumns: 7\nrows: 1\n')
        path = folder / f'{skin}.player.yaml'
        text = path.read_text()
        start = text.index('    animations: &default_anims')
        end = text.index('  fin:', start)
        body = '    animations: &default_anims\n'
        for i, (name, indexes) in enumerate(sequences.items()):
            body += f'      {name}:\n        frames:\n'
            for frame in indexes:
                body += f'          - idx: {frame}\n            offset: [0, 0]\n'
                if frame == 6: body += '            head_offset: [0, -8]\n'
            body += '        fps: ' + ('&fps 9' if i == 0 else '*fps') + '\n'
            body += '        repeat: ' + ('true' if name in ('idle','walk') else 'false') + '\n'
        path.write_text(text[:start] + body + text[end:])
    print('Seven frames: idle, four steps, jump, seated sleep; upper-body alignment verified.')

if __name__ == '__main__': build()
