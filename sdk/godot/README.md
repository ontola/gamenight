# GameNight for Godot 4

Start with the [Godot integration guide](../../docs/site/godot.md), published in
[GameNight Docs](https://gamenight.ontola.io/docs/godot). It covers installation,
lifecycle signals, seat-based controller input, faces and release testing.

For the runnable **Living Room lobby**, open this directory's `project.godot`
and follow [Build a lobby](../../docs/site/lobbies.md), published at
[GameNight Docs / Lobbies](https://gamenight.ontola.io/docs/lobbies).
It uses the separate `lobby.gd` client and reusable `face.gd` renderer.
Run it through `python scripts/run-local.py --lobby godot --godot /path/to/godot`.

Copy `addons/gamenight` into your project and enable the plugin. It registers
`GameNight` and `GameNightScreen` autoloads. The connection reads the host launch
environment automatically.

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
