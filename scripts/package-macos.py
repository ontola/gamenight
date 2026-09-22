"""Create a relocatable macOS app from universal native binaries."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path


def plist(name, identifier, version, background=False):
    return dict(CFBundleName=name, CFBundleDisplayName=name, CFBundleExecutable=name,
                CFBundleIdentifier=identifier, CFBundlePackageType="APPL",
                CFBundleShortVersionString=version, CFBundleVersion=version,
                CFBundleIconFile="GameNight.icns", NSHighResolutionCapable=True,
                LSMinimumSystemVersion="12.0", LSUIElement=background,
                NSBluetoothAlwaysUsageDescription="Connect controllers to GameNight.")


def package(repo, binaries, output, version, binary_revision=None, lobby_revision=None):
    app = output / "GameNight.app"
    contents = app / "Contents"
    resources = contents / "Resources"
    helper = contents / "Helpers/GameNight.app/Contents"
    for folder in [contents / "MacOS", resources / "bin", helper / "MacOS", helper / "Resources"]:
        folder.mkdir(parents=True, exist_ok=False)
    for source, target in [("gamenight-launcher", contents / "MacOS/GameNight"),
                           ("gamenight-daemon", resources / "bin/gamenight-daemon"),
                           ("lobby", helper / "MacOS/GameNight")]:
        shutil.copy2(binaries / source, target)
        target.chmod(0o755)
    for target, ident, background in [(contents, "io.ontola.gamenight", True),
                                       (helper, "io.ontola.gamenight.lobby", False)]:
        (target / "Info.plist").write_bytes(plistlib.dumps(plist("GameNight", ident, version, background)))
    for folder in ["assets", "packs", "licenses"]:
        shutil.copytree(repo / "crates/lobby" / folder, resources / "lobby" / folder)
    for file in ["LICENSE", "CREDITS.md"]:
        shutil.copy2(repo / "crates/lobby" / file, resources / "lobby" / file)
    shutil.copytree(repo / "vendor/bones/licenses", resources / "notices/bones")
    for file in ["LICENSE", "THIRD_PARTY.md"]:
        shutil.copy2(repo / file, resources / file)
    shutil.copy2(repo / "crates/lobby/tools/reskin/ASSET-SOURCES.md", resources / "notices")
    catalog = resources / "catalog/games"
    catalog.mkdir(parents=True)
    for file in (repo / "catalog/games").glob("*.json"):
        if "mac" in json.loads(file.read_text(encoding="utf-8")).get("downloads", {}):
            shutil.copy2(file, catalog / file.name)
    shutil.copy2(repo / "catalog/schema.json", catalog.parent / "schema.json")
    # Verify every source asset in the bundle, including Bevy fonts and current
    # clubhouse textures. A compile-only job cannot catch stale/missing assets.
    hashes = {}
    for folder in ["assets", "packs"]:
        source = repo / "crates/lobby" / folder
        for file in source.rglob("*"):
            if file.is_file():
                relative = Path("lobby") / folder / file.relative_to(source)
                digest = hashlib.sha256(file.read_bytes()).hexdigest()
                if hashlib.sha256((resources / relative).read_bytes()).hexdigest() != digest:
                    raise RuntimeError(f"Packaged asset differs: {relative}")
                hashes[relative.as_posix()] = digest
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    (resources / "build.json").write_text(json.dumps({"commit": revision, "version": version,
                                                    "binary_commit": binary_revision or revision, "lobby_commit": lobby_revision or binary_revision or revision, "assets": hashes}, indent=2) + "\n", encoding="utf-8")
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--binary-revision")
    parser.add_argument("--lobby-revision")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    app = package(repo, args.binaries, args.output, args.version, args.binary_revision, args.lobby_revision)
    iconset = args.output / "GameNight.iconset"
    iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
            subprocess.run(["sips", "-z", str(size * scale), str(size * scale), str(repo / "site/icon.png"),
                            "--out", str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
    icon = app / "Contents/Resources/GameNight.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icon)], check=True)
    shutil.copy2(icon, app / "Contents/Helpers/GameNight.app/Contents/Resources/GameNight.icns")
    # Ad-hoc signing supports Apple Silicon execution. It is not notarization.
    for path in [app / "Contents/Resources/bin/gamenight-daemon", app / "Contents/Helpers/GameNight.app", app]:
        subprocess.run(["codesign", "--force", "--sign", "-", str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
