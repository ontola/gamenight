"""Rebuild the map tilesets and parallax backgrounds from CC0 source art.

Tile indices are baked into every level file, so the grids keep their exact
dimensions and each index is filled with a tile of the same structural role it
plays in the levels (see tile_roles.py). Unused cells get the interior-fill tile
rather than being left blank, so the map editor still shows a usable palette.

Each tileset is assigned a different Kenney material, which is what actually
replaces the underwater/pirate identity: rock/wood/metal/coral/ship become
stone/dirt/castle/grass/sand.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

import atlaslib as al
from tile_roles import infer

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
DELUXE = Path("/tmp/cc0/kenney_platformer-art-deluxe")
TILES = DELUXE / "Base pack" / "Tiles"
BACKGROUNDS = DELUXE / "Mushroom expansion" / "Backgrounds"

# Jumpy tileset -> Kenney material family. Chosen to keep the five sets visually
# distinguishable, the way rock/wood/metal/coral/ship were.
MATERIAL = {
    "ground_rock": "stone",
    "ground_wood": "dirt",
    "ground_metal": "castle",
    "coral": "grass",
    "ship_decorations": "sand",
    "default_tileset": "stone",
}

# Role -> Kenney filename suffix. 'Solo' is a one-tile platform, for which the
# bare material name is the full block with a finished top.
SUFFIX = {"Left": "Left", "Mid": "Mid", "Right": "Right", "Center": "Center", "Solo": ""}

BG = {
    "background_01.png": "bg_grasslands.png",
    "background_02.png": "bg_shroom.png",
    "background_03.png": "bg_desert.png",
    "background_04.png": "bg_castle.png",
}


def tile_image(material: str, role: str, size: int) -> Image.Image:
    name = f"{material}{SUFFIX[role]}.png"
    path = TILES / name
    if not path.exists():
        path = TILES / f"{material}Center.png"
    return al.load(path).resize((size, size), al.RESAMPLE)


def build_tilesets() -> None:
    roles_by_set = infer()
    print("tilesets:")
    for name, material in MATERIAL.items():
        atlas = ASSETS / "map" / "resources" / f"{name}.atlas.yaml"
        if not atlas.exists():
            continue
        grid = al.read_grid(atlas)
        size = grid.tile_w
        roles = roles_by_set.get(name, {})

        cache = {r: tile_image(material, r, size) for r in SUFFIX}
        sheet = al.transparent(grid)
        for idx in range(grid.columns * grid.rows):
            role = roles.get(idx, "Center")
            ox, oy = grid.cell(idx)
            sheet.alpha_composite(cache[role], (ox, oy))

        dest = ASSETS / "map" / "resources" / f"{name}.png"
        al.save(sheet, dest)
        al.verify(dest, grid)
        print(f"  {name:18s} <- {material:7s} {grid.columns}x{grid.rows} "
              f"({len(roles)} roles from levels)")


def build_backgrounds() -> None:
    print("backgrounds:")
    for dest_name, src_name in BG.items():
        dest = ASSETS / "map" / "resources" / dest_name
        # The map YAML declares these as 896x480; keep that exactly or the
        # parallax layers shift.
        w, h = Image.open(dest).size
        src = al.load(BACKGROUNDS / src_name).resize((w, h), al.RESAMPLE)
        al.save(src, dest)
        print(f"  {dest_name} <- {src_name} ({w}x{h})")


if __name__ == "__main__":
    build_tilesets()
    build_backgrounds()
