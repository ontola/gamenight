"""Draw a real frame from every packaged game using the Windows LOVE runtime."""
import argparse
import os
from pathlib import Path
import subprocess

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--love", type=Path, required=True)
    parser.add_argument("--pack", type=Path, required=True)
    args = parser.parse_args()
    games = sorted(args.pack.resolve().glob("*.love"))
    if not games:
        raise SystemExit("No packaged games found")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GAMENIGHT", "GNLOVE"))}
    env.update(GNLOVE_RENDER_SMOKE="1", GNLOVE_DEMO="1")
    for game in games:
        result = subprocess.run([str(args.love.resolve()), str(game)], env=env,
                                capture_output=True, text=True, timeout=30)
        if result.returncode or "PASS rendered " not in result.stdout:
            raise SystemExit(f"{game.name} failed to render:\n{result.stdout}\n{result.stderr}")
        print(result.stdout.strip())

if __name__ == "__main__":
    main()

