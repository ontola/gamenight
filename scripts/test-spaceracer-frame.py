"""Capture and inspect a real frame from the packaged SpaceRacer executable."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import zlib


def png_pixels(path):
    data = path.read_bytes()
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        raise ValueError('Capture is not a PNG')
    width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', data[16:29])
    if width < 640 or height < 360 or depth != 8 or color not in (2, 6) or compression or filtering or interlace:
        raise ValueError('Capture has unexpected dimensions or pixel format')
    chunks = []
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset+4])[0]
        kind = data[offset+4:offset+8]
        if offset + length + 12 > len(data):
            raise ValueError('Truncated PNG chunk')
        if kind == b'IDAT':
            chunks.append(data[offset+8:offset+8+length])
        offset += length + 12
        if kind == b'IEND':
            break
    raw = zlib.decompress(b''.join(chunks))
    stride = width * (3 if color == 2 else 4) + 1
    if len(raw) != stride * height:
        raise ValueError('Capture has incomplete pixel rows')
    # PNG filter residuals still retain colour/texture variation. A blank
    # frame compresses to a tiny file with very few distinct residual bytes.
    if len(data) < 100_000 or len(set(raw)) < 100:
        raise ValueError('Capture appears blank')
    return width, height


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    args = parser.parse_args()
    if args.capture.exists():
        parser.error('Capture path already exists; refusing stale frame evidence')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('GAMENIGHT', 'SPACERACER_PROBE'))}
    command = [str(args.godot.resolve()), '--position', '-20000,-20000',
               '--audio-driver', 'Dummy', '--', '--demo',
               '--capture=' + str(args.capture.resolve()), '--capture-frame=120']
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stdout)
    match = re.search(r'SPACERACER_RENDER (\{[^\n]+\})', result.stdout)
    if not match:
        raise RuntimeError('Godot did not report a captured frame: ' + result.stdout)
    render = json.loads(match.group(1))
    width, height = png_pixels(args.capture)
    if render.get('views', 0) < 1 or render.get('frames', 0) < 60 or render.get('draw_calls', 0) < 100:
        raise RuntimeError('Renderer did not draw gameplay: ' + json.dumps(render))
    print(f'PASS captured {width}x{height} gameplay frame with {render["draw_calls"]} draw calls')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'FAIL {exc}', file=sys.stderr)
        sys.exit(1)
