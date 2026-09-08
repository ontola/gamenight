"""Lay the lobby out as furniture, and write it back into the map.

The platforms stop being abstract ledges and become the things a living room is
made of: bookshelves, a sofa back, a TV cabinet, an arcade machine, a hi-fi
sideboard. Each piece declares its footprint in tiles, and that footprint is
both the collision box *and* the canvas its art gets generated on — so the art
cannot be the wrong size for the thing players stand on, which is exactly how
the painted-background version went wrong.

Scale falls out of this for free. A bookshelf is four tiles tall because that is
what a bookshelf is next to a person, and a player is 54px — a little under two
tiles. Nothing has to be talked into the right size by a prompt.

Run with --write to update the map, without to preview only. The map is in git;
`git diff` is the review.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import yaml
from PIL import Image, ImageDraw

ASSETS = Path(__file__).resolve().parents[2] / "assets"
MAP = ASSETS / "map" / "levels" / "gamenight_lobby.map.yaml"
STAGING = Path(__file__).resolve().parent / "staging" / "structure"

TILE = 32
GRID_W, GRID_H = 40, 24
FLOOR_TOP = 3          # first free row above the floor slab (rows 1-2 are floor)


class Piece:
    """One piece of furniture: a footprint in tiles, and what it is."""

    def __init__(self, name: str, x: int, y: int, w: int, h: int, prompt: str,
                 hosts: str | None = None, solid: bool = True):
        self.name, self.x, self.y, self.w, self.h = name, x, y, w, h
        self.prompt = prompt
        self.hosts = hosts          # interactive element that belongs to it
        # Not everything with a footprint is something to stand on. The exit
        # doorway occupies tiles so that its art is placed and sliced like any
        # other piece, but players have to be able to walk *into* it, so its
        # tiles are written to the map as Empty.
        self.solid = solid

    @property
    def px(self) -> tuple[int, int]:
        return self.w * TILE, self.h * TILE

    def top_world_y(self) -> float:
        return (self.y + self.h) * TILE

    def centre_world_x(self) -> float:
        return (self.x + self.w / 2) * TILE


# Ground floor, left to right.
#
# Scale is derived, not guessed. The player is 54px tall, which is 1.7 tiles; if
# that is a 1.7m person then **one tile is one metre**, and every footprint below
# is just the real object in metres. Getting this wrong is what produced a
# four-metre bookcase on the first pass.
FURNITURE = [
    Piece("bookshelf_tall", 3, FLOOR_TOP, 2, 2,
          "a tall wooden bookcase packed with colourful books and a few board "
          "game boxes, seen straight on"),
    Piece("sofa", 7, FLOOR_TOP, 3, 1,
          "the back and arms of a plump red velvet sofa seen straight on, "
          "cushions visible above the backrest"),
    # The wardrobe is where you become somebody: land on it and the wall's join
    # QR points at you, so your phone is what sets your name, colour and face.
    # It used to be an unmarked mat on the floor, which said nothing about what
    # it was for — a wardrobe says "this is where you get your look" without a
    # word of UI.
    Piece("wardrobe", 10, FLOOR_TOP, 2, 2,
          "an open wooden wardrobe with hanging outfits, hats and a mirror",
          hosts="sign_in"),
    Piece("coffee_table", 12, FLOOR_TOP, 2, 1,
          "a low wooden coffee table with a pizza box and a bowl of popcorn "
          "on top, seen straight on"),
    Piece("tv_cabinet", 16, FLOOR_TOP, 3, 1,
          "a low wooden media cabinet with games consoles and cartridges on "
          "its shelf, flat front, no television on top",
          hosts="next_game"),
    Piece("arcade", 22, FLOOR_TOP, 2, 2,
          "an upright arcade cabinet seen straight on, glowing marquee at the "
          "top, dark screen, joystick and coloured buttons"),
    # The jukebox, as a real stereo rather than a sideboard: a record cupboard
    # with a valve amp and a turntable standing on it, flanked by a speaker at
    # each end. Two tiles tall because a deck at knee height is not a thing
    # anyone owns, and because the top of the cupboard is where the deck goes.
    Piece("speaker_l", 24, FLOOR_TOP, 1, 2, "a tall wooden hi-fi speaker"),
    Piece("jukebox", 25, FLOOR_TOP, 5, 2,
          "a record cupboard with a valve amplifier and a vintage turntable "
          "standing on top of it",
          hosts="music"),
    Piece("speaker_r", 30, FLOOR_TOP, 1, 2, "a tall wooden hi-fi speaker"),
    Piece("bookshelf_low", 31, FLOOR_TOP, 2, 2,
          "a wooden bookshelf with games and a trophy, slightly shorter, "
          "seen straight on"),
    # The way out. Walk into it and you leave the party; it is deliberately at
    # the far end, past everything else, so nobody arrives at it by accident on
    # their way between the sofa and the arcade.
    Piece("exit_door", 34, FLOOR_TOP, 2, 3,
          "an open doorway out of the room, warm light in the hall beyond",
          hosts="exit", solid=False),
]

# Upper level: wall shelves, and they have to be *reachable*. The jump apex is
# 101px — 3.2 tiles — so each step up is three tiles from the surface below it,
# and the ground furniture is the first rung. Scattering them at pretty heights
# would make half the room decorative.
SHELVES = [
    Piece("shelf_a", 5, 5, 3, 1,
          "a wooden wall shelf with a row of books and a small plant"),
    Piece("shelf_b", 11, 8, 3, 1,
          "a wooden wall shelf with stacked board games"),
    Piece("shelf_c", 17, 11, 3, 1,
          "a wooden wall shelf with a record player and records"),
    Piece("shelf_d", 23, 7, 3, 1,
          "a wooden wall shelf with trophies and a small lamp"),
    Piece("shelf_e", 29, 10, 3, 1,
          "a wooden wall shelf with plants trailing over the edge"),
    Piece("shelf_f", 34, 13, 3, 1,
          "a wooden wall shelf with a stack of magazines"),
]

ALL = FURNITURE + SHELVES


def floor_and_walls() -> list[tuple[int, int]]:
    cells = [(x, y) for x in range(1, GRID_W - 1) for y in (1, 2)]
    cells += [(x, y) for x in (1, GRID_W - 2) for y in range(3, GRID_H - 1)]
    return cells


def piece_cells() -> list[tuple[int, int]]:
    return [(px, py) for p in ALL
            for px in range(p.x, p.x + p.w)
            for py in range(p.y, p.y + p.h)]


def build_tiles() -> list[dict]:
    """Every solid cell, tagged with the role its art will be sliced for."""
    solid = set(floor_and_walls()) | {
        c for p in ALL if p.solid
        for c in [(px, py) for px in range(p.x, p.x + p.w)
                  for py in range(p.y, p.y + p.h)]
    }
    tiles = []
    for (x, y) in sorted(solid):
        # Index is assigned later by the art step; role is what matters here.
        top = (x, y + 1) not in solid
        left = (x - 1, y) in solid
        right = (x + 1, y) in solid
        if not top:
            idx = 18                      # interior fill
        elif left and right:
            idx = 1                       # mid
        elif right:
            idx = 0                       # left end
        elif left:
            idx = 2                       # right end
        else:
            idx = 4                       # single
        tiles.append({"pos": [x, y], "idx": idx, "collision": "Solid"})
    return tiles


def element_positions() -> dict[str, list[float]]:
    """Put each interactive element on the furniture that owns it."""
    by_name = {p.name: p for p in ALL}
    tv, juke = by_name["tv_cabinet"], by_name["jukebox"]
    shelf, wardrobe, door = by_name["bookshelf_tall"], by_name["wardrobe"], by_name["exit_door"]
    return {
        # The start button sits on the cabinet top; its screen is drawn below it.
        "next_game": [tv.centre_world_x(), tv.top_world_y() + 7],
        # The jukebox's screen sits in the amplifier's face, and the transport
        # buttons stand on the deck beside it — the same relationship a real
        # stack has, rather than a panel floating on a sideboard front.
        "music_screen": [juke.centre_world_x(), juke.top_world_y() - 44],
        "music_pause": [juke.centre_world_x() - 36, juke.top_world_y() + 7],
        "music_skip": [juke.centre_world_x() + 36, juke.top_world_y() + 7],
        # Join QR hangs on the wall above the tall bookcase; standing on the
        # shelf next to it is how you reach it.
        "qr_sign": [shelf.centre_world_x() + 40, 11.5 * TILE],
        # Sign-in is the wardrobe: land on top of it to claim the wall's QR,
        # then scan it to choose your name, colour and face.
        "sign_in": [wardrobe.centre_world_x(), wardrobe.top_world_y() + 7],
        # The exit trigger fills the doorway's opening, standing on the floor.
        "exit_door": [door.centre_world_x(), (door.y + 1.5) * TILE],
    }


JUMP_APEX = 101.0      # v^2 / 2g from jump_speed 660, gravity 2160
# Horizontal reach at the apex: walk_speed 360 over the ~0.3s rise is about
# 110px, so a step across may be up to three tiles as well as three tiles up.
REACH_TILES = 3


def check_reachable() -> list[str]:
    """Every platform must be reachable by jumping from some lower surface.

    Worth asserting rather than eyeballing: the first pass put the shelves at
    pretty heights and left half of them 200px above anything, which looks fine
    in a layout diagram and is unplayable.
    """
    # Only solid pieces are surfaces, and only solid pieces need reaching. The
    # doorway is neither: you walk through it along the floor.
    solid = [p for p in ALL if p.solid]
    surfaces = [("floor", FLOOR_TOP * TILE, 1, GRID_W - 2)]
    surfaces += [(p.name, p.top_world_y(), p.x, p.x + p.w) for p in solid]
    problems = []
    for p in solid:
        top = p.top_world_y()
        ok = any(
            s_top < top <= s_top + JUMP_APEX
            and s_x0 - REACH_TILES <= p.x + p.w and s_x1 + REACH_TILES >= p.x
            for name, s_top, s_x0, s_x1 in surfaces if name != p.name
        )
        if not ok:
            problems.append(f"{p.name} top={top:.0f} unreachable")
    return problems


def apply(write: bool) -> None:
    doc = yaml.safe_load(MAP.read_text())
    tiles = build_tiles()
    for layer in doc["layers"]:
        if layer.get("id") == "main layer":
            layer["tiles"] = tiles
    moves = element_positions()
    for layer in doc["layers"]:
        for el in layer.get("elements") or []:
            key = el["element"].split("/")[-1].replace(".element.yaml", "")
            key = "music_screen" if key == "music_screen" else key
            if key in moves:
                el["pos"] = [float(v) for v in moves[key]]
    print(f"tiles: {len(tiles)}   furniture: {len(FURNITURE)}   shelves: {len(SHELVES)}")
    problems = check_reachable()
    print("reachability: OK" if not problems else "reachability PROBLEMS:")
    for msg in problems:
        print(f"  ! {msg}")
    for name, pos in moves.items():
        print(f"  {name:14s} -> {pos[0]:.0f},{pos[1]:.0f}")
    if write:
        MAP.write_text(yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))
        print(f"written: {MAP}")
    preview(tiles)


def preview(tiles: list[dict]) -> None:
    img = Image.new("RGB", (GRID_W * TILE, GRID_H * TILE), (26, 22, 30))
    d = ImageDraw.Draw(img)
    for t in tiles:
        x, y = t["pos"]
        d.rectangle([x * TILE, (GRID_H - 1 - y) * TILE,
                     x * TILE + TILE - 1, (GRID_H - 1 - y) * TILE + TILE - 1],
                    fill=(96, 68, 44), outline=(52, 36, 24))
    for p in ALL:
        x0, y0 = p.x * TILE, (GRID_H - p.y - p.h) * TILE
        d.rectangle([x0, y0, x0 + p.w * TILE - 1, y0 + p.h * TILE - 1],
                    outline=(255, 176, 92), width=2)
        d.text((x0 + 3, y0 + 3), f"{p.name} {p.w}x{p.h}", fill=(255, 220, 170))
    for name, pos in element_positions().items():
        px, py = pos[0], GRID_H * TILE - pos[1]
        d.rectangle([px - 16, py - 8, px + 16, py + 8], outline=(120, 200, 255), width=2)
        d.text((px - 16, py - 20), name, fill=(170, 220, 255))
    # A player, for scale.
    d.rectangle([11 * TILE - 16, (GRID_H - FLOOR_TOP) * TILE - 54,
                 11 * TILE + 16, (GRID_H - FLOOR_TOP) * TILE],
                outline=(120, 255, 140), width=2)
    d.text((11 * TILE - 16, (GRID_H - FLOOR_TOP) * TILE - 66), "player 54px",
           fill=(150, 255, 170))
    STAGING.mkdir(parents=True, exist_ok=True)
    out = STAGING / "layout.png"
    img.save(out)
    print(f"preview -> {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    apply(ap.parse_args().write)
