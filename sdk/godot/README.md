# GameNight for Godot 4

Start with the [Godot integration guide](../../docs/site/godot.md), published in
[GameNight Docs](https://gamenight.ontola.io/docs/godot). It covers installation,
lifecycle signals, current gaps and release testing.

Copy `addons/gamenight` into your project and enable the plugin. It registers
`GameNight` and `GameNightScreen` autoloads. The connection reads the host launch
environment automatically.

This addon is not yet a complete implementation of the current contract:

- It does not dispatch host controller frames or game roster updates.
- Its screen helper requests Start on focus. Remove that path for managed play.
- It enumerates local devices; that cannot establish host controller ownership.

Pause/resume is required. Games own round results and continue until players
switch games. A handshake does not certify input, window behaviour or faces.
The guide is built from canonical Markdown and excerpts from this addon; CI
flags changes to its watched implementation for documentation review.