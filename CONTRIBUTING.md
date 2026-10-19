# Contributing

Start with a reproducible issue, a small SDK improvement, or an integration
for a game you maintain. Keep protocol additions backward-compatible and
preserve standalone game behavior.

## Checks

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
python sdk/godot/sync.py --check lobbies/game-room
```

The Game Room lobby is a Godot 4.5 project; CI runs its tests in
`lobbies/game-room/tests` with a pinned Godot (see `.github/workflows/ci.yml`).

For a game integration, run `gamenight-certify` and report any skipped checks.
Verify hidden/silent preparation, start focus, real controller input, pause,
resume, replay and closing the window on your platform. Do not label a game
certified based only on its metadata.

Changes to downloads should include the exact upstream release, checksum and
entrypoint. Keep credentials, machine-specific paths and private notes out of
contributions. Preserve upstream notices for third-party code and media.

See [development setup](docs/development.md) for platform requirements and
[the SDK guide](docs/integrating-your-game.md) for the lifecycle contract.
