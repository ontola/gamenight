"""Check Mac bundle identity, complete asset hashes and universal executables."""
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def verify(app):
    contents = app / "Contents"
    resources = contents / "Resources"
    helper = contents / "Helpers/GameNight.app/Contents"
    for bundle in [contents, helper]:
        data = plistlib.loads((bundle / "Info.plist").read_bytes())
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"]:
            assert data[key] == "GameNight", (bundle, key)
        assert (bundle / "Resources" / data["CFBundleIconFile"]).stat().st_size > 100
    for binary in [contents / "MacOS/GameNight", helper / "MacOS/GameNight", resources / "bin/gamenight-daemon"]:
        subprocess.run(["lipo", "-verify_arch", "arm64", "x86_64", str(binary)], check=True)
    manifest = json.loads((resources / "build.json").read_text())
    assert manifest["assets"], "Empty asset manifest"
    for name, digest in manifest["assets"].items():
        assert hashlib.sha256((resources / name).read_bytes()).hexdigest() == digest, name
    assert (resources / "catalog/games/pinpals.json").is_file()
    assert (resources / "lobby/assets/game.yaml").is_file()
    print(f"Verified {len(manifest['assets'])} packaged assets and both Mac architectures: {manifest['commit']}")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())
