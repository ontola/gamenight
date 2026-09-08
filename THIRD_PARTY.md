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
