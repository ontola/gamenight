# GameNight Windows developer preview

Experimental local multiplayer for Windows x64. No Rust, Python, account or
cloud service is required. Extract the ZIP to a writable folder, then run
**GameNight.exe**. Keep the console open; press Enter
there to close the host and its games. Use a normal, non-administrator account.
The launcher does not use PowerShell.

Connect two controllers and press a button on each to join the lobby. Pinpals
is the first game. Walk onto Start and jump to play. Back/Select returns to
the lobby. The game should remain hidden and silent while preparing.
Logs are stored in `.local` inside the extracted folder.

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
through WSL. There is no automatic update or installation service.

## Rebuild the preview

From a native Windows checkout with Rust/MSVC and Python 3 installed:

```powershell
./scripts/build-windows-preview.ps1 -OutputDir C:/builds/gamenight-preview -TargetDir C:/builds/gamenight-target
```

Use a new output directory. The build fetches fixed Pinpals and LÖVE versions
and validates their SHA-256 hashes. The package includes license notices.
The **Package Windows preview** Actions workflow performs the same build.
Controller gameplay should still be tested before promoting a preview to stable.
