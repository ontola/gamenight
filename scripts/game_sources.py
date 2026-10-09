"""Locate the separate game checkout. Builds use game-sources.json; devs may override."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / "game-sources.json").read_text())

def game_sources():
    override = os.environ.get("GAMENIGHT_GAMES_DIR")
    folder = Path(override).resolve() if override else ROOT.parent / "gamenight-games"
    if not (folder / "love-party/main.lua").is_file():
        raise RuntimeError("Game source is separate. Run python scripts/fetch-game-sources.py first, or set GAMENIGHT_GAMES_DIR to your game checkout.")
    if not override:
        revision = subprocess.check_output(["git", "-C", str(folder), "rev-parse", "HEAD"], text=True).strip()
        if revision != MANIFEST["revision"]:
            raise RuntimeError("Game source revision differs from game-sources.json. Fetch the pinned source, or explicitly set GAMENIGHT_GAMES_DIR for development.")
    if not override and subprocess.check_output(["git", "-C", str(folder), "status", "--porcelain"], text=True).strip():
        raise RuntimeError("Pinned game sources have local changes. Set GAMENIGHT_GAMES_DIR explicitly for a development build.")
    return folder
