"""Infer each tile index's structural role from how the levels actually use it.

Reading the role out of the original art turned out to be unreliable — the cap
that marks a walkable surface is rendered differently in each tileset, and in
`ground_metal` and `ground_wood` it isn't lighter than the body at all, so a
luminance test finds nothing.

Level usage is the better signal and is what we actually care about preserving:
a tile the designer placed with open space above it is a surface, one with
another solid tile above it is interior fill. That is exactly the distinction
Kenney's Left/Mid/Right vs Center tiles encode, so the roles map straight over.

Where one index is used in more than one context, the majority context wins.
"""

from __future__ import annotations

import collections
import re
from pathlib import Path

LEVELS = Path(__file__).resolve().parents[2] / "assets" / "map" / "levels"

# Roles, named to match Kenney's tile suffixes.
LEFT, MID, RIGHT, CENTER, SOLO = "Left", "Mid", "Right", "Center", "Solo"


def parse_layers(path: Path) -> list[tuple[str, list[tuple[int, int, int]]]]:
    """Yield (tileset, [(x, y, idx), ...]) for each tile layer in a map."""
    out: list[tuple[str, list[tuple[int, int, int]]]] = []
    tileset: str | None = None
    tiles: list[tuple[int, int, int]] = []
    pos: list[int] = []
    in_tiles = False

    for line in path.read_text().splitlines():
        m = re.search(r"tilemap:\s*(\S+)", line)
        if m:
            if tileset and tiles:
                out.append((tileset, tiles))
            tileset = m.group(1).split("/")[-1].replace(".atlas.yaml", "")
            tiles, in_tiles = [], False
            continue
        if re.match(r"^\s*-?\s*pos:\s*$", line):
            pos, in_tiles = [], True
            continue
        if in_tiles:
            m = re.match(r"^\s*-\s*(-?\d+)\s*$", line)
            if m and len(pos) < 2:
                pos.append(int(m.group(1)))
                continue
            m = re.match(r"^\s*idx:\s*(\d+)", line)
            if m and len(pos) == 2:
                tiles.append((pos[0], pos[1], int(m.group(1))))
                in_tiles = False
    if tileset and tiles:
        out.append((tileset, tiles))
    return out


def infer() -> dict[str, dict[int, str]]:
    # votes[tileset][idx][role] -> count
    votes: dict[str, dict[int, collections.Counter]] = collections.defaultdict(
        lambda: collections.defaultdict(collections.Counter)
    )
    y_up_votes = collections.Counter()

    per_map: list[tuple[str, dict[tuple[int, int], int]]] = []
    for path in sorted(LEVELS.glob("*.map.yaml")):
        for tileset, tiles in parse_layers(path):
            occ = {(x, y): idx for x, y, idx in tiles}
            per_map.append((tileset, occ))
            # Decide the vertical axis direction once, from the data: ground
            # stacks are far more common than ceilings, so whichever direction
            # has more "solid neighbour" hits is 'down'.
            for (x, y) in occ:
                y_up_votes["minus"] += (x, y - 1) in occ
                y_up_votes["plus"] += (x, y + 1) in occ

    # 'below' is the direction that is more often occupied.
    below = -1 if y_up_votes["minus"] >= y_up_votes["plus"] else 1
    above = -below

    for tileset, occ in per_map:
        for (x, y), idx in occ.items():
            open_above = (x, y + above) not in occ
            left = (x - 1, y) in occ
            right = (x + 1, y) in occ
            if not open_above:
                role = CENTER
            elif left and right:
                role = MID
            elif right:
                role = LEFT
            elif left:
                role = RIGHT
            else:
                role = SOLO
            votes[tileset][idx][role] += 1

    return {
        ts: {idx: c.most_common(1)[0][0] for idx, c in sorted(idxs.items())}
        for ts, idxs in votes.items()
    }


if __name__ == "__main__":
    for ts, roles in sorted(infer().items()):
        counts = collections.Counter(roles.values())
        print(f"{ts:18s} {dict(counts)}")
        print(f"   {roles}")
