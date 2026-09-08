"""Rebuild the four player skin sheets from CC0 source characters.

Source: Kenney "Platformer Characters" (CC0). Each source character ships 24
poses on an 80x110 canvas, bottom-anchored and mutually aligned.

Every frame index the animation YAML references is filled at its existing
position in the existing 14x7 grid, so none of the animation data needs editing.
The one value this script does write back is the face layer's offset — see
below.

`fin` is written as a fully transparent sheet — the source characters have no
equivalent part, and `PlayerLayersMeta` (src/core/metadata/player.rs) declares
the layer non-optional, so it has to exist as a valid atlas rather than be
removed.

`face` is the interesting one. The source characters have their eyes and mouth
painted into the body art, which is wrong for GameNight: a player's face is
their identity, so it has to be swappable and the stock face must never show.
So the body art is wiped to a blank head (faces.wipe_face) and the features move
onto the face layer as chunky pixel art, several variants deep — one row of
expressions per variant, so a player can be dealt a face at random and keep it
until they sign in with an avatar of their own.

The face layer also anchors that drawn avatar (`player_face_placement` in
src/gamenight.rs). Upstream's offsets were tuned to each fish's snout, which put
the avatar off the head once the art changed, so this script measures where each
new character's face actually is and writes the offset back into the
`*.player.yaml`. Change TARGET_VISIBLE_H or BASELINE and the offsets are
re-derived with them — they must not be hand-edited back.
"""

from __future__ import annotations

import re
from pathlib import Path

from PIL import Image

import atlaslib as al
import faces

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "assets"
SRC = Path("/tmp/cc0/kenney_platformer-characters/PNG")

# Which CC0 character dresses which skin slot. Kenney ships five; Zombie is left
# unused so there is a spare that matches the set if we ever add a fifth player.
SKINS = {
    "fishy": "Player",
    "pescy": "Female",
    "sharky": "Adventurer",
    "orcy": "Soldier",
}

# Where the art has to sit inside a 96x80 cell to line up with the physics body.
# body_size is [32, 48] centred in the cell, so the collider's feet are at y=64.
# The original fish art measured 40x53 visible with its feet on that same line;
# matching it keeps item hold points and head_offsets honest.
BASELINE = 64
TARGET_VISIBLE_H = 54

# Frame indices, read off the `*.player.yaml` animations. Identical for all four
# skins. Anything not listed is never sampled and stays transparent.
IDLE = list(range(0, 14))
WALK = list(range(14, 20))
RISE, FALL, CROUCH, SLIDE = 28, 42, 56, 58
DEATH_SPINE = list(range(70, 77))
DEATH_BELLY = list(range(84, 91))


def poses(character: str) -> dict[str, Image.Image]:
    folder = SRC / character / "Poses"
    prefix = character.lower()
    out = {}
    for p in folder.glob(f"{prefix}_*.png"):
        out[p.stem[len(prefix) + 1:]] = al.load(p)
    if not out:
        raise SystemExit(f"no poses found in {folder}")
    return out


def scale_factor(stand: Image.Image) -> float:
    """Derive one scale from the standing pose and reuse it for every frame.

    Scaling each pose to fit its own bounding box would silently resize the
    character between animations — a crouch would come out as tall as a stand.
    """
    bbox = stand.getbbox()
    return TARGET_VISIBLE_H / (bbox[3] - bbox[1])


def placed(pose: Image.Image, factor: float) -> Image.Image:
    """Scale a full pose canvas, keeping Kenney's inter-pose alignment intact."""
    return al.scale_to(pose, factor)


def death_frames(hurt: Image.Image, factor: float, forward: bool) -> list[Image.Image]:
    """Fake a 7-frame death from the single `hurt` pose by toppling it over.

    The source pack has no death animation. Rotating to 90 degrees over the run
    reads as a knockdown and matches the timing the YAML already declares.
    """
    base = placed(hurt, factor)
    sign = -1 if forward else 1
    out = []
    for i in range(7):
        angle = sign * (90 * i / 6)
        out.append(base.rotate(angle, resample=Image.BICUBIC, expand=True))
    return out


def face_anchor(stand: Image.Image, factor: float) -> tuple[int, int]:
    """Where the character's face sits, as a face-layer offset from cell centre.

    Found from the eye whites: they are the only near-white pixels in the upper
    body across all five source characters, and unlike hair or skin they don't
    vary between them. The anchor is dropped a little below the eyes because a
    portrait reads best centred on the face, not on the eye line.
    """
    px = stand.convert("RGBA").load()
    w, h = stand.size
    bbox = stand.getbbox()
    pts = [(x, y)
           for y in range(bbox[1], bbox[1] + int((bbox[3] - bbox[1]) * 0.55))
           for x in range(w)
           if (lambda p: p[3] > 150 and p[0] > 225 and p[1] > 225 and p[2] > 225)(px[x, y])]
    if not pts:
        raise SystemExit("no eye whites found; the source art has changed shape")
    ex = sum(p[0] for p in pts) / len(pts)
    ey = sum(p[1] for p in pts) / len(pts)

    # Into cell coordinates: the canvas is scaled and its bottom sits on BASELINE.
    frame_x = 48 + (ex - w / 2) * factor
    frame_y = BASELINE - (h - ey) * factor + EYES_TO_FACE_CENTRE
    # The layer offset is measured up from the cell centre.
    return round(frame_x - 48), round(40 - frame_y)


# How far below the eye line the middle of the face is, in cell pixels.
EYES_TO_FACE_CENTRE = 2.0

_FACE_BLOCK = re.compile(
    r"(^  face:\n(?:[ \t]+\S.*\n)*?[ \t]+offset: )\[[^\]]*\]", re.MULTILINE)


def write_face_offset(skin: str, offset: tuple[int, int]) -> None:
    path = ASSETS / "player" / "skins" / skin / f"{skin}.player.yaml"
    text = path.read_text()
    patched, n = _FACE_BLOCK.subn(rf"\g<1>[{offset[0]}, {offset[1]}]", text, count=1)
    if n != 1:
        raise SystemExit(f"{path}: could not locate the face layer's offset")
    path.write_text(patched)


# The face atlas is rebuilt to a fixed shape: one column per expression, one row
# per variant. Every skin gets the same width so the runtime can find a variant
# with a flat `variant * FACE_COLUMNS` offset instead of looking up each atlas.
# FACE_VARIANTS must stay in step with FACE_VARIANTS in src/gamenight.rs.
FACE_TILE = (46, 32)
FACE_COLUMNS = 11
FACE_VARIANTS = 8

# Which expression sits in each column. Positions are fixed by the animations
# already in the `*.player.yaml` files: 1 is used for rising, 2 for falling, 4
# and 5 for the idle blink and the crouch, 8/9 for the alarm emote. The last
# column was upstream's "intentionally invisible" frame, used for slides and
# deaths because the fish art drew its own face on those body frames; ours has
# no painted face to defer to, so it gets a real expression and the character
# keeps a face throughout.
FACE_COLUMN_EXPRESSIONS = [
    faces.NEUTRAL, faces.UP, faces.DOWN, faces.NEUTRAL, faces.BLINK,
    faces.SQUINT, faces.SMILE, faces.SURPRISE, faces.ALARM, faces.SHOCK,
    faces.SHOCK,
]


def build_face_atlas(skin_dir: Path, skin: str) -> None:
    grid = al.Grid(FACE_TILE[0], FACE_TILE[1], FACE_COLUMNS, FACE_VARIANTS)
    sheet = al.transparent(grid)
    for variant in range(FACE_VARIANTS):
        for col, expression in enumerate(FACE_COLUMN_EXPRESSIONS):
            idx = variant * FACE_COLUMNS + col
            ox, oy = grid.cell(idx)
            sheet.alpha_composite(faces.draw_face(FACE_TILE, expression, variant),
                                  (ox, oy))
    png = skin_dir / f"{skin}-face.png"
    al.save(sheet, png)
    (skin_dir / f"{skin}-face.atlas.yaml").write_text(
        f"image: ./{skin}-face.png\n"
        f"tile_size: [{FACE_TILE[0]}, {FACE_TILE[1]}]\n"
        f"columns: {FACE_COLUMNS}\n"
        f"rows: {FACE_VARIANTS}\n"
    )
    al.verify(png, grid)


def build_skin(skin: str, character: str) -> None:
    skin_dir = ASSETS / "player" / "skins" / skin
    body_grid = al.read_grid(skin_dir / f"{skin}-body.atlas.yaml")
    p = poses(character)
    factor = scale_factor(p["stand"])

    # Measure the face anchor first: it keys off the eye whites, which the wipe
    # is about to remove.
    offset = face_anchor(p["stand"], factor)

    # Wipe the painted face off every pose before any of it is composited, so
    # no frame of the body sheet carries the stock face.
    skin_tone = faces.skin_colour(p["stand"])
    p = {name: faces.wipe_face(img, skin_tone) for name, img in p.items()}

    sheet = al.transparent(body_grid)

    def put(idx: int, img: Image.Image, dy: int = 0) -> None:
        al.paste_bottom_center(sheet, body_grid, idx, img, BASELINE, dy=dy)

    # Idle alternates stand/idle so the pose breathes; the YAML already applies a
    # 0/-1/-2 px vertical bob on top of these frames.
    stand, idle = placed(p["stand"], factor), placed(p["idle"], factor)
    for n, idx in enumerate(IDLE):
        put(idx, idle if 7 <= n <= 12 else stand)

    walk = [placed(p["walk1"], factor), placed(p["walk2"], factor)]
    for n, idx in enumerate(WALK):
        put(idx, walk[n % 2])

    put(RISE, placed(p["jump"], factor))
    put(FALL, placed(p["fall"], factor))
    put(CROUCH, placed(p["duck"], factor))
    put(SLIDE, placed(p["slide"], factor))

    for idx, img in zip(DEATH_SPINE, death_frames(p["hurt"], factor, forward=False)):
        put(idx, img)
    for idx, img in zip(DEATH_BELLY, death_frames(p["hurt"], factor, forward=True)):
        put(idx, img)

    body_png = skin_dir / f"{skin}-body.png"
    al.save(sheet, body_png)
    al.verify(body_png, body_grid)

    # Retire the fin layer; the source characters have no equivalent part.
    for layer in ("fin",):
        grid = al.read_grid(skin_dir / f"{skin}-{layer}.atlas.yaml")
        png = skin_dir / f"{skin}-{layer}.png"
        al.save(al.transparent(grid), png)
        al.verify(png, grid)

    build_face_atlas(skin_dir, skin)
    write_face_offset(skin, offset)

    print(f"  {skin:8s} <- {character:12s} scale={factor:.3f} "
          f"body={body_grid.size} face_offset={list(offset)} "
          f"faces={FACE_COLUMNS}x{FACE_VARIANTS}")


def main() -> None:
    if not SRC.exists():
        raise SystemExit(f"CC0 source missing: {SRC}")
    print("players:")
    for skin, character in SKINS.items():
        build_skin(skin, character)


if __name__ == "__main__":
    main()
