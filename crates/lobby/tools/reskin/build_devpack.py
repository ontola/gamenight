"""Reskin the bundled `packs/devpack` sample pack.

Small, but it ships in the repo as the worked example of how to write a mod, so
leaving four NonCommercial images in it would reintroduce exactly the problem
the rest of the reskin removes.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

import atlaslib as al
from build_props import GUNS, ITEMS, TILES, burst_frame, _image_name

PACK = Path(__file__).resolve().parents[2] / "packs" / "devpack"


def fill_atlas(atlas: Path, source: Path, pad: float = 0.92) -> None:
    grid = al.read_grid(atlas)
    sheet = al.transparent(grid)
    src = al.load(source)
    for idx in range(grid.columns * grid.rows):
        al.paste_center(sheet, grid, idx, al.fit(src, grid.tile_w, grid.tile_h, pad))
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    print(f"  {dest.relative_to(PACK)}")


def main() -> None:
    print("devpack:")
    fill_atlas(PACK / "hats" / "pink_pirate.atlas.yaml", ITEMS / "flagRed.png", pad=0.95)
    fill_atlas(PACK / "items" / "blunderbass" / "bullet.atlas.yaml",
               GUNS / "small_bullet.png", pad=1.0)

    # The blunderbass sprite is referenced directly, not through an atlas.
    gun = PACK / "items" / "blunderbass" / "blunderbass.png"
    w, h = Image.open(gun).size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    spr = al.fit(al.load(GUNS / "shotgun.png"), w, h, 0.95)
    out.alpha_composite(spr, ((w - spr.width) // 2, (h - spr.height) // 2))
    al.save(out, gun)
    print(f"  {gun.relative_to(PACK)}")

    # Explosion frames are drawn, matching the main pack's effects.
    atlas = PACK / "items" / "blunderbass" / "explosion.atlas.yaml"
    grid = al.read_grid(atlas)
    n = grid.columns * grid.rows
    sheet = al.transparent(grid)
    for idx in range(n):
        ox, oy = grid.cell(idx)
        sheet.alpha_composite(
            burst_frame(grid.tile_w, grid.tile_h, idx / max(1, n - 1)), (ox, oy))
    dest = atlas.parent / _image_name(atlas)
    al.save(sheet, dest)
    al.verify(dest, grid)
    print(f"  {dest.relative_to(PACK)}")

    # Reuse the CC0 impact sound the main pack now uses for weapon hits.
    src = Path("/tmp/cc0/kenney_impact-sounds/Audio/impactSoft_medium_000.ogg")
    if src.exists():
        (PACK / "items" / "blunderbass" / "bullet_hit_dull.ogg").write_bytes(src.read_bytes())
        print("  items/blunderbass/bullet_hit_dull.ogg")


if __name__ == "__main__":
    main()
