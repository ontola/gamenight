#!/usr/bin/env python3
"""Write the .meta files Unity needs for this package.

A package installed from git is read-only to Unity, so it cannot create its
own .meta files and ignores every asset without one. GUIDs are derived from
the path, so running this again never changes an existing asset's identity.

    python3 scripts/unity-package-meta.py           # add missing .meta files, remove stale ones
    python3 scripts/unity-package-meta.py --check   # fail when any is missing or stale (CI)
"""
import argparse
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "sdk/unity"

FOLDER = """fileFormatVersion: 2
guid: {guid}
folderAsset: yes
DefaultImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""
SCRIPT = """fileFormatVersion: 2
guid: {guid}
MonoImporter:
  externalObjects: {{}}
  serializedVersion: 2
  defaultReferences: []
  executionOrder: 0
  icon: {{instanceID: 0}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""
ASMDEF = """fileFormatVersion: 2
guid: {guid}
AssemblyDefinitionImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""
TEXT = """fileFormatVersion: 2
guid: {guid}
TextScriptImporter:
  externalObjects: {{}}
  userData: 
  assetBundleName: 
  assetBundleVariant: 
"""


def ignored(path: Path) -> bool:
    # Unity skips names ending in ~ and starting with a dot; so do we.
    rel = path.relative_to(ROOT)
    return any(part.endswith("~") or part.startswith(".") for part in rel.parts)


def template(path: Path) -> str:
    if path.is_dir():
        return FOLDER
    return {".cs": SCRIPT, ".asmdef": ASMDEF}.get(path.suffix, TEXT)


def wanted() -> dict[Path, str]:
    out = {}
    for path in sorted(ROOT.rglob("*")):
        if path.suffix == ".meta" or ignored(path):
            continue
        guid = hashlib.md5(("com.ontola.gamenight/" + path.relative_to(ROOT).as_posix()).encode()).hexdigest()
        out[path.with_name(path.name + ".meta")] = template(path).format(guid=guid)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    metas = wanted()
    problems = []
    for meta, text in metas.items():
        if meta.exists() and meta.read_text(encoding="utf-8") == text:
            continue
        problems.append(f"{meta.relative_to(ROOT)}: missing or different")
        if not args.check:
            meta.write_text(text, encoding="utf-8", newline="\n")
    for meta in ROOT.rglob("*.meta"):
        if meta not in metas and not ignored(meta):
            problems.append(f"{meta.relative_to(ROOT)}: stale")
            if not args.check:
                meta.unlink()
    if args.check and problems:
        print("\n".join(problems) + "\nrun python3 scripts/unity-package-meta.py", file=sys.stderr)
        return 1
    print(f"{len(metas)} .meta files {'match' if args.check else 'written'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
