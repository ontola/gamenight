"""Fetch the pinned game repositories into sibling checkouts without overwriting local work."""
import os
import subprocess
from game_sources import ROOT, SOURCES, pinned_source

def git(folder, *args):
    return subprocess.check_output(["git", "-C", str(folder), *args], text=True).strip()

def fetch(name):
    pin, sibling, variable, _ = SOURCES[name]
    if os.environ.get(variable):
        print(f"Using explicit development source for {sibling}: {pinned_source(name)}")
        return
    folder = ROOT.parent / sibling
    if folder.exists():
        if not (folder / ".git").exists():
            raise SystemExit(f"Refusing to replace {folder}: it is not a Git checkout")
        if git(folder, "remote", "get-url", "origin").removesuffix(".git") != pin["repository"].removesuffix(".git"):
            raise SystemExit(f"Refusing to replace an unrelated checkout: {folder}")
        if git(folder, "status", "--porcelain"):
            raise SystemExit(f"Keep your local changes: commit them or set {variable} before fetching into {folder}")
    else:
        subprocess.run(["git", "clone", "--no-checkout", pin["repository"], str(folder)], check=True)
    git(folder, "fetch", "origin", pin["revision"])
    git(folder, "checkout", "--detach", pin["revision"])
    if git(folder, "rev-parse", "HEAD") != pin["revision"]:
        raise SystemExit(f"Fetched {sibling} revision does not match the pin")
    print(f"Pinned source ready: {folder}")

def main():
    for name in SOURCES:
        fetch(name)

if __name__ == "__main__":
    main()
