#!/usr/bin/env python3
"""Keep a game's copy of the GameNight Godot addon identical to this SDK.

Godot has no external dependencies, so every game vendors `addons/gamenight`.
Those copies drift: games end up missing protocol features they look like they
support. This script copies the SDK in, and with --check fails when a copy
differs, so a game's CI notices the moment the SDK moves on.

    python sdk/godot/sync.py path/to/game            # update the copy
    python sdk/godot/sync.py --check path/to/game    # fail if it differs
    python sdk/godot/sync.py --all path/to/game      # also add optional files

`gamenight.gd` is required. The other scripts are optional: a game that only
vendors `gamenight.gd` keeps it that way unless --all is given. A game's own
`.uid` files are kept, because its scenes and autoloads may refer to them.
"""
import argparse
import shutil
import sys
from pathlib import Path

SDK = Path(__file__).resolve().parent / "addons" / "gamenight"
REQUIRED = ["gamenight.gd"]
OPTIONAL = ["screen.gd", "lobby.gd", "face.gd", "artwork.gd", "plugin.gd", "plugin.cfg"]


def wanted(addon: Path, everything: bool) -> list[str]:
    return REQUIRED + [f for f in OPTIONAL if everything or (addon / f).exists()]


def sync(game: Path, check: bool, everything: bool) -> list[str]:
    if not (game / "project.godot").is_file():
        return [f"{game}: not a Godot project (no project.godot)"]
    addon = game / "addons" / "gamenight"
    problems = []
    for name in wanted(addon, everything):
        source, target = SDK / name, addon / name
        if target.is_file() and target.read_bytes() == source.read_bytes():
            continue
        if check:
            state = "missing" if not target.exists() else "differs from the SDK"
            problems.append(f"{target}: {state}")
            continue
        addon.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        uid = SDK / f"{name}.uid"
        if uid.exists() and not (addon / uid.name).exists():
            shutil.copyfile(uid, addon / uid.name)
        print(f"updated {target}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("games", nargs="+", type=Path, help="Godot project directories")
    parser.add_argument("--check", action="store_true", help="only report differences")
    parser.add_argument("--all", action="store_true", help="also copy optional scripts the game lacks")
    args = parser.parse_args()
    problems = [p for game in args.games for p in sync(game, args.check, args.all)]
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(
            "\nThe GameNight addon is out of date. From a gamenight checkout, run:\n"
            "    python sdk/godot/sync.py path/to/your/game",
            file=sys.stderr,
        )
        return 1
    if args.check:
        print("GameNight addon matches the SDK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
