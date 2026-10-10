# Windows distribution

GameNight uses [Velopack](https://docs.velopack.io/getting-started/rust) 1.2.0 for
per-user installation and updates. The player needs neither a development
toolchain nor .NET. Packaging machines need Rust/MSVC, Python 3 and .NET 8.

## Build

From a native Windows checkout:

```powershell
dotnet tool install --global vpk --version 1.2.0
./scripts/build-windows-installer.ps1 -Version 0.1.0-preview.2 -Channel preview -OutputDir C:/builds/preview2 -TargetDir C:/builds/target
```

The default profile is `release`; `-BuildProfile ci` is a faster build for packaging
checks. Choose a new output directory. The script packages GameNight and its starter catalogue, and produces `Setup.exe`, a
portable ZIP, a full update package, a channel feed and SHA-256 checksums in
`releases/`. This first implementation ships full updates. Delta packaging can
be added later by supplying the preceding release to Velopack.

Visual C++ runtime DLLs are copied from the installed toolchain's redistributable
directory alongside the launcher and native binaries, avoiding a separate
machine-wide prerequisite installer. Keep the build toolchain patched: GameNight
releases are responsible for updating these app-local runtime copies. The
package includes their version and redistribution notice.

The application IDs are `Ontola.GameNight.Preview` and `Ontola.GameNight`, and
the channels are `win-preview` and `win-stable`. The installation directories
are separate from `%LOCALAPPDATA%\GameNight` user data. Application updates
replace the complete application folder, while games and shared runtimes download independently
into hash-specific directories under the user data folder. Old content versions are retained.
Both channels share GameNight user data and cannot run simultaneously against
that directory. LÖVE games manage their saves independently.

## CI and releases

The normal **Build and test** workflow tests the runtime on Windows, Linux and
macOS. Windows also installs an isolated fixture using real Velopack installers
and the production update/data/process helpers. It checks offline startup,
rejection of a corrupt update, deferral until exit, restart on the new version,
data preservation, termination of a child process and use of the bundled C++ runtime. It uses a unique app ID
and uninstalls the fixture after the test. This is not a controller/GPU test.

**Windows installer** builds a complete package on relevant pull requests using
the `ci` profile. Run it manually from `main` for an optimized release, choosing
a version and channel. `publish=true` uploads all assets to a **draft** GitHub
release. Finish reviewing it and the CI results before publishing the draft.
Only published releases enter the update feed. A preview must remain marked as
a GitHub prerelease. Upload the feed and all `.nupkg` files together with Setup;
Setup alone cannot serve automatic updates. Existing releases are never
silently overwritten.

The installer workflow also compares its packaged catalog with every Windows
entry in the committed source and installs each native download into an empty
cache through `gamenight-installer`. See the `native-download-evidence` artifact.
Missing entries, changed metadata, failed HTTP downloads, checksum mismatches
and missing entrypoints block publication. These checks do not certify native
controller input or GPU behavior.

For a local delivery check, build `gamenight-installer`, then run:

```powershell
python scripts/check-release-catalog.py --platform windows --packaged-catalog C:/builds/app/catalog/games --installer target/debug/gamenight-installer.exe --output C:/builds/download-check
```

Use a new output directory. For an isolated running host, the installed-game
probe accepts that same catalog as its fourth argument, so native games are
included in prepare/start/pause/resume checks:

```powershell
node scripts/test-installed-downloads.mjs ws://127.0.0.1:17912 C:/builds/results.json C:/builds/app/catalog/games
```

The probe uses AI seats. Physical controller ownership, actual paused simulation,
audio and window presentation require the engine probes and hardware checks too.

## Signing

Preview artifacts can be built unsigned. Stable packaging refuses to proceed
without signing metadata. For [Azure Artifact Signing](https://docs.velopack.io/packaging/signing),
configure a public-trust certificate profile and a federated GitHub identity
with permission to sign that profile. Scope the federation to this repo's main
branch. Add these repository variables:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- `WINDOWS_SIGNING_ENDPOINT`, `WINDOWS_SIGNING_ACCOUNT`, `WINDOWS_SIGNING_PROFILE`

The release workflow uses OIDC via `azure/login` and passes temporary metadata
to Velopack, which signs the application, updater and installer. No signing
credentials are embedded in the app. Signing runs only for manual builds on
`main`, never pull requests. The script verifies the resulting Setup signature.
Account creation and publisher identity validation must be completed separately;
adding the workflow alone does not create a signing identity. Signing also does
not guarantee that every machine will immediately suppress SmartScreen prompts.

Setup for Ontola (one time, in the Azure portal):

1. Create an Artifact Signing account (Basic tier) in a resource group, and note
   its endpoint, for example `https://weu.codesigning.azure.net/`.
2. Create a Public Trust identity validation for Ontola as an organization and
   wait for approval. Microsoft checks the company details against public records.
3. Create a Public Trust certificate profile on that validated identity.
4. Create an app registration with a federated credential for GitHub Actions,
   entity `Branch`, repository `ontola/gamenight`, branch `main`.
5. Give that app the role *Artifact Signing Certificate Profile Signer* (formerly *Trusted
   Signing Certificate Profile Signer*) on the
   certificate profile.
6. Add the six repository variables above (Settings, Secrets and variables,
   Actions, Variables). They are identifiers, not secrets.

The next automatic preview from `main` is then signed: Setup, `GameNight.exe`,
the updater and the bundled binaries. SmartScreen stops warning once the signing
certificate has built reputation; with Artifact Signing that usually happens
after a modest number of downloads, not immediately on the first release.

The Windows icon has classic BMP frames for 16 to 64 px and a PNG frame only at
256 px. Explorer and the taskbar ignore PNG-compressed small frames in some
places, which shows up as a missing or generic `.exe` icon.

For a local signed build, pass `-SigningMetadata C:/signing/metadata.json` after
authenticating with Azure. Do not commit credentials or account-specific files.

## Lifecycle

The launcher's very first call handles Velopack lifecycle hooks. Normal startup
locks the user data directory and starts the daemon behind a
startup pipe. On Windows it assigns the daemon to a private job object before
releasing the pipe, so every game inherits the job. Closing the lobby ends the
desktop daemon; the launcher terminates and waits for all remaining descendants
before applying a pending update. Killing the launcher also closes its job.
The standalone/headless daemon retains its existing resident behavior.

The launcher checks for an update at startup and again every 30 minutes until
one is downloaded, so a PC that keeps GameNight open all evening still picks up
new releases. The update is applied when GameNight closes. An unfinished
download does not delay exit and is retried during a later session. Update failures are recorded in `updater.log`. There is no in-game
restart prompt and no update replacement while a session is running. Controller
input, focus, silent prewarm and fullscreen still require a real hardware check
before promoting a preview to stable.

## Starter downloads

The Windows package ships the catalog entries with Windows downloads, not game or LÖVE bytes.
The desktop daemon uses the same installer queue as the standalone host and
forwards download progress to the lobby. A finished install joins the playable
shelf immediately without restarting. GameNight can open offline; playing a
starter game the first time requires its download to finish.

A catalogue download can declare a shared `runtime` with an ID, HTTPS URL,
SHA-256, entrypoint and argument mode. `game_directory` passes the directory
containing the game's entrypoint to LÖVE; `entry_point` passes the file itself.
Runtimes are shared by ID and hash. Game and runtime entrypoints must both exist
before an install becomes playable. Downloads extract into staging directories
and publish only complete versions. Old versions and game saves are retained.
Failures do not prevent the lobby from opening; restart to retry failed downloads.
`GAMENIGHT_INSTALL_DIR` overrides the standalone install cache; the desktop
launcher sets it to `%LOCALAPPDATA%\GameNight\games` (or its test data override).


## Release acceptance

The package includes every catalog entry with a Windows download. Game archives stay outside the installer and use immutable HTTPS URLs
plus SHA-256 checksums. Test against an empty `GAMENIGHT_DATA_DIR`; a developer
shelf containing local `.love` paths is not download acceptance.

After launching the extracted release with the isolated data directory, run:

```
node scripts/test-installed-downloads.mjs ws://127.0.0.1:7912 download-e2e.json
```

This checks all seven party games appearing in the installed library, preparing,
starting, pausing and resuming through the real host. It refuses a party with
existing user profiles. It uses AI seats and does not replace a physical
controller/focus test or visual inspection. Keep the JSON and daemon logs.

The LÖVE pack CI renders real frames under Xvfb with Mesa software OpenGL;
Windows CI still runs simulation, authentication, certification and disconnect
checks against the official Windows LÖVE runtime. Interactive LÖVE error screens
must not hide failures in automated rendering jobs.

## App and installer branding

`web/icon.svg` is the editable logo. `scripts/generate-branding.cjs` produces the
shared multi-size Windows icon used by the lobby, launcher and Velopack installer.
Run it with Sharp available after changing the logo, then run its `--check` mode.
The launcher embeds Windows product/description metadata as GameNight. Preview
installers and their shortcuts use GameNight Preview; stable uses GameNight.
Package IDs remain distinct to keep their update channels separate.

The installer build checks executable and Setup icon resources and display names
with `scripts/test-windows-branding.ps1`. A successful resource compile alone is
not sufficient: the standalone launcher must link the resource into its EXE.
