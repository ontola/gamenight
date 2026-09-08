"""Generate the level's art from the level's own geometry.

The map is the source of truth. `gamenight_lobby.map.yaml` already says where
every platform is and how wide it is; this asks PixelLab to draw art for exactly
those shapes, so the thing players stand on is the thing they can see.

Two lessons from the earlier attempts are baked in:

*Generate strips, not tiles.* Asking for a "seamless left end cap" one tile at a
time produced three unrelated pictures that did not join. A three-tile platform
is generated as one 96x32 strip and then sliced, so the ends match the middle by
construction.

*Sketch, don't box.* `init_image` is a compositional hint, not a stencil. Fed a
flat rectangle at high strength the model reproduces it and `no_background`
strips the result to nothing; fed a rough drawing with a lip, a body and a
shadow at low strength, it fills in the form. Strength is an integer 0-999
despite the docs saying 0.0-1.0, and useful values are low.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging" / "structure"
ASSETS = HERE.parents[1] / "assets"

# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.
sys.path.insert(0, str(HERE.parents[1] / "tools" / "reskin"))

import generate as gen  # noqa: E402  (loads the .env key)
import spec  # noqa: E402
import pixellab  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402
from tile_roles import infer  # noqa: E402

TILE = 32
STRENGTH = 320          # low: a hint, not a stencil

# The first run ignored "warm walnut" in the prompt and returned grey riveted
# metal, which fought the room. `forced_palette` is documented but rejected by
# this endpoint ("extra inputs are not permitted"), so the colour is anchored
# with a style image instead — the jukebox, which is already the walnut we want.
STYLE_ANCHOR = "jukebox"


def bitforge(description: str, w: int, h: int, init: Image.Image,
             strength: int = STRENGTH, transparent: bool = False) -> Image.Image:
    body = {
        "description": f"{description}, {spec.STYLE}",
        "image_size": {"width": w, "height": h},
        "init_image": pixellab._encode_png(init),
        "init_image_strength": strength,
        "outline": "single color black outline",
        "detail": "medium detail",
        "view": "side",
        "direction": "south",
        # Off for solids. A platform fills its whole cell, so there is no
        # background to remove — and asking for one erases the tile.
        "no_background": transparent,
    }
    # A style_image was the obvious way to force the walnut, but bitforge
    # returns a 500 for every shape of it we tried. The colour therefore has to
    # come from the sketch, which is why STRENGTH is higher here than the value
    # that suited free-standing props.
    req = urllib.request.Request(
        pixellab.API + "/create-image-bitforge",
        data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": f"Bearer {pixellab._secret()}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        out = json.loads(resp.read().decode())
    b64 = (out.get("image") or {}).get("base64")
    if not b64:
        raise SystemExit(f"bitforge returned no image: {list(out)}")
    img = pixellab._decode_png(b64)
    return img if img.size == (w, h) else img.resize((w, h), Image.NEAREST)


# --------------------------------------------------------------------------
# sketches — rough form for the model to build on
# --------------------------------------------------------------------------

WOOD_TOP = (176, 132, 88, 255)
WOOD_BODY = (124, 86, 54, 255)
WOOD_DARK = (74, 48, 32, 255)


def sketch_platform(w: int, h: int = TILE) -> Image.Image:
    """A ledge: bright walkable lip, planked body, shadowed underside.

    Worth drawing properly. At the strength needed to keep the palette warm the
    model largely *reproduces* this rather than reinterpreting it, so flat bands
    in give flat blocks out. Plank seams and grain here come back as plank seams
    and grain, cleaned up.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w - 1, h - 1], fill=WOOD_BODY)
    d.rectangle([0, 0, w - 1, 4], fill=WOOD_TOP)          # walkable lip
    d.line([(0, 5), (w - 1, 5)], fill=WOOD_DARK)          # under the lip
    for y in (12, 19, 25):                                 # grain
        d.line([(0, y), (w - 1, y)], fill=WOOD_DARK)
    for x in range(0, w, 24):                              # plank seams
        d.line([(x, 6), (x, h - 7)], fill=WOOD_DARK)
    d.rectangle([0, h - 5, w - 1, h - 1], fill=WOOD_DARK)  # shadowed underside
    return im


def sketch_fill(w: int = TILE, h: int = TILE) -> Image.Image:
    """Interior: no lip, no light — the inside of a solid, stacked timber."""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, w - 1, h - 1], fill=WOOD_BODY)
    for y in range(0, h, 8):                               # stacked boards
        d.line([(0, y), (w - 1, y)], fill=WOOD_DARK)
    for n, x in enumerate(range(0, w, 16)):                # staggered joints
        off = 4 if n % 2 else 0
        d.line([(x + off, 0), (x + off, h - 1)], fill=WOOD_DARK)
    return im


def sketch_solo(w: int = TILE, h: int = TILE) -> Image.Image:
    im = sketch_platform(w, h)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, 2, h - 1], fill=WOOD_DARK)
    d.rectangle([w - 3, 0, w - 1, h - 1], fill=WOOD_DARK)
    return im


PIECES = {
    "platform_strip": dict(
        size=(96, TILE), sketch=sketch_platform,
        prompt="a sturdy wooden shelf platform seen straight on, warm walnut "
               "planks, a lighter worn strip along the walkable top edge, "
               "darker shadowed underside, the full width of the image"),
    "fill": dict(
        size=(TILE, TILE), sketch=sketch_fill,
        prompt="the solid inside of a dark wooden structure, close packed "
               "timber, no top edge and no highlight, seamless in all "
               "directions"),
    "solo": dict(
        size=(TILE, TILE), sketch=sketch_solo,
        prompt="a small single wooden ledge with finished ends on both sides, "
               "warm walnut, lighter walkable top"),
}


def generate_pieces(force: bool = False) -> dict[str, Image.Image]:
    STAGING.mkdir(parents=True, exist_ok=True)
    out: dict[str, Image.Image] = {}
    for name, cfg in PIECES.items():
        dest = STAGING / f"{name}.png"
        if dest.exists() and not force:
            print(f"  cached  {name}")
            out[name] = Image.open(dest).convert("RGBA")
            continue
        w, h = cfg["size"]
        init = cfg["sketch"](w, h)
        init.save(STAGING / f"{name}_sketch.png")
        print(f"  drawing {name} {w}x{h}")
        img = bitforge(cfg["prompt"], w, h, init)
        img.save(dest)
        out[name] = img
    return out


def build_tileset(pieces: dict[str, Image.Image], tileset: str = "ground_rock") -> Path:
    """Lay the generated pieces onto the grid the maps already address.

    Roles come from `tile_roles.infer()`, which reads them out of how the levels
    place each index — so a tile the designer used as a left end really gets the
    left end of the strip.
    """
    atlas = ASSETS / "map" / "resources" / f"{tileset}.atlas.yaml"
    text = atlas.read_text()
    cols = int([l for l in text.splitlines() if l.startswith("columns")][0].split(":")[1])
    rows = int([l for l in text.splitlines() if l.startswith("rows")][0].split(":")[1])

    strip = pieces["platform_strip"]
    by_role = {
        "Left": strip.crop((0, 0, TILE, TILE)),
        "Mid": strip.crop((TILE, 0, TILE * 2, TILE)),
        "Right": strip.crop((TILE * 2, 0, TILE * 3, TILE)),
        "Center": pieces["fill"],
        "Solo": pieces["solo"],
    }

    roles = infer().get(tileset, {})
    sheet = Image.new("RGBA", (cols * TILE, rows * TILE), (0, 0, 0, 0))
    for idx in range(cols * rows):
        tile = by_role.get(roles.get(idx, "Center"), by_role["Center"])
        sheet.alpha_composite(tile, ((idx % cols) * TILE, (idx // cols) * TILE))

    dest = STAGING / f"{tileset}.png"
    sheet.save(dest)
    print(f"  tileset {tileset}: {cols}x{rows} -> {dest}  ({len(roles)} roles from the map)")
    return dest


def preview(tileset: str = "ground_rock") -> Path:
    """Render the lobby with the generated tiles, over the painted room."""
    from tile_roles import parse_layers
    sheet = Image.open(STAGING / f"{tileset}.png").convert("RGBA")
    atlas = (ASSETS / "map" / "resources" / f"{tileset}.atlas.yaml").read_text()
    cols = int([l for l in atlas.splitlines() if l.startswith("columns")][0].split(":")[1])

    layers = parse_layers(ASSETS / "map" / "levels" / "gamenight_lobby.map.yaml")
    tiles = [t for ts, ts_tiles in layers if ts == tileset for t in ts_tiles]
    if not tiles:
        raise SystemExit("no tiles for that tileset in the lobby map")
    max_x = max(t[0] for t in tiles) + 2
    max_y = max(t[1] for t in tiles) + 2

    room = Image.new("RGBA", (max_x * TILE, max_y * TILE), (30, 24, 34, 255))
    bg = STAGING.parent / "room_bg.png"
    if bg.exists():
        room.alpha_composite(Image.open(bg).convert("RGBA")
                             .resize((max_x * TILE, max_y * TILE), Image.NEAREST))
    for x, y, idx in tiles:
        src = sheet.crop(((idx % cols) * TILE, (idx // cols) * TILE,
                          (idx % cols) * TILE + TILE, (idx // cols) * TILE + TILE))
        room.alpha_composite(src, (x * TILE, (max_y - 1 - y) * TILE))

    out = STAGING / "lobby_preview.png"
    room.convert("RGB").save(out)
    print(f"  preview -> {out}  ({len(tiles)} tiles placed)")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--tileset", default="ground_rock")
    args = ap.parse_args()
    print("structure-driven tiles:")
    pieces = generate_pieces(force=args.force)
    build_tileset(pieces, args.tileset)
    preview(args.tileset)


if __name__ == "__main__":
    main()
