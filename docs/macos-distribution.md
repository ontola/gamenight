# macOS distribution

The website serves `/download/GameNight.dmg` as a static file. Publishing a Windows release does not update that file. The server deployment and download replacement procedure are documented in the internal repository at `deploy/cloud/HOSTED.md`.

Download the [Mac preview](https://gamenight.ontola.io/download/GameNight.dmg) and drag `GameNight.app` into Applications, replacing the old copy. The September 22 release is [0.1.4 Preview](https://github.com/ontola/gamenight/releases/tag/macos-v0.1.4-preview).

## Build

Run the **macOS installer** workflow on `main`, with a numeric bundle version such as `0.1.4`. It builds both Apple Silicon and Intel binaries from the same commit and combines them into one universal app.

The packaging job installs the pinned universal Godot 4.5.2 (`.github/actions/setup-godot`), exports the Game Room lobby (`lobbies/game-room`, preset `macOS`) as a `.pck`, and adds the Mac catalog entries, attribution files and the GameNight icon. `Contents/Resources/build.json` records the source commit and the SHA-256 digest of the lobby pack. Packaging checks both executable architectures, bundle names and the pack hash. The native smoke check launches the packaged host from an unrelated working directory and waits until the Game Room connects to it with its launch token.

The app contains:

- `Contents/MacOS/GameNight`: launcher, without a separate Dock icon.
- `Contents/Helpers/GameNight.app`: the visible lobby, whose process and app name are both GameNight. Its executable is Godot's universal editor binary; the launcher starts it with `--main-pack` on `Contents/Resources/GameNight.pck` (the exported Game Room), so no export templates are needed, as on Windows.
- `Contents/Resources/bin/gamenight-daemon`: session host.
- `Contents/Resources/notices/game-room`: Godot's and the lobby fonts' licenses.
- `Contents/Resources/catalog`: downloadable Mac games. Shared LÖVE games use the same game archives as Windows and a separately pinned Mac runtime.

Launcher logs and downloaded games go in `~/Library/Application Support/GameNight`. The app bundle stays read-only. `GAMENIGHT_DATA_DIR` overrides this directory for isolated tests.

## Publish

Download `gamenight-macos-installer` and inspect the `gamenight-macos-smoke` logs. Only publish after the build, bundle checks and native launch pass. Upload the DMG and checksum together to a GitHub release, then update the website's DMG and checksum atomically. Keep the previous installer outside the web root. Verify a fresh download against the release hash, not just the server's local file.

For changes limited to packaging or catalog metadata, `binaries_run` can reuse successful native build artifacts from an earlier run. The asset manifest records both the packaging commit and the binary commit. Never reuse all binaries when Rust sources or dependencies have changed. The lobby is always exported from the packaging commit.

## Signing and notarization

Without Developer ID credentials the build falls back to ad-hoc signatures, with a workflow warning. Those permit native Apple Silicon execution on the build machine, but Gatekeeper blocks the downloaded app ("Apple could not verify GameNight.app"). Testers can then use System Settings > Privacy & Security > Open Anyway, or `xattr -dr com.apple.quarantine /Applications/GameNight.app`.

With these repository secrets, the workflow signs every executable inside out with hardened runtime and a secure timestamp, signs the DMG, notarizes it with `notarytool`, staples the ticket and checks it with `spctl`:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Base64 of a **Developer ID Application** certificate with its private key, exported from Keychain Access as `.p12` (`base64 -i cert.p12 \| pbcopy`). |
| `MACOS_CERTIFICATE_PASSWORD` | The export password of that `.p12`. |
| `APPLE_API_KEY_P8` | Contents (or base64) of an App Store Connect API key `AuthKey_XXXX.p8` with the Developer role. |
| `APPLE_API_KEY_ID` | That key's ID. |
| `APPLE_API_ISSUER_ID` | The issuer ID shown above the keys list in App Store Connect > Users and Access > Integrations. |

Once the certificate secret is present, a missing API key fails the build instead of silently shipping an unnotarized DMG. The automatic release workflow passes these secrets on with `secrets: inherit`.

Physical controller behavior still needs a real Mac/controller test; an automated launch is not that test.
