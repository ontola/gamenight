"""Generate the lobby's room art with PixelLab, one reviewable batch at a time.

Writes to `staging/`, never straight into `assets/`. Generated art needs looking
at before it ships, and a bad batch should cost nothing but a rerun.

Every generation costs credits, so results are cached by name+size+prompt hash:
rerunning is free unless something actually changed. `--force` overrides that
for the one asset you are iterating on.

    export PIXELLAB_API_KEY=...          # never commit this
    python3 generate.py --batch interactive
    python3 generate.py --only jukebox --force --seed 7
    python3 generate.py --contact-sheet
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging"
CACHE = STAGING / ".cache.json"

# Reuse the proven client from the Last Draw tooling rather than keeping a
# second copy of it in sync. If these ever need to diverge, promote it to a
# shared location instead of forking it.
# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.


def load_dotenv() -> None:
    """Take the key from the repo-root `.env` if it isn't already exported.

    The client reads `os.environ`, and the key lives in `.env`; without this the
    obvious invocation fails with "not set" while the key is sitting right
    there. Existing environment wins, so an explicit `PIXELLAB_API_KEY=... cmd`
    still overrides the file.
    """
    import os

    env_file = HERE.parents[3] / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        name = name.strip()
        if name and name not in os.environ:
            os.environ[name] = value.strip().strip('"').strip("'")


load_dotenv()

import pixellab  # noqa: E402
import spec  # noqa: E402

from PIL import Image  # noqa: E402


def key_for(item: dict) -> str:
    raw = (f"{item['name']}|{item['w']}x{item['h']}|{item['prompt']}"
           f"|{item.get('direction', 'south')}|{spec.STYLE}")
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def load_cache() -> dict:
    return json.loads(CACHE.read_text()) if CACHE.exists() else {}


def save_cache(cache: dict) -> None:
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(cache, indent=2, sort_keys=True))


def pixen(prompt: str, w: int, h: int, seed: int | None = None,
          direction: str = "south") -> Image.Image:
    """Ask for a W x H sprite and keep it that shape.

    Deliberately not `pixellab.create_pixen`, which finishes by calling
    `fit_cell(im, width)` — that squares the canvas off at width x width and
    plants the art on the bottom edge. Correct for Last Draw's 32x32 fighters,
    wrong for a 172x72 jukebox, which came back centred in a 172x172 square.

    Props here are furniture: they want their declared footprint, and anything
    the model draws smaller gets centred horizontally and stood on the floor
    line rather than scaled up into mush.
    """
    # Two API constraints meet our hitbox contracts here. Sides must be
    # multiples of 4, and no side may be under 32 unless the canvas is square.
    # The floor pads are 56x14 and 64x14 because that is where players land, so
    # the sizes cannot move: ask for the smallest legal canvas at or above the
    # target and bring the result back down afterwards.
    round4 = lambda v: (-(-v // 4)) * 4
    req_w, req_h = max(32, round4(w)), max(32, round4(h))

    payload = {
        "description": prompt,
        "image_size": {"width": req_w, "height": req_h},
        "outline": "single color black outline",
        "detail": "medium detail",
        "view": "side",
        # `direction` is what actually controls flatness. "east" turns the
        # object side-on, which the model happily renders in three-quarter;
        # "south" faces it at the camera and gives the flat front elevation a
        # 2D platformer wants. `view` only offers side / low / high top-down,
        # so there is no "orthographic" switch — this is it.
        "direction": direction,
        "no_background": True,
        "enhance_prompt": True,
    }
    if seed is not None:
        payload["seed"] = seed
    out = pixellab._request("POST", "/create-image-pixen", payload, timeout=240)
    b64 = (out.get("image") or {}).get("base64")
    if not b64:
        raise RuntimeError(f"pixellab returned no image: {list(out)}")
    img = pixellab._decode_png(b64)
    if img.size == (w, h):
        return img

    bbox = img.getbbox() or (0, 0, img.width, img.height)
    art = img.crop(bbox)

    # Fit the width by scaling — a prop that is too wide is just drawn big.
    if art.width > w:
        s = w / art.width
        art = art.resize((w, max(1, int(art.height * s))), Image.NEAREST)

    # Fit the height. Cropping preserves native pixels and is right when the
    # art is merely taller than its slot — but for the floor pads, whose 14px
    # is far under the 32px minimum canvas the API will draw, cropping kept a
    # meaningless band of whatever happened to be at the bottom. There, squash
    # the whole thing: a flat pad survives a vertical resample, and a sliver of
    # someone else's shadow does not.
    if art.height > h:
        if h < 24:
            art = art.resize((art.width, h), Image.NEAREST)
        else:
            art = art.crop((0, art.height - h, art.width, art.height))

    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.alpha_composite(art, ((w - art.width) // 2, h - art.height))
    return canvas


def generate(item: dict, seed: int | None, force: bool, cache: dict) -> Path:
    dest = STAGING / f"{item['name']}.png"
    digest = key_for(item)
    if dest.exists() and cache.get(item["name"]) == digest and not force:
        print(f"  cached  {item['name']:22s} {item['w']}x{item['h']}")
        return dest

    prompt = f"{item['prompt']}, {spec.STYLE}"
    img = pixen(prompt, item["w"], item["h"], seed=seed,
                direction=item.get("direction", "south"))
    dest.parent.mkdir(parents=True, exist_ok=True)
    img.save(dest)
    cache[item["name"]] = digest
    print(f"  drew    {item['name']:22s} {item['w']}x{item['h']}  -> {dest.name}")
    return dest


def contact_sheet() -> Path:
    """One image of everything generated so far, for judging coherence.

    Individual sprites look fine on their own and clash as a set; the only way
    to see that is side by side.
    """
    pngs = sorted(p for p in STAGING.glob("*.png") if p.name != "contact-sheet.png")
    if not pngs:
        raise SystemExit("nothing in staging/ yet")
    imgs = [(p.stem, Image.open(p).convert("RGBA")) for p in pngs]
    pad, cols = 12, 5
    cell_w = max(i.width for _, i in imgs) + pad
    cell_h = max(i.height for _, i in imgs) + pad + 10
    rows = (len(imgs) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (28, 24, 34, 255))
    for n, (name, im) in enumerate(imgs):
        cx, cy = (n % cols) * cell_w, (n // cols) * cell_h
        sheet.alpha_composite(im, (cx + (cell_w - im.width) // 2,
                                   cy + (cell_h - 10 - im.height) // 2))
    out = STAGING / "contact-sheet.png"
    sheet.save(out)
    print(f"contact sheet: {out}  ({len(imgs)} sprites)")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", choices=["interactive", "decor", "tiles", "all"])
    ap.add_argument("--only", help="single asset name from spec.py")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--contact-sheet", action="store_true")
    ap.add_argument("--balance", action="store_true")
    args = ap.parse_args()

    if args.balance:
        print(pixellab.balance())
        return
    if args.contact_sheet and not (args.batch or args.only):
        contact_sheet()
        return

    items = spec.batch(args.batch or "all")
    if args.only:
        items = [i for i in items if i["name"] == args.only]
        if not items:
            raise SystemExit(f"no asset named {args.only!r}")

    print(f"pixellab: {len(items)} asset(s)")
    cache = load_cache()
    try:
        for item in items:
            generate(item, args.seed, args.force, cache)
    finally:
        # Keep whatever succeeded, even if a later call fails or is interrupted.
        save_cache(cache)
    contact_sheet()


if __name__ == "__main__":
    main()
