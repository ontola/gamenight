"""One palette for the whole room, and a remapper that holds every asset to it.

The lobby's art was incoherent in a way that is easy to see and hard to name, so
here is the measurement that named it. The two background layers come back from
PixelLab hard-quantised — 26 colours each, a deep maroon wall and a night-blue
skyline. The furniture comes back from bitforge with **676 colours**, and they
are olive and khaki: not one of them is in the wall's family. Half the room was
obeying a strict palette and the other half was not, and the two halves did not
even share a hue. That reads as two games in one screenshot.

A pixel artist would not have had this problem, because a pixel artist picks the
palette once and every asset is drawn from it. That is all this file is: the
palette, picked once, and a nearest-colour remap that no asset gets to escape.

Every entry below is a colour the room *already* contains, lifted from
`bg_room.png` and `bg_city.png` — with one exception, noted at the ramp. The
point is not to invent a look; it is to stop the furniture inventing its own.

    tools/pixelart/.venv/bin/python palette.py            # preview only
    tools/pixelart/.venv/bin/python palette.py --write    # remap the assets

Originals are kept alongside as `*.orig.png`, so a remap is never destructive
and the source art can be re-derived if the palette changes.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
ASSETS = HERE.parents[1] / "assets"
RES = ASSETS / "map" / "resources"
STAGING = HERE / "staging"

# Deliberate ramps, not a colour census.
#
# Taking "the 26 colours already in the wall" wholesale was the first attempt and
# it failed for one specific reason: that set contains desaturated greys like
# #504e40, and in any distance metric a khaki plank is *closer* to a grey than to
# a warm brown. The furniture came back the colour of dishwater. A palette for
# remapping has to be curated so that the only place a colour can land is
# somewhere you would have been happy to put it by hand.
#
# The wood ramp is the long one on purpose. It is where almost every furniture
# pixel lands, and a ramp with too few steps does not just shift the colour — it
# flattens the shading, because three source tones collapse onto one entry and
# the plank loses its edge. Eight steps keeps the modelling that was there.
WOOD = ["#2a1712", "#3d2118", "#4a2a1c", "#5e3620", "#7c4028", "#8f5330", "#ab6d38", "#d48d55"]
WALL = ["#0c020c", "#1e0913", "#340f1b", "#401818", "#471f1c"]
EMBER = ["#9d380d", "#cb4a11", "#f58219", "#f9bc61"]
GOLD = ["#eca637", "#ffea9d", "#fefefb"]
NIGHT = ["#030524", "#12153c", "#211e56", "#324c7c"]
# The one invented colour is the sage. Without a green anywhere in range, every
# houseplant and every little painted trinket on the shelves quantised to brown,
# and the shelves went from "someone lives here" to "someone stores planks here".
#
# A pale blue (#b6d1ea, the cold light on the city's glass) was here too, and it
# had to go: it is the only cool light tone in the set, so every neutral grey in
# the furniture found it and the TV cabinet came out powder blue. A palette entry
# that exists for one distant highlight will be claimed by everything.
ACCENT = ["#19323b", "#2f5d4a", "#921134"]

ROOM_PALETTE = WOOD + WALL + EMBER + GOLD + NIGHT + ACCENT


def _rgb(hex_: str) -> tuple[int, int, int]:
    h = hex_.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _lab(c: tuple[int, int, int]) -> tuple[float, float, float]:
    """sRGB to CIELab, so "nearest" means nearest to the eye.

    Plain RGB distance judges by voltage, not by sight: it will happily swap a
    hue for a similarly-bright neutral, which is exactly the swap that ruins a
    limited palette. Lab is a dozen lines and removes the whole class of error.
    """

    def lin(v: float) -> float:
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4

    r, g, b = (lin(v) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t: float) -> float:
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    fx, fy, fz = f(x), f(y), f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


PALETTE_RGB = [_rgb(h) for h in ROOM_PALETTE]
PALETTE_LAB = [_lab(c) for c in PALETTE_RGB]


def remap(img: Image.Image) -> tuple[Image.Image, int]:
    """Snap every pixel to the palette. Alpha is passed through untouched.

    Fully transparent pixels keep whatever colour they carry rather than being
    snapped — they are invisible, and mapping them wastes time on every asset
    that is mostly empty space, which most of them are.
    """
    src = img.convert("RGBA")
    px = src.load()
    cache: dict[tuple[int, int, int], tuple[int, int, int]] = {}
    changed = 0
    for y in range(src.height):
        for x in range(src.width):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            key = (r, g, b)
            hit = cache.get(key)
            if hit is None:
                l0, a0, b0 = _lab(key)
                best = min(
                    range(len(PALETTE_RGB)),
                    key=lambda i: (PALETTE_LAB[i][0] - l0) ** 2
                    + (PALETTE_LAB[i][1] - a0) ** 2
                    + (PALETTE_LAB[i][2] - b0) ** 2,
                )
                hit = PALETTE_RGB[best]
                cache[key] = hit
            if hit != key:
                px[x, y] = (*hit, a)
                changed += 1
    return src, changed


def swatch(width: int = 640, height: int = 48) -> Image.Image:
    im = Image.new("RGBA", (width, height), (0, 0, 0, 255))
    w = width // len(PALETTE_RGB)
    for i, c in enumerate(PALETTE_RGB):
        for y in range(height):
            for x in range(i * w, min((i + 1) * w, width)):
                im.putpixel((x, y), (*c, 255))
    return im


def compose(tileset: Image.Image) -> Image.Image:
    """The room as the game draws it, for judging a change before shipping it."""
    sys.path.insert(0, str(HERE.parents[1] / "tools" / "reskin"))
    from tile_roles import parse_layers  # noqa: E402

    import layout  # noqa: E402

    tile = layout.TILE
    w, h = layout.GRID_W * tile, layout.GRID_H * tile
    img = Image.new("RGBA", (w, h), (12, 6, 12, 255))
    city = Image.open(RES / "bg_city.png").convert("RGBA")
    room = Image.open(RES / "bg_room.png").convert("RGBA")
    img.alpha_composite(city.resize((w, h), Image.NEAREST))
    img.alpha_composite(room.resize((w, h), Image.NEAREST))

    atlas = (RES / "ground_rock.atlas.yaml").read_text()
    cols = int([l for l in atlas.splitlines() if l.startswith("columns")][0].split(":")[1])
    for _, tiles in parse_layers(layout.MAP):
        for x, y, idx in tiles:
            src = tileset.crop(
                ((idx % cols) * tile, (idx // cols) * tile,
                 (idx % cols) * tile + tile, (idx // cols) * tile + tile)
            )
            img.alpha_composite(src, (x * tile, (layout.GRID_H - 1 - y) * tile))
    return img


def audit(name: str) -> None:
    """Report how far an asset sits from the palette, without touching it."""
    im = Image.open(RES / name).convert("RGBA")
    px = im.load()
    seen: dict[tuple[int, int, int], int] = {}
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            if a > 128:
                seen[(r, g, b)] = seen.get((r, g, b), 0) + 1
    exact = sum(k for c, k in seen.items() if c in PALETTE_RGB)
    total = sum(seen.values())
    print(f"  {name:18} {len(seen):>4} colours, {100 * exact / total:5.1f}% already on palette")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--remap", nargs="+", metavar="FILE",
                    help="asset(s) under map/resources to snap to the palette")
    ap.add_argument("--write", action="store_true", help="write the remap to disk")
    args = ap.parse_args()

    STAGING.mkdir(parents=True, exist_ok=True)
    print(f"palette: {len(PALETTE_RGB)} colours")

    if not args.remap:
        # Auditing by default, because remapping is now the wrong move for the
        # asset that originally needed it. `ground_rock.png` is drawn by
        # `furniture_art` straight out of this palette's ramps, in deliberate
        # in-family tints; snapping it again would collapse those tints onto
        # their nearest ramp step and flatten the shading the drawings depend on.
        # Remap is for art that arrives from outside — a generated background,
        # or a sprite sheet from somewhere else.
        for n in ("ground_rock.png", "bg_room.png", "bg_city.png"):
            audit(n)
        print("\n  nothing changed. pass --remap FILE [--write] to snap an asset.")
        return

    targets = list(args.remap)
    before = {n: Image.open(RES / n).convert("RGBA") for n in targets}
    after = {}
    for n in targets:
        out, changed = remap(before[n])
        after[n] = out
        total = out.width * out.height
        print(f"  {n:16} {changed:>7} of {total} px moved ({100 * changed / total:.1f}%)")

    # The whole room, before and after, as the game draws it. A tileset contact
    # sheet cannot show whether furniture belongs in a room; only the room can.
    # Every remapped file is written to a scratch copy for the "after" compose,
    # then put back, so a preview run never leaves the assets altered.
    tileset = RES / "ground_rock.png"
    old = compose(Image.open(tileset).convert("RGBA"))
    backups = {RES / n: (RES / n).read_bytes() for n in targets}
    try:
        for n in targets:
            after[n].save(RES / n)
        new = compose(Image.open(tileset).convert("RGBA"))
    finally:
        for path, data in backups.items():
            path.write_bytes(data)

    sheet = Image.new("RGBA", (old.width, old.height * 2 + 48), (0, 0, 0, 255))
    sheet.alpha_composite(old, (0, 0))
    sheet.alpha_composite(new, (0, old.height))
    sheet.alpha_composite(swatch(old.width, 48), (0, old.height * 2))
    dest = STAGING / "palette_preview.png"
    sheet.convert("RGB").save(dest)
    print(f"  preview -> {dest}   (top: now, middle: remapped, bottom: palette)")

    if args.write:
        for n in targets:
            orig = RES / n.replace(".png", ".orig.png")
            if not orig.exists():
                orig.write_bytes((RES / n).read_bytes())
            after[n].save(RES / n)
            print(f"  wrote {n}  (original kept at {orig.name})")


if __name__ == "__main__":
    main()
