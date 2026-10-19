"""Create a relocatable macOS app from universal native binaries and the Game Room lobby."""
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


def package(repo, binaries, game_room, output, version, binary_revision=None):
    app = output / "GameNight.app"
    contents = app / "Contents"
    resources = contents / "Resources"
    helper = contents / "Helpers/GameNight.app/Contents"
    for folder in [contents / "MacOS", resources / "bin", helper / "MacOS", helper / "Resources"]:
        folder.mkdir(parents=True, exist_ok=False)
    # The lobby helper is Godot's universal binary; it runs the same-named
    # Game Room PCK from its bundle's Resources.
    for source, target in [(binaries / "gamenight-launcher", contents / "MacOS/GameNight"),
                           (binaries / "gamenight-daemon", resources / "bin/gamenight-daemon"),
                           (game_room / "GameNight", helper / "MacOS/GameNight")]:
        shutil.copy2(source, target)
        target.chmod(0o755)
    shutil.copy2(game_room / "GameNight.pck", helper / "Resources/GameNight.pck")
    for target, ident, background in [(contents, "io.ontola.gamenight", True),
                                       (helper, "io.ontola.gamenight.lobby", False)]:
        (target / "Info.plist").write_bytes(plistlib.dumps(plist("GameNight", ident, version, background)))
    notices = resources / "notices/game-room"
    notices.mkdir(parents=True)
    for notice in (repo / "lobbies/game-room/assets/fonts").glob("*LICENSE*.txt"):
        shutil.copy2(notice, notices / notice.name)
    shutil.copy2(repo / "lobbies/game-room/GODOT-LICENSE.txt", notices / "godot.txt")
    for file in ["LICENSE", "THIRD_PARTY.md"]:
        shutil.copy2(repo / file, resources / file)
    catalog = resources / "catalog/games"
    catalog.mkdir(parents=True)
    for file in (repo / "catalog/games").glob("*.json"):
        if "mac" in json.loads(file.read_text(encoding="utf-8")).get("downloads", {}):
            shutil.copy2(file, catalog / file.name)
    shutil.copy2(repo / "catalog/schema.json", catalog.parent / "schema.json")
    # Record the lobby's exported pack, relative to Resources, so the bundle
    # check can tell a stale or truncated copy from the one exported here.
    digest = hashlib.sha256((game_room / "GameNight.pck").read_bytes()).hexdigest()
    hashes = {"../Helpers/GameNight.app/Contents/Resources/GameNight.pck": digest}
    revision = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    (resources / "build.json").write_text(json.dumps({"commit": revision, "version": version,
                                                    "binary_commit": binary_revision or revision, "assets": hashes}, indent=2) + "\n", encoding="utf-8")
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--game-room", type=Path, required=True,
                        help="Exported Game Room lobby: universal Godot binary GameNight + GameNight.pck")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--binary-revision")
    parser.add_argument("--sign-identity", default="-",
                        help="Developer ID Application identity; '-' signs ad hoc")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    app = package(repo, args.binaries, args.game_room, args.output, args.version, args.binary_revision)
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
    links = app / "Contents/Helpers/GameNight Link.app/Contents"
    (links / "MacOS").mkdir(parents=True)
    (links / "Resources").mkdir()
    link_plist = plist("GameNight Link", "io.ontola.gamenight.link", args.version, True)
    link_plist["CFBundleURLTypes"] = [{"CFBundleURLName": "GameNight games", "CFBundleURLSchemes": ["gamenight"]}]
    (links / "Info.plist").write_bytes(plistlib.dumps(link_plist))
    shutil.copy2(icon, links / "Resources/GameNight.icns")
    architectures = []
    for arch in ["arm64", "x86_64"]:
        binary = args.output / ("GameNightLink-" + arch)
        subprocess.run(["swiftc", "-target", arch + "-apple-macosx12.0", str(repo / "scripts/macos-link.swift"), "-o", str(binary)], check=True)
        architectures.append(str(binary))
    subprocess.run(["lipo", "-create", *architectures, "-output", str(links / "MacOS/GameNight Link")], check=True)
    # Sign inside out. Ad-hoc signing only permits Apple Silicon execution; a
    # Developer ID signature with hardened runtime and timestamp is what
    # notarization (and so Gatekeeper on other Macs) requires.
    sign = ["codesign", "--force", "--sign", args.sign_identity]
    if args.sign_identity != "-":
        sign += ["--options", "runtime", "--timestamp"]
    for path in [app / "Contents/Resources/bin/gamenight-daemon", app / "Contents/Helpers/GameNight.app", links.parent, app]:
        subprocess.run([*sign, str(path)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print(app)


if __name__ == "__main__":
    main()
