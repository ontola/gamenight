"""Draw the lobby's furniture directly, in the room's own palette.

This replaces a generative step that was not earning its keep. Every piece was
sent to bitforge with the *same* rough sketch — a lit top edge, some seams, a
shadowed base — and at the init strength needed to hold a palette the model
mostly returns the sketch it was given. So an arcade cabinet, a sofa, a hi-fi
and two bookcases all came back as the same tan box, because that is what they
all were before they went. The generator was faithfully reproducing the fact
that we had not decided what these things looked like.

Deciding is cheap. Furniture is rectilinear, this is a 32px grid, and the palette
is fixed — the conditions under which a drawing program is simply the right tool.
Everything here is on-palette by construction, so nothing needs remapping
afterwards, and it is deterministic, so a rebuild does not quietly reshuffle the
room.

One rule drives most of the shapes: **the top of a footprint is what players
stand on**, so it is always a solid board with a lit front edge, and all the
interesting content sits in recesses *below* it. That is also why the wall
shelves are drawn as cubby units rather than thin planks — the whole 32px cell
is solid whether or not it is painted, and a thin plank leaves players standing
on nothing.
"""

from __future__ import annotations

import random

from PIL import Image, ImageDraw

# The room palette, by role. Kept as literals rather than imported from
# `palette.py` so this module renders identically whether or not a remap has
# been run; `palette.check()` asserts the two agree.
DARKEST = (42, 23, 18)
DARKER = (61, 33, 24)
DARK = (74, 42, 28)
MID_DARK = (94, 54, 32)
MID = (124, 64, 40)
MID_LIT = (143, 83, 48)
LIT = (171, 109, 56)
LIGHTEST = (212, 141, 85)

EMBER_DARK = (157, 56, 13)
EMBER = (203, 74, 17)
EMBER_HOT = (245, 130, 25)
EMBER_PALE = (249, 188, 97)
GOLD = (236, 166, 55)
CREAM = (255, 234, 157)

TEAL = (25, 50, 59)
SAGE = (47, 93, 74)
WINE = (146, 17, 52)
NIGHT = (3, 5, 36)
NIGHT_LIT = (33, 30, 86)
NIGHT_COLD = (50, 76, 124)

# Book spines. Deliberately drawn from across the whole palette — a shelf of
# books is the one place in a warm brown room where colour is expected, and
# without it the bookcases read as stacks of firewood.
SPINES = [WINE, SAGE, TEAL, EMBER, GOLD, MID, NIGHT_COLD, LIT, EMBER_DARK, NIGHT_LIT]


def _d(im: Image.Image) -> ImageDraw.ImageDraw:
    return ImageDraw.Draw(im)


def box(im, x0, y0, x1, y1, fill):
    """Inclusive rectangle. Pixel art counts pixels, not half-open ranges."""
    _d(im).rectangle([x0, y0, x1, y1], fill=fill)


def disc(im: Image.Image, cx: int, cy: int, r: int, fill) -> None:
    """A rasterised circle, row by row — hard edges, no antialiasing.

    Pillow's own ellipse smooths its edge, which is the one thing this art
    cannot have; a speaker cone with a grey fringe looks like a mistake next to
    a bookshelf drawn pixel by pixel. Round things are rare here, but a driver
    and a record are both unmistakably round and unreadable as squares.
    """
    for dy in range(-r, r + 1):
        dx = int((r * r - dy * dy) ** 0.5)
        box(im, cx - dx, cy + dy, cx + dx, cy + dy, fill)


def carcass(im: Image.Image, top_board: int = 6) -> None:
    """The shell every cabinet-like piece shares.

    A lit top board that reads as a standing surface, dark sides, a shadowed
    plinth, and a recessed interior for whatever the piece is *for*.
    """
    w, h = im.size
    box(im, 0, 0, w - 1, h - 1, DARKEST)              # interior / recess
    box(im, 0, 0, w - 1, top_board - 1, MID_LIT)      # top board
    box(im, 0, 0, w - 1, 0, LIGHTEST)                 # lit front edge
    box(im, 0, top_board, w - 1, top_board, DARKER)   # shadow under the board
    box(im, 0, 0, 1, h - 1, DARK)                     # left stile
    box(im, w - 2, 0, w - 1, h - 1, DARK)             # right stile
    box(im, 0, h - 3, w - 1, h - 1, DARKER)           # plinth
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)


def books(im: Image.Image, x0: int, x1: int, base: int, height: int, rng: random.Random) -> None:
    """A row of spines standing on `base`, packed left to right."""
    x = x0
    while x <= x1:
        w = rng.choice((2, 2, 3, 3, 4))
        if x + w - 1 > x1:
            w = x1 - x + 1
        if w <= 0:
            break
        tall = height - rng.choice((0, 0, 1, 2))
        c = rng.choice(SPINES)
        box(im, x, base - tall + 1, x + w - 1, base, c)
        # A lighter pixel down the left edge of each spine: at this size it is
        # the only thing that separates one book from the next.
        box(im, x, base - tall + 1, x, base, tuple(min(255, v + 34) for v in c))
        if rng.random() < 0.25:                        # a gilt band on the spine
            box(im, x, base - tall + 2, x + w - 1, base - tall + 2, GOLD)
        x += w


def plant(im: Image.Image, cx: int, base: int, rng: random.Random, big: bool = False) -> None:
    r = 4 if big else 2
    box(im, cx - r, base - 5, cx + r, base, EMBER_DARK)     # pot
    box(im, cx - r, base - 5, cx + r, base - 5, EMBER)      # rim
    box(im, cx - r, base - 4, cx - r, base, (120, 40, 10))  # shaded side
    span = r + 2
    for _ in range(rng.randint(5, 8)):                      # foliage
        dx = rng.randint(-span, span)
        dy = rng.randint(6, 10 if big else 8)
        box(im, cx + dx, base - dy, cx + dx, base - 6, SAGE)
        box(im, cx + dx, base - dy, cx + dx, base - dy, (66, 122, 98))
    box(im, cx - 1, base - (12 if big else 9), cx + 1, base - (10 if big else 8), SAGE)


def cubby(im: Image.Image, x0: int, y0: int, x1: int, y1: int) -> None:
    """A recess: dark ground, with a shelf board under it to sit things on."""
    box(im, x0, y0, x1, y1, DARKEST)
    box(im, x0, y0, x1, y0, (24, 12, 12))       # shadow at the top of the recess
    box(im, x0, y1, x1, y1, MID)                # the board itself
    box(im, x0, y1 - 1, x1, y1 - 1, DARKER)


# ---------------------------------------------------------------- the pieces


def bookcase(w: int, h: int, seed: int, trophy: bool = False) -> Image.Image:
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = random.Random(seed)
    carcass(im)
    top = 8
    bottom = h - 5
    # Rows are sized to *fill* the carcass. Dividing the height and taking the
    # floor left a dead band of bare backboard along the bottom of both
    # bookcases, which read as a cabinet someone had half emptied.
    rows = max(1, (bottom - top) // 22)
    space = (bottom - top) // rows
    for r in range(rows):
        y0 = top + r * space
        y1 = (bottom if r == rows - 1 else y0 + space) - 2
        cubby(im, 3, y0, w - 4, y1)
        if trophy and r == 0:
            box(im, w // 2 - 1, y1 - 6, w // 2 + 1, y1 - 1, GOLD)   # cup
            box(im, w // 2 - 3, y1 - 6, w // 2 + 3, y1 - 5, GOLD)
            box(im, w // 2 - 2, y1 - 1, w // 2 + 2, y1 - 1, EMBER_DARK)
            books(im, 4, w // 2 - 6, y1 - 1, space - 6, rng)
        elif rng.random() < 0.3:
            # A stack of boxes lying flat — board games, which is what the
            # bottom shelf of a bookcase in a games room actually holds.
            y = y1 - 1
            for _ in range(rng.randint(2, 3)):
                c = rng.choice(SPINES)
                box(im, 4, y - 2, w - 6, y, c)
                box(im, 4, y - 2, w - 6, y - 2, tuple(min(255, v + 30) for v in c))
                y -= 3
            books(im, w // 2 + 2, w - 5, y1 - 1, space - 6, rng)
        else:
            books(im, 4, w - 5, y1 - 1, space - 6, rng)
            if rng.random() < 0.4:
                plant(im, w - 8, y1 - 1, rng)
    return im


def sofa(w: int, h: int) -> Image.Image:
    """Seen from behind: the backrest, the arms, and a blanket over one of them.

    The first version was one wine-coloured rectangle with faint seams, and at
    this size that is a slab, not a sofa. What makes it read is *value* — arms
    lighter than the back, a hard shadow where the back meets them, buttoning to
    give the fabric a surface — plus the blanket, which is the only thing in the
    drawing that says somebody sits here.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    # Muted, not neon. The first pass reached for a bright magenta because
    # "red velvet" suggests it, and it was the most saturated thing in a room
    # built out of browns — the sofa stopped being furniture and became a
    # colour swatch. Burgundy sits in the room instead of shouting over it.
    back, arm = (104, 26, 40), (132, 42, 54)
    seam, lit, arm_lit = (68, 14, 26), (158, 58, 70), (176, 76, 86)
    box(im, 0, 0, w - 1, h - 1, back)
    box(im, 0, 0, w - 1, 0, lit)                    # the edge players land on
    box(im, 0, 1, w - 1, 2, (124, 36, 48))
    box(im, 0, 3, w - 1, 3, seam)                   # under the top rail
    arm_w = 11
    for x0, x1 in ((0, arm_w), (w - 1 - arm_w, w - 1)):
        box(im, x0, 0, x1, h - 1, arm)
        box(im, x0, 0, x1, 0, arm_lit)
        box(im, x0, 1, x1, 2, lit)
        # A stepped inner corner: two pixels of stagger is all it takes for an
        # arm to stop being a rectangle and start being upholstery.
        inner = x1 - 1 if x0 == 0 else x0 + 1
        step = 1 if x0 == 0 else -1
        box(im, inner, 4, inner, 5, back)
        box(im, inner - step, 4, inner - step, 4, back)
    box(im, arm_w + 1, 4, arm_w + 1, h - 5, seam)   # where back meets arm
    box(im, w - 2 - arm_w, 4, w - 2 - arm_w, h - 5, seam)
    for i in (1, 2):                                # cushion divisions
        x = arm_w + 2 + (w - 2 * arm_w - 4) * i // 3
        box(im, x, 5, x, h - 5, seam)
        box(im, x + 1, 5, x + 1, h - 5, (120, 38, 50))
    for cy in (10, 19):                             # buttoning
        for cx in range(arm_w + 7, w - arm_w - 4, 10):
            box(im, cx, cy, cx, cy, seam)
            box(im, cx, cy - 1, cx, cy - 1, lit)
    box(im, 0, h - 4, w - 1, h - 1, (60, 12, 24))   # shadow into the floor
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def coffee_table(w: int, h: int) -> Image.Image:
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    box(im, 0, 0, w - 1, 4, MID_LIT)                # top
    box(im, 0, 0, w - 1, 0, LIGHTEST)
    box(im, 0, 5, w - 1, 6, DARK)                   # apron
    for x0 in (3, w - 6):                           # legs
        box(im, x0, 7, x0 + 2, h - 2, DARK)
        box(im, x0, 7, x0, h - 2, MID)
    box(im, 4, h - 8, w - 5, h - 6, MID)            # lower stretcher shelf
    box(im, 6, h - 13, 18, h - 9, EMBER_PALE)       # pizza box
    box(im, 6, h - 13, 18, h - 13, CREAM)
    box(im, 8, h - 11, 16, h - 11, EMBER)
    box(im, w - 16, h - 12, w - 8, h - 9, MID_DARK)  # popcorn bowl
    box(im, w - 16, h - 13, w - 8, h - 13, CREAM)
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def cabinet(w: int, h: int, seed: int) -> Image.Image:
    """A low media cabinet: two doors and an open bay of consoles."""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = random.Random(seed)
    carcass(im, top_board=5)
    bay = (w // 3, w - w // 3)
    for x0, x1 in ((3, bay[0] - 2), (bay[1] + 1, w - 4)):
        box(im, x0, 8, x1, h - 5, MID)              # door
        box(im, x0, 8, x1, 8, LIT)
        box(im, x0, h - 5, x1, h - 5, DARKER)
        # A recessed panel. A cabinet door at this size is otherwise a flat
        # rectangle with a dash on it, and two of them side by side read as a
        # gap in the art rather than as joinery.
        box(im, x0 + 3, 11, x1 - 3, h - 8, MID_DARK)
        box(im, x0 + 3, 11, x1 - 3, 11, DARKER)
        box(im, x0 + 3, 11, x0 + 3, h - 8, DARKER)
        box(im, x0 + 4, 12, x1 - 3, h - 8, MID)
        cx = (x0 + x1) // 2
        box(im, cx - 3, h // 2, cx + 3, h // 2, GOLD)   # handle
        box(im, cx - 3, h // 2 + 1, cx + 3, h // 2 + 1, EMBER_DARK)
    cubby(im, bay[0], 8, bay[1], h - 5)
    x = bay[0] + 2
    while x < bay[1] - 4:                            # consoles and cartridges
        c = rng.choice((TEAL, NIGHT_LIT, DARKER, SAGE))
        box(im, x, h - 10, x + 3, h - 7, c)
        box(im, x, h - 10, x + 3, h - 10, tuple(min(255, v + 40) for v in c))
        if rng.random() < 0.5:
            box(im, x + 1, h - 8, x + 1, h - 8, EMBER_HOT)   # standby light
        x += 5
    return im


def wardrobe(w: int, h: int, seed: int) -> Image.Image:
    """An open wardrobe: hanging outfits, hats on the shelf, a mirror in the door.

    This is where a player becomes somebody — landing on it aims the wall's join
    QR at them, and their phone then sets their name, colour and face. It reads
    as that only if it is standing open with clothes in it; a closed cupboard is
    just another box, and the room already has enough of those.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = random.Random(seed)
    carcass(im, top_board=6)
    inner_x0, inner_x1 = 4, w - 5
    box(im, inner_x0, 9, inner_x1, h - 5, DARKEST)      # the open interior

    # The left leaf, swung open flat against the carcass, with a mirror in it.
    door_w = 11
    box(im, inner_x0, 9, inner_x0 + door_w, h - 5, MID)
    box(im, inner_x0, 9, inner_x0 + door_w, 9, LIT)
    box(im, inner_x0 + 2, 12, inner_x0 + door_w - 2, h - 8, NIGHT_LIT)   # glass
    box(im, inner_x0 + 2, 12, inner_x0 + door_w - 2, 12, (120, 140, 190))
    box(im, inner_x0 + 3, 14, inner_x0 + 4, h - 14, (96, 112, 160))      # a gleam
    box(im, inner_x0 + door_w, 9, inner_x0 + door_w, h - 5, DARKER)

    rail = 12
    box(im, inner_x0 + door_w + 2, rail, inner_x1, rail, GOLD)           # hanging rail
    x = inner_x0 + door_w + 4
    while x < inner_x1 - 3:                                              # outfits
        c = rng.choice(SPINES)
        wide = rng.choice((4, 5, 6))
        drop = rng.randint(12, h - rail - 12)
        box(im, x, rail + 1, x, rail + 2, LIGHTEST)                      # hanger
        box(im, x - 1, rail + 3, x + wide - 2, rail + 3, LIGHTEST)
        box(im, x - 1, rail + 4, x + wide - 2, rail + 3 + drop, c)
        box(im, x - 1, rail + 4, x - 1, rail + 3 + drop, tuple(min(255, v + 34) for v in c))
        box(im, x - 1, rail + 3 + drop, x + wide - 2, rail + 3 + drop,
            tuple(max(0, v - 30) for v in c))
        x += wide + 2

    # Hats on the top shelf, above the rail.
    box(im, inner_x0 + door_w + 2, 9, inner_x1, 9, MID)
    for cx, c in ((inner_x0 + door_w + 7, EMBER), (inner_x0 + door_w + 17, SAGE)):
        if cx + 4 < inner_x1:
            box(im, cx - 4, 8, cx + 4, 8, c)                             # brim
            box(im, cx - 2, 5, cx + 2, 7, c)                             # crown
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def speaker(w: int, h: int) -> Image.Image:
    """A floorstander: cabinet, two drivers, a port. Reads at one tile wide."""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    box(im, 0, 0, w - 1, h - 1, DARK)
    box(im, 0, 0, w - 1, 0, LIGHTEST)               # the top players land on
    box(im, 0, 1, w - 1, 2, MID_LIT)
    box(im, 0, 3, w - 1, 3, DARKEST)
    box(im, 2, 5, w - 3, h - 4, DARKER)             # baffle
    box(im, 2, 5, w - 3, 5, MID_DARK)
    cx = w // 2
    for cy, r in ((16, 6), (h - 20, 10)):           # tweeter over woofer
        disc(im, cx, cy, r, (30, 16, 16))           # surround
        disc(im, cx, cy, r - 1, (58, 34, 28))       # cone
        disc(im, cx, cy, max(1, r - 4), (38, 22, 20))
        disc(im, cx, cy, max(1, r // 3), MID_DARK)  # dust cap
        box(im, cx - r + 1, cy - r + 1, cx + r - 1, cy - r + 1, (74, 46, 36))
    box(im, cx - 3, h - 8, cx + 3, h - 6, DARKEST)  # bass port
    box(im, cx - 3, h - 8, cx + 3, h - 8, (20, 10, 12))
    box(im, 0, h - 3, w - 1, h - 1, DARKER)
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def jukebox(w: int, h: int, seed: int) -> Image.Image:
    """A record cupboard with a deck and an amp standing on it.

    Two tiles tall, and the split is the point: the bottom half is storage full
    of sleeves, the top half is the machine. A turntable at knee height on a
    one-tile sideboard was the old shape, and nobody owns one of those.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = random.Random(seed)
    deck_h = h // 2
    box(im, 0, 0, w - 1, h - 1, DARK)

    # --- the deck, on top
    box(im, 0, 0, w - 1, 0, LIGHTEST)               # the lid players stand on
    box(im, 0, 1, w - 1, 3, MID_LIT)
    box(im, 0, 4, w - 1, 4, DARKER)
    plinth = deck_h - 3
    box(im, 3, 6, w // 2 + 2, plinth, DARKEST)      # turntable plinth
    box(im, 3, 6, w // 2 + 2, 6, MID_DARK)
    pcx, pcy = (3 + w // 2 + 2) // 2 - 2, (6 + plinth) // 2
    rec = min(10, (plinth - 8) // 2)
    disc(im, pcx, pcy, rec + 1, (26, 12, 14))                   # platter rim
    disc(im, pcx, pcy, rec, (16, 8, 10))                        # the record
    for gr in range(3, rec, 3):                                 # grooves
        disc(im, pcx, pcy, gr, (16, 8, 10) if gr % 2 else (34, 20, 18))
    disc(im, pcx, pcy, max(2, rec // 3), GOLD)                  # label
    box(im, pcx, pcy, pcx, pcy, DARKEST)                        # spindle
    box(im, pcx + rec + 3, pcy - rec, pcx + rec + 4, pcy - 1, LIGHTEST)   # tonearm
    box(im, pcx + 2, pcy - 1, pcx + rec + 4, pcy, LIGHTEST)
    box(im, pcx + 2, pcy, pcx + 3, pcy + 1, MID_DARK)           # the cartridge
    # The amplifier beside it: a dark faceplate, a lit meter, and a row of dials.
    amp_x0 = w // 2 + 6
    box(im, amp_x0, 6, w - 4, plinth, DARKER)
    box(im, amp_x0, 6, w - 4, 6, MID_LIT)
    box(im, amp_x0 + 2, 9, w - 7, plinth - 8, NIGHT)          # VU meter
    box(im, amp_x0 + 2, 9, w - 7, 9, DARKEST)
    for i in range(6):                                        # its needles
        x = amp_x0 + 4 + i * 3
        if x < w - 8:
            bars = (2, 4, 3, 5, 3, 2)[i]
            box(im, x, plinth - 10 - bars, x + 1, plinth - 10,
                EMBER_HOT if bars > 3 else EMBER_DARK)
    for i in range(3):
        cx = amp_x0 + 4 + i * 6
        if cx + 2 < w - 4:
            box(im, cx - 2, plinth - 6, cx + 2, plinth - 2, MID_DARK)
            box(im, cx - 2, plinth - 6, cx + 2, plinth - 6, LIGHTEST)
            box(im, cx, plinth - 5, cx, plinth - 4, DARKEST)

    # --- the cupboard, below
    #
    # Deliberately plain: the music screen element is drawn over this face at
    # runtime, so anything detailed here is work nobody will ever see. Only the
    # margins around the screen show, and they get the joinery.
    box(im, 0, deck_h, w - 1, deck_h, DARKEST)
    box(im, 0, deck_h + 1, w - 1, deck_h + 1, MID_LIT)
    box(im, 0, deck_h + 2, w - 1, h - 1, MID)
    box(im, 3, deck_h + 4, w - 4, h - 4, MID_DARK)      # a recessed panel
    box(im, 3, deck_h + 4, w - 4, deck_h + 4, DARKER)
    box(im, 3, deck_h + 4, 3, h - 4, DARKER)
    box(im, 4, deck_h + 5, w - 4, h - 4, DARK)
    for x in (6, w - 7):                                # sleeves in the margins
        c = rng.choice(SPINES)
        box(im, x - 1, deck_h + 7, x + 1, h - 7, c)
        box(im, x - 1, deck_h + 7, x - 1, h - 7, tuple(min(255, v + 40) for v in c))
    box(im, 0, h - 3, w - 1, h - 1, DARKER)
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def doorway(w: int, h: int) -> Image.Image:
    """The way out: an open door, and a lit hall on the other side of it.

    The light is the entire trick. The first version was a dark opening with a
    thin strip of glow along the bottom, and standing next to a bookcase it read
    as a tall cabinet — players would have walked straight past the only way to
    leave. A hall has to be *brighter* than the room it opens off, and the open
    leaf standing back against the reveal is what makes it a door somebody left
    open rather than a hole in the wall.

    No threshold across the bottom, either. A rail there is the single detail
    that turns a doorway back into a piece of furniture.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    jamb, head = 3, 11
    inner_x0, inner_x1 = jamb, w - 1 - jamb

    # The hall: banded, brightening towards the floor, because the light is
    # spilling in from a lamp down there rather than from its ceiling.
    box(im, inner_x0, head, inner_x1, h - 1, (58, 34, 24))
    for i, c in enumerate(((78, 48, 28), (104, 64, 36), (132, 84, 46))):
        top = head + 6 + i * 9
        box(im, inner_x0 + 1, top, inner_x1 - 1, h - 1, c)
    box(im, inner_x0, head, inner_x1, head + 1, (34, 20, 18))     # reveal shadow
    box(im, inner_x0, head, inner_x0 + 1, h - 1, (44, 26, 20))
    # Floor of the hall, with a skirting line above it.
    box(im, inner_x0 + 1, h - 8, inner_x1 - 1, h - 1, (150, 98, 56))
    box(im, inner_x0 + 1, h - 9, inner_x1 - 1, h - 9, (58, 34, 24))
    box(im, inner_x0 + 1, h - 8, inner_x1 - 1, h - 8, (182, 124, 72))

    # The open leaf, stood back against the left reveal.
    leaf = jamb + 7
    box(im, inner_x0, head + 2, leaf, h - 1, MID)
    box(im, inner_x0, head + 2, inner_x0, h - 1, LIT)
    box(im, leaf, head + 2, leaf, h - 1, DARKEST)
    for py in (head + 8, h - 30):
        box(im, inner_x0 + 2, py, leaf - 2, py + 16, MID_DARK)
        box(im, inner_x0 + 2, py, leaf - 2, py, DARKER)
        box(im, inner_x0 + 2, py, inner_x0 + 2, py + 16, DARKER)
    box(im, leaf - 2, h // 2, leaf - 1, h // 2 + 1, GOLD)         # the handle

    # The frame: two jambs and a deep head, in the room's wood.
    box(im, 0, 0, jamb - 1, h - 1, MID)
    box(im, w - jamb, 0, w - 1, h - 1, MID)
    box(im, 0, 0, w - 1, head - 1, MID)
    box(im, 1, head, 1, h - 1, MID_LIT)                  # moulding on each jamb
    box(im, w - 2, head, w - 2, h - 1, MID_DARK)
    box(im, 0, 0, w - 1, 0, LIGHTEST)                    # lit top of the frame
    box(im, 0, 1, w - 1, 1, LIT)
    box(im, 0, head - 1, w - 1, head - 1, DARKEST)
    box(im, 0, 0, 0, h - 1, LIT)
    box(im, w - 1, 0, w - 1, h - 1, DARKER)

    # An EXIT sign on the head. A doorway on its own is architecture; this is
    # what makes it an instruction.
    sx = w // 2
    box(im, sx - 12, 2, sx + 11, head - 3, DARKEST)
    box(im, sx - 11, 3, sx + 10, head - 4, SAGE)
    box(im, sx - 11, 3, sx + 10, 3, (78, 146, 116))
    for dx in (-9, -4, 1, 6):                            # four illegible letters
        box(im, sx + dx, 4, sx + dx + 2, head - 5, CREAM)
    return im


def hifi(w: int, h: int) -> Image.Image:
    """A sideboard whose face is mostly display — the music screen lands here."""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    carcass(im, top_board=5)
    box(im, 3, 8, w - 4, h - 5, DARKER)             # walnut front
    box(im, 3, 8, w - 4, 8, MID_LIT)
    # A speaker grille at each end, a bank of dials, and the display between.
    # The music screen element is drawn over the middle at runtime, so the
    # detail lives out at the ends where it will still be visible.
    for x0 in (5, w - 21):
        box(im, x0, 10, x0 + 15, h - 7, DARKEST)
        for gy in range(12, h - 8, 2):
            for gx in range(x0 + 2, x0 + 14, 2):
                box(im, gx, gy, gx, gy, (58, 30, 24))
        box(im, x0, 10, x0 + 15, 10, MID_DARK)
    for i in range(3):                              # dials
        cx = w // 2 - 8 + i * 8
        box(im, cx - 2, h - 12, cx + 2, h - 8, MID_DARK)
        box(im, cx - 2, h - 12, cx + 2, h - 12, LIGHTEST)
        box(im, cx, h - 11, cx, h - 10, DARKEST)
    box(im, w // 2 - 12, 11, w // 2 + 12, h - 15, NIGHT)   # display well
    box(im, w // 2 - 12, 11, w // 2 + 12, 11, DARKEST)
    for i in range(7):                              # a frozen spectrum
        x = w // 2 - 10 + i * 3
        bars = (2, 4, 3, 5, 2, 4, 3)[i]
        box(im, x, h - 17 - bars, x + 1, h - 17, EMBER_HOT if bars > 3 else EMBER_DARK)
    return im


def arcade(w: int, h: int) -> Image.Image:
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    box(im, 0, 0, w - 1, h - 1, DARK)
    box(im, 0, 0, w - 1, 0, LIGHTEST)               # the top players stand on
    box(im, 0, 1, w - 1, 3, MID_LIT)
    box(im, 0, 4, w - 1, 4, DARKEST)
    box(im, 2, 6, w - 3, 11, EMBER_PALE)            # lit marquee
    box(im, 2, 6, w - 3, 6, CREAM)
    box(im, 2, 11, w - 3, 11, EMBER)
    box(im, 4, 8, w - 5, 9, EMBER_DARK)             # lettering, unreadable by design
    box(im, 3, 14, w - 4, h - 22, DARKEST)          # screen bezel
    box(im, 5, 16, w - 6, h - 24, NIGHT)
    for y in range(17, h - 24, 3):                  # the tube's own texture
        box(im, 5, y, w - 6, y, NIGHT_LIT)
    # Something is playing on it. Ranks of little invaders and a ship below say
    # "arcade" instantly; the earlier version was horizontal scanlines only, and
    # a dark box with stripes reads as a broken television.
    for row, c in enumerate((EMBER_HOT, GOLD, SAGE)):
        y = 19 + row * 5
        for i in range(5):
            x = 8 + i * 10
            if x + 4 > w - 8:
                break
            box(im, x, y, x + 4, y + 1, c)          # body
            box(im, x + 1, y - 1, x + 1, y - 1, c)  # antennae
            box(im, x + 3, y - 1, x + 3, y - 1, c)
            box(im, x, y + 2, x, y + 2, c)          # legs
            box(im, x + 4, y + 2, x + 4, y + 2, c)
    ship = w // 2 - 2
    box(im, ship, h - 28, ship + 4, h - 27, NIGHT_COLD)
    box(im, ship + 2, h - 29, ship + 2, h - 29, CREAM)
    box(im, ship + 2, h - 33, ship + 2, h - 31, CREAM)   # its shot, in flight
    box(im, 3, h - 20, w - 4, h - 12, MID)          # control panel
    box(im, 3, h - 20, w - 4, h - 20, LIT)
    box(im, 9, h - 18, 10, h - 15, DARKEST)         # joystick
    box(im, 8, h - 19, 11, h - 18, WINE)
    for i, c in enumerate((EMBER_HOT, GOLD, SAGE, NIGHT_COLD)):
        box(im, 16 + i * 6, h - 17, 18 + i * 6, h - 15, c)
    box(im, 0, h - 10, w - 1, h - 1, DARKER)        # base
    box(im, 0, h - 10, 1, h - 1, WINE)              # side art, just a stripe
    box(im, w - 2, h - 10, w - 1, h - 1, WINE)
    box(im, 0, h - 1, w - 1, h - 1, DARKEST)
    return im


def wall_shelf(w: int, h: int, seed: int, kind: str) -> Image.Image:
    """A cubby unit, not a plank.

    The plank version left the top 24px of a solid cell unpainted, so players
    stood on empty air above a thin board. A unit fills its footprint honestly
    and puts the contents where they can be seen — under the surface being
    stood on, which is also where a shelf's contents actually are.
    """
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rng = random.Random(seed)
    carcass(im, top_board=5)
    cubby(im, 3, 7, w - 4, h - 5)
    base = h - 6
    # Every shelf fills its width. Half-empty shelves looked less like a room
    # somebody lives in and more like a shop that had been cleared out — and at
    # a glance across a lobby, a sparse shelf reads as a missing texture.
    if kind == "records":
        x = 5
        while x < w - 26:                           # sleeves, filed upright
            c = rng.choice(SPINES)
            box(im, x, base - 14, x + 3, base, c)
            box(im, x, base - 14, x, base, tuple(min(255, v + 40) for v in c))
            box(im, x, base - 14, x + 3, base - 14, tuple(max(0, v - 24) for v in c))
            x += rng.choice((4, 5, 5))
        box(im, w - 24, base - 10, w - 5, base, DARKER)      # the deck
        box(im, w - 24, base - 10, w - 5, base - 10, MID_DARK)
        box(im, w - 21, base - 8, w - 9, base - 1, DARKEST)  # platter
        box(im, w - 17, base - 6, w - 13, base - 4, GOLD)    # label
        box(im, w - 8, base - 8, w - 7, base - 3, MID_LIT)   # tonearm
    elif kind == "plants":
        # Three, at different sizes, rather than a regular row — evenly spaced
        # identical pots read as a fence, not as somebody's plants.
        for cx, big in ((12, True), (w // 2 + 2, False), (w - 16, True)):
            plant(im, cx, base, rng, big=big)
        for x in range(8, w - 8):                   # trailing over the edge
            if rng.random() < 0.3:
                box(im, x, base + 1, x, base + rng.randint(1, 3), SAGE)
    elif kind == "magazines":
        x = 5
        while x < w - 8:                            # several short stacks
            wide = rng.randint(12, 20)
            y = base
            for _ in range(rng.randint(3, 6)):
                c = rng.choice(SPINES)
                box(im, x, y - 2, min(w - 6, x + wide), y, c)
                box(im, x, y - 2, min(w - 6, x + wide), y - 2,
                    tuple(min(255, v + 30) for v in c))
                y -= 3
            x += wide + 3
    elif kind == "trophies":
        # Four, with handles. Without the handles a cup at this size is a stem
        # and a blob, which reads as a mushroom — the previous shelf looked like
        # somebody was growing them.
        for i, cx in enumerate((12, 27, 44, 58)):
            if cx > w - 10:
                break
            top = base - (8 + (i % 3) * 3)
            box(im, cx - 3, top, cx + 3, top + 3, GOLD)          # bowl
            box(im, cx - 3, top, cx + 3, top, CREAM)
            box(im, cx - 5, top + 1, cx - 5, top + 2, GOLD)      # handles
            box(im, cx + 5, top + 1, cx + 5, top + 2, GOLD)
            box(im, cx - 1, top + 4, cx + 1, base - 3, GOLD)     # stem
            box(im, cx - 3, base - 2, cx + 3, base, EMBER_DARK)  # plinth
            box(im, cx - 3, base - 2, cx + 3, base - 2, EMBER)
        box(im, w - 14, base - 8, w - 7, base, EMBER_PALE)       # a small lamp
        box(im, w - 16, base - 11, w - 5, base - 9, CREAM)
        box(im, w - 11, base - 8, w - 10, base - 1, GOLD)
    elif kind == "games":
        x = 5
        while x < w - 10:
            wide = rng.randint(14, 22)
            y = base
            for _ in range(rng.randint(3, 5)):
                c = rng.choice(SPINES)
                box(im, x, y - 3, min(w - 6, x + wide), y, c)
                box(im, x, y - 3, min(w - 6, x + wide), y - 3,
                    tuple(min(255, v + 30) for v in c))
                box(im, x, y - 3, x, y, tuple(max(0, v - 30) for v in c))
                y -= 4
            x += wide + 4
    else:                                            # books, with a plant
        books(im, 5, w - 14, base, 15, rng)
        plant(im, w - 8, base, rng)
    return im


# What each named piece in `layout.py` is. Keeping this here rather than on
# `Piece` leaves the layout file about shape and reachability, which is what it
# is good at, and keeps every decision about *appearance* in one place.
KINDS = {
    "bookshelf_tall": lambda w, h: bookcase(w, h, 1),
    "bookshelf_low": lambda w, h: bookcase(w, h, 2, trophy=True),
    "sofa": sofa,
    "coffee_table": coffee_table,
    "tv_cabinet": lambda w, h: cabinet(w, h, 3),
    "wardrobe": lambda w, h: wardrobe(w, h, 4),
    "jukebox": lambda w, h: jukebox(w, h, 5),
    "speaker_l": speaker,
    "speaker_r": speaker,
    "exit_door": doorway,
    "arcade": arcade,
    "shelf_a": lambda w, h: wall_shelf(w, h, 11, "books"),
    "shelf_b": lambda w, h: wall_shelf(w, h, 12, "games"),
    "shelf_c": lambda w, h: wall_shelf(w, h, 13, "records"),
    "shelf_d": lambda w, h: wall_shelf(w, h, 14, "trophies"),
    "shelf_e": lambda w, h: wall_shelf(w, h, 15, "plants"),
    "shelf_f": lambda w, h: wall_shelf(w, h, 16, "magazines"),
}


def draw(piece) -> Image.Image:
    w, h = piece.px
    maker = KINDS.get(piece.name)
    if maker is None:
        raise SystemExit(f"no drawing for piece {piece.name!r}; add one to KINDS")
    im = maker(w, h)
    if im.size != (w, h):
        raise SystemExit(f"{piece.name}: drew {im.size}, footprint is {(w, h)}")
    return im


def floor_tile() -> Image.Image:
    """Board flooring: long planks along the room, lit at the top edge.

    Two courses, not three, and one butt joint per course. The first attempt had
    short bays and frequent joints, which at 32px is indistinguishable from
    brickwork — and the floor of a living room reading as masonry was half of why
    the ground plane fought the furniture standing on it.
    """
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    rng = random.Random(99)
    box(im, 0, 0, 31, 31, MID)
    box(im, 0, 0, 31, 0, LIGHTEST)                   # the surface players walk on
    box(im, 0, 1, 31, 2, MID_LIT)
    box(im, 0, 3, 31, 3, DARK)
    box(im, 0, 17, 31, 17, DARKER)                   # the one course line
    box(im, 0, 18, 31, 18, MID_LIT)
    for _ in range(18):                              # grain
        x, y = rng.randint(0, 27), rng.choice(list(range(5, 17)) + list(range(19, 31)))
        box(im, x, y, x + rng.randint(2, 5), y, MID_DARK)
    box(im, 21, 4, 21, 16, DARKER)                   # butt joints, staggered
    box(im, 6, 19, 6, 31, DARKER)
    return im


def wall_tile() -> Image.Image:
    """Dark brick, to match the wall the background already paints."""
    im = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    box(im, 0, 0, 31, 31, (64, 24, 24))
    for row in range(4):
        y = row * 8
        box(im, 0, y, 31, y, (30, 9, 19))
        offset = 0 if row % 2 == 0 else 8
        for x in range(offset, 32, 16):
            box(im, x, y + 1, x, y + 7, (30, 9, 19))
        box(im, 0, y + 1, 31, y + 1, (71, 31, 28))
    return im


if __name__ == "__main__":
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import layout  # noqa: E402

    scale = 6
    pieces = [(p.name, draw(p)) for p in layout.ALL]
    pieces += [("floor", floor_tile()), ("wall", wall_tile())]
    pad, cols = 10, 4
    cw = max(im.width for _, im in pieces) * scale + pad
    ch = max(im.height for _, im in pieces) * scale + pad + 14
    rows = (len(pieces) + cols - 1) // cols
    sheet = Image.new("RGBA", (cw * cols + pad, ch * rows + pad), (40, 18, 20, 255))
    for i, (name, im) in enumerate(pieces):
        big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        x = pad + (i % cols) * cw
        y = pad + (i // cols) * ch
        ImageDraw.Draw(sheet).text((x, y), name, fill=(230, 200, 160))
        sheet.alpha_composite(big, (x, y + 14))
    out = Path(__file__).resolve().parent / "staging" / "furniture_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(out)
    print(f"sheet -> {out}")
