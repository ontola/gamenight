# macOS distribution

The website serves `/download/GameNight.dmg` as a static file. Publishing a Windows release does not update that file. The server deployment and download replacement procedure are documented in the internal repository at `deploy/cloud/HOSTED.md`.

Download the [Mac preview](https://gamenight.ontola.io/download/GameNight.dmg) and drag `GameNight.app` into Applications, replacing the old copy. The September 22 release is [0.1.4 Preview](https://github.com/ontola/gamenight/releases/tag/macos-v0.1.4-preview).

## Build

Run the **macOS installer** workflow on `main`, with a numeric bundle version such as `0.1.4`. It builds both Apple Silicon and Intel binaries from the same commit and combines them into one universal app.

The packaging job includes the current lobby assets and packs, Mac catalog entries, attribution files and the GameNight icon. `Contents/Resources/build.json` records the source commit and a SHA-256 digest for every lobby asset. Packaging checks both executable architectures, bundle names and asset hashes. The native smoke check launches the packaged host from an unrelated working directory and captures the rendered lobby.

The app contains:

- `Contents/MacOS/GameNight`: launcher, without a separate Dock icon.
- `Contents/Helpers/GameNight.app`: the visible lobby, whose process and app name are both GameNight.
- `Contents/Resources/bin/gamenight-daemon`: session host.
- `Contents/Resources/lobby`: all assets and packs, passed to the lobby through an explicit working directory and `BEVY_ASSET_ROOT`.
- `Contents/Resources/catalog`: downloadable Mac games. Shared LÖVE games use the same game archives as Windows and a separately pinned Mac runtime.

Launcher logs and downloaded games go in `~/Library/Application Support/GameNight`. The app bundle stays read-only. `GAMENIGHT_DATA_DIR` overrides this directory for isolated tests.

## Publish

Download `gamenight-macos-installer` and inspect the `gamenight-macos-smoke` screenshot and logs. Only publish after the build, bundle checks and native launch pass. Upload the DMG and checksum together to a GitHub release, then update the website's DMG and checksum atomically. Keep the previous installer outside the web root. Verify a fresh download against the release hash, not just the server's local file.

For changes limited to packaging or catalog metadata, `binaries_run` can reuse successful native build artifacts from an earlier run. The asset manifest records both the packaging commit and the binary commit. Never reuse all binaries when Rust sources or dependencies have changed. `lobby_run` can reuse only the lobby while rebuilding the host; use it only when lobby sources and dependencies are unchanged. The manifest records the lobby commit separately.

The build currently uses ad-hoc signatures. These permit native Apple Silicon execution but are not Developer ID signatures or Apple notarization. Do not describe this package as notarized. Physical controller behavior still needs a real Mac/controller test; an automated launch is not that test.
