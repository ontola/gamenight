"""Map reviewed room and weapon exports into existing runtime asset grids.

Requires Pillow. No image synthesis: crops alpha bounds and assembles atlases.
The original generated exports and prompts live in docs/art/lobby-redesign.
"""
from pathlib import Path
import re
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
SOURCE = ROOT / "docs/art/lobby-redesign"
ASSETS = ROOT / "crates/lobby/assets"


def build():
    Image.open(SOURCE / "room-source.png").convert("RGBA").resize(
        (640, 384), Image.Resampling.NEAREST
    ).save(ASSETS / "map/resources/bg_room.png")
    for name in ("buss", "cannon", "machine_gun", "musket", "periscope", "sniper_rifle"):
        path = SOURCE / (name + "-1.png")
        if not path.exists():
            continue
        source = Image.open(path).convert("RGBA")
        assert source.getchannel("A").getextrema()[0] == 0, "Weapon export must have real alpha"
        source = source.crop(source.getbbox())
        folder = ASSETS / "elements/item" / name
        meta = (folder / (name + ".atlas.yaml")).read_text()
        width, height = map(int, re.search(r"tile_size: \[(\d+), (\d+)\]", meta).groups())
        cols = int(re.search(r"columns: (\d+)", meta)[1])
        rows = int(re.search(r"rows: (\d+)", meta)[1])
        scale = min((width - 4) / source.width, (height - 4) / source.height)
        sprite = source.resize((max(1, round(source.width * scale)), max(1, round(source.height * scale))), Image.Resampling.NEAREST)
        atlas = Image.new("RGBA", (width * cols, height * rows))
        for idx in range(cols * rows):
            # Existing gameplay selects firing frames. Recoil is a translation,
            # never a different weapon or an independently resized texture.
            recoil = -2 if (name == "cannon" and idx == 1) or (name == "machine_gun" and idx == 2) else -1 if name == "cannon" and idx == 2 else 0
            x = idx % cols * width + (width - sprite.width) // 2 + recoil
            y = idx // cols * height + (height - sprite.height) // 2
            atlas.alpha_composite(sprite, (x, y))
        atlas.save(folder / re.search(r"image: (.+)", meta)[1].strip())
        print(f"Mapped {name}: {cols}x{rows} cells of {width}x{height}")


if __name__ == "__main__":
    build()
