"""Arrange the generated props into a mock room, at game scale.

A contact sheet answers "is this sprite good". It cannot answer the question
that actually matters — whether the set reads as one room, and whether the
pieces are the right size *relative to each other and to a player*. Those only
show up in a scene.

Nothing here calls the API. It composes what is already in `staging/`, so it is
free to rerun after every regeneration.

The character is pulled from the shipping player atlas so the scale reference is
real rather than guessed: everything is judged against the body that will
actually stand next to it.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging"
ASSETS = HERE.parents[1] / "assets"

W, H = 688, 384          # the generated room background's size
FLOOR_Y = 296            # the skirting line in room_bg.png
WALL_COLOUR = (38, 30, 46, 255)
FLOOR_COLOUR = (58, 38, 32, 255)
FLOOR_EDGE = (96, 60, 44, 255)


def load(name: str) -> Image.Image | None:
    p = STAGING / f"{name}.png"
    return Image.open(p).convert("RGBA") if p.exists() else None


def player_sprite() -> Image.Image | None:
    """Frame 0 of a shipping skin, body + pixel face, for scale."""
    body = ASSETS / "player" / "skins" / "fishy" / "fishy-body.png"
    face = ASSETS / "player" / "skins" / "fishy" / "fishy-face.png"
    if not body.exists():
        return None
    cell = Image.open(body).convert("RGBA").crop((0, 0, 96, 80))
    if face.exists():
        # Face layer offset [1, 7] from the cell centre, per fishy.player.yaml.
        f = Image.open(face).convert("RGBA").crop((0, 0, 46, 32))
        cell.alpha_composite(f, (48 + 1 - 23, (40 - 7) - 16))
    return cell


# (name, x, y_mode). y_mode "floor" stands it on the floor line; an int is an
# explicit top edge, for things hung on the wall.
# Only what the game has to drive. Sofas, shelves, lamp, rug, posters and
# window are painted into room_bg.png — a room is a scene, not a pile of props.
LAYOUT = [
    ("tv_cabinet", 330, "floor"),
    ("jukebox", 60, 150),
    ("arcade_cabinet", 560, "floor"),
]

# The interactive pads sit flush on the floor line.
PADS = [("sign_in_pad", 180), ("music_pad_pause", 70), ("music_pad_skip", 130)]


def build(show_grid: bool = False) -> Path:
    bg = STAGING / "room_bg.png"
    if bg.exists():
        room = Image.open(bg).convert("RGBA").resize((W, H), Image.NEAREST)
    else:
        room = Image.new("RGBA", (W, H), WALL_COLOUR)
        d0 = ImageDraw.Draw(room)
        d0.rectangle([0, FLOOR_Y, W, H], fill=FLOOR_COLOUR)
    d = ImageDraw.Draw(room)

    missing = []
    for name, x, y in LAYOUT:
        im = load(name)
        if im is None:
            missing.append(name)
            continue
        top = FLOOR_Y - im.height if y == "floor" else y
        room.alpha_composite(im, (x, top))

    for name, x in PADS:
        im = load(name)
        if im is None:
            missing.append(name)
            continue
        room.alpha_composite(im, (x, FLOOR_Y - im.height))

    player = player_sprite()
    if player is not None:
        # Cell is 96x80 with the feet on the baseline at y=64 within it.
        room.alpha_composite(player, (250, FLOOR_Y - 64))
        room.alpha_composite(player, (470, FLOOR_Y - 64))

    if show_grid:
        for gx in range(0, W, 32):
            d.line([(gx, 0), (gx, H)], fill=(255, 255, 255, 22))

    out = STAGING / "room.png"
    room.convert("RGB").save(out)
    big = room.resize((W * 2, H * 2), Image.NEAREST)
    big.convert("RGB").save(STAGING / "room@2x.png")
    print(f"room -> {out}  and room@2x.png")
    if missing:
        print(f"missing sprites: {', '.join(missing)}")
    return out


if __name__ == "__main__":
    import sys
    build(show_grid="--grid" in sys.argv)
