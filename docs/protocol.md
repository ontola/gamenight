# The GameNight Protocol (v1)

The protocol is the product. Engine plugins are convenience wrappers around
what is written here. Anything that can open a WebSocket and speak JSON can be
a GameNight game or overlay — Godot, Unity, Bevy, a shell script, a browser.

This document is the formal wire reference. **If you're integrating a game,
start with [Integrating your game](integrating-your-game.md)** — it walks the
lifecycle in build order and links the checks and runnable examples. The
canonical type definitions live in
[`crates/gamenight-protocol`](../crates/gamenight-protocol/src/lib.rs).

## Transport

The daemon listens on one port (default `127.0.0.1:7912`) and accepts two
framings of the same protocol. It tells them apart from the first four bytes
a client sends — `GET ` means WebSocket, anything else means plain — so
there is nothing to configure on either side.

| | **WebSocket** | **Plain** |
|---|---|---|
| address | `ws://127.0.0.1:7912` | `tcp://127.0.0.1:7912` |
| framing | one JSON object per text frame | one JSON object per line, `\n`-terminated |
| handshake | HTTP upgrade (`Sec-WebSocket-Key`, SHA-1, base64) | none — send your `hello` |
| use it when | your engine or runtime already has a WebSocket client: browsers, Godot, Rust, Node | your engine doesn't, and you'd rather not vendor one: most C/C++ engines |

Both are first-class and can share one party — a WebSocket overlay and a
plain-socket game see exactly the same messages. The plain form exists
because "anything that can open a socket can be a GameNight game" has to be
literally true: WebSocket's handshake and masked frame codec are several
hundred lines of ceremony before the first byte of protocol, which is free
in Godot and expensive in a C++ engine with no such dependency. Blank lines
on the plain transport are ignored, so a `\n\n` keepalive is safe.

Common to both:

- Every message carries a `"type"` field (snake_case).
- Receivers **must ignore unknown fields** and should ignore unknown message
  types. That is how the protocol grows without breaking old SDKs.
- `protocol_version` (currently `1`) only bumps on breaking changes. Adding a
  transport is not a breaking change: a v1 WebSocket client keeps working
  untouched.

## Roles

A connection announces itself with its first message, a `hello`:

| role | who | sends | receives |
|---|---|---|---|
| `game` | a game process (via an SDK) | `ready` (mandatory), `finished` + `declare_settings` + `declare_companion` + `companion_message` (optional) | session lifecycle commands, `controller_frame`, `setting_changed`, `companion_message`, `companion_presence` |
| `overlay` | party UI / controller surface / LLM (via `gamenight-mcp`) | party commands | `party_state` snapshots |
| `lobby` | selected replacement lobby executable | party commands, `lobby_ready`, `quit_party` | full snapshots, `lobby_focus`, runtime controller frames |

The replacement lobby role requires the configured lobby ID and launch token,
including on reconnect. Declare `GAMENIGHT_LOBBY_API=1` in its launch environment
so the runtime owns input and retains the party if that process fails before
hello. Send `lobby_ready` after initial rendering; `quit_party` explicitly ends
the runtime. A disconnect alone preserves players and bindings. See
[Build a lobby](site/lobbies.md) for the lifecycle, example and current limits.

```json
{ "type": "hello", "role": "game", "game": "my-game", "token": "<GAMENIGHT_TOKEN>" }
{ "type": "hello", "role": "overlay" }
```

The daemon answers with a `welcome`:

```json
{ "type": "welcome", "protocol_version": 1, "party": { ... } }
```

One connection per game id: a second `hello` for the same game is answered
with an `error` and the connection is closed. Identity is per *title*, not per
session — one process hosts many disposable sessions over the night.

After three automatic replacement-lobby restarts fail, the host pauses the
game and opens its local recovery page. A trusted overlay may then send
`retry_lobby` to reset the restart budget, or `quit_party` to end the session.
Games cannot issue these commands. A retry preserves players and the playlist;
`party_state` acknowledges the request, not successful rendering of the new
lobby. A later `lobby_ready` confirms readiness.

## Session lifecycle

Sessions are disposable. They move strictly forward:

```
created → preparing → ready → running ⇄ paused
   (any live phase) ──────────→ disposed
```

The daemon drives the lifecycle; games only ever *report* two facts.

### Daemon → game

| message | meaning | game must |
|---|---|---|
| `prepare` | warm up this session for these seats | load everything, then send `ready`. Show nothing. |
| `start` | the transition landed on you | start the match **instantly** |
| `pause` / `resume` | party paused the night | freeze / unfreeze |
| `dispose` | session over, id never reused | tear down; a new `prepare` may follow |
| `setting_changed` | the party turned one of your declared knobs | apply it live, or from the next match — whichever is sensible |
| `lobby_focus` | *(lobby games only)* some other game took the screen, or gave it back | mute and step out of the way on `active: false`; take over again on `true` |

`lobby_focus` only ever reaches the game registered as the party's lobby
(the one the daemon launches on a controller press with nothing else
running). It is not session-scoped — the lobby has no tracked session to
hang it off — so it carries just the flag:

```json
{ "type": "lobby_focus", "active": false }
```

```json
{
  "type": "prepare",
  "session": "9be2…",
  "game": "my-game",
  "seats": [
    { "index": 0, "occupant": { "kind": "local", "player_id": "41af…" } },
    { "index": 1, "occupant": { "kind": "ai" } },
    { "index": 2, "occupant": { "kind": "empty" } },
    { "index": 3, "occupant": { "kind": "empty" } }
  ],
  "players": [ { "id": "41af…", "name": "Ada" } ]
}
```

Games receive seats with occupant identities and optional opaque controller tokens.
Preserve player ownership across games; do not map seats to engine device order.
See [authoritative input](#bundled-games-authoritative-controller-input).
Occupant kinds are `local`, `remote` (reserved for network play), `ai`, `empty`.

If the party is smaller than the game's declared `min_players`, the daemon
fills the empty seats with `ai` up to that minimum — one person warming up
before the others arrive is the everyday case, not an error to refuse. So a
game that needs two players and gets one seated human always sees a second
seat with a bot in it, and never has to invent its own fallback. The party's
own seating is untouched: those seats stay free for people to take.

The seats are the whole player list. A game running under a daemon should
**not** also run its own "press X to join" — the party decides who is
playing, in the lobby, and a second route in makes the two disagree.

### Game → daemon

| message | meaning |
|---|---|
| `ready` | assets loaded, inputs mapped — this session can start instantly |
| `finished` *(optional)* | a round ended — keep session, focus and pause state unchanged |
| `progress` *(optional)* | how far along warming is, so screens can stay truthful while the party waits |
| `request_overlay` *(optional)* | "get me back to the party" — a player asked to leave your game |
| `request_start` *(optional)* | explicit player request to start or resume; never a focus callback |
| `declare_settings` *(optional)* | the match settings this game exposes (see [Match settings](#match-settings)) |
| `declare_companion` *(optional)* | a phone screen for this game (see [Phone screens](#phone-screens)) |
| `companion_message` *(optional)* | JSON for one player's phone screen, or every phone |

```json
{ "type": "ready",    "session": "9be2…" }
{ "type": "finished", "session": "9be2…" }
```

`progress` reports loading between `prepare` and `ready`. Send it as often as
is useful; the daemon keeps the latest and republishes it on the session in
every snapshot, so overlays can show a real bar instead of a spinner:

```json
{ "type": "progress", "session": "9be2…", "percent": 40, "label": "loading track" }
```

`percent` is a whole number, clamped to 0–100 by the daemon; `label` is
optional. A game that loads instantly should never send this — "loading"
with no number is a legitimate state, and screens must stay honest without
it. This matters most for games with genuinely slow warm-ups: a kart racer
loading a track for eight seconds is a fine GameNight citizen if it *says*
so, and a mystery if it doesn't.

`request_overlay` takes no arguments. Games are not allowed to drive the
party in general — this is the one exception, because a player stuck inside
a game with no route back to the party is the single failure the party can't
recover from on its own. Wire it to a Back/Select button, never to Guide/Home
(the OS reserves that one). The daemon pauses your session and gives the
lobby the screen.

```json
{ "type": "request_overlay" }
```

`request_start` requests starting or resuming this game after an explicit user
action. It takes no arguments:

```json
{ "type": "request_start" }
```

Never send it automatically when a window gains focus. Host focus changes can
otherwise bounce straight back into the game. Only Start/Resume commands authorize
gameplay. See the [integration guide](integrating-your-game.md) for Back release
handling and borderless windows.

Ready completes preparation. Release acceptance additionally requires the
behaviors in [the contract](../contract/requirements.json), including pause,
resume, input ownership, clean switching and continuous play.

Session snapshots include [diagnostics](#session-diagnostics). Consumers must
treat absent diagnostics from older hosts as unavailable, not zero measured
play time.

`finished` is an optional round notification. It never advances the playlist,
opens the lobby, pauses the game or hides its window. The game owns its score
screen and starts the next round itself. Players can keep playing indefinitely.
Back/Select pauses and opens the lobby; Resume continues. Play next explicitly
switches games, while Skip changes only the queued next game. A prepared next
session stays ready across rounds. Pausing also freezes the game's results timer.

## Party commands (overlay → daemon)

The authenticated replacement `lobby` role may also send these commands.
Game lifecycle reports and physical input publication are excluded from that
role; the runtime supplies its controller stream.

| message | effect |
|---|---|
| `join_party {name, seat?}` | new player; the requested seat if free, else the first empty one |
| `leave_party {player_id}` | player leaves; their seat empties |
| `rename_player {player_id, name}` | change a player's display name |
| `set_player_color {player_id, color}` | game-controlled clothing/team colour (`#rrggbb`); independent of skin |
| `set_player_skin_color {player_id, skin_color}` | saved personal skin preference (`#rrggbb`); exposed as `Player.skin_color` |
| `set_player_avatar {player_id, avatar}` | set their pixel-art face (opaque string — see [avatars](faces.md)) |
| `assign_seat {seat, occupant}` | re-seat a player / add a bot / empty a seat |
| `swap_seats {a, b}` | two people trade controllers: swap the occupants of two seats |
| `set_playlist {entries}` | set the night's queue; the next game starts warming |
| `play_next {game}` | make this game the next one up: it starts warming now (inserted into the playlist after the current entry if needed) |
| `queue_game {game, first}` | append a new occurrence, or insert first among upcoming games when `first` is true; preserves the current game and never starts playback |
| `queue_next {game}` | select an existing or new upcoming game without starting playback |
| `next` | skip to the warm session immediately, no vote |
| `pause` / `resume` | pause/resume the active session |
| `open_overlay` / `close_overlay` | the party overlay came up / went away (see below) |
| `vote {player_id, option}` | stand on `replay` \| `skip` \| `next_game` \| `quit` |
| `set_setting {game?, key, value}` | change a match setting; `game` defaults to the active game (see [Match settings](#match-settings)) |
| `media_control {action}` | `play_pause` \| `next_track` \| `previous_track` on the host's background music (see [The host's music](#the-hosts-music)) |

### The overlay is party state

Whether the overlay is up is **server-authoritative** (`overlay_open` in the
snapshot), so every screen shows the same thing. The rules:

- `open_overlay` pauses the active session (if it was running) — opening the
  party never costs anyone gameplay.
- `close_overlay` resumes **only if the overlay caused the pause**. An
  explicit `pause` stays paused.
- A transition (skip, vote consensus, auto-start) closes the overlay: the new
  game starts running and everyone is dropped straight into it.
- A `finished` racing an in-flight overlay pause preserves that pause.

```json
{ "type": "set_playlist", "entries": [
  { "game": "neon-trails", "title": "Neon Trails" },
  { "game": "neon-siege", "title": "Neon Siege" }
] }
```

## Party state (daemon → overlays)

Every state change is broadcast as one snapshot — overlays are dumb renderers:

```json
{ "type": "party_state", "party": {
  "players": [ { "id": "41af…", "name": "Ada" } ],
  "seats": [ ... ],
  "playlist": { "entries": [ ... ], "current": 0 },
  "active_session": { "id": "9be2…", "game": "neon-trails", "phase": "running" },
  "warm_session":   { "id": "77c1…", "game": "neon-siege", "phase": "ready" },
  "history": [ "neon-trails" ],
  "vote": { "positions": [ [ "41af…", "next_game" ] ], "decided": null },
  "overlay_open": false,
  "library": [
    { "id": "neon-trails", "title": "Neon Trails", "players": "2–4" }
  ],
  "connected_games": [ "neon-siege", "neon-trails" ],
  "settings": [],
  "now_playing": { "title": "Hivernale", "artist": "Reynaldo Hahn",
                   "playing": true, "source": "Spotify" }
} }
```

## The host's music

Somebody puts a record on before the first match, and for the rest of the
evening they're the only one who can reach it — it's their laptop, in another
room, behind a lock screen. So the daemon watches whatever the host already
has playing and puts it in the snapshot as `now_playing`, and any screen can
send `media_control` to pause or skip it.

`now_playing` is **absent whenever nothing is on**, which is most nights.
That's the whole rendering rule: a screen draws its music controls only when
the field is there, because controls for a stereo that isn't playing are
worse than none. The [lobby](../crates/lobby) draws a card with the track and
two buttons on the floor under it — jump on one to pause, the other to skip,
and they visibly sink when you land — and neither the card nor the buttons
exist while the field is absent.

A `play_pause` flips `playing` in the very next snapshot rather than waiting
for the poll to confirm: a pad that appears to do nothing for a second is a
pad people stand on twice, and two play/pauses are no play/pause at all. A
skip leaves the title alone until the OS says otherwise — guessing the next
track's name would only be wrong.

How the daemon reads it, per platform:

| platform | source | reached via |
|---|---|---|
| macOS | Spotify, Music | AppleScript, and only for apps already running (`pgrep`) — GameNight never launches a player to ask it what it's doing |
| Linux | any MPRIS player | `playerctl`, if installed |
| other | — | no music card, ever |

`source` is the app's own name, and it's the handle the daemon controls
through — so it's validated against the players it knows rather than trusted.
What this deliberately can't see is audio from a browser tab or a game;
reaching that on macOS needs a private framework Apple gates behind an
entitlement. Set `GAMENIGHT_NO_MUSIC=1` to switch the whole thing off — on
macOS, talking to another app is something the OS asks the host to approve,
and a host who'd rather not be asked should be able to say so.

## Match settings

Games expose the knobs a party may turn — items on/off, stock count, arena —
and **the daemon owns the values**: it validates every write, broadcasts them
in every snapshot, pushes changes to the game, and keeps them when the game's
process reconnects. Anything speaking the overlay role can turn a knob: the
party overlay, or an LLM through [`gamenight-mcp`](llm-control.md) ("hey
GameNight, disable items").

A game declares its settings once, right after `welcome` (and again after
every reconnect — the daemon replays changed values in response):

```json
{ "type": "declare_settings", "settings": [
  { "key": "items", "label": "Items", "kind": "toggle", "default": true,
    "description": "Whether power-up items spawn during a match." },
  { "key": "stock", "label": "Stock", "kind": "number",
    "default": 3, "min": 1, "max": 99 },
  { "key": "arena", "label": "Arena", "kind": "choice",
    "default": "meadow", "options": ["meadow", "volcano", "space"] }
] }
```

Three kinds, all values plain JSON scalars: `toggle` (bool), `number`
(integer in `min..=max`), `choice` (one of `options`). Write `description`
well — it's what overlays show and what an LLM reads to map "no more
power-ups please" onto `items`.

Anyone in the party changes a value with:

```json
{ "type": "set_setting", "key": "items", "value": false }
```

`game` is optional and defaults to the active game — "disable items"
mid-match needs no lookup. The daemon validates against the declared spec;
rejections are `error` messages that spell out what would have been legal
(`"'towerfall' has no setting 'itemz'; available: items, stock, arena"`) —
written to be shown to a human or fed back to an LLM correcting itself.

Valid writes land in the next snapshot's `settings` and are pushed to the
game:

```json
{ "type": "setting_changed", "game": "towerfall", "key": "items", "value": false }
```

Apply it live if you can (item spawners are easy to stop mid-match), or from
the next match if you can't — either is fine, and the choice is yours per
setting. Settings are **game-scoped, not session-scoped**: they survive
sessions, skips and replays, and because the daemon keeps the values they
also survive your process crashing. The `declare_settings` after your
reconnect answers with a `setting_changed` for every value the party had
moved off its default.

### Atomic settings batches

Remote controls should use `control_settings` rather than sending independent
`set_setting` writes. Read `revision` and `can_undo` from the game's entry in
`party.settings`, and use the current active/warm session ID and seated player ID:

```json
{
  "type": "control_settings",
  "game": "my-game",
  "session": "<session UUID>",
  "expected_revision": 4,
  "player_id": "<player UUID>",
  "action": "set",
  "values": {"items": false, "arena": "volcano"}
}
```

Every key and value is validated before any state or SDK notification changes.
Wrong types, unknown keys, stale revisions and departed players receive `error`.
A successful request sends **only its requesting overlay**:

```json
{"type":"settings_accepted","game":"my-game","session":"<session UUID>","revision":5}
```

Then the updated party snapshot is broadcast. This receipt confirms daemon
acceptance, not a rendered gameplay effect. Games still receive the existing
`setting_changed` messages and apply them at their declared time.

Use `action: "undo"` with empty `values` to restore the preceding change, or
`action: "keep"` to discard undo. Both require the current revision and advance
it once. Redeclaring settings clears undo and advances the revision. Setting
values survive sessions within the daemon; these revisions do not make them
durable across a daemon restart.

### How a game launches

The daemon is the launcher: when the next playlist entry needs warming and no
process for that title is connected, the daemon spawns one using the library
entry's `launch` spec:

```json
{ "id": "towerfall", "title": "TowerFall",
  "launch": { "command": "/games/towerfall/TowerFall.x86_64",
              "args": ["--windowed"], "cwd": "/games/towerfall",
              "env": { "SDL_VIDEODRIVER": "wayland" } } }
```

The handshake context travels in **environment variables, not CLI arguments**
— unknown flags break existing games, extra env vars are invisible:

| variable | meaning |
|---|---|
| `GAMENIGHT=1` | this process was launched by a GameNight daemon |
| `GAMENIGHT_ADDR` | the daemon's WebSocket address |
| `GAMENIGHT_GAME_ID` | the title this process was launched to serve |
| `GAMENIGHT_TOKEN` | per-launch secret; echo it in the `hello` |
| `GAMENIGHT_OVERLAY_URL` | *(optional)* the party overlay's URL/file path, forwarded from the daemon's own environment — lets a game raise the real overlay (e.g. on a controller Back/Select-button press — not Guide/Home, which iOS/macOS and most consoles reserve at the OS level) instead of building its own party UI |

SDKs auto-detect these, so the same binary boots into game-night mode when
the daemon launches it (skip the menu, connect, wait for `prepare`) and runs
as a normal standalone game otherwise. No flag plumbing.

Token rules:

- While the daemon has a launched process pending for a title, a `hello` for
  that title **must** carry the matching token — anything else is rejected.
  First-come-first-served ends where launching begins.
- With no pending launch, token-less hellos are accepted (dev mode: start
  your game by hand, connect, iterate).

Process lifetime: one process per title, resident all night — launching is
the expensive thing that happens once; sessions cycle cheaply inside the
living process. The daemon reaps processes when they exit (a crash rolls the
night to the warm session), retries a launch that never says hello within
15 s, and kills every child when the party votes to quit. Games without a
`launch` spec are simply awaited (externally managed).

### The library (cover art and all that)

The daemon owns a **game shelf**: presentation metadata for every title it
knows, playable right now or not. Overlays render next-game options from it —
this is what makes "what's next" feel like Netflix instead of a file picker.

- `cover` is portrait art; `icon` is the square case-spine image; `screenshot`
  is gameplay imagery for the TV. Missing artwork uses a readable title fallback.
- `connected_games` says which titles have a live process — overlays show the
  rest as offline (queueable, but they won't warm until their process
  appears).
- The daemon loads the shelf from `$GAMENIGHT_LIBRARY` (a JSON array of these
  objects) and falls back to a built-in demo shelf.

Separately, on startup the daemon also folds [the catalogue](../catalog/)
into the shelf: free entries with a direct, hash-verified binary for the
running platform that are already installed (from a previous run) join
`library` immediately, with a real `launch` spec resolved from the
catalogue's `downloads.<platform>.entrypoint` — no hand-written
`$GAMENIGHT_LIBRARY` entry required. An explicit `$GAMENIGHT_LIBRARY` entry
for the same id always wins; the catalogue only fills gaps. Anything not yet
installed downloads in the background (`gamenight-installer`) instead of
blocking this start, so it's ready to join the shelf on the *next* one. Set
`GAMENIGHT_NO_PREWARM=1` to disable both.

That background queue is live-reorderable, not fixed at catalogue order.
`maybe_warm` only ever emits `Effect::Launch` for a library entry that
already has a `launch` spec — a catalogue-only game that isn't installed yet
never reaches that path, so the daemon watches `play_next` directly instead:
the moment a `play_next` names a game with no launch spec, it calls
[`PrewarmHandle::prioritize`](../crates/gamenight-installer/src/lib.rs) to
bump that game to the front of whatever's left in the queue. An in-flight
download always finishes first (no HTTP range support to resume a cancelled
one); reprioritizing only reorders what hasn't started yet.

## Phone screens

A game can give every seated player a screen of their own on their phone: a
hand of cards nobody else may see, a god's-eye map, a private vote. This is
how GameNight does asymmetric play. The phone screen is a small web page that
ships with the game; the host's local web server (`GAMENIGHT_WEB=1`, port
7913) serves it while that game is the active session, and the GameNight app
and the phone studio open it automatically.

Declare it once after `welcome`, and again after every reconnect:

```json
{ "type": "declare_companion", "root": "/abs/path/to/game/phone", "entry": "index.html" }
```

`root` must be an absolute directory and `entry` a path inside it. Phones load
`/play/<game>/<entry>?profile=…&game=<game>`, so relative links in the page
resolve inside `root`, and nothing outside it is served.

The page loads `/assets/companion.js` and exchanges plain JSON with the game:

```js
const game = GameNight.connect((data) => render(data), (status) => showStatus(status));
game.send({ action: "roll" });
```

The game receives what a phone sends tagged with the sender, and is told when
a phone opens or closes its screen. Send that player their current view on
`connected: true`; phones reconnect after a refresh or a host restart.

```json
{ "type": "companion_presence", "player_id": "7d0c…", "connected": true }
{ "type": "companion_message",  "player_id": "7d0c…", "data": { "action": "roll" } }
```

To answer, address one player, or leave `player_id` out to reach every phone:

```json
{ "type": "companion_message", "player_id": "7d0c…", "data": { "hand": ["wood", "wool"] } }
{ "type": "companion_message", "data": { "turn": "7d0c…" } }
```

Phones never name their own player: the web server knows which party member
each signed-in phone is and fills it in, so a player cannot read or play
another player's hand. Keep messages small (under 16 KB) and treat every one
as untrusted input. Overlays see declared screens in `party_state.companions`
and relay traffic with `companion_message` (`game` and `player_id` set) and
`companion_presence`; the lobby sees screens without their `root`.

### Native phone apps

Some phone sides are a whole game of their own, such as a 3D god view, and
don't fit in a web page. Declare a native app instead of (or next to) a page:

```json
{ "type": "declare_companion", "root": "/abs/path/to/game/phone",
  "app": { "name": "The Voice and the Will", "android": "io.ontola.godgame",
           "download": "voice-and-will.apk" } }
```

`download` is an `https://` URL or a file inside `root`; a file is served by
the GameNight PC over the LAN, so the PC is the phone's installer. The
GameNight app acts as the store: **Install** downloads the APK and hands
it to Android's installer (Android asks once to allow installs from
GameNight and confirms each first install; updates of apps GameNight
installed need no confirmation on Android 12+), and **Open** launches
`android`. In Godot: `GameNight.declare_companion(root, "", app)`. The app connects to the
game by its own means, for example LAN discovery; `companion_message` is for
pages only. iPhones can't install apps from outside the App Store, so there
the app must come from the App Store or TestFlight.

## The night, end to end

```
overlay: set_playlist [neon-trails, neon-siege]
daemon → neon-trails: prepare      (warm the first game)
neon-trails → daemon: ready
daemon → neon-trails: start        (nothing was playing: auto-start)
daemon → neon-siege: prepare      (warm the next one behind it)
neon-siege → daemon: ready        (the party is now skip-proof)

neon-trails → daemon: finished     (round reported; game shows results and repeats)
players explicitly choose next_game
daemon → neon-trails: dispose
daemon → neon-siege: start         (instant transition)
daemon → neon-trails: prepare      (playlist wraps; warm again)
...repeat until someone wins the "quit" vote
```

## Rules the daemon enforces

- **Auto-start**: the first session to become `ready` while nothing is active
  starts immediately.
- **Warm behind the active game**: whenever the warm slot is empty and the
  next playlist entry's process is connected and free, a `prepare` goes out.
- **One process, one session**: if the next entry is the same game as the
  active one (single-entry playlists, replays), the active session is disposed
  first, then the fresh session warms.
- **Transitions wait for warmth**: `next` (or a vote) before the warm session
  is `ready` becomes pending and fires on its `ready`.
- **Voting is consensus of the seated**: everyone holding a seat must stand on
  the same option. Spectators don't vote. If the last holdout leaves, the vote
  resolves. Round completion never auto-advances, even with no seated players.
- **Crashes don't end the night**: if the active game's process dies, the
  daemon transitions to the warm session as soon as it can.
- `error` messages are informational; the connection stays open (except after
  a rejected `hello`).

## Errors

```json
{ "type": "error", "message": "no seat 9" }
```

## Future (kept off v1 on purpose)

Remote gameplay seats, voice and GPU/memory budgeting for multiple warm sessions
are not implemented. Downloads and host controller routing are implemented.

### Ready crossing Dispose

A host may replace a preparing session when seats change. A `ready` reply for
a recently disposed session can already be in flight. GameNight ignores these
late replies for the 64 most recent disposals; it never applies them to the
replacement session. Unknown session IDs still produce a protocol error.

## Player activity, sleep and joining during play

Presence is host-authoritative and separate from player identity. A controller-bound
player warns after 60 seconds without meaningful input and sleeps after 75 seconds.
Input wakes the same player immediately; their ID, name, controller binding and seat
remain intact. Sleeping players do not block votes and cannot activate lobby TV pads.
The lobby shows animated `zZz` while sleeping, without a warning on the player name.

After `prepare`, games opt in before replying `ready`:

```json
{"type":"participation","session":"<session UUID>","instant_join":true}
```

Use `instant_join:false` when a round has a fixed roster. Both values enable presence
notifications. Legacy games need no changes: their active matches do not advance AFK
clocks, and they receive no new lifecycle messages.

Report real human activity from **all** controllers, including unassigned devices:

```json
{"type":"controller_input","session":"<active session UUID>","controller":"ordinal:0"}
```

`ordinal:N` identifies a device in the resident host, as used by `seats[].controller`.
Treat it as an opaque token. Do not index an SDL or engine-local device list with it.
Bundled games consume the host controller frames described below. Apply a 0.25 stick/trigger
deadzone, ignore device-connect events, and throttle held input to once per second
per controller. Bots, animation, repeated network heartbeats and simulated input must
never report activity. A game may report only while its own session is running and
foreground; reports from stale sessions, warm games and other game IDs are ignored.
The persistent lobby can report through its overlay connection without `session`.

A previously unseen controller joins the party once, up to the seat limit. Games
with `instant_join:true` receive the new player in their current match, subject to
the game's maximum player count. Other games keep their prepared roster; the new
player joins on the next preparation. Repeated input never creates duplicate players.

Opted-in games receive a full snapshot on declaration and subsequent changes:

```json
{"type":"party_updated","session":"<session UUID>","seats":[],"players":[],"presence":[{"player_id":"<player UUID>","state":"warning"}]}
```

The actual message contains the full seat/player arrays. Presence states are `active`,
`warning`, and `sleeping`; absent presence means active/untracked. Overlays receive
these records in `party_state.party.presence`. Preserve match state and scores when
applying updates. Visually distinguish sleeping players without requiring warning text.
Games choose how sleeping characters behave (neutral input, safe removal, or AI).
Sleep is not a `leave_party`: never reassign the sleeping player's controller.

Rust games use `GameNight::participation`, `GameNight::controller_input`, and
`GameEvent::PartyUpdated`. The LOVE party pack implements these messages in its
shared lifecycle module; sleeping players use AI until they wake. Neon Siege is the
first instant-join implementation: a new pilot spawns centrally with three seconds
of protection, preserving the current wave and team score. Other pack games retain
fixed round rosters. Custom clients can send the JSON directly.

The character studio saves `skin_color` with the player profile and never changes
`Player.color` on sign-in. Games may assign clothing or team colours while retaining
the skin preference. Avatar paint is composited above skin and is not recoloured.


### Bundled games: authoritative controller input

With a replacement `lobby` role, the runtime samples physical controllers and
publishes `controller_frame` to the lobby and games. It consumes Back/Select
and the A press used to claim a seat. No client may inject physical frames in
this mode. The legacy platformer still samples input on its authenticated game
connection; the daemon forwards those frames to connected games.
Each frame contains the full connected-device list, including released buttons.

```json
{"type":"controller_frame","controllers":[{"controller":"ordinal:0","axes":[16384,0,0,0,0,0],"buttons":1}]}
```

`controllers` contains `{controller, axes, buttons}` records. `controller` is an
opaque host token matching `seats[].controller`, not an index into SDL's joystick
list. The lobby keeps device IDs stable when another controller disconnects.
`axes` contains left X/Y, right X/Y, and left/right trigger, scaled by 32767.
Y is down-positive. Button bits 0 through 13 are A, B, X, Y, LB, RB, Back, Start,
left stick, right stick, D-pad up, down, left, right.

The shared LÖVE adapter uses these frames in managed sessions and never matches
local SDL enumeration against lobby ordinals. Standalone games still read local
controllers. Legacy frames are sent on change, with a 50 ms heartbeat; the
runtime-owned stream samples approximately every 16 ms. After 250 ms
without input, controls become neutral. TCP_NODELAY is enabled on both hops.
The Rust SDK exposes each frame as `GameEvent::ControllerFrame`. Use the seat's
opaque controller token to find its input record; an empty frame or missing
record means neutral input. `controller_input` reports actual human activity
for presence and joining. It does not move a game character by itself.

Regression checks: `host_controller_identity_survives_reordering_and_disconnects`
in the shared Lua suite, the daemon socket test
`lobby_controller_frames_keep_device_ids_across_the_real_socket`, and
`scripts/test-love-integration.py` with sparse, reversed host device IDs.

## Circular player faces

Use the [face API](faces.md) for drawn faces and hats. LÖVE games call
`Face.drawFace(player, x, y, radius)` from `shared.face`; Rust games use
`Avatar::head_layout()`. Coordinates describe the head centre, not the image
bounds. Skin colour is separate. Keep transparent space for hats, and mirror
around the head centre. Refresh artwork when the player profile changes.

`profile.face` tests artwork rendering and live updates independently of
`profile.colors`. Carrying an avatar string without drawing it does not pass.
Faces may appear on characters or in a player portrait for games with vehicles.

## Session diagnostics

`SessionInfo.diagnostics` contains cumulative `active_ms`, `paused_ms` and
`rounds_reported`. The host counts time only for the active session, excluding
preloading. A long host suspension contributes at most two seconds per tick.
Round counts reflect optional `finished` notifications, not verified completion.

A game may also send cumulative application-frame measurements:

```json
{"type":"performance","session":"SESSION_UUID","sample":{"frames":600,"elapsed_us":10000000,"slow_frames":2,"max_frame_us":41000,"gpu":"GPU model","os":"Windows","width":1920,"height":1080}}
```

Reset counters on `prepare`. Count only running frames. Skip the first frame
after start/resume and suspension gaps over two seconds. `slow_frames` counts
intervals over 33,333 microseconds. Report roughly every ten active seconds.
The host accepts reports only from the game registered for the running session,
rejects invalid or decreasing counters, and exposes the latest sample as
`SessionInfo.diagnostics.performance`. An absent sample means unknown, never zero FPS.
Average application FPS is `frames * 1_000_000 / elapsed_us`; this is not a count
of display presents or a frame-time percentile.

Optional hardware fields are `cpu`, `gpu`, `os`, `memory_mib`, `width` and
`height`. Strings must be at most 256 UTF-8 bytes without control characters.
Use an empty string or zero for unavailable hardware. Never include serial
numbers, machine names, paths, network addresses or raw input.

The bundled LÖVE launcher reports frames, GPU, OS and pixel dimensions. The
Godot autoload also reports CPU and physical RAM. These are shipped source
adapters: already published game binaries need rebuilding to use them. Rust
games can call `GameNight::performance(session, sample)` with their own frame
measurements. C and other engines must send the JSON message themselves; there
is no automatic sampler for them yet.

These are factual diagnostics available to any host. The public runtime keeps
only the current session counters. It contains no behavioral database, account
profiling, recommendation model or training pipeline. An optional configured
cloud room relay includes session diagnostics in its discovery snapshot.
