"""Check installer catalog coverage and install native games through the real installer.

Run against the release staging directory, not a developer's populated game cache.
The download check proves delivery and extraction, not controller or GPU behavior.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def entries(directory, platform):
    return {p.stem: json.loads(p.read_text(encoding="utf-8"))
            for p in sorted(directory.glob("*.json"))
            if platform in json.loads(p.read_text(encoding="utf-8")).get("downloads", {})}


def check_coverage(source, packaged, platform):
    expected = entries(source, platform)
    actual = entries(packaged, platform)
    if not expected or actual != expected:
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
        raise ValueError(f"Packaged catalog differs: missing={missing}, extra={extra}, changed={changed}")
    return actual


def install_native(catalog, platform, installer, output):
    output.mkdir(parents=True, exist_ok=False)
    staged = output / "catalog"
    staged.mkdir()
    native = {k: e for k, e in catalog.items()
              if not e["downloads"][platform].get("runtime")}
    if not native:
        raise ValueError("No native games found; refusing an empty download check")
    for key, entry in native.items():
        (staged / f"{key}.json").write_text(json.dumps(entry), encoding="utf-8")
    env = dict(os.environ, GAMENIGHT_CATALOG=str(staged.resolve()),
               GAMENIGHT_INSTALL_DIR=str((output / "games").resolve()))
    result = subprocess.run([str(installer.resolve())], env=env, capture_output=True,
                            text=True, encoding="utf-8", errors="replace", timeout=600)
    (output / "installer.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"Native game installation failed; see {output / 'installer.log'}")
    markers = list((output / "games").rglob(".gamenight-install.json"))
    checks = []
    for key, entry in native.items():
        download = entry["downloads"][platform]
        match = [p for p in markers if json.loads(p.read_text())["sha256"] == download["sha256"]]
        if len(match) != 1 or not (match[0].parent / download["entrypoint"]).is_file():
            raise ValueError(f"{key}: missing verified install or entrypoint")
        checks.append({"game": key, "sha256": download["sha256"], "checks": ["download", "checksum", "extract", "entrypoint"]})
        print(f"PASS {key}: downloaded, verified and installed")
    (output / "results.json").write_text(json.dumps(checks, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "catalog/games")
    parser.add_argument("--packaged-catalog", type=Path, required=True)
    parser.add_argument("--platform", choices=["windows", "mac", "linux"], required=True)
    parser.add_argument("--installer", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    catalog = check_coverage(args.source, args.packaged_catalog, args.platform)
    print(f"Packaged catalog contains all {len(catalog)} {args.platform} games")
    if args.installer:
        if not args.output:
            parser.error("--installer requires a new --output directory")
        host = {"win32": "windows", "darwin": "mac", "linux": "linux"}[sys.platform]
        if args.platform != host:
            parser.error("Download installation must run on the target OS")
        install_native(catalog, args.platform, args.installer, args.output)


if __name__ == "__main__":
    main()
