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

A game you start by hand stays offline, so a test run never joins the party
on your machine. To connect it to a development host anyway, set
`GAMENIGHT_ADDR=127.0.0.1:7912`, or call `GameNight.connect_to_host()`.

Use the `GameNight` autoload and connect to its signals; don't subclass it and
override its message handling. A subclass that replaces `_handle` silently
loses performance reports, settings replay and future protocol features.

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

To get live roster updates, opt in from `prepared`, before Ready:

```gdscript
func _on_prepared(session_id: String, seats: Array, players: Array) -> void:
    GameNight.notify_participation(session_id, false)  # true: new players can join mid-round
    build_level(seats, players)
    GameNight.notify_ready(session_id)
```

Report real play with `GameNight.report_activity(seat)` on a press or a stick
past its deadzone, so GameNight does not mark a player asleep. It sends at
most once a second per controller. See [Controllers & players](/docs/controllers#joining-and-changing-profiles).

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
    var movement = GameNight.stick(frame, 0)          # left stick, deadzone applied
    var throttle = GameNight.trigger(frame, 1)        # right trigger, 0 to 1
    if GameNight.just_pressed(0, GameNight.BUTTON_A): # one press, one jump
        jump(0)
    if GameNight.button(frame, GameNight.BUTTON_X):   # held
        charge(0)
    if movement != Vector2.ZERO:
        GameNight.report_activity(0)
```

The SDK names every button and axis (`BUTTON_A` to `BUTTON_RIGHT`,
`AXIS_LEFT_X` to `AXIS_RIGHT_TRIGGER`). `stick` and `trigger` apply the
deadzones our games settled on (`STICK_DEADZONE` 0.15, `TRIGGER_DEADZONE`
0.06); pass your own as the last argument. `just_pressed` is true on the
physics tick a button went down; read it in `_physics_process`. After Start
and Resume, a button still held from the lobby must be released first, so the
press that started the game does not also fire in it.

`frame_for_seat` is empty while the session is not running. Your own Start
menu can read input while paused with `frame_for_seat(seat, true)`.

Use `GameNight.roster_changed` to refresh seat ownership, names, skin colour
and avatar artwork. The current snapshot is available in `GameNight.party`.

Connect `GameNight.players_updated` too. It fires when someone picks up a
profile in the lobby mid-match: the same players in the same seats, with a new
name, colour, face or `profile_key`. Update labels and faces in place and keep
the match going; never restart over it. Every game gets it, opted in or not.

Split-screen and other left-to-right layouts follow the couch, not the seat:
`GameNight.couch_order(seats, players)` returns the seats left to right as the
players sit (they pick their place in the lobby's Start menu). Call it again on
`players_updated`, because people can move mid-match; slide the views over.
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

### Keep the window hidden at launch

For a game that prepares before being played, set `display/window/size/mode` to
`1` (Minimized) and `display/window/size/no_focus` to `true` at engine startup.
Minimizing in `_ready()` is too late to prevent the initial window appearing.
Use `GameNightScreen` for Start/Resume and explicitly claim the screen in your
standalone launch path. OS focus must never request gameplay.

For a Windows game that keeps its normal standalone window settings, pass
`--position -30000,-30000` as engine arguments in its managed launch entry,
before any `--` separator for game arguments. This parks the initial window
before the SDK runs. `GameNightScreen` also parks a warming Windows window and
disables focus before minimizing, so the minimize animation stays off-screen.
Start/Resume restores focus and fullscreen.

The Windows host also launches games with a hidden initial window and no
console window, before the SDK connects. Console wrappers inherit the managed
environment; the host owns their entire child process tree. This suppresses
the first native show request, not later explicit requests made by the game.
Keep the minimized/no-focus startup settings or off-screen engine arguments,
and let `GameNightScreen` control visibility until Start/Resume. The persistent
lobby itself launches normally.

On Windows, a focused game grants foreground permission through the host's
`GAMENIGHT_FOREGROUND_HELPER` before minimizing on Pause. Warmup, disposal,
repeated pauses and games behind another app never grant that permission.
The Game Room retries a new host focus handoff for at most one second because
the pause and focus messages arrive in different processes. Acquiring or losing
native focus cancels the retry; Alt-Tab never starts another handoff. The same
ordering applies when a game uses `automatic = false` and calls
`take_the_screen()` / `go_quiet("pause")` itself. The Windows helper and native
desktop focus policy still need real-device validation; headless tests cover
the lifecycle ordering, not Windows foreground-lock behavior.

While warming, a minimized window never draws, so never await
`RenderingServer.frame_post_draw` before `notify_ready()`: it does not return
and the lobby waits on "preloading" forever. Await `get_tree().process_frame`
instead whenever `DisplayServer.window_get_mode()` is `WINDOW_MODE_MINIMIZED`.
Leave the window itself to `GameNightScreen`. Godot refuses `hide()` on the main
window, and on Windows setting `borderless` shows the window again.

## Phone screens

`GameNight.declare_companion_folder("res://phone")` serves a folder of your
game as each player's phone screen. See [Phone screens](/docs/phone-screens)
for the export settings it needs and how to keep the game in charge.

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

For what to do about the numbers, see [Performance](/docs/performance).

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
