"""Build deterministic LÖVE games and an optional local GameNight shelf."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

GAMES = {"bumper-royale": "Bumper Royale", "neon-trails": "Neon Trails", "meteor-dash": "Meteor Dash"}
RUNTIME = {
    "id": "love-11-5",
    "url": "https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip",
    "sha256": "ba6e56be2685e53c817749c4a5007f51137136fe5a3ab64920508babc2e74369",
    "entrypoint": "love-11.5-win64/love.exe", "argument": "entry_point",
}

def write_zip(path, files):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, content in sorted(files.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--love", type=Path, help="LÖVE executable for a local shelf.json")
    parser.add_argument("--base-url", help="Immutable HTTPS release URL; generates downloadable catalogue entries")
    args = parser.parse_args()
    if args.base_url and not args.base_url.startswith("https://"):
        parser.error("--base-url must use HTTPS")
    source = Path(__file__).resolve().parents[1] / "games/love-party"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    files = {str(p.relative_to(source)).replace("\\", "/"): p.read_bytes()
             for p in source.rglob("*") if p.is_file() and "tests" not in p.relative_to(source).parts}
    shelf, sums = [], []
    for game, title in GAMES.items():
        artifact = output / f"{game}.love"
        write_zip(artifact, {**files, "game.lua": f'return {{id="{game}"}}\n'.encode()})
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        sums.append(f"{digest}  {artifact.name}")
        meta = {"id": game, "title": title, "min_players": 2, "max_players": 4, "players": "2–4"}
        if args.love:
            meta["launch"] = {"command": str(args.love.resolve()), "args": [str(artifact)], "cwd": str(output)}
            shelf.append(meta)
        if args.base_url:
            entry = {"id": game, "title": title, "developer": "GameNight contributors", "players": {"min": 2, "max": 4},
                     "price": "free", "integration": {"level": "integrated", "protocol": 1},
                     "downloads": {"windows": {"url": f"{args.base_url.rstrip('/')}/{artifact.name}", "sha256": digest,
                                               "entrypoint": artifact.name, "runtime": RUNTIME}}}
            (output / "catalog").mkdir(exist_ok=True)
            (output / "catalog" / f"{game}.json").write_text(json.dumps(entry, indent=2)+"\n", encoding="utf-8")
    (output / "SHA256SUMS.txt").write_text("\n".join(sums)+"\n", encoding="utf-8")
    if shelf:
        (output / "shelf.json").write_text(json.dumps(shelf, indent=2)+"\n", encoding="utf-8")
    (output / "README.md").write_bytes((source / "README.md").read_bytes())
    write_zip(output / "gamenight-love-party.zip", {p.name: p.read_bytes() for p in output.iterdir()
                                                  if p.is_file() and p.suffix in {".love", ".md", ".txt"}})
    print(output)

if __name__ == "__main__":
    main()
