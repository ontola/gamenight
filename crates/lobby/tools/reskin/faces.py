"""Strip the painted face off a source character, and draw pixel faces.

The CC0 source characters have their eyes and mouth painted into the body art.
That is fine for a platformer with fixed characters and wrong for GameNight,
where a player's face is their identity: it has to be swappable, and the stock
face must never show through underneath.

So the body art gets its face wiped to bare skin here, and the eyes and mouth
move onto jumpy's `face` layer, which is exactly the swappable slot the engine
already has (and which `swap_player_faces_system` already knows how to take away
when a player signs in with a drawn avatar of their own).
"""

from __future__ import annotations

from collections import Counter

from PIL import Image, ImageDraw

Colour = tuple[int, int, int, int]


def eye_points(im: Image.Image) -> list[tuple[int, int]]:
    """The near-white pixels of the eyes, in the upper half of the character.

    Eye whites are the only near-white thing up there and, unlike hair or skin,
    look the same on every character in the pack — which makes them the one
    reliable landmark for finding the face.
    """
    px = im.load()
    w, _ = im.size
    bbox = im.getbbox()
    if not bbox:
        return []
    top, bottom = bbox[1], bbox[1] + int((bbox[3] - bbox[1]) * 0.55)
    return [(x, y)
            for y in range(top, bottom)
            for x in range(w)
            if px[x, y][3] > 150 and min(px[x, y][:3]) > 225]


def skin_colour(im: Image.Image) -> Colour:
    """Sample skin at the bridge of the nose.

    Sampling the cheek instead picks up facial hair — on the bearded character
    it returned the beard's white, which then made the wipe a no-op.
    """
    pts = eye_points(im)
    if not pts:
        raise ValueError("no eyes found")
    ex = sum(p[0] for p in pts) / len(pts)
    ey = sum(p[1] for p in pts) / len(pts)
    px = im.load()
    tally: Counter[Colour] = Counter()
    for dy in range(-2, 4):
        for dx in range(-2, 3):
            x, y = int(ex + dx), int(ey + dy)
            if 0 <= x < im.width and 0 <= y < im.height and px[x, y][3] > 200:
                tally[px[x, y]] += 1
    if not tally:
        raise ValueError("no skin found")
    return tally.most_common(1)[0][0]


def _close(a: Colour, b: Colour, tol: int = 24) -> bool:
    return all(abs(a[i] - b[i]) <= tol for i in range(3))


def wipe_face(pose: Image.Image, skin: Colour) -> Image.Image:
    """Paint the face flat, leaving a blank head.

    Works row by row: on every row that has skin on it, everything between the
    leftmost and rightmost skin pixel becomes skin. Eyes, brows, nose and mouth
    all sit between skin and so are wiped, while hair outside that span — and
    anything on rows with no skin at all, like a beard below the chin — is left
    alone.
    """
    out = pose.copy()
    px = out.load()
    w, h = out.size
    bbox = out.getbbox()
    if not bbox:
        return out

    # Band the wipe around this pose's *own* eyes rather than a fixed fraction
    # of its height. Poses where the character is tilted — sliding, hurt — put
    # the head somewhere a fixed band misses, which left those frames with eyes.
    pts = eye_points(pose)
    if pts:
        ey = sum(p[1] for p in pts) / len(pts)
        top = max(bbox[1], int(ey) - 14)
        limit = min(bbox[3], int(ey) + 17)
    else:
        # No eyes visible (a back view): fall back to the head's share of the
        # silhouette. Must stop short of the bare hands, which are skin too and
        # would drag the span across the whole torso.
        top = bbox[1]
        limit = bbox[1] + int((bbox[3] - bbox[1]) * 0.46)

    for y in range(top, min(limit, h)):
        xs = [x for x in range(w) if px[x, y][3] > 150 and _close(px[x, y], skin)]
        if len(xs) < 4:
            continue
        for x in range(min(xs), max(xs) + 1):
            if px[x, y][3] > 150:
                px[x, y] = skin
    return out


# --------------------------------------------------------------------------
# pixel faces
# --------------------------------------------------------------------------

# Expression slots. The engine addresses these by column index; the last column
# of each skin's face atlas is upstream's "intentionally invisible" frame.
NEUTRAL, UP, DOWN, SPARE, BLINK, SQUINT, SMILE, SURPRISE, ALARM, SHOCK = range(10)

INK = (38, 38, 48, 255)
WHITE = (255, 255, 255, 255)


def _blk(d: ImageDraw.ImageDraw, x: int, y: int, w: int, h: int, px: int,
         colour: Colour) -> None:
    """Draw a rectangle snapped to a `px`-sized pixel grid, so it reads chunky."""
    d.rectangle([x, y, x + w * px - 1, y + h * px - 1], fill=colour)


def draw_face(size: tuple[int, int], expression: int, variant: int,
              px: int = 2) -> Image.Image:
    """One expression of one face variant, on transparent.

    Only eyes and a mouth — the head underneath is the character's own skin, so
    anything else here would fight it.

    Everything is measured in tile units against the head it has to sit on,
    which is roughly 22 wide by 24 tall. The tile itself is much larger (46x32,
    inherited from upstream), so drawing to the tile rather than to the head
    puts the eyes out past the ears.
    """
    w, h = size
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = w // 2, h // 2

    def snap(v: float) -> int:
        return int(round(v / px) * px)

    # Variant knobs, in tile units: how far apart the eyes sit and how big they
    # are, plus which mouth is used.
    gap = (4, 5, 4, 6, 5, 4, 6, 5)[variant % 8]
    eye_w = (4, 4, 6, 4, 6, 4, 4, 6)[variant % 8]
    eye_h = (5, 4, 4, 5, 4, 5, 5, 4)[variant % 8]
    mouth_style = variant % 4

    if expression == SHOCK:
        eye_w, eye_h = 6, 6
    if expression in (BLINK, SQUINT):
        eye_h = px

    # Measured off a running frame: the chin is only about 6 units below the eye
    # line on these heads, so the whole face has to stay tight. The anchor sits
    # two units below the eyes (EYES_TO_FACE_CENTRE), which puts the eye centre
    # at cy - 2 and leaves room for a mouth at cy + 2 without it sliding onto
    # the neck.
    eye_top = cy - 2 - eye_h // 2
    if expression == UP:
        eye_top -= px
    elif expression == DOWN:
        eye_top += px

    for sign in (-1, 1):
        # `gap` is the distance from the centre line to the inner edge of an eye.
        ex = cx + gap if sign > 0 else cx - gap - eye_w
        if expression in (BLINK, SQUINT):
            d.rectangle([snap(ex), snap(eye_top + 2),
                         snap(ex) + eye_w - 1, snap(eye_top + 2) + px - 1], fill=INK)
            continue
        d.rectangle([snap(ex), snap(eye_top),
                     snap(ex) + eye_w - 1, snap(eye_top) + eye_h - 1], fill=WHITE)
        # Pupil, dropped low when looking down and raised when looking up.
        py = eye_top + (eye_h - px if expression == DOWN else 0)
        d.rectangle([snap(ex + (eye_w - px) / 2), snap(py),
                     snap(ex + (eye_w - px) / 2) + px - 1, snap(py) + px * 2 - 1],
                    fill=INK)

    my = cy + 1
    if expression in (SHOCK, SURPRISE, ALARM):
        d.rectangle([snap(cx - px), snap(my - px),
                     snap(cx - px) + px * 2 - 1, snap(my - px) + px * 2 - 1], fill=INK)
    elif expression == SMILE or mouth_style == 3:
        d.rectangle([snap(cx - 3), snap(my), snap(cx - 3) + 6 - 1, snap(my) + px - 1],
                    fill=INK)
        d.rectangle([snap(cx - 3 - px), snap(my - px),
                     snap(cx - 3 - px) + px - 1, snap(my - px) + px - 1], fill=INK)
        d.rectangle([snap(cx + 3), snap(my - px),
                     snap(cx + 3) + px - 1, snap(my - px) + px - 1], fill=INK)
    elif mouth_style == 0:
        d.rectangle([snap(cx - 3), snap(my), snap(cx - 3) + 6 - 1, snap(my) + px - 1],
                    fill=INK)
    elif mouth_style == 1:
        d.rectangle([snap(cx - px), snap(my), snap(cx - px) + px * 2 - 1,
                     snap(my) + px - 1], fill=INK)
    else:
        d.rectangle([snap(cx - 2), snap(my), snap(cx - 2) + 4 - 1, snap(my) + px - 1],
                    fill=INK)
        d.rectangle([snap(cx - 2), snap(my - px),
                     snap(cx - 2) + px - 1, snap(my - px) + px - 1], fill=INK)
    return img
