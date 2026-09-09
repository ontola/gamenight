# GameNight Windows developer preview

Experimental local multiplayer for Windows x64. No Rust, Python, .NET, account
or cloud service is required on the player's computer.

For releases that include **Setup.exe**, run it once. It installs for the current
user, adds a shortcut, and opens GameNight. No administrator account is required.
The portable ZIP also works: extract it and run **GameNight.exe**. Close the lobby
to close GameNight and all its games; there is no separate console to manage.
The older `v0.1.0-preview.1` ZIP uses a console and Enter to exit instead.

Connect two controllers and press a button on each to join the lobby. Pinpals
is the first game. Walk onto Start and jump to play. Back/Select returns to
the lobby. The game should remain hidden and silent while preparing.

Installed builds check the public GitHub releases for updates in the background.
A downloaded update is applied only after the lobby and all game processes have
closed. Slow, offline or failed downloads do not hold up startup or shutdown.
Preview builds stay on the preview channel; stable builds stay on stable.
Portable builds are updated by downloading a new ZIP.

Logs and versioned game content live under `%LOCALAPPDATA%\GameNight`, outside
the replaceable application directory. Game saves remain in the game's own user
save directory. `shelf.json` in this folder is generated, not a settings file.
`GAMENIGHT_DATA_DIR` can override the GameNight data directory with an absolute
path for testing. It does not relocate a game's own saves. Uninstalling GameNight
does not intentionally delete its external user data or the game's saves.

## Included versions

- GameNight: native Windows developer build (unsigned).
- Pinpals: Polle Pas's MIT-licensed game, using the GameNight integration fork
  at `95ea42fe544cf3906c90aeb556359180964c1e88`.
  [Upstream integration PR](https://github.com/Polleps/pinpals/pull/1) is pending;
  this is not an upstream Pinpals release.
- LÖVE 11.5: official Windows x64 runtime, including its license notices.
- Lobby/Bones: see the included notices and media credits.

This preview is intended for feedback. Controller mappings and focus should
be checked on your hardware. Use Windows native, rather than Linux binaries
through WSL. Unsigned preview installers can trigger a Windows warning.

## Rebuild the preview

From a native Windows checkout with Rust/MSVC and Python 3 installed:

```powershell
./scripts/build-windows-preview.ps1 -OutputDir C:/builds/gamenight-preview -TargetDir C:/builds/gamenight-target
```

Use a new output directory. The build fetches fixed Pinpals and LÖVE versions
and validates their SHA-256 hashes. The package includes license notices.
For the installer and release workflow, see [Windows distribution](windows-distribution.md).
Controller gameplay should still be tested before promoting a preview to stable.
