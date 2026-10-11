# GameNight Game Room

A replacement lobby in Godot 4.5: the platformer lobby's ideas (run, jump,
items, stations you use by standing at them) in a 2.5D neon game room. Only
the players are pixel art; the room, props and lights are 3D.

It uses the lobby role of the protocol through `addons/gamenight/lobby.gd`,
kept identical to `sdk/godot` with `python sdk/godot/sync.py lobbies/game-room`.

## Run it

```sh
python scripts/run-local.py --lobby game-room --godot /path/to/godot
```

Without a runtime, a demo party with bots shows the room:

```sh
godot --path lobbies/game-room -- --demo [--scene=action|stations|sleep|empty]
```

The project runs from source without an editor import step: the fonts (Outfit
for all text, the pixel font only for the neon wordmark) and the logo are read
from their files at runtime.

## Controls

| Input | In the room |
|---|---|
| Stick / D-pad | Walk |
| A | Jump; down + A drops through a shelf; jump off the side walls |
| B | Grab an item, throw it; open a hat box |
| X | Punch, fire the confetti blaster, throw a lit bomb; at the game shelf: queue the box |
| Y | Use the station you stand at (button at the station); at the game shelf: play the box next |
| LB / RB | At the game shelf: browse the boxes; at the jukebox: previous / next track |
| Start | Your menu: leave, unlink, choose another lobby, quit |

The runtime joins controllers and handles Back, as for every lobby.

## Stations

- **Game shelf**: a bookcase of game box spines and a stand with the selected
  box face forward. LB/RB pick the previous or next box, Y makes it the next
  game without starting it (`queue_next`), X adds it to the end of the queue
  (`queue_game`). Floating button prompts above the stand show both.
- **Up next cabinet** beside the stand shows one large next-game preview and
  ordered titles for the later games, with a count for overflow. The title
  list slides when the queue changes; later games never have cover images.
- **TV**: Y resumes the paused game, or starts the queue head (`next`) when
  nothing runs. The TV shows the current or next game with loading progress
  and stopped-game issues.
- **Profile doors** appear for phone profiles waiting in the room. An unlinked
  player presses Y at the door to pick it up (`/api/room-pickup`).
- **QR plaque** shows the room QR and code from `/api/player-links`.
- **Jukebox**: LB/RB select the previous/next track while you stand nearby;
  Y plays or pauses. The buttons above the jukebox show all three controls.
- **Exit door** leaves the party.

The room fills the monitor with a borderless desktop window, without changing
the display resolution. It never uses always-on-top priority or reclaims focus
after Alt-Tab; only a host ownership transition returns to it. Set `GAMENIGHT_LOBBY_FULLSCREEN=0`
for a window.

Station buttons stay anchored to the TV, shelf, jukebox or door and only appear
while a player is within interaction range. Opening a menu hides that player's
station buttons; player names remain visible.

Items drop from the ceiling every few seconds: bombs (knock everyone back),
confetti blasters, hat boxes and one beach ball. Nobody gets hurt; hits only
knock players around. A red **B** badge floats above the item you can grab,
open or kick while you are within reach. It disappears when you walk away,
carry another item or open your menu. Players sharing a target see one badge.
Sleeping players (runtime AFK presence) sit down with
their hands over their eyes and wake on input.

## Tests

The isolated item-hint regression checks pickup range, carrying, menus,
sleep/stun, shared targets and the B input path. Run it without a daemon:

```sh
godot --headless --path lobbies/game-room --script tests/item_hints.gd -- --demo
godot --headless --path lobbies/game-room --script tests/music_controls.gd -- --demo
xvfb-run godot --path lobbies/game-room --script tests/item_hints.gd -- --demo --capture-dir=/tmp/game-room-items
```

```sh
cargo build -p gamenight-daemon
python scripts/test-game-room.py --godot /path/to/godot
/path/to/godot --headless --path lobbies/game-room --script res://tests/queue.gd -- --demo --scene=stations
xvfb-run python scripts/test-game-room.py --godot /path/to/godot --capture-dir .local/game-room
xvfb-run -a -s '-screen 0 1920x1080x24' sh -c 'openbox >/tmp/game-room-display-wm.log 2>&1 & /path/to/godot --path lobbies/game-room --rendering-method gl_compatibility --script res://tests/display.gd'
```

The display test requires a window manager to handle minimize/restore and checks
full monitor bounds, repeated game returns and non-topmost behavior without
connecting to the running party. A deterministic focus adapter checks delayed
grants, the one-second deadline and cancellation after focus loss/deactivation;
Xvfb can leave Godot's native focus flag stale even after X11 changes foreground.
On Windows,
run the Godot command directly when the desktop is free; that
native run is needed to verify Windows taskbar and DPI behavior.

The flow test runs the real scene against a real daemon and local web server,
with stub games and a phone profile waiting in the local room. It drives the
controller input path: queue, play next, browse, start, pause, resume, pickup
and leave. It does not check physical controllers, the feel of the platforming,
audio or phone camera scanning; those need a playtest on the TV.

## Limits

- Forward+ renderer for the volumetric light beams and glow. Without Vulkan,
  Godot falls back to OpenGL; the room still works, with fewer effects.
- No sound effects yet.
- Game settings and the session assistant from the Living Room are not in
  this lobby yet.
- No export preset yet; an export must include `assets/fonts/*` and
  `assets/icon.svg` as non-resource files.
