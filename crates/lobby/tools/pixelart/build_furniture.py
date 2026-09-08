"""Draw each piece of furniture at its own footprint, and wire it into the map.

This is the flow the room is built on: the map declares a shape, the shape is the
canvas, and the art is made the exact size of the thing players stand on. No
prompt has to be talked into the right scale, and no painted background can
disagree with the collision.

Each piece is made whole — a 2x2 bookcase as one 64x64 image — and then sliced
into 32px tiles which are appended to the tileset the map already addresses.
Slicing a finished piece is what keeps its halves lined up; asking for the tiles
separately is what made the first tileset attempt fall apart.

The art itself comes from `furniture_art`, not from PixelLab. That step used to
send every piece to bitforge with the same generic sketch, and at the init
strength needed to hold a palette the model returns roughly the sketch it was
given — so a sofa, an arcade cabinet and two bookcases all came back as the same
tan box, in a khaki that appears nowhere in the room. Furniture is rectilinear
and the palette is fixed, which makes this the one part of the pipeline a
drawing program does better than a model.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml
from PIL import Image

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging" / "furniture"
ASSETS = HERE.parents[1] / "assets"

import layout  # noqa: E402
import furniture_art  # noqa: E402

TILE = layout.TILE


def generate() -> dict[str, Image.Image]:
    """Draw every piece. No cache: it is a few milliseconds and deterministic."""
    STAGING.mkdir(parents=True, exist_ok=True)
    art: dict[str, Image.Image] = {}
    for piece in layout.ALL:
        img = furniture_art.draw(piece)
        img.save(STAGING / f"{piece.name}.png")
        art[piece.name] = img
        print(f"  drew    {piece.name} {piece.px[0]}x{piece.px[1]}")
    return art


def build_tileset(art: dict[str, Image.Image], tileset: str = "ground_rock"):
    """Slice every piece into the tileset, remembering which index went where."""
    atlas = ASSETS / "map" / "resources" / f"{tileset}.atlas.yaml"
    text = atlas.read_text()
    cols = int([l for l in text.splitlines() if l.startswith("columns")][0].split(":")[1])
    rows = int([l for l in text.splitlines() if l.startswith("rows")][0].split(":")[1])
    sheet = Image.new("RGBA", (cols * TILE, rows * TILE), (0, 0, 0, 0))

    index: dict[tuple[str, int, int], int] = {}
    slot = 0

    def put(img: Image.Image) -> int:
        nonlocal slot
        if slot >= cols * rows:
            raise SystemExit("tileset full")
        sheet.alpha_composite(img, ((slot % cols) * TILE, (slot // cols) * TILE))
        slot += 1
        return slot - 1

    for piece in layout.ALL:
        im = art[piece.name]
        for cy in range(piece.h):
            for cx in range(piece.w):
                # Piece art is top-down; map rows count upward.
                box = (cx * TILE, (piece.h - 1 - cy) * TILE,
                       cx * TILE + TILE, (piece.h - cy) * TILE)
                index[(piece.name, cx, cy)] = put(im.crop(box))

    # Floor and walls are drawn to purpose rather than cropped off something
    # else. The floor used to be a slice of a cabinet's top edge, which made the
    # whole ground plane one repeated 32px sliver, and the wall was cut from the
    # background photo, which carried a lit brick highlight that tiled into a
    # stripe up both sides of the room.
    floor_idx = put(furniture_art.floor_tile())
    wall_idx = put(furniture_art.wall_tile())

    dest = ASSETS / "map" / "resources" / f"{tileset}.png"
    sheet.save(dest)
    print(f"  tileset -> {dest}  ({slot} tiles used of {cols * rows})")
    return index, floor_idx, wall_idx


def write_map(index, floor_idx, wall_idx) -> None:
    doc = yaml.safe_load(layout.MAP.read_text())
    tiles = []
    for (x, y) in sorted(set(layout.floor_and_walls())):
        idx = floor_idx if y in (1, 2) else wall_idx
        tiles.append({"pos": [x, y], "idx": idx, "collision": "Solid"})
    for piece in layout.ALL:
        for cy in range(piece.h):
            for cx in range(piece.w):
                tiles.append({"pos": [piece.x + cx, piece.y + cy],
                              "idx": index[(piece.name, cx, cy)],
                              # The doorway is drawn but not solid: the whole
                              # point of it is that you can walk in.
                              "collision": "Solid" if piece.solid else "Empty"})
    for lyr in doc["layers"]:
        if lyr.get("id") == "main layer":
            lyr["tiles"] = tiles
    moves = layout.element_positions()
    for lyr in doc["layers"]:
        for el in lyr.get("elements") or []:
            key = el["element"].split("/")[-1].replace(".element.yaml", "")
            if key in moves:
                el["pos"] = [float(v) for v in moves[key]]
    layout.MAP.write_text(yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))
    print(f"  map -> {layout.MAP}  ({len(tiles)} tiles)")


def preview() -> Path:
    sys.path.insert(0, str(HERE.parents[1] / "tools" / "reskin"))
    from tile_roles import parse_layers
    sheet = Image.open(ASSETS / "map" / "resources" / "ground_rock.png").convert("RGBA")
    atlas = (ASSETS / "map" / "resources" / "ground_rock.atlas.yaml").read_text()
    cols = int([l for l in atlas.splitlines() if l.startswith("columns")][0].split(":")[1])
    W, H = layout.GRID_W * TILE, layout.GRID_H * TILE
    img = Image.new("RGBA", (W, H), (34, 26, 38, 255))
    # The bare room, at full strength. It can be stretched freely because there
    # is nothing scale-bearing left in it — the furniture is all platforms now.
    bg = HERE / "staging" / "room_bare.png"
    if not bg.exists():
        bg = HERE / "staging" / "room_bg.png"
    if bg.exists():
        img.alpha_composite(Image.open(bg).convert("RGBA").resize((W, H), Image.NEAREST))
    for _, tiles in parse_layers(layout.MAP):
        for x, y, idx in tiles:
            src = sheet.crop(((idx % cols) * TILE, (idx // cols) * TILE,
                              (idx % cols) * TILE + TILE, (idx // cols) * TILE + TILE))
            img.alpha_composite(src, (x * TILE, (layout.GRID_H - 1 - y) * TILE))
    # A player, for scale.
    body = ASSETS / "player" / "skins" / "fishy" / "fishy-body.png"
    if body.exists():
        cell = Image.open(body).convert("RGBA").crop((0, 0, 96, 80))
        img.alpha_composite(cell, (10 * TILE - 48, (layout.GRID_H - 3) * TILE - 64))
    out = STAGING / "room.png"
    img.convert("RGB").save(out)
    print(f"  preview -> {out}")
    return out


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()
    print("furniture:")
    art = generate()
    index, f_idx, w_idx = build_tileset(art)
    if args.write:
        write_map(index, f_idx, w_idx)
    preview()
