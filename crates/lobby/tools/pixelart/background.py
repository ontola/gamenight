"""Paint the lobby as one big background image, rather than tiling it.

Tiles were the wrong idea twice over. `create-image-pixen` cannot draw a
seamless one, and even a correct tileset would build the room out of repeating
32px squares — which is not what a cosy living room looks like. A room with a
sofa in a particular corner and a lamp beside it is a *scene*, and the map
format already supports scenes: `gamenight_lobby.map.yaml` has parallax
background layers with their own sizes.

So the furniture that nobody interacts with belongs *in* the background, and
only the things the game has to drive — the jukebox face, the next-game screen,
the join QR, the floor pads — stay as sprites on top.

`/generate-image-v2` is async and takes a `style_image`, so the room can be
anchored to props we have already accepted rather than drifting into its own
look.
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
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging"

# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.
from generate import load_dotenv  # noqa: E402

load_dotenv()

import pixellab  # noqa: E402
from PIL import Image  # noqa: E402

# 16:9 is the largest landscape the endpoint will draw in one piece. Above a
# 170px maximum dimension it returns a single image rather than a grid, which is
# what we want — one room, not four variations stitched together.
SIZE = (640, 384)   # 5:3, matching the map's 40x24 tiles

# Deliberately an EMPTY room. Every piece of furniture is a platform now,
# generated at its own footprint and placed by the map — so anything painted
# here would be scenery at the wrong scale that players cannot stand on, which
# is exactly what went wrong when the sofa ended up several times too big.
# What is left is the shell: walls, skirting, window, lights, ambience.
ROOM = (
    "an empty cosy living room interior seen straight on as a flat 2D "
    "platformer backdrop, completely unfurnished, no sofa, no shelves, no "
    "tables, no lamps, bare walls only: deep teal patterned wallpaper meeting "
    "dark red brick, a wooden skirting board along the bottom, a large window "
    "on the right with curtains and a night city skyline beyond, a string of "
    "warm fairy lights hanging across the top of the wall, soft amber light "
    "spilling from off screen, warm saturated palette, deep browns and dark "
    "teal shadows, chunky readable pixel art, strictly flat front elevation, "
    "no perspective, no isometric angle, no furniture"
)


def _poll(job_id: str, timeout_s: int = 900) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        req = urllib.request.Request(
            pixellab.API + f"/background-jobs/{job_id}",
            method="GET",
            headers={"Authorization": f"Bearer {pixellab._secret()}",
                     "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                payload = json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (423, 404):
                time.sleep(6)
                continue
            raise
        status = (payload.get("status") or "").lower()
        if status in ("completed", "succeeded", "success", "done"):
            return payload
        if status in ("failed", "error"):
            raise SystemExit(f"job failed: {json.dumps(payload)[:600]}")
        print(f"    {status or 'processing'}…")
        time.sleep(8)
    raise SystemExit(f"timed out waiting for {job_id}")


def _images(payload: dict) -> list[Image.Image]:
    """Dig the PNGs out of whatever shape the job response takes."""
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


def generate(name: str, description: str, style: Path | None) -> Path:
    body: dict = {"description": description,
                  "image_size": {"width": SIZE[0], "height": SIZE[1]}}
    if style and style.exists():
        # The field wraps the encoded PNG one level deeper than the sprite
        # endpoints do: {"image": {...}}, not the encoded object directly.
        style_img = Image.open(style).convert("RGBA")
        body["style_image"] = {
            "image": pixellab._encode_png(style_img),
            "size": {"width": style_img.width, "height": style_img.height},
        }
        print(f"  style anchored to {style.name}")

    job = pixellab._request("POST", "/generate-image-v2", body, timeout=180)
    job_id = job.get("background_job_id") or job.get("id")
    if not job_id:
        raise SystemExit(f"no job id: {list(job)}")
    print(f"  job {job_id} queued…")

    payload = _poll(job_id)
    imgs = _images(payload)
    if not imgs:
        dump = STAGING / f"{name}.job.json"
        dump.write_text(json.dumps(payload, indent=2)[:40000])
        raise SystemExit(f"no images in response (dumped to {dump})")

    STAGING.mkdir(parents=True, exist_ok=True)
    out = STAGING / f"{name}.png"
    imgs[0].convert("RGB").save(out)
    for n, extra in enumerate(imgs[1:], start=2):
        extra.convert("RGB").save(STAGING / f"{name}_alt{n}.png")
    print(f"  {len(imgs)} image(s) -> {out}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="room_bg")
    ap.add_argument("--style", default="tv_cabinet",
                    help="staging sprite to anchor the style to, or 'none'")
    args = ap.parse_args()
    style = None if args.style == "none" else STAGING / f"{args.style}.png"
    print(f"background {SIZE[0]}x{SIZE[1]}")
    generate(args.name, ROOM, style)


if __name__ == "__main__":
    main()
