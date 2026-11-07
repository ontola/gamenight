# Bevy

`gamenight-bevy` is a Bevy plugin that does the Gamepad Party side of a game for
you. Add it next to `DefaultPlugins`, read `GameNightEvent` messages and ask
`GameNight` for each seat's controller. The plugin:

- connects when Gamepad Party launched the game and runs standalone otherwise,
  with the keyboard and every local gamepad as seats, so your input code is
  the same in both modes;
- follows Prepare, Start, Pause, Resume and Dispose, and sends Ready two frames
  after you call `ready()`, so the first frame of your level exists before Start;
- keeps the window hidden and unfocused while warming, shows it borderless
  fullscreen on Start and Resume and hides it on Pause and Dispose;
- pauses every playing `AudioSink` while you are not on the TV and updates at
  10 fps while warm or paused, while still hearing Resume;
- gives each seat its own controller by host token, with deadzones, press
  edges and a release required after Start and Resume;
- reports activity so nobody is marked asleep, and rumbles a seat's pad;
- re-declares your settings, phone buttons, phone screen and text commands
  after every reconnect, and replays setting changes from your own menu;
- reports frame timing every ten seconds of play, with CPU, GPU, OS, memory
  and window size;
- sends F1 to the party (physical Back is the host's own) and exits when the
  host goes away.

The demo game in [`sdk/bevy/demo`](../../sdk/bevy/demo/src/main.rs), Star
Catch, uses every feature on this page. Each excerpt below is read from it.
CI runs it through the [conformance harness](/docs/testing) against a real
host on every push.

## Add the plugin

The plugin targets Bevy 0.20 (Rust 1.97.1 or newer). Pin a reviewed commit of
the public repository:

```toml
[dependencies]
bevy = "0.20"
gamenight-bevy = { git = "https://github.com/ontola/gamepad-party", rev = "YOUR_REVIEWED_COMMIT" }
```

Replace `YOUR_REVIEWED_COMMIT` with an actual commit hash.

## Set up the app

Wrap your window in `managed_window`, so a game Gamepad Party launched starts
hidden and unfocused. A window that flashes up while warming steals the TV
from the game being played. Run simulation systems only while
`gameplay_runs`: that is what freezes play, timers and bots on Pause.

::: source rust sdk/bevy/demo/src/main.rs "fn main() {" "// ── Command line"

`GameNightPlugin::new` turns the window, audio and throttling on. Set
`manage_window`, `fullscreen`, `manage_audio`, `throttle_when_hidden` or
`report_activity` to false to handle one of them yourself.

## Follow the session

Every message from Gamepad Party arrives as a `GameNightEvent`. On Prepare, build
the level for exactly the seats you were given, then call `ready()`. Opt into
live roster changes with `participation(true)` first if new players can join
mid-round, as here. Nothing restarts on `RosterChanged` or `PlayersUpdated`:
newcomers get a pawn, leavers lose theirs, and a new name, colour or face is
painted onto the same pawn.

::: source rust sdk/bevy/demo/src/main.rs "fn gamenight_events(" "/// Plain-text requests"

Prepare can follow a Dispose in the same frame (a replay, a skip). Despawn
with `try_despawn` and skip entities you already removed in the same batch.

## Read each seat's controller

`gn.pad(seat)` returns the seat's controller for this frame: neutral when the
seat has none, when input is more than 250 ms old and while the game is not
running. `stick` applies a radial deadzone (up is positive y, as in Bevy's
world), `trigger` a trigger deadzone. `just_pressed` is true once per press,
and a button still held from the lobby has to be released before it counts.
Never use Bevy's gamepad order under Gamepad Party: a seat's controller is a host
token.

::: source rust sdk/bevy/demo/src/main.rs "fn steer(" "fn bots("

AI seats get bots, empty seats get nothing. `rumble(seat, weak, strong,
seconds)` vibrates a pad; standalone it drives the local gamepad.

## Declare settings, phone buttons and a phone screen

Declare once at startup; the plugin declares again after each reconnect, and
Gamepad Party replays the values the party picked. A `player` scope gives every
player a value of their own, which arrives as `PlayerSettings`.

::: source rust sdk/bevy/demo/src/main.rs "fn settings() -> Vec<SettingSpec> {" "#[derive(Clone)]"

::: source rust sdk/bevy/demo/src/main.rs "/// Declare once;" "// ── GameNight"

`declare_companion_folder` looks for a relative folder next to the executable,
under `BEVY_ASSET_ROOT` or `CARGO_MANIFEST_DIR`, then the working directory.
Ship the folder with your build. The page loads `/assets/companion.js`; see
[Phone screens](/docs/phone-screens) and the demo's
[phone page](../../sdk/bevy/demo/assets/phone/index.html).

Plain-text requests from the Gamepad Party app or the session assistant arrive as
`GameCommand`. Answer every one with `command_result`:

::: source rust sdk/bevy/demo/src/main.rs "fn command(gn: &mut GameNight" "/// Standalone, the game starts"

## The Start menu

Start opens your own menu, for everyone; Back belongs to Gamepad Party. The game's
name heads the menu, then Resume, then New round, then the settings, without
button hints. The menu changes settings through `set_setting`, so the change
also shows in the apps and comes back as `SettingChanged` (standalone too).

::: source rust sdk/bevy/demo/src/main.rs "/// Start opens and closes the menu" "fn next_value("

## Rounds keep going

At the end of a round, show the result briefly, put the winner in the room log,
save each player's progress and call `finished()`. Then start the next round
yourself: `finished()` does not end the session. Players leave with Back.

::: source rust sdk/bevy/demo/src/main.rs "fn round_clock(" "// ── Menu"

`save_player_data` keeps up to 64 KB of JSON with a player's profile between
nights; `player_data` reads it back. Guests keep it for the night only.

## Faces, colours and couch order

`avatar_image(player)` decodes a player's drawn face into a nearest-filtered
`Image` plus where the head sits in it. Draw a circle in the skin colour and
put the drawing's head centre on it. `hex_color` reads profile colours.

::: source rust sdk/bevy/demo/src/main.rs "/// The body in the player's colour" "/// A five-pointed star"

Lay anything that runs left to right out with `couch_order(seats, players)`:
the order in which players sit, which they choose in the lobby. Call it again
when players update, because people move mid-match.

## Host music

When the host plays music, `GameNightEvent::HostMusic { playing: true }`
arrives and `host_music_playing()` is true. Mute your music, not your effects,
and turn it back up when it stops.

## Run and test

```sh
cd sdk/bevy
cargo run -p bevy-demo                      # standalone: keyboard and gamepads
cargo run -p bevy-demo -- --bots 3          # with three bots
cargo run -p bevy-demo -- --bots 3 --shot star-catch.png
xvfb-run -a cargo test --workspace          # plugin tests and the conformance harness
```

To play it through a development host, start the host and set
`GAMENIGHT_ADDR=127.0.0.1:7912` before running the demo. For your own game, run
the harness the same way, with your game id and binary:

```sh
cargo run -p gamenight-certify -- my-game --players 2 -- path/to/my-game
```

## What is not covered yet

These were checked on Linux (X11, software rendering) with synthetic
controller frames. Windows and macOS window behaviour, the Windows
foreground-permission helper the Godot SDK uses on Pause, physical
controllers and real audio devices still need testing on hardware. The
plugin hides the window rather than minimising it; Alt-Tab back to a paused
game goes through the lobby. See [Engine support](/docs/engines) for how this
compares with the other engines.
