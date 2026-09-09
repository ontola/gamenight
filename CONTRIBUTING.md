# Contributing

Start with a reproducible issue, a small SDK improvement, or an integration
for a game you maintain. Keep protocol additions backward-compatible and
preserve standalone game behavior.

## Checks

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo build --manifest-path crates/lobby/Cargo.toml --locked
```

The lobby is a separate workspace; building only the root does not validate it.
The vendored engine is included so no private checkout is needed.

For a game integration, run `gamenight-certify` and report any skipped checks.
Verify hidden/silent preparation, start focus, real controller input, pause,
resume, replay and closing the window on your platform. Do not label a game
certified based only on its metadata.

Changes to downloads should include the exact upstream release, checksum and
entrypoint. Keep credentials, machine-specific paths and private notes out of
contributions. Preserve upstream notices for third-party code and media.

See [development setup](docs/development.md) for platform requirements and
[the SDK guide](docs/integrating-your-game.md) for the lifecycle contract.
