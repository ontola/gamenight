"""Fetch the pinned games into a sibling checkout without overwriting local work."""
from pathlib import Path
import subprocess
from game_sources import ROOT, MANIFEST

def git(folder, *args):
    return subprocess.check_output(["git", "-C", str(folder), *args], text=True).strip()

def main():
    folder = ROOT.parent / "gamenight-games"
    if folder.exists():
        if not (folder / ".git").exists():
            raise SystemExit(f"Refusing to replace {folder}: it is not a Git checkout")
        if git(folder, "remote", "get-url", "origin").removesuffix(".git") != MANIFEST["repository"].removesuffix(".git"):
            raise SystemExit(f"Refusing to replace an unrelated checkout: {folder}")
        if git(folder, "status", "--porcelain"):
            raise SystemExit(f"Keep your local game changes: commit them or use GAMENIGHT_GAMES_DIR before fetching into {folder}")
    else:
        subprocess.run(["git", "clone", "--no-checkout", MANIFEST["repository"], str(folder)], check=True)
    git(folder, "fetch", "origin", MANIFEST["revision"])
    git(folder, "checkout", "--detach", MANIFEST["revision"])
    if git(folder, "rev-parse", "HEAD") != MANIFEST["revision"]:
        raise SystemExit("Fetched game revision does not match the pin")
    print(f"Game sources ready: {folder}")

if __name__ == "__main__":
    main()
