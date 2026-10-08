# Godot 4

The Godot addon handles lifecycle messages, runtime controller frames and live
player profiles over WebSocket. Your game connects these to its simulation and
rendering.

## Install

Copy `sdk/godot/addons/gamenight` into your project’s `addons` directory and enable GameNight in Project Settings → Plugins. The plugin registers `GameNight` and `GameNightScreen` autoloads.

Godot has no package manager, so every game keeps its own copy of the addon, and copies fall behind. Run `python sdk/godot/sync.py path/to/your/game` from a GameNight checkout to update it, and add the drift check to your game's CI. It fails as soon as your copy differs from the SDK on `main`:

```yaml
jobs:
  gamenight-sdk:
    uses: ontola/gamenight/.github/workflows/godot-sdk-check.yml@main
    with:
      path: .  # the folder that holds project.godot
```

The connection reads the launch environment automatically. Keep standalone menus separate from the managed path using `GameNight.launched_by_daemon`.

## Lifecycle signals

These declarations come directly from the addon:

::: source gdscript sdk/godot/addons/gamenight/gamenight.gd "signal prepared(" "## Connection"

Connect each signal to your game. Prepare loads a level while hidden; Start begins play. Pause must freeze gameplay, timers and audio. Resume continues the same state. Dispose clears session resources but permits a later Prepare.

The autoload processes while the scene tree is paused, so it can receive Resume.
In managed mode, losing the host clears input and exits the game. Standalone
development connections may reconnect automatically.

## Report preparation progress

The addon provides this implementation:

::: source gdscript sdk/godot/addons/gamenight/gamenight.gd "func notify_progress(" "## A player asked"

Call `GameNight.notify_ready(session_id)` only after your level and first frame are prepared. `notify_finished` reports a round; your game still owns the results screen and next round.

## Controllers and live profiles

Use the runtime stream in managed play. A seat's controller token is opaque;
it is not a Godot joystick index. `frame_for_seat` resolves the token from the
latest roster, returns a copy, and returns an empty frame while paused or when
input is more than 250 ms old.

```gdscript
func _physics_process(delta: float) -> void:
    if GameNight.phase != "running":
        return
    var frame = GameNight.frame_for_seat(0)
    var movement = Vector2(GameNight.axis(frame, 0), GameNight.axis(frame, 1))
    # Apply movement to the character assigned to seat 0.
    if GameNight.button(frame, 0): # A, held; add your own press-edge detection.
        pass
```

Use `GameNight.roster_changed` to refresh seat ownership, names, skin colour
and avatar artwork. The current snapshot is available in `GameNight.party`.
`devices_for_local_seats()` is only for standalone play and returns no native
devices in managed mode. Back/Select belongs to the host; do not bind native
Back to a second pause/resume handler.

For circular faces, use `face.gd` with a head centre and radius. See the
[face helper example](/docs/lobbies#faces-and-names). The helper draws the skin
circle under the artwork and supports historic avatar anchors.

## Screen ownership

`GameNightScreen` follows Start, Pause, Resume and Dispose. OS focus does not
request Start or Resume. A game preparing in the background stays quiet until
the runtime explicitly starts it. The helper handles the window and master
audio bus; your lifecycle callbacks must still pause the simulation and timers.

## Godot lobby example

The SDK includes a runnable Living Room project using a separate authenticated
lobby client. It shows live player names and faces and can join, queue, play
and resume. See [Build a lobby](/docs/lobbies) for launch instructions and the
runtime-owned controller contract. Its client is independent of the game autoloads.

## Before release

Check the [lifecycle contract](/docs/lifecycle) and [controller stream](/docs/controllers), then run [packaged integration checks](/docs/testing). Run `python scripts/test-godot-sdk.py --godot /path/to/godot` for the headless
adapter regression checks. The lobby has a separate real-daemon flow test.
These tests and source-checked documentation do not verify your game callbacks,
physical controllers or platform window behaviour. Enabling the plugin alone
does not certify a game.

## Optional performance diagnostics

The GameNight autoload samples application frame intervals while running and reports them every ten active seconds, with CPU/GPU model, OS, physical RAM and window dimensions. Rebuild your game to ship this adapter update. See the [protocol reference](../protocol.md#session-diagnostics) for counters, limits and missing-data semantics. These diagnostics contain no accounts, behavioral history or recommendation logic.


## Yield your soundtrack to host music

The welcome snapshot and subsequent `GameNight.party_updated` snapshots include
`now_playing` when GameNight detects a host music player. Check `playing`, not
just whether a track exists: paused tracks still have metadata. When it is true,
mute your music bus only. Keep effects audible and preserve the player's own
music preference. Restore that preference when host music pauses or disappears.

```gdscript
func _ready():
    GameNight.party_updated.connect(_host_music)
    _host_music(GameNight.party)

func _host_music(party: Dictionary):
    var track = party.get("now_playing", {})
    var playing = track is Dictionary and bool(track.get("playing", false))
    AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), playing)
```

Use a dedicated `Music` bus. Growing Guns uses `MusicA` and `MusicB` for its two
soundtrack layers. Do not mute `Master`: that also silences game effects.

For a game that prepares before being played, set `display/window/size/mode` to
`1` (Minimized) and `display/window/size/no_focus` to `true` at engine startup.
Minimizing in `_ready()` is too late to prevent the initial window appearing.
Use `GameNightScreen` for Start/Resume and explicitly claim the screen in your
standalone launch path. OS focus must never request gameplay.
