#!/usr/bin/env python3
"""Scaffold a game from templates/godot-game and check it works: it imports,
bots play a deterministic run (same seed, same state hash), and it passes the
fake-host lifecycle test.

    python3 scripts/test-godot-template.py --godot /path/to/godot
"""
import argparse
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sim(godot: str, game: Path, seed: int) -> str:
    out = subprocess.run([godot, "--headless", "--fixed-fps", "60", "--path", str(game), "--",
                          "--sim", "4000", "--seed", str(seed)], capture_output=True, text=True, timeout=300)
    if out.returncode != 0 or "sim: ok" not in out.stdout:
        raise SystemExit(f"sim failed:\n{out.stdout}\n{out.stderr}")
    return re.search(r"hash (\w+)", out.stdout).group(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--godot", default="godot")
    godot = ap.parse_args().godot
    with tempfile.TemporaryDirectory() as tmp:
        game = Path(tmp) / "orb-test"
        subprocess.run([sys.executable, str(ROOT / "scripts/new-godot-game.py"), str(game), "orb-test", "Orb Test"], check=True)
        assert '"id": "orb-test"' in (game / "gamenight.json").read_text()
        subprocess.run([sys.executable, str(ROOT / "sdk/godot/sync.py"), "--check", str(game)], check=True)
        subprocess.run([godot, "--headless", "--import", "--path", str(game)], capture_output=True, timeout=300)
        first, again, other = sim(godot, game, 1), sim(godot, game, 1), sim(godot, game, 2)
        if first != again:
            raise SystemExit(f"the same seed gave two runs: {first} {again}")
        if first == other:
            raise SystemExit("different seeds gave the same run")
        print("ok: deterministic bots, seed", first)
        subprocess.run([sys.executable, str(game / "tests/lifecycle.py"), "--godot", godot], check=True, timeout=300)
    print("template: all good")
    return 0


if __name__ == "__main__":
    sys.exit(main())
