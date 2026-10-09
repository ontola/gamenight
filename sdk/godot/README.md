# GameNight for Godot 4

Start with the [Godot integration guide](../../docs/site/godot.md), published in
[GameNight Docs](https://gamenight.ontola.io/docs/godot). It covers installation,
lifecycle signals, seat-based controller input, faces and release testing.

For the runnable **Living Room lobby**, open this directory's `project.godot`
and follow [Build a lobby](../../docs/site/lobbies.md), published at
[GameNight Docs / Lobbies](https://gamenight.ontola.io/docs/lobbies).
It uses the separate `lobby.gd` client and reusable `face.gd` renderer.
Run it through `python scripts/run-local.py --lobby godot --godot /path/to/godot`.

Copy `addons/gamenight` into your project with `sdk/godot/install.sh` and enable
the plugin. It registers `GameNight` and `GameNightScreen` autoloads. The
connection reads the host launch environment automatically.

Vendored copies drift. Update one with `python sdk/godot/sync.py path/to/game`
and let the game's CI fail when it falls behind:

```yaml
jobs:
  gamenight-sdk:
    uses: ontola/gamenight/.github/workflows/godot-sdk-check.yml@main
```

## Crowd sound

`addons/crowd_sound` is an optional procedural crowd: murmur, cheers, applause,
"ooh"s, screams and chants, all synthesized at boot, no samples. It came from
Growing Guns. Add it with `python sdk/godot/sync.py --add crowd_sound path/to/game`;
after that the same sync and CI check keep it current. Use it as a node, set
`active = true` while there is an audience, and call `kickoff()`, `hit()`,
`roar()`, `celebrate()`, `excite()` or `scare()`. Extend the script to route
one-shots through your own mixer or place sounds in 3D; the header lists the
hooks. Ballkickers and Growing Guns both use it.

Games that publish to the catalog can call
`ontola/gamenight/.github/workflows/publish-game.yml@main` from a `workflow_run`
workflow instead of copying the upload steps; the file shows an example.

Managed games read `GameNight.frame_for_seat(index)` rather than native joystick
indices. Subscribe to `roster_changed` for live profiles. Stale input is cleared,
OS focus never starts gameplay, and managed games exit when the host disconnects.

Run `python scripts/test-godot-sdk.py --godot /path/to/godot` from the repository
root. For the complete lobby flow, run `scripts/test-godot-lobby.py` after building
the daemon. These tests do not replace real controller and OS focus checks.

Pause/resume is required. Games own round results and continue until players
switch games. A handshake does not certify input, window behaviour or faces.
The guide is built from canonical Markdown and excerpts from this addon; CI
flags changes to its watched implementation for documentation review.
