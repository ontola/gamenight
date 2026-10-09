#!/usr/bin/env python3
"""Keep a game's copies of the GameNight Godot addons identical to this SDK.

Godot has no external dependencies, so every game vendors `addons/gamenight`.
Those copies drift: games end up missing protocol features they look like they
support. This script copies the SDK in, and with --check fails when a copy
differs, so a game's CI notices the moment the SDK moves on.

    python sdk/godot/sync.py path/to/game            # update the copy
    python sdk/godot/sync.py --check path/to/game    # fail if it differs
    python sdk/godot/sync.py --all path/to/game      # also add optional files
    python sdk/godot/sync.py --add crowd_sound path/to/game  # opt in to an addon

`gamenight.gd` is required. The other scripts are optional: a game that only
vendors `gamenight.gd` keeps it that way unless --all is given. A game's own
`.uid` files are kept, because its scenes and autoloads may refer to them.

Opt-in addons (`crowd_sound`: procedural crowd audio) are only synced and
checked in games that already have them, or when named with --add.
"""
import argparse
import shutil
import sys
from pathlib import Path

ADDONS = Path(__file__).resolve().parent / "addons"
# addon -> (required files, optional files, opt-in)
SPECS = {
    "gamenight": (
        ["gamenight.gd"],
        ["screen.gd", "lobby.gd", "face.gd", "artwork.gd", "plugin.gd", "plugin.cfg"],
        False,
    ),
    "crowd_sound": (["crowd_sound.gd"], [], True),
}


def wanted(name: str, addon: Path, everything: bool) -> list[str]:
    required, optional, _ = SPECS[name]
    return required + [f for f in optional if everything or (addon / f).exists()]


def sync(game: Path, check: bool, everything: bool, add: list[str]) -> list[str]:
    if not (game / "project.godot").is_file():
        return [f"{game}: not a Godot project (no project.godot)"]
    problems = []
    for name, (_, _, opt_in) in SPECS.items():
        addon = game / "addons" / name
        if opt_in and name not in add and not addon.exists():
            continue
        problems += sync_addon(name, addon, check, everything)
    return problems


def sync_addon(name: str, addon: Path, check: bool, everything: bool) -> list[str]:
    sdk = ADDONS / name
    problems = []
    for file in wanted(name, addon, everything):
        source, target = sdk / file, addon / file
        if target.is_file() and target.read_bytes() == source.read_bytes():
            continue
        if check:
            state = "missing" if not target.exists() else "differs from the SDK"
            problems.append(f"{target}: {state}")
            continue
        addon.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        uid = sdk / f"{file}.uid"
        if uid.exists() and not (addon / uid.name).exists():
            shutil.copyfile(uid, addon / uid.name)
        print(f"updated {target}")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("games", nargs="+", type=Path, help="Godot project directories")
    parser.add_argument("--check", action="store_true", help="only report differences")
    parser.add_argument("--all", action="store_true", help="also copy optional scripts the game lacks")
    parser.add_argument("--add", action="append", default=[], choices=[n for n, s in SPECS.items() if s[2]],
                        help="opt in to an addon the game doesn't have yet")
    args = parser.parse_args()
    problems = [p for game in args.games for p in sync(game, args.check, args.all, args.add)]
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        print(
            "\nA GameNight addon is out of date. From a gamenight checkout, run:\n"
            "    python sdk/godot/sync.py path/to/your/game",
            file=sys.stderr,
        )
        return 1
    if args.check:
        print("GameNight addons match the SDK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
