# The GameNight Protocol (v1)

The protocol is the product. Engine plugins are convenience wrappers around
what is written here. Anything that can open a WebSocket and speak JSON can be
a GameNight game or overlay — Godot, Unity, Bevy, a shell script, a browser.

This document is the formal wire reference. **If you're integrating a game,
start with [Integrating your game](integrating-your-game.md)** — it walks the
lifecycle in build order, with the rules of thumb, a test checklist, and a
complete dependency-free example. The canonical type definitions live in
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
| `game` | a game process (via an SDK) | `ready` (mandatory), `finished` + `declare_settings` (optional) | session lifecycle commands, `setting_changed` |
| `overlay` | party UI / controller surface / LLM (via `gamenight-mcp`) | party commands | `party_state` snapshots |

```json
{ "type": "hello", "role": "game", "game": "towerfall" }
{ "type": "hello", "role": "overlay" }
```

The daemon answers with a `welcome`:

```json
{ "type": "welcome", "protocol_version": 1, "party": { ... } }
```

One connection per game id: a second `hello` for the same game is answered
with an `error` and the connection is closed. Identity is per *title*, not per
session — one process hosts many disposable sessions over the night.

## Session lifecycle

Sessions are disposable. They move strictly forward:

```
created → preparing → ready → running ⇄ paused
                                 ↓
                              finished
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
  "game": "towerfall",
  "seats": [
    { "index": 0, "occupant": { "kind": "local", "player_id": "41af…" } },
    { "index": 1, "occupant": { "kind": "ai" } },
    { "index": 2, "occupant": { "kind": "empty" } },
    { "index": 3, "occupant": { "kind": "empty" } }
  ],
  "players": [ { "id": "41af…", "name": "Ada" } ]
}
```

Games receive **seats, not controller ids**. Seat indices are stable across
games — player 2 is player 2 all night. Occupant kinds: `local`, `remote`
(future, already on the wire), `ai`, `empty`.

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
| `finished` *(optional)* | the match is over — open the vote / start the transition |
| `progress` *(optional)* | how far along warming is, so screens can stay truthful while the party waits |
| `request_overlay` *(optional)* | "get me back to the party" — a player asked to leave your game |
| `request_start` *(optional)* | "a player just switched to my window" — treat it as a go signal |
| `declare_settings` *(optional)* | the match settings this game exposes (see [Match settings](#match-settings)) |

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

`request_start` is its mirror, and takes no arguments either. Send it whenever
your window gains focus: on a desktop that means the player reached for you
directly — Cmd+Tab, a Dock click, a click on the window — instead of going
through the party.

```json
{ "type": "request_start" }
```

Report it unconditionally; don't try to work out whether it *should* mean
something. The daemon holds the session state and rules on it: warm and ready
→ your session starts, paused → it resumes, anything else → nothing happens.
A stray focus event can't reorder the playlist or launch anything.

The reason this exists: a warm game is a whole running process with a real
window, and the window server will happily hand it focus without asking
GameNight first. Treating that as a "go" is the difference between the party
switching to a game and getting it, versus switching to a game that sits
there refusing to start because nobody pressed the right button. Focus is the
one signal the party can always express and the daemon cannot override — so
it's read as intent rather than fought.

`ready` is the whole mandatory surface for a game. Target: integrate an
existing game in under an hour.

`finished` is a nicety, not a requirement. Sending it opens the party vote
the instant a match ends, while the scoreboard's still up — nobody has to
notice and reach for the overlay. A game that never sends it works fine too:
the party's **Skip** button always disposes the active session on demand,
independent of whether the game ever reports itself finished. Round-based
games that are happy to keep playing indefinitely (best-of-forever, endless
waves) are not obligated to define a "match" boundary at all — let the
players decide when they're done, from the overlay.

## Party commands (overlay → daemon)

| message | effect |
|---|---|
| `join_party {name, seat?}` | new player; the requested seat if free, else the first empty one |
| `leave_party {player_id}` | player leaves; their seat empties |
| `rename_player {player_id, name}` | change a player's display name |
| `set_player_color {player_id, color}` | change their accent-color hint (`#rrggbb`) |
| `set_player_avatar {player_id, avatar}` | set their pixel-art face (opaque string — see [avatars](integrating-your-game.md#showing-player-avatars)) |
| `assign_seat {seat, occupant}` | re-seat a player / add a bot / empty a seat |
| `swap_seats {a, b}` | two people trade controllers: swap the occupants of two seats |
| `set_playlist {entries}` | set the night's queue; the next game starts warming |
| `play_next {game}` | make this game the next one up: it starts warming now (inserted into the playlist after the current entry if needed) |
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
- A `finished` racing an in-flight overlay pause wins: the vote opens.

```json
{ "type": "set_playlist", "entries": [
  { "game": "towerfall", "title": "TowerFall" },
  { "game": "duck-game", "title": "Duck Game" }
] }
```

## Party state (daemon → overlays)

Every state change is broadcast as one snapshot — overlays are dumb renderers:

```json
{ "type": "party_state", "party": {
  "players": [ { "id": "41af…", "name": "Ada" } ],
  "seats": [ ... ],
  "playlist": { "entries": [ ... ], "current": 0 },
  "active_session": { "id": "9be2…", "game": "towerfall", "phase": "running" },
  "warm_session":   { "id": "77c1…", "game": "duck-game", "phase": "ready" },
  "history": [ "towerfall" ],
  "vote": { "positions": [ [ "41af…", "next_game" ] ], "decided": null },
  "overlay_open": false,
  "library": [
    { "id": "towerfall", "title": "TowerFall", "tagline": "Arrows, friends, betrayal.",
      "color": "#7c5cff", "emoji": "🏹", "players": "2–4" }
  ],
  "connected_games": [ "duck-game", "towerfall" ],
  "settings": [
    { "game": "towerfall",
      "specs": [ … ],
      "values": { "items": false, "stock": 5 } }
  ],
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

- `cover` is a URL or data URI for real art. When absent, overlays generate a
  poster from `color` + `emoji`, so a shelf works with zero assets.
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

## The night, end to end

```
overlay: set_playlist [towerfall, duck-game]
daemon → towerfall: prepare        (warm the first game)
towerfall → daemon: ready
daemon → towerfall: start          (nothing was playing: auto-start)
daemon → duck-game: prepare        (warm the next one behind it)
duck-game → daemon: ready          (the party is now skip-proof)

towerfall → daemon: finished       (match over → vote opens)
players stand on "next_game"       (consensus!)
daemon → towerfall: dispose
daemon → duck-game: start          (instant transition)
daemon → towerfall: prepare        (playlist wraps; warm again)
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
  resolves. If nobody is seated, finished games auto-advance (demo mode).
- **Crashes don't end the night**: if the active game's process dies, the
  daemon transitions to the warm session as soon as it can.
- `error` messages are informational; the connection stays open (except after
  a rejected `hello`).

## Errors

```json
{ "type": "error", "message": "no seat 9" }
```

## Future (kept off v1 on purpose)

Downloads, remote seats over the network, voice, input routing, GPU/memory
budgeting for multiple warm sessions. They will arrive as new message types —
old games won't notice.
