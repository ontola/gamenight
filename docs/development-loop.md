# Fast local iteration

Windows controllers need the native Windows lobby. Run these commands in
PowerShell from the public repository; the source may live in WSL, but the
build cache and staged assets default to Windows storage.

Requires Windows Rust/Cargo and Python 3 (`-PythonExe` accepts its full path).
If PowerShell treats a WSL UNC script as unsigned remote content, invoke it
with `pwsh -NoProfile -ExecutionPolicy Bypass -File ./scripts/dev-windows.ps1`
followed by the same arguments. This applies to that process only.

```powershell
# Initial build. Packaging/installer creation is a separate operation.
./scripts/dev-windows.ps1 -Action build
./scripts/dev-windows.ps1 -Action start

# No Cargo invocation: stop this launcher's session, sync changed assets, launch.
./scripts/dev-windows.ps1 -Action restart

# Rust edit: explicitly select the component that changed.
./scripts/dev-windows.ps1 -Action stop
./scripts/dev-windows.ps1 -Action build -Component lobby
./scripts/dev-windows.ps1 -Action start
# Use -Component host for daemon/local-web Rust changes; all for shared protocol changes.
```

The default preview is lobby-only, connected to gamenight.ontola.io. Supply
`-Shelf path/to/library.json` when starting to include games. Restart preserves
the staged library. Use `-CloudUrl ''` for offline mode. Close older previews
launched by other scripts before starting: this launcher never adopts or kills
unknown processes. `stop` verifies its recorded PID, creation time and executable
before terminating its own process tree. Restart creates a new party session.

## Web and artwork

In the lobby, X (the controller's west button) punches when unarmed and keeps
its existing weapon action when armed. Each press strikes once after a short
wind-up; misses still consume the 0.32-second cooldown. Nonlethal hits push the
victim back. Four punches received within a rolling two-second window trigger
the normal death/respawn flow; isolated hits expire. Spawn invulnerability and
solid obstacles are respected. The fist is hand-pixelled in `punch_visual.rs`;
its wind-up/extension/retraction reuse that drawing and the player's skin colour.

The launcher sets `GAMENIGHT_DEV_WEB_DIR` to the public `web` directory.
Refresh the **local** studio after HTML/CSS/JS edits; no build or restart is
needed. Local URLs carrying pairing parameters still redirect to cloud sign-in.
Changes to this local directory do not update the hosted site. Clear the env
variable to use embedded production files. Missing development files return an
error rather than silently showing stale embedded content. Only known public
web assets are served; arbitrary repository files are not exposed.

`-Action sync` stages only changed lobby assets/packs; restart runs it as well.
Size/timestamps provide the fast path; changed files are hashed before copying.
If an external tool deliberately preserves both size and timestamp while editing,
delete `.dev-assets.json` to force a full comparison. Removed files
are deleted only when listed in the previous staging manifest. Web files are
served directly, not staged. Asset/map changes may require restart to reload.

## Timing

For remote visual review, capture the actual game framebuffer:

```powershell
./scripts/dev-windows.ps1 -Action start -Screenshot C:/Temp/lobby.png -CleanView
```

Create the output directory first. The game captures after ten seconds and
then exits. `-CleanView` hides only the connect-controller overlay during capture;
omit it to inspect the normal attract screen. This is a snapshot, not streaming.
No players, queued games or pending profiles are invented for the screenshot.

The launcher reports sync and process-launch duration. `daemon.log` / 
`daemon.err.log` in the runtime directory record:

- `first_window_frame_submitted`: first acquired window frame after Bevy's render/present step.
- `lobby_scene_ready`: lobby session exists and Bones preload completed without errors.
- `first_lobby_frame_submitted`: first render/present step after that readiness condition.

Each has `elapsed_ms` measured from the start of lobby `main`. The first window
frame may show loading. Submission is not a measurement of physical monitor
scanout, nor a guarantee that every shader is compiled or every pixel correct.
Use a visual check for black-screen regressions.

Production archives/installers continue to use `build-windows-preview.ps1` and
`build-windows-installer.ps1`. Neither is part of restart. WSL filesystem overhead
has not been isolated; benchmark a native checkout before attributing build time
to that boundary or changing compiler optimization settings.
