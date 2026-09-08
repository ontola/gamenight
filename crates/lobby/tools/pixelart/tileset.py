"""Generate the room's terrain with PixelLab's sidescroller tileset endpoint.

`generate.py` asks `create-image-pixen` for one sprite at a time, which is right
for furniture and wrong for ground: prompting it for a "seamless floor tile"
produced isometric slabs floating on transparency that did not tile at all, and
a wallpaper tile that came back with a face in it.

`/create-tileset-sidescroller` is the endpoint that actually models this. It
returns a wang set — tiles that know which of their edges are solid — which is
the same idea as the Left/Mid/Right/Center roles `tools/reskin/tile_roles.py`
infers from the maps, so the output drops onto our grid.

It is async: POST returns a job, then the GET answers 423 with `Retry-After`
until the set is ready.
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
OUT = HERE / "staging" / "tilesets"

# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.
from generate import load_dotenv  # noqa: E402  (also pulls in the .env key)

load_dotenv()

import pixellab  # noqa: E402
from PIL import Image  # noqa: E402


def _get_tolerating_423(path: str) -> tuple[int, dict]:
    """GET that treats 423 as "not ready yet" rather than an error.

    `pixellab._request` raises on any non-2xx, which would turn the normal
    still-generating response into a crash.
    """
    req = urllib.request.Request(
        pixellab.API + path,
        method="GET",
        headers={
            "Authorization": f"Bearer {pixellab._secret()}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code in (423, 404):
            return e.code, {"retry_after": int(e.headers.get("Retry-After") or 5)}
        raise


def create(lower: str, transition: str | None, size: int, name: str,
           timeout_s: int = 900) -> Path:
    body: dict = {
        "lower_description": lower,
        "tile_size": {"width": size, "height": size},
        "outline": "single color black outline",
        "shading": "medium shading",
        "detail": "medium detail",
    }
    if transition:
        body["transition_description"] = transition

    job = pixellab._request("POST", "/create-tileset-sidescroller", body, timeout=180)
    tileset_id = job.get("tileset_id") or job.get("id")
    if not tileset_id:
        raise SystemExit(f"no tileset id in response: {list(job)}")
    print(f"  job {tileset_id} queued, waiting…")

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        # Poll /tilesets/{id}, not /tilesets-sidescroller/{id} — the latter
        # 404s for a sidescroller job that is still generating, while the
        # former correctly answers 423 with an ETA.
        status, payload = _get_tolerating_423(f"/tilesets/{tileset_id}")
        if status == 200:
            return save(payload, name, tileset_id)
        print(f"    {status}, retrying in {payload.get('retry_after', 5)}s")
        time.sleep(min(10, max(2, payload.get("retry_after", 5))))
    raise SystemExit(f"timed out after {timeout_s}s waiting for {tileset_id}")


def save(payload: dict, name: str, tileset_id: str) -> Path:
    dest = OUT / name
    dest.mkdir(parents=True, exist_ok=True)
    tiles = payload.get("tiles") or []
    if not tiles:
        (dest / "raw.json").write_text(json.dumps(payload, indent=2)[:20000])
        raise SystemExit(f"no tiles in payload; keys were {list(payload)} "
                         f"(dumped to {dest/'raw.json'})")

    saved = []
    for n, tile in enumerate(tiles):
        b64 = (tile.get("image") or {}).get("base64") if isinstance(tile.get("image"), dict) \
            else tile.get("image")
        if not b64:
            continue
        img = Image.open(io.BytesIO(base64.b64decode(b64.split(",", 1)[-1]))).convert("RGBA")
        label = (tile.get("name") or tile.get("description") or f"tile_{n:02d}")
        label = "".join(c if c.isalnum() or c in "-_" else "_" for c in label)[:40]
        path = dest / f"{n:02d}_{label}.png"
        img.save(path)
        saved.append((path, tile.get("corners")))

    # Keep the corner metadata: it says which edges of each tile are solid,
    # which is what decides where a tile may be placed.
    (dest / "tiles.json").write_text(json.dumps(
        [{"file": p.name, "corners": c} for p, c in saved], indent=2))
    print(f"  saved {len(saved)} tiles -> {dest}")
    sheet(dest)
    return dest


def sheet(dest: Path) -> Path:
    pngs = sorted(p for p in dest.glob("*.png") if p.name != "sheet.png")
    if not pngs:
        return dest
    imgs = [Image.open(p).convert("RGBA") for p in pngs]
    S, cols = 4, 8
    cw = max(i.width for i in imgs) * S + 8
    ch = max(i.height for i in imgs) * S + 8
    rows = (len(imgs) + cols - 1) // cols
    out = Image.new("RGBA", (cols * cw, rows * ch), (28, 24, 34, 255))
    for n, im in enumerate(imgs):
        out.alpha_composite(im.resize((im.width * S, im.height * S), Image.NEAREST),
                            ((n % cols) * cw + 4, (n // cols) * ch + 4))
    path = dest / "sheet.png"
    out.save(path)
    print(f"  sheet -> {path}")
    return path


SETS = {
    "floor": dict(
        lower="warm walnut wooden floorboards of a cosy living room, "
              "rich brown planks with visible grain and a darker skirting edge",
        transition="a worn patterned carpet runner in deep red and purple"),
    "wall": dict(
        lower="dark red brick interior wall of a cosy den, warm mortar, "
              "a few bricks slightly lighter",
        transition="deep teal patterned wallpaper with a subtle repeating motif"),
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("set", choices=[*SETS, "all"])
    ap.add_argument("--size", type=int, default=32, choices=[16, 32])
    args = ap.parse_args()
    names = list(SETS) if args.set == "all" else [args.set]
    for name in names:
        print(f"tileset: {name}")
        create(SETS[name]["lower"], SETS[name]["transition"], args.size, name)


if __name__ == "__main__":
    main()
