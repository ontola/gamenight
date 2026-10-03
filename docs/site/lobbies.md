# Build a lobby

A lobby is a persistent party interface, implemented as a separate executable.
The runtime owns players, controller bindings and game sessions. The lobby
chooses how to present them. The Godot Living Room is a runnable example with
names, custom faces, guest joining, game selection, queueing and resume.

## Run the Godot example

Install Godot 4.5 or newer and the [development dependencies](../development.md).
From the repository root:

```sh
python scripts/run-local.py --lobby godot --godot /path/to/godot --shelf /path/to/games.json
```

On Windows, pass the Godot executable path. With no shelf, the script supplies
the terminal SDK demo. `--skip-build` reuses existing Rust binaries. The default
lobby remains the bundled platformer; this option selects `godot-lobby`.

Open `sdk/godot/project.godot` in the editor to change the example. Start it
through the runtime to get an authenticated connection. Opening the project
alone displays a connecting screen, not a synthetic party.

Controls: connected controllers join automatically. LT/RT cycle games; the
selected game is larger in the centre of its two neighbours. The stick/D-pad
moves between controls. On a game card, A appends a new occurrence to the queue;
X inserts it first among upcoming games. Neither action starts gameplay. The
merged queue panel shows its first entry as Up next, with the remaining games
alongside it. Select Start game to launch the head of the queue. Back returns to
the lobby or resumes an overlay-paused game. Y leaves that controller's seat.

The controller hint bar shows **X Play next · A Queue · LT Previous · RT Next**
with Xbox-style face-button and trigger icons. These hints are not selectable;
focus stays on the game cards and the other lobby controls.

## Talk to the assistant

When `GAMENIGHT_ASSISTANT_URL` supplies an authenticated session entry, select
**Talk to assistant** and hold A, or hold the control with the mouse. Keyboard
users can hold C. A pulsing microphone shows when recording is active. Release
to transcribe and send; B or Escape cancels before submission. The Menu/Start
button has no assistant shortcut. The lobby remains open throughout the request
and shows the assistant's result. Closing a submitted request's panel does not
undo a game change already sent to the host.

This source example currently transcribes with the installed Windows speech
recognizer. Enable microphone access for desktop apps and install a Windows
speech language. Recording lasts at most 20 seconds and stops on release,
focus loss, controller disconnection or loss of the runtime connection. Audio
is transcribed locally; only the text reaches the existing assistant API. The
temporary WAV is deleted after transcription. A process crash may leave that
file in Godot's user-data directory. The recording effect only runs while the
talk control is held, up to the 20-second limit.

The current native sign-in path supports the disposable preview's loopback
`/start/…` entry. It keeps its session cookie in memory and uses the existing
CSRF-protected assistant endpoints. Redirects are not followed. An ordinary
hosted `/agent` page cannot share a browser's login with a native process;
production native sign-in and non-Windows speech adapters remain unimplemented.
Local AI requests send on release. Paid requests first show the maximum credit
estimate and require explicit confirmation in the lobby.

`lobby/assistant.gd` and `lobby/transcribe-windows.ps1` belong to the example,
not the ordinary game addon. The current runner uses the source project;
packaged exports still need helper extraction and packaging support.

Run `python scripts/test-lobby-assistant.py --godot /path/to/godot` for the
loopback authentication, transcript, result and credit-confirmation checks.
Add `--check-windows-speech` to also transcribe generated speech and check that
the temporary recording is removed, without opening a microphone.
The lobby flow tests hold/release ownership and disconnect cancellation with
simulated controller frames. These tests do not validate a physical microphone
or speech accuracy in a noisy room.

## Queue behaviour

The lobby sends `queue_game` with `first: false` for A and `first: true` for X.
This is one atomic host command, so simultaneous additions cannot overwrite each
other's order. It preserves the current game and its position. `next` starts the
prepared queue head. The older `play_next` command can start an idle game and is
not used for either catalog button.

## Register a replacement lobby

Set `GAMENIGHT_LOBBY_GAME` on the daemon to your shelf entry's ID. Include
`"GAMENIGHT_LOBBY_API": "1"` in that entry's `launch.env`. This declares runtime
input and party preservation before the executable connects, including when
it fails during startup. The launch command may be an exported executable or
Godot with `--path` pointing at a project.

The runtime supplies `GAMENIGHT_ADDR`, `GAMENIGHT_GAME_ID` and `GAMENIGHT_TOKEN`.
Use one WebSocket connection (plain JSON lines also work):

```json
{"type":"hello","role":"lobby","game":"my-lobby","token":"<GAMENIGHT_TOKEN>"}
```

Only the configured ID with its launch token can claim this role. Unlike the
game development handshake, a tokenless lobby is rejected. The welcome carries
the complete party snapshot. Send `{"type":"lobby_ready"}` after building the
first usable frame. The runtime then sends `lobby_focus` with screen ownership.
The lobby does not receive disposable game sessions.

This is an additive extension of protocol v1. Older daemons do not support the
lobby role; deploy the updated daemon and lobby together. A launch token binds
the connection to the selected process; it does not sandbox native code.
Existing overlay connections retain their [trusted local scope](../../SECURITY.md).

## State and commands

The lobby receives `party_state`, `lobby_focus`, `controller_frame` and `error`.
It may issue the existing [party commands](../protocol.md#party-commands-overlay-daemon),
plus `lobby_ready` and `quit_party`. It cannot report another game's session
lifecycle or publish physical controller frames.

| Request | Meaning |
|---|---|
| `join_party`, `leave_party`, profile and seat commands | Change runtime-owned players |
| `queue_next {game}` | Prepare a chosen game without starting it |
| `play_next {game}` | Choose the next game; starts when ready only if no game is active |
| `queue_game {game,first}` | Append a new occurrence, or insert first among upcoming games; never starts playback |
| `next` | Start the prepared next game, or wait for its preparation |
| `move_playlist_entry {expected,from,to}` / `remove_playlist_entry {expected,index}` | Edit an occurrence using the latest playlist snapshot; stale edits are rejected |
| `open_overlay` | Pause the active game and return to the lobby |
| `close_overlay` | Resume only the pause caused by opening the lobby |
| `set_setting {game,key,value}` | Apply a setting validated by the runtime |
| `quit_party` | Explicitly shut down the runtime and its children |

Use `party_state` as the authoritative result. Commands currently have no
request IDs or individual success acknowledgements. Do not blindly replay
commands after a lost connection. Reconnect with the launch token and rebuild
from the new snapshot. The SDK never queues disconnected writes.

The Godot client lives in `addons/gamenight/lobby.gd`. Instantiate it directly;
do not enable the game plugin's `GameNight` or `GameNightScreen` autoloads in a
lobby. Its signals supply snapshots, controller frames, connection status,
focus and errors. The example displays embedded or HTTPS catalog artwork.

## Minimal Godot client

Attach this script to your lobby scene. Connect signals before adding the client,
so the view receives the initial welcome. The client sends `lobby_ready` after
one scene-tree frame; finish any asynchronous screen setup before adding it.

```gdscript
extends Control

var lobby = preload("res://addons/gamenight/lobby.gd").new()
var party: Dictionary = {}

func _ready() -> void:
    lobby.party_changed.connect(func(snapshot):
        party = snapshot
        queue_redraw())
    lobby.rejected.connect(func(message): push_warning(message))
    add_child(lobby)

func add_to_queue(game_id: String) -> void:
    lobby.queue_game(game_id)        # A: append

func put_first(game_id: String) -> void:
    lobby.queue_game(game_id, true)  # X: put first, without starting

func start_queue() -> void:
    lobby.start_next()              # Separate Start action
```

This is the connection and queue portion only. A complete lobby must also handle
`focus_changed` and `controllers_changed` as described below. The runnable scene
is `sdk/godot/lobby/main.gd`.

Queueing adds an occurrence, so the same game can appear more than once. Use
playlist indices to move or remove one occurrence; game IDs alone are ambiguous.
The `expected` field must contain the full latest `party.playlist` value. On a
stale-edit error, redraw from the latest snapshot instead of silently retrying.
The SDK's `move_in_queue` and `remove_from_queue` helpers include this guard.

For loading feedback, read `warm_session.phase`, `progress` and `progress_label`,
plus `installs` for downloads. An entry being in the queue does not mean it is
ready. Keep the selected next game's artwork visible while it prepares. The
runtime's playlist currently wraps when it reaches the end; it is not a finite
queue that automatically stops the night.

## Input and screen ownership

Replacement lobbies receive runtime-sampled controller frames. Device tokens
are opaque, and must be matched against `seats[].controller`. The runtime
joins connected controllers, handles controller activity and Back/Select. It consumes
an A press held during connection and Back before broadcasting frames so clients cannot accidentally
start a game while joining or immediately reopen a resumed game.

Controller frames use a sampler-owned delivery path, separate from party-state
serialization. Large catalog snapshots must not block stick updates. Back is
consumed by the host; an A button held when a controller connects is suppressed
until release. The stream retains opaque controller tokens and full analog axes.

Render the active lobby at a normal frame rate. On `lobby_focus: false`, mute,
release the screen and reduce background work while keeping the connection
alive. Only explicit player requests start or resume games; window focus is
not such a request. The Godot example uses window minimisation and restoration.

Player and controller state survives a replacement lobby disconnect. A socket
failure can reconnect to the same process. A dead process gets up to three
restart attempts before opening the local recovery page. The game is paused
and players remain registered. Recovery offers Retry lobby, Resume game and
End game night. Retry resets the restart budget; it does not erase the party.
The installed launcher keeps browser requests available throughout the session.
Development hosts need `GAMENIGHT_WEB=1` to serve the recovery page. `quit_party`
is the deliberate exit path. The legacy platformer retains its old input and
disconnect behaviour until it adopts this role.

## Faces and names

Read names, skin colours, clothing colours and avatar payloads from the current
snapshot. The reusable `addons/gamenight/face.gd` implements the canonical
[face coordinates](../faces.md), transparent pixels, historic 16/32 pixel
anchors and nearest-neighbour artwork. It caches decoded textures, bounds its
cache and falls back to a default face for missing or malformed artwork.

```gdscript
var faces = preload("res://addons/gamenight/face.gd").new()

func _draw():
    faces.draw_face(self, player, Vector2(100, 100), 32)
```

Call it from a CanvasItem's drawing callback. Set that CanvasItem's
`texture_filter` to `TEXTURE_FILTER_NEAREST`. Supply the head centre and radius;
leave space around the head for hats and hair. Repaint when a party snapshot
changes a profile. The example keeps names and portraits beside each other.

## Verification and current limits

Build the daemon, then run:

```sh
python scripts/test-godot-lobby.py --godot /path/to/godot
python scripts/test-godot-lobby.py --godot /path/to/godot --capture-dir .local/lobby-previews
```

The flow test runs the actual Godot scene against a real daemon, using synthetic
profiles and protocol stub games. It checks queue versus play, pause/resume,
live names and artwork, reconnect, leaving and joining. The capture option
requires a display and saves desktop and narrow-window PNGs. Stub games do not
validate real gameplay, controller drivers, audio or OS focus handoff. Test
those with real games and devices on every supported platform before release.

The example has separate player-colored selections, queue controls and media
controls. LT/RT cycle each player's selected game on a trigger press; holding
the trigger does not keep cycling. The selected game is larger in the center,
with smaller neighbors on either side. The stick and D-pad move between
controls, with animated focus and card movement. The layout expands to the display aspect
ratio, keeps players in a compact strip and gives Up Next a large game image.
Guests get their random face and hat from the host. Music depends on an active
OS media session; it does not provide a streaming service itself.

## Phone joining and profile pickup

The public local-web server supplies `GET /api/player-links`. Its `room`
contains the current `code`, `join_url` and `qr_svg`; the URL uses the actual
LAN host and web port for a local room, or the registered cloud room's origin.
Do not build a QR from the lobby's WebSocket address. Unregistered rooms do not
get a QR. `scripts/run-local.py --lobby godot` starts local-web automatically.

The Godot view defaults to `http://127.0.0.1:7913`. Set `GAMENIGHT_LINKS_URL`
only when running a different local-web bridge. Phone profiles waiting for
pickup are returned in the same response. A local controller selects its
profile and the native lobby posts to
`/api/room-pickup/{pending_id}/{player_id}` with
`X-GameNight-Local-Pickup: 1`. Pickup requires a loopback connection and this
header; a phone cannot assign itself to another controller through this API.

## Game settings and artwork

The Settings button opens the selected game's declared settings. Toggles,
bounded integers and choices map to `set_setting`; the view reads the accepted
values from `party.settings`. A game must connect and declare its settings
before they appear. Queue it to load them. The host validates values, and the
game receives `setting_changed`.

`addons/gamenight/artwork.gd` loads PNG, JPEG and WebP asynchronously. It accepts
embedded images and HTTPS URLs, plus loopback HTTP for development. Downloads
are limited to two at a time, eight seconds and 8 MiB each; decoded images must
fit within 4096 × 4096. The texture cache holds 32 entries. Missing, invalid or
failed artwork leaves the game title visible instead of blocking navigation.

## Choose a lobby in the installed app

Register an installed executable in `local-games.json` in the GameNight data
directory, alongside the launcher's `shelf.json`. Use an absolute executable
path and an absolute existing `cwd` when supplied:

```json
[{"id":"my-lobby","title":"My lobby","launch":{
  "command":"/absolute/path/to/my-lobby",
  "env":{"GAMENIGHT_LOBBY_API":"1"}
}}]
```

Both bundled lobbies have **Select other lobby** in their Start menu. In Living
Room, press Start on a controller, M on a keyboard, or click **Start · Menu**.
The platformer uses the player's existing Start menu. The chooser opens on the
host computer and lists each installed lobby by name. Saving does not interrupt
the current game: the selected lobby is used the next time GameNight starts.

Living Room shows **Current game** and **Up next** side by side, or stacked in a
narrow window. Current game shows the game's screenshot and **Resume**, even
when other games are queued. If there is no current game, only Up next is shown.
Resume keeps the current session and queue intact;
**Start game** under Up next advances the queue.

Launch `gamenight-launcher --choose-lobby`, or open
`http://127.0.0.1:7913/host/lobby` on the host while the installed app runs.
Choose the bundled platformer or a registered replacement. The choice is saved
in `selected-lobby.json` and applies on the next launch. Missing executables
fall back to the bundled lobby. Registration does not download or install a
third-party lobby. Only install code you trust.

The preference and recovery controls are host-only. They reject LAN requests;
mutations also require `X-GameNight-Host: 1`. The recovery page uses
`retry_lobby`, `close_overlay` and `quit_party` through a trusted local overlay.
Retry is available only after the automatic restart budget is exhausted.

## Automated coverage

`python scripts/test-godot-sdk.py --godot /path/to/godot` checks the shared game
adapter's seat mapping, profile updates, lifecycle guards, stale input and
focus behaviour. `python scripts/test-lobby-recovery.py` checks the actual
daemon's crash budget, retry and party retention. Set `GAMENIGHT_TEST_DAEMON`
to a built daemon binary to use a non-default build directory.

Run `python scripts/test-host-lobby.py` for host preference and room-link HTTP
checks (requires local port 7913). The lobby flow also checks settings and
artwork fallback. These checks do not
certify physical controller drivers, TV focus handoff, media sessions or phone
camera scanning. Those still need device tests on each release platform.

## Closed games and failed launches

Read `party.game_issues` before showing loading or ready status. Each item has a
`game` ID and a `kind`: `closed`, `disconnected`, `exited_unexpectedly`,
`failed_to_start`, or `startup_timeout`. `warming` still identifies the intended
next game; an issue means its process is stopped, not currently loading.

The host clears the lost session and broadcasts the issue to connected lobbies
and overlays. It also checks every 200 ms for processes that exit before sending
`hello`. Startup has a ten-minute connection deadline to allow development builds.
A missing executable is reported immediately. Games remain stopped until an
explicit queue/start command retries them. Show a Retry action using `next` for
the head of the queue, or `queue_next` for a specific game without starting it.

A clean process exit can be labelled “Game closed”. A broken connection alone
cannot prove a crash or a deliberate quit; show “Game disconnected”. An observed
nonzero exit is “Game exited unexpectedly”. These states describe evidence, not
user intent. Reconnecting games clear their issue and must prepare again before
being shown as ready.
