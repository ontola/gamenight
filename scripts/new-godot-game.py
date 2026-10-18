#!/usr/bin/env python3
"""Start a new GameNight game in Godot 4 from templates/godot-game.

    python3 scripts/new-godot-game.py ../my-game my-game "My Game"

Copies the template (a small working couch game with bots, headless tests,
a deterministic store-clip capture and a CI that builds, releases and fills
the store page), renames it, and installs the GameNight addon from this SDK.
Then: git init, push to GitHub, and follow docs/site/playbook.md.
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "templates" / "godot-game"
TEXT = {".gd", ".godot", ".tscn", ".cfg", ".json", ".md", ".py", ".sh", ".yml", ".gitignore"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dest", type=Path)
    ap.add_argument("id", help="lowercase-with-dashes, also the store and catalog id")
    ap.add_argument("title")
    args = ap.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", args.id) or len(args.id) > 64:
        raise SystemExit("Use a lowercase id with dashes, such as my-game")
    if args.dest.exists() and any(args.dest.iterdir()):
        raise SystemExit(f"{args.dest} is not empty")
    shutil.copytree(TEMPLATE, args.dest, dirs_exist_ok=True)
    exe = re.sub(r"[^A-Za-z0-9]", "", args.title) or "Game"
    for path in args.dest.rglob("*"):
        if path.is_file() and (path.suffix in TEXT or path.name in TEXT):
            text = path.read_text()
            new = (text.replace("template-game", args.id).replace("Template Game", args.title)
                   .replace("TemplateGame", exe))
            if new != text:
                path.write_text(new)
    subprocess.run([sys.executable, str(ROOT / "sdk/godot/sync.py"), "--all", str(args.dest)], check=True)
    print(f"Created {args.title} in {args.dest}. Next: read {ROOT / 'docs/site/playbook.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
