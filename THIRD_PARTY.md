# Third-party sources

## Lobby

`crates/lobby` derives from Fish Folk: Jumpy. Its MIT/Apache notices and
contributors are preserved in `crates/lobby/LICENSE`, `licenses/` and
`CREDITS.md`. GameNight adds the local party integration and lobby map.

Media sources and replacement scripts are in
`crates/lobby/tools/reskin/ASSET-SOURCES.md`. Keep the separate font notices
with distributions. The current source snapshot does not include the removed
upstream combat maps or earlier Git history.

## Bones

`vendor/bones` is a source snapshot of https://github.com/fishfolk/bones at
revision `7e1d92578e1b35256debfb95492d0a519d8c796e` (the revision resolved by the lobby lockfile), with upstream
license notices. The local change in `bones_asset/src/server.rs` checks that
a cached ID exists in the raw-byte store before returning it. This avoids a
cooked-ID/raw-ID cache mismatch during concurrent asset loading.

Vendoring makes a new clone build without a private fork or an untracked
patch. Update the snapshot, revision and modification note together.

## Windows binary distributions

Windows packages include the Microsoft Visual C++ Runtime DLLs from the build
machine's licensed Visual Studio redistributable directory, under Microsoft's
license terms. These files are not part of GameNight's MIT-licensed source.
`notices/msvc-runtime.txt` in each package identifies the runtime version.
See Microsoft's [redistribution documentation](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files).
The app-local copies must be refreshed through GameNight releases when Microsoft
updates the runtime; they are not maintained by Windows Update.

The pinned LOVE distribution also includes its own runtime libraries and license
notices. Pinpals and its selected source revision are listed in the Windows
preview instructions shipped with the package.
