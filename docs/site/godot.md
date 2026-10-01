# Godot 4

The Godot addon exposes lifecycle signals over WebSocket. It is a starting point, not a complete current integration. Read the gaps below before shipping with it.

## Install

Copy `sdk/godot/addons/gamenight` into your project’s `addons` directory and enable GameNight in Project Settings → Plugins. The plugin registers `GameNight` and `GameNightScreen` autoloads.

The connection reads the launch environment automatically. Keep standalone menus separate from the managed path using `GameNight.launched_by_daemon`.

## Lifecycle signals

These declarations come directly from the addon:

::: source gdscript sdk/godot/addons/gamenight/gamenight.gd "signal prepared(" "## Connection"

Connect each signal to your game. Prepare loads a level while hidden; Start begins play. Pause must freeze gameplay, timers and audio. Resume continues the same state. Dispose clears session resources but permits a later Prepare.

Keep `GameNight` processing while your scene is paused. Its transport must still receive Resume. Opt out of reconnecting and exit cleanly on host loss in managed mode.

## Report preparation progress

The addon provides this implementation:

::: source gdscript sdk/godot/addons/gamenight/gamenight.gd "func notify_progress(" "## A player asked"

Call `GameNight.notify_ready(session_id)` only after your level and first frame are prepared. `notify_finished` reports a round; your game still owns the results screen and next round.

## Current gaps

The addon does not dispatch `controller_frame` or game `party_updated` messages. Its `party_updated` signal currently comes from the overlay-style `party_state` snapshot. Add the game message handlers and match controller tokens to seats; `devices_for_local_seats()` uses local enumeration and is not safe for managed ownership.

`GameNightScreen` currently calls `request_start()` on focus. That conflicts with the current contract: focus must not start or resume a game. Remove that focus-triggered path before shipping. Setting `automatic = false` after its `_ready()` has run does not disconnect existing signals.

The default connection retries automatically. Managed games need to handle disconnection by stopping and exiting. There is no built-in circular-face renderer in this addon; implement the [face transform](/docs/faces) in your scene.

## Before release

Check the [lifecycle contract](/docs/lifecycle) and [controller stream](/docs/controllers), then run [packaged integration checks](/docs/testing). These documentation excerpts are checked against source. There is no Godot runtime test attached to this docs build, and enabling the plugin alone does not prove compatibility.

## Optional performance diagnostics

The GameNight autoload samples application frame intervals while running and reports them every ten active seconds, with CPU/GPU model, OS, physical RAM and window dimensions. Rebuild your game to ship this adapter update. See the [protocol reference](../protocol.md#session-diagnostics) for counters, limits and missing-data semantics. These diagnostics contain no accounts, behavioral history or recommendation logic.
