# GameNight SDK for Godot

Integrate an existing Godot 4 game with a GameNight party in under an hour.

## Install

Copy `addons/gamenight/` into your project and enable the **GameNight** plugin
(Project → Project Settings → Plugins), or run `sdk/godot/install.sh
/path/to/your/project`, which does the copying and tells you the two autoload
lines to add.

The plugin registers two autoloads:

| autoload | what it is |
|---|---|
| `GameNight` | the daemon connection: signals in, `notify_*` out |
| `GameNightScreen` | the window: off-screen while warm, on the TV from `start` |

`GameNightScreen` is the part you would otherwise write yourself, badly, once
— and it is inert unless a daemon launched you. Left alone it hides and mutes
your window at boot, throttles the frame rate the moment you report `ready`
(never before: loading is what those frames are for), takes the screen on
`start` and `resume`, and steps out of the way on `pause` and `dispose` so the
lobby can come forward at all. It also reports a window the party Cmd+Tabbed
to as `request_start`, so reaching for your game is a way to start it.

Every step of that is a window-server negotiation that can be declined, and
the retry logic — different waits for different transitions, a deadline, and a
fallback that parks the window off-screen — is the accumulated result of
getting it wrong in three games. If your game needs to sequence the window
against something of its own, set `GameNightScreen.automatic = false` and call
`go_quiet()` / `settle()` / `take_the_screen()` yourself.

## Integrate

When the GameNight daemon launches your game, the addon detects the
`GAMENIGHT_*` environment automatically — game id, daemon address and launch
token all arrive from the launcher, and `GameNight.launched_by_daemon` is
true (skip your title screen, wait for `prepared`). Started by hand, the same
build runs as a normal standalone game.

```gdscript
func _ready() -> void:
    GameNight.game_id = "my-game"        # fallback for standalone runs
    GameNight.prepared.connect(_on_prepared)
    GameNight.started.connect(_on_started)
    GameNight.disposed.connect(_on_disposed)

var _session: String

func _on_prepared(session_id: String, seats: Array, players: Array) -> void:
    _session = session_id
    # Load your arena, spawn one pawn per occupied seat. Seat dicts look like
    # {"index": 0, "occupant": {"kind": "local", "player_id": "..."}}.
    # Do NOT show anything yet — you are warming up behind the current game.
    GameNight.notify_ready(_session)

func _on_started(_session_id: String) -> void:
    # You are live. Start the match instantly — no menus, no intro videos.
    start_match()

func _match_over() -> void:
    GameNight.notify_finished(_session)
    # Keep rendering (scoreboard, fireworks) until `disposed` arrives.

func _on_disposed(_session_id: String) -> void:
    reset_to_empty()   # a new `prepared` may follow later tonight
```

One pawn per occupied seat, and one *device* per local seat:

```gdscript
func _on_started(_session_id: String) -> void:
    # On `start`, not on `prepare`: while warming you are minimised and
    # unfocused, where a pad that just connected may not be enumerated yet.
    var devices := GameNight.devices_for_local_seats(GameNight.local_seat_count(_seats))
    for seat in range(devices.size()):
        bind_player(seat, devices[seat])     # -1 means keyboard/mouse
    # Short when a seat had no device left: fill the gap with a bot rather
    # than leave the match a player down and waiting forever.
    spawn_bots(GameNight.ai_seat_count(_seats)
        + GameNight.local_seat_count(_seats) - devices.size())
    start_match()
```

`devices_for_local_seats` is the rule every game was inventing separately:
connected pads in seat order, keyboard/mouse last and only once (there is one
mouse — give it to two seats and one mouse turns two heads), and a seat with
nothing left to drive it left out rather than doubled up.

That's the whole contract: receive a session, seats and players; say when you
are ready; say when the match is over. Pause/resume (`GameNight.paused` /
`GameNight.resumed`) are optional but appreciated.

Optionally, declare your match settings and the party — or an LLM saying
"hey GameNight, disable items" — can change them without anyone opening a
menu:

```gdscript
func _ready() -> void:
    GameNight.declare_settings([
        {"key": "items", "label": "Items", "kind": "toggle", "default": true,
         "description": "Whether power-up items spawn during a match."},
        {"key": "stock", "label": "Stock", "kind": "number",
         "default": 3, "min": 1, "max": 99},
    ])
    GameNight.setting_changed.connect(_on_setting_changed)

func _on_setting_changed(key: String, value: Variant) -> void:
    match key:
        "items": items_enabled = value   # applies live
        "stock": stock = value           # applies from the next match
```

The daemon validates every write against your declaration and remembers the
values across reconnects — never build your own settings menu in game-night
mode.

For the full picture — what `ready` promises, how seats work, the test
checklist — read the integration guide at
[`docs/integrating-your-game.md`](../../docs/integrating-your-game.md).
The wire format is in [`docs/protocol.md`](../../docs/protocol.md) if you'd
rather talk WebSockets directly.
