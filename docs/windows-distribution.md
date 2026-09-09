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

The default profile is `release`; `-Profile ci` is a faster build for packaging
checks. Choose a new output directory. The script verifies the pinned Pinpals
and LOVE archive hashes, includes their notices, and produces `Setup.exe`, a
portable ZIP, a full update package, a channel feed and SHA-256 checksums in
`releases/`. This first implementation ships full updates. Delta packaging can
be added later by supplying the preceding release to Velopack.

The application IDs are `Ontola.GameNight.Preview` and `Ontola.GameNight`, and
the channels are `win-preview` and `win-stable`. The installation directories
are separate from `%LOCALAPPDATA%\GameNight` user data. Application updates
replace the complete application folder, while pinned content is seeded once
into version-specific user directories. Old content versions are retained.
Both channels share GameNight user data and cannot run simultaneously against
that directory. LOVE manages Pinpals saves independently.

## CI and releases

The normal **Build and test** workflow tests the runtime on Windows, Linux and
macOS. Windows also installs an isolated fixture using real Velopack installers
and the production update/data/process helpers. It checks offline startup,
rejection of a corrupt update, deferral until exit, restart on the new version,
data preservation and termination of a child process. It uses a unique app ID
and uninstalls the fixture after the test. This is not a controller/GPU test.

**Windows installer** builds a complete package on relevant pull requests using
the `ci` profile. Run it manually from `main` for an optimized release, choosing
a version and channel. `publish=true` uploads all assets to a **draft** GitHub
release. Finish reviewing it and the CI results before publishing the draft.
Only published releases enter the update feed. A preview must remain marked as
a GitHub prerelease. Upload the feed and all `.nupkg` files together with Setup;
Setup alone cannot serve automatic updates. Existing releases are never
silently overwritten.

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

For a local signed build, pass `-SigningMetadata C:/signing/metadata.json` after
authenticating with Azure. Do not commit credentials or account-specific files.

## Lifecycle

The launcher's very first call handles Velopack lifecycle hooks. Normal startup
locks the user data directory, seeds content, and starts the daemon behind a
startup pipe. On Windows it assigns the daemon to a private job object before
releasing the pipe, so every game inherits the job. Closing the lobby ends the
desktop daemon; the launcher terminates and waits for all remaining descendants
before applying a pending update. Killing the launcher also closes its job.
The standalone/headless daemon retains its existing resident behavior.

An unfinished download does not delay exit and is retried during a later
session. Update failures are recorded in `updater.log`. There is no in-game
restart prompt and no update replacement while a session is running. Controller
input, focus, silent prewarm and fullscreen still require a real hardware check
before promoting a preview to stable.
