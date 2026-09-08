"""Build the room as parallax layers: a city behind, a wall with holes in front.

The room stops being one flat picture. The wall is the near layer and its
windows are *cut out*; a night skyline sits far behind it and drifts as players
move, which is what makes a room feel like it has an outside.

Scale is the other half of this. The previous background was drawn as a single
"photo of a room" and then stretched to fill a 1280x768 map, which is how the
window ended up twenty metres tall. Here the wall is described as a tall
multi-storey space with *several* modest windows, so after the stretch each one
lands around two or three tiles — two or three metres, at 1 tile = 1m.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import sys
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path

import yaml
from PIL import Image

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging"
ASSETS = HERE.parents[1] / "assets"
RES = ASSETS / "map" / "resources"

# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.
from generate import load_dotenv  # noqa: E402

load_dotenv()

import pixellab  # noqa: E402
import layout  # noqa: E402

SIZE = (640, 384)

CITY = (
    "a night city skyline seen from a high window, distant tower blocks with "
    "hundreds of tiny lit windows, radio masts, a low moon and thin clouds, "
    "deep blue and indigo, small warm amber window lights, no foreground, "
    "no interior, flat 2D pixel art, straight on, no perspective"
)

ROOM = (
    "the interior back wall of a tall spacious multi storey games den, seen "
    "straight on and completely unfurnished, deep teal patterned wallpaper "
    "above a dark red brick lower wall, a wooden skirting board along the "
    "bottom, SIX evenly spaced tall narrow arched windows set at three "
    "different heights across the wall, each window filled with a flat "
    "uniform solid bright magenta panel and framed in dark wood with tied back "
    "curtains, strings of warm fairy lights hanging between the windows, warm "
    "amber wall lamps, deep browns and dark teal shadows, chunky readable "
    "pixel art, strictly flat front elevation, no perspective, no furniture"
)


def _poll(job_id: str, timeout_s: int = 900) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        req = urllib.request.Request(
            pixellab.API + f"/background-jobs/{job_id}", method="GET",
            headers={"Authorization": f"Bearer {pixellab._secret()}",
                     "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                payload = json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (423, 404):
                time.sleep(6)
                continue
            raise
        status = (payload.get("status") or "").lower()
        if status in ("completed", "succeeded", "success", "done"):
            return payload
        if status in ("failed", "error"):
            raise SystemExit(f"job failed: {json.dumps(payload)[:400]}")
        time.sleep(8)
    raise SystemExit("timed out")


def _images(payload: dict) -> list[Image.Image]:
    found: list[Image.Image] = []

    def walk(node) -> None:
        if isinstance(node, dict):
            b64 = node.get("base64")
            if isinstance(b64, str) and len(b64) > 512:
                found.append(Image.open(io.BytesIO(
                    base64.b64decode(b64.split(",", 1)[-1]))).convert("RGBA"))
                return
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(payload.get("last_response") or payload)
    return found


def generate(name: str, description: str) -> Image.Image:
    dest = STAGING / f"{name}.png"
    if dest.exists():
        print(f"  cached  {name}")
        return Image.open(dest).convert("RGBA")
    job = pixellab._request("POST", "/generate-image-v2", {
        "description": description,
        "image_size": {"width": SIZE[0], "height": SIZE[1]},
    }, timeout=180)
    job_id = job.get("background_job_id") or job.get("id")
    print(f"  {name}: job {job_id}…")
    imgs = _images(_poll(job_id))
    if not imgs:
        raise SystemExit(f"no image for {name}")
    imgs[0].save(dest)
    print(f"  drew    {name} -> {dest}")
    return imgs[0].convert("RGBA")


def cut_windows(room: Image.Image, tol: int = 90) -> tuple[Image.Image, int]:
    """Fill the wall but leave the window openings see-through.

    Two attempts failed before this one, and both failed for the same reason —
    trying to identify the windows by *colour*. Keying black also keyed the
    curtains' own shadows and punched holes through the fabric; asking for a
    magenta chroma was simply ignored, and the model returned windows that were
    already transparent. But so was most of the wall, so nothing could tell them
    apart by pixel value.

    Topology can. The transparency that *is* the wall reaches the edge of the
    image; the transparency inside a window is enclosed by its own frame. So
    flood fill the gaps inward from the border: everything reached is wall and
    gets painted, and every transparent island left behind is a window.
    """
    src = room.convert("RGBA")
    w, h = src.size
    alpha = src.getchannel("A").load()

    outside = [[False] * w for _ in range(h)]
    stack = [(x, y) for x in range(w) for y in (0, h - 1) if alpha[x, y] == 0]
    stack += [(x, y) for y in range(h) for x in (0, w - 1) if alpha[x, y] == 0]
    for x, y in stack:
        outside[y][x] = True
    while stack:
        x, y = stack.pop()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not outside[ny][nx] \
                    and alpha[nx, ny] == 0:
                outside[ny][nx] = True
                stack.append((nx, ny))

    px = Image.new("RGBA", src.size, (0, 0, 0, 0))
    px.alpha_composite(src)
    out = px.load()
    wall = _wall_colour(room)
    filled = kept = 0
    for y in range(h):
        for x in range(w):
            if out[x, y][3] == 0:
                if outside[y][x]:
                    out[x, y] = wall            # wall the model never drew
                    filled += 1
                else:
                    kept += 1                   # a window, left see-through
    print(f"  wall filled {filled} px, windows kept {kept} px "
          f"({100 * kept / (w * h):.1f}% see-through)")
    return px, kept


def _wall_colour(room: Image.Image) -> tuple[int, int, int, int]:
    """The most common solid colour in the wall, for filling the gaps."""
    tally = Counter()
    px = room.convert("RGBA").load()
    w, h = room.size
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b, a = px[x, y]
            if a > 200 and r + g + b > 90:
                tally[(r // 8 * 8, g // 8 * 8, b // 8 * 8)] += 1
    if not tally:
        return (48, 32, 40, 255)
    r, g, b = tally.most_common(1)[0][0]
    return (r, g, b, 255)


def write_map(city: str, room: str) -> None:
    doc = yaml.safe_load(layout.MAP.read_text())
    doc["background"]["speed"] = [0.12, 0.05]
    doc["background"]["layers"] = [
        # Far: the city drifts most. Scale >1 so it covers as it moves.
        {"image": f"/map/resources/{city}", "size": list(SIZE),
         "depth": 6.0, "scale": 2.4, "offset": [0.0, 0.0]},
        # Near: the wall itself, effectively locked to the room.
        {"image": f"/map/resources/{room}", "size": list(SIZE),
         "depth": 1.0, "scale": 2.0, "offset": [0.0, 0.0]},
    ]
    layout.MAP.write_text(yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))
    print(f"  map background -> 2 parallax layers")


def preview(city: Image.Image, room: Image.Image) -> Path:
    """Three camera positions, to show the city sliding behind the windows."""
    W, H = layout.GRID_W * layout.TILE, layout.GRID_H * layout.TILE
    shots = []
    for n, shift in enumerate((0, 120, 240)):
        frame = Image.new("RGBA", (W, H), (18, 16, 26, 255))
        c = city.resize((int(W * 1.4), H), Image.NEAREST)
        frame.alpha_composite(c, (-shift, 0))
        frame.alpha_composite(room.resize((W, H), Image.NEAREST),
                              (-int(shift * 0.15), 0))
        shots.append(frame)
    out = Image.new("RGB", (W, H * len(shots)), (12, 10, 16))
    for n, s in enumerate(shots):
        out.paste(s.convert("RGB"), (0, n * H))
    path = STAGING / "parallax_preview.png"
    out.save(path)
    print(f"  preview -> {path}")
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    print("parallax layers:")
    city = generate("bg_city", CITY)
    room_raw = generate("bg_room", ROOM)
    room, cut = cut_windows(room_raw)
    room.save(STAGING / "bg_room_cut.png")
    if args.write:
        city.convert("RGB").save(RES / "bg_city.png")
        room.save(RES / "bg_room.png")
        write_map("bg_city.png", "bg_room.png")
    preview(city, room)


if __name__ == "__main__":
    main()
