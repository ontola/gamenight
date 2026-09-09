"""Generate player skins with PixelLab, keeping the face a separate layer.

The face is not part of the body here, and that is the whole point: a player's
face is their identity, drawn by them in the profile studio and swapped onto the
character by `swap_player_faces_system`. So the bodies are generated with
**blank heads** — no eyes, no mouth, just skin — and the face layer keeps
owning the features.

Asking for a blank face turns out to be far more reliable than drawing one and
wiping it, which is what `tools/reskin/faces.py` has to do for the CC0
characters. The model honours "completely blank featureless face" directly, and
`animate` preserves it across every frame.

Characters face the camera (`direction="south"`), not sideways. That is forced
by the avatar: a drawn face is a front-facing portrait and cannot sit on a
profile head. The engine flips the sprite for travel direction.

Output goes to `staging/characters/<name>/` for review. Nothing is written into
`assets/` — `adopt.py` does that once a set is accepted.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGING = HERE / "staging" / "characters"

# `pixellab.py` is vendored here rather than imported from the Last Draw
# tools. The two are separate products now, so a shared copy would be a
# dependency between repos that neither wants; divergence between them is
# expected, not drift.
sys.path.insert(0, str(HERE.parents[1] / "tools" / "reskin"))

import generate as gen  # noqa: E402  (also loads the .env key)
import spec  # noqa: E402
import pixellab  # noqa: E402
from PIL import Image  # noqa: E402

# The rig, mirrored from tools/reskin/build_players.py. Same grid, same frame
# indices, same baseline — a generated skin has to drop into the atlas the
# animation YAML already addresses.
CELL_W, CELL_H = 96, 80
COLUMNS, ROWS = 14, 7
BASELINE = 64
TARGET_VISIBLE_H = 54

IDLE = list(range(0, 14))
WALK = list(range(14, 20))
RISE, FALL, CROUCH, SLIDE = 28, 42, 56, 58
DEATH_SPINE = list(range(70, 77))
DEATH_BELLY = list(range(84, 91))

BLANK_FACE = ("completely blank featureless face with no eyes and no mouth, "
              "smooth plain skin where the face would be")

CHARACTERS = {
    "fishy": "wearing a green hoodie and blue jeans, messy brown hair",
    "pescy": "wearing a blue t-shirt and dark shorts, long auburn hair",
    "sharky": "wearing a grey zip jacket and cargo trousers, short dark hair",
    "orcy": "wearing a mustard cardigan and brown trousers, curly black hair",
}

# One animate call per entry, all at four frames. Fewer is not an option: the
# v3 endpoint rejects frame_count < 4, and the v1 fallback it drops to draws
# motion smears and opaque white haloes that ruin the sprite. Poses the rig only
# samples once still ask for four and use the first.
ACTIONS = {
    "idle": ("idle standing, breathing gently, tiny bob, facing the viewer", 4),
    "walk": ("walking towards the viewer, legs stepping, arms swinging", 4),
    "jump": ("jumping upward, knees bent, arms raised, facing the viewer", 4),
    "fall": ("falling downward, arms out to the sides, facing the viewer", 4),
    "crouch": ("crouching down low, knees bent, facing the viewer", 4),
    "hurt": ("stumbling backwards hurt, facing the viewer", 4),
}


def base_sprite(outfit: str, size: int = 64) -> Image.Image:
    prompt = (f"a friendly chunky game-night character standing facing the "
              f"viewer, arms at sides, {outfit}, {BLANK_FACE}, full body, "
              f"standing, {spec.STYLE}")
    return gen.pixen(prompt, size, size, direction="south")


def animate(first: Image.Image, action: str, n: int, outfit: str) -> list[Image.Image]:
    try:
        # animate_v3 directly, not pixellab.animate: that helper falls back to
        # the v1 model on any failure, and v1's output here was unusable.
        frames = pixellab.animate_v3(first, action, n)
        return [f for f in frames if f.getbbox()]
    except Exception as e:  # noqa: BLE001 - a failed action must not lose the set
        print(f"    ! {action[:28]}… failed ({e}); reusing the base pose")
        return [first]


def scaled(img: Image.Image, factor: float) -> Image.Image:
    w = max(1, round(img.width * factor))
    h = max(1, round(img.height * factor))
    return img.resize((w, h), Image.NEAREST)


def place(sheet: Image.Image, idx: int, sprite: Image.Image) -> None:
    col, row = idx % COLUMNS, idx // COLUMNS
    x = col * CELL_W + (CELL_W - sprite.width) // 2
    y = row * CELL_H + BASELINE - sprite.height
    sheet.alpha_composite(sprite, (x, y))


def head_anchor(base: Image.Image, factor: float) -> tuple[int, int]:
    """Where the blank head sits, as a face-layer offset from the cell centre.

    `tools/reskin/build_players.py` finds this from the eye whites, which these
    characters deliberately do not have. The head is instead the mass above the
    shoulders: scan down from the top of the sprite and stop where the silhouette
    suddenly widens.
    """
    alpha = base.getchannel("A")
    bbox = base.getbbox()
    widths = []
    for y in range(bbox[1], bbox[3]):
        xs = [x for x in range(base.width) if alpha.getpixel((x, y)) > 40]
        widths.append((y, (min(xs), max(xs), len(xs))) if xs else (y, None))

    solid = [(y, w) for y, w in widths if w]
    if not solid:
        raise SystemExit("empty sprite")
    head_w = max(w[2] for _, w in solid[:max(3, len(solid) // 6)])
    head_bottom = solid[-1][0]
    for y, w in solid:
        if w[2] > head_w * 1.6:          # shoulders
            head_bottom = y
            break
    head_rows = [(y, w) for y, w in solid if y <= head_bottom]
    cx = sum((w[0] + w[1]) / 2 for _, w in head_rows) / len(head_rows)
    cy = (head_rows[0][0] + head_bottom) / 2

    # Into cell coordinates: the sprite is scaled and stood on the baseline.
    frame_x = CELL_W / 2 + (cx - base.width / 2) * factor
    frame_y = BASELINE - (bbox[3] - cy) * factor
    return round(frame_x - CELL_W / 2), round(CELL_H / 2 - frame_y)


def build(name: str, outfit: str) -> Path:
    out = STAGING / name
    out.mkdir(parents=True, exist_ok=True)
    print(f"{name}: {outfit}")

    base = base_sprite(outfit)
    base.save(out / "base.png")
    bbox = base.getbbox()
    factor = TARGET_VISIBLE_H / (bbox[3] - bbox[1])

    poses: dict[str, list[Image.Image]] = {}
    for key, (action, n) in ACTIONS.items():
        print(f"  animate {key}")
        poses[key] = animate(base, action, n, outfit)

    sheet = Image.new("RGBA", (COLUMNS * CELL_W, ROWS * CELL_H), (0, 0, 0, 0))

    def pose(key: str, i: int = 0) -> Image.Image:
        frames = poses.get(key) or [base]
        return scaled(frames[i % len(frames)], factor)

    for n, idx in enumerate(IDLE):
        place(sheet, idx, pose("idle", n // 4))
    for n, idx in enumerate(WALK):
        place(sheet, idx, pose("walk", n))
    place(sheet, RISE, pose("jump"))
    place(sheet, FALL, pose("fall"))
    place(sheet, CROUCH, pose("crouch"))
    place(sheet, SLIDE, pose("crouch", 1))

    # No death animation exists; topple the hurt pose, as the CC0 build does.
    hurt = pose("hurt")
    for k, idx in enumerate(DEATH_SPINE):
        place(sheet, idx, hurt.rotate(90 * k / 6, resample=Image.BICUBIC, expand=True))
    for k, idx in enumerate(DEATH_BELLY):
        place(sheet, idx, hurt.rotate(-90 * k / 6, resample=Image.BICUBIC, expand=True))

    body = out / f"{name}-body.png"
    sheet.save(body)
    offset = head_anchor(base, factor)
    (out / "face_offset.txt").write_text(f"{offset[0]} {offset[1]}\n")
    print(f"  sheet {sheet.size}  scale={factor:.3f}  face_offset={list(offset)}")

    preview(out, name, sheet)
    return body


def preview(out: Path, name: str, sheet: Image.Image) -> None:
    """The frames the rig actually samples, side by side."""
    picks = [("idle", 0), ("idle", 9), ("walk", 14), ("walk", 15), ("jump", RISE),
             ("fall", FALL), ("crouch", CROUCH), ("slide", SLIDE),
             ("death", 70), ("death", 73), ("death", 76)]
    S = 2
    img = Image.new("RGBA", (len(picks) * CELL_W * S, CELL_H * S), (28, 24, 34, 255))
    for n, (_, idx) in enumerate(picks):
        col, row = idx % COLUMNS, idx // COLUMNS
        cell = sheet.crop((col * CELL_W, row * CELL_H,
                           col * CELL_W + CELL_W, row * CELL_H + CELL_H))
        img.alpha_composite(cell.resize((CELL_W * S, CELL_H * S), Image.NEAREST),
                            (n * CELL_W * S, 0))
    img.save(out / "preview.png")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="one skin name")
    args = ap.parse_args()
    names = [args.only] if args.only else list(CHARACTERS)
    for name in names:
        if name not in CHARACTERS:
            raise SystemExit(f"unknown skin {name!r}")
        build(name, CHARACTERS[name])


if __name__ == "__main__":
    main()
