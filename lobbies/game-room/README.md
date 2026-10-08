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

The project runs from source without an editor import step: the pixel font
and logo are read from their files at runtime.

## Controls

| Input | In the room |
|---|---|
| Stick / D-pad | Walk |
| A | Jump; down + A drops through a shelf; jump off the side walls |
| B | Grab an item, throw it; open a hat box |
| X | Punch, fire the confetti blaster, throw a lit bomb |
| Y | Use the station you stand at (hint above your name) |
| LT / RT | Browse the arcade cabinets |
| LB | At a cabinet: play that game next |
| Start | Your menu: leave, unlink, choose another lobby, quit |

The runtime joins controllers and handles Back, as for every lobby.

## Stations

- **Arcade cabinets** show three games from the shelf. Y adds the game to the
  queue (`queue_game`), LB puts it first. LT/RT shift the whole row.
- **TV pads**: left resumes the paused game (or starts the queue head when
  nothing runs), middle starts the queue head (`next`), right skips to the
  following game (`queue_next`).
- **Up next board** above the couch lists the queue; the TV shows the current
  or next game with loading progress and stopped-game issues.
- **Profile doors** appear for phone profiles waiting in the room. An unlinked
  player presses Y at the door to pick it up (`/api/room-pickup`).
- **QR plaque** shows the room QR and code from `/api/player-links`.
- **Jukebox pads** control host music when something is playing.
- **Exit door** leaves the party.

Items drop from the ceiling every few seconds: bombs (knock everyone back),
confetti blasters, hat boxes and one beach ball. Nobody gets hurt; hits only
knock players around. Sleeping players (runtime AFK presence) sit down with
their hands over their eyes and wake on input.

## Tests

```sh
cargo build -p gamenight-daemon
python scripts/test-game-room.py --godot /path/to/godot
xvfb-run python scripts/test-game-room.py --godot /path/to/godot --capture-dir .local/game-room
```

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
- No export preset yet; an export must include `assets/fonts/*.ttf` and
  `assets/icon.svg` as non-resource files.
