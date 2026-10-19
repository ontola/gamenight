# Third-party sources

## Game Room lobby

`lobbies/game-room` is GameNight's own lobby. Desktop packages run it with the
unmodified Godot 4.5.2 editor binary (MIT, `lobbies/game-room/GODOT-LICENSE.txt`).
Its fonts keep their SIL Open Font License notices next to them in
`lobbies/game-room/assets/fonts`. Packages carry these notices in
`notices/game-room`.

The Clubhouse lobby (`crates/lobby`, derived from Fish Folk: Jumpy, with the
vendored Bones framework and `bevy_gilrs`) was retired in October 2026; its
notices and media credits remain in the repository history.

## Fonts for catalog artwork

`scripts/fonts/FairfaxSM.ttf` (Kreative Software, SIL Open Font License 1.1,
`scripts/fonts/FairfaxSM.ttf.license.txt`) is used unchanged by
`scripts/build-catalog-art.py`.

## Windows binary distributions

Windows packages include the Microsoft Visual C++ Runtime DLLs from the build
machine's licensed Visual Studio redistributable directory, under Microsoft's
license terms. These files are not part of GameNight's MIT-licensed source.
`notices/msvc-runtime.txt` in each package identifies the runtime version.
See Microsoft's [redistribution documentation](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files).
The app-local copies must be refreshed through GameNight releases when Microsoft
updates the runtime; they are not maintained by Windows Update.

The separately downloaded, pinned LOVE distribution includes its own runtime libraries and license
notices.
