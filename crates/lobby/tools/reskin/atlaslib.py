"""Shared helpers for composing CC0 source art into Jumpy's atlas geometry.

Jumpy addresses sprites by frame index into a fixed grid declared in the
`*.atlas.yaml` next to each PNG. Keeping that grid byte-for-byte identical means
the animation YAML — frame indices, offsets, head_offsets — keeps working, so a
reskin is a pure image swap. Everything here is built around preserving grid
geometry rather than re-authoring it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

RESAMPLE = Image.LANCZOS


@dataclass(frozen=True)
class Grid:
    """The geometry declared by a `*.atlas.yaml`."""

    tile_w: int
    tile_h: int
    columns: int
    rows: int

    @property
    def size(self) -> tuple[int, int]:
        return (self.tile_w * self.columns, self.tile_h * self.rows)

    def cell(self, idx: int) -> tuple[int, int]:
        """Top-left pixel of frame `idx`, in row-major order."""
        if not 0 <= idx < self.columns * self.rows:
            raise IndexError(f"frame {idx} outside {self.columns}x{self.rows} grid")
        return ((idx % self.columns) * self.tile_w, (idx // self.columns) * self.tile_h)


_NUM = r"-?\d+"


def read_grid(atlas_yaml: Path) -> Grid:
    """Parse tile_size/columns/rows out of an atlas YAML.

    Deliberately a regex read rather than a YAML parse: these files are also
    consumed by the game, and we only ever read three scalars from them. Adding a
    PyYAML dependency to the toolchain to read `[96, 80]` is not worth it.
    """
    text = atlas_yaml.read_text()

    def scalar(key: str) -> int:
        m = re.search(rf"^{key}:\s*({_NUM})", text, re.MULTILINE)
        if not m:
            raise ValueError(f"{atlas_yaml}: no '{key}'")
        return int(m.group(1))

    m = re.search(rf"^tile_size:\s*\[\s*({_NUM})\s*,\s*({_NUM})\s*\]", text, re.MULTILINE)
    if not m:
        raise ValueError(f"{atlas_yaml}: no 'tile_size'")
    return Grid(int(m.group(1)), int(m.group(2)), scalar("columns"), scalar("rows"))


def load(path: Path) -> Image.Image:
    return Image.open(path).convert("RGBA")


def transparent(grid: Grid) -> Image.Image:
    """A fully transparent sheet matching `grid`.

    Used to retire a sprite layer that the engine requires structurally but the
    new art does not need — `PlayerLayersMeta` has non-optional `fin` and `face`
    fields, so the layers cannot simply be deleted from the YAML.
    """
    return Image.new("RGBA", grid.size, (0, 0, 0, 0))


def scale_to(img: Image.Image, factor: float) -> Image.Image:
    w = max(1, round(img.width * factor))
    h = max(1, round(img.height * factor))
    return img.resize((w, h), RESAMPLE)


def fit(img: Image.Image, box_w: int, box_h: int, pad: float = 1.0) -> Image.Image:
    """Scale `img` to fit inside a box, preserving aspect ratio."""
    src = img.crop(img.getbbox() or (0, 0, img.width, img.height))
    factor = min(box_w / src.width, box_h / src.height) * pad
    return scale_to(src, factor)


def paste_bottom_center(sheet: Image.Image, grid: Grid, idx: int, sprite: Image.Image,
                        baseline: int, dx: int = 0, dy: int = 0) -> None:
    """Place `sprite` in frame `idx`, horizontally centred, feet on `baseline`.

    `baseline` is measured from the top of the cell and should line up with the
    bottom of the physics collider so the art stands where the body actually is.
    """
    ox, oy = grid.cell(idx)
    x = ox + (grid.tile_w - sprite.width) // 2 + dx
    y = oy + baseline - sprite.height + dy
    sheet.alpha_composite(sprite, (x, y))


def paste_center(sheet: Image.Image, grid: Grid, idx: int, sprite: Image.Image,
                 dx: int = 0, dy: int = 0) -> None:
    ox, oy = grid.cell(idx)
    x = ox + (grid.tile_w - sprite.width) // 2 + dx
    y = oy + (grid.tile_h - sprite.height) // 2 + dy
    sheet.alpha_composite(sprite, (x, y))


def save(sheet: Image.Image, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(dest, optimize=True)


def verify(dest: Path, grid: Grid) -> None:
    """Fail loudly if a written sheet no longer matches its declared grid."""
    got = Image.open(dest).size
    if got != grid.size:
        raise AssertionError(f"{dest}: wrote {got}, atlas declares {grid.size}")
