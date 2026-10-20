"""Locate the separate game checkouts. Builds use game-sources.json; devs may override."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "game-sources.json").read_text())

# name -> (pin, sibling folder, override variable, file that proves the checkout)
SOURCES = {
    "games": (MANIFEST, "gamenight-games", "GAMENIGHT_GAMES_DIR", "love-party/main.lua"),
    "mineclonia": (MANIFEST["mineclonia"], "gamenight-mineclonia", "GAMENIGHT_MINECLONIA_DIR", "managed.py"),
}


def pinned_source(name):
    pin, sibling, variable, marker = SOURCES[name]
    override = os.environ.get(variable)
    folder = Path(override).resolve() if override else ROOT.parent / sibling
    if not (folder / marker).is_file():
        raise RuntimeError(f"{sibling} is a separate repository. Run python scripts/fetch-game-sources.py first, or set {variable} to your checkout.")
    if not override:
        revision = subprocess.check_output(["git", "-C", str(folder), "rev-parse", "HEAD"], text=True).strip()
        if revision != pin["revision"]:
            raise RuntimeError(f"{sibling} revision differs from game-sources.json. Fetch the pinned source, or explicitly set {variable} for development.")
        if subprocess.check_output(["git", "-C", str(folder), "status", "--porcelain"], text=True).strip():
            raise RuntimeError(f"Pinned {sibling} has local changes. Set {variable} explicitly for a development build.")
    return folder


def game_sources():
    return pinned_source("games")


def mineclonia_source():
    return pinned_source("mineclonia")
