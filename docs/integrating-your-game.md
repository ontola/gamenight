# Integrating your game with GameNight

**Goal: your game playable inside a party in under an hour.**

The mandatory contract is **one** message you send (`ready`) and five you
react to. A second outbound message, `finished`, is optional — send it if
your game has a natural match boundary and you want the party vote to open
the instant it's reached; skip it entirely if your game is happy to keep
playing (round after round, endless waves) until a human hits **Skip** in
the overlay. Everything else — playlists, voting, transitions, controllers,
who's in the party — is the daemon's problem, not yours.

This guide is written for the person doing the integration. The formal wire
spec lives in [protocol.md](protocol.md); this document tells you what to
build, in what order, and how to test it.

---

## The mental model (read this first)

GameNight inverts the usual relationship between a game and a launcher:

- **The party is persistent. Your game is a disposable session.**
  One evening = one party = many games. Yours is one track on a playlist.
- **Your process is launched once and stays resident all night.** Inside it,
  *sessions* are created and destroyed cheaply. Think of your game as a
  jukebox that can load a record, play it, eject it, and load another —
  without rebooting.
- **You are warmed up behind the current game.** While the party plays
  something else, your game silently loads everything. When the transition
  lands on you, you must be *instantly* playable. That's the entire product:
  the next game is already warm.

The lifecycle of one session, from your point of view:

```
            you receive              you send
            ───────────              ────────
              prepare   ──►  load everything, bind seats
                                     ready      (nothing on screen yet!)
   (maybe minutes pass — you are the warm session)
               start    ──►  GO. Gameplay within a second.
              (pause)   ──►  freeze
              (resume)  ──►  unfreeze
                             ...match ends...
                                     finished
   (players vote; you keep rendering your score screen)
              dispose   ──►  tear the session down, wait for the next prepare
```

Two invariants you can build on:

1. **Phases only move forward.** You will never see `start` before your
   `ready`, never see the same session revived after `dispose`. A "replay"
   is a brand-new session (new id) of the same game.
2. **Session ids are never reused.** Log them, key your state on them,
   assert on them freely.

---

## Step 0 — How your game gets launched

You don't add CLI flags. The daemon launches your binary from its library
entry and passes the handshake in **environment variables**:

| variable | meaning |
|---|---|
| `GAMENIGHT=1` | you were launched by a GameNight daemon |
| `GAMENIGHT_ADDR` | WebSocket address to connect to (e.g. `127.0.0.1:7912`) |
| `GAMENIGHT_GAME_ID` | the title id you were launched to serve |
| `GAMENIGHT_TOKEN` | per-launch secret — echo it in your `hello` |

The pattern every integration should follow at boot:

```
if GAMENIGHT == "1":
    skip the title screen, skip the intro video, skip your own lobby
    connect to GAMENIGHT_ADDR, say hello, wait for prepare
else:
    boot normally — you are a standalone game tonight
```

One binary, two modes, zero flag plumbing. During development you'll mostly
run the third mode: start your game by hand with no environment and connect
anyway — the daemon accepts token-less hellos for titles it hasn't launched
itself.

---

## Step 1 — Connect and say hello

Open a socket to `$GAMENIGHT_ADDR` (default `127.0.0.1:7912`) and start
sending JSON objects, each with a `type` field.

Two framings, same protocol, same port — the daemon tells them apart from
your first four bytes:

- **WebSocket** (`ws://$GAMENIGHT_ADDR`), one JSON object per text frame.
  Use this if your engine already has a WebSocket client: browsers, Godot,
  Rust, Node.
- **Plain TCP**, one JSON object per line. No handshake, no frame codec —
  connect and write. Use this if it doesn't: most C/C++ engines, and
  anything where vendoring a WebSocket library costs more than the
  integration itself.

Neither is a downgrade and they interoperate freely; pick whichever is less
work in your codebase. The rest of this guide is identical either way.

Your first message must be `hello`:

```json
{ "type": "hello", "role": "game", "game": "my-game", "token": "…" }
```

- `game` is your **title id** — lowercase, stable, matches the library and
  playlist entries (`"duck-game"`, not `"Duck Game v1.2"`).
- `token` is `GAMENIGHT_TOKEN` if it's set; omit it otherwise. If the daemon
  launched a process for your title, only the token holder gets in.

The daemon answers with `welcome`:

```json
{ "type": "welcome", "protocol_version": 1, "party": { … } }
```

Check `protocol_version` (currently `1`; it only changes on breaking
changes). The `party` snapshot tells you who's around — most games can
ignore it and just wait for `prepare`.

**One process, one title.** A second connection claiming the same title is
rejected. Your process hosts many sessions over the night, sequentially.

---

## Step 2 — `prepare`: load everything, show nothing

> **Before any of this: don't take the screen when you launch.** The daemon
> starts your process long before anyone asks to play you, so the party is
> looking at the lobby when your window appears. A game that boots fullscreen
> — the default for a lot of engines, and a *project setting* that applies
> before a line of your code runs — covers the lobby the moment it's warmed,
> and on macOS it drags the whole desktop onto its fullscreen Space with it.
>
> Fix it where it happens: at launch, not at runtime. Godot takes `--windowed`
> (and `--resolution 640x400` to keep the flash small), Unity `-screen-fullscreen 0`,
> and most engines have an equivalent flag or an env var — put it in the
> `launch.args` of your catalogue entry. Going fullscreen is what `start`
> means, and nothing before it.

At some point — possibly seconds after connecting, possibly much later — the
daemon warms you up:

```json
{
  "type": "prepare",
  "session": "9be2e2f0-…",
  "game": "my-game",
  "seats": [
    { "index": 0, "occupant": { "kind": "local", "player_id": "41af…" } },
    { "index": 1, "occupant": { "kind": "local", "player_id": "77c1…" } },
    { "index": 2, "occupant": { "kind": "ai" } },
    { "index": 3, "occupant": { "kind": "empty" } }
  ],
  "players": [
    { "id": "41af…", "name": "Ada" },
    { "id": "77c1…", "name": "Joep" }
  ]
}
```

Now do *all* the slow work: load the level, compile shaders, spawn pawns,
bind input. Then reply:

```json
{ "type": "ready", "session": "9be2e2f0-…" }
```

Rules that make or break the experience:

- **Show nothing and play no audio.** Another game is on screen. If you're
  windowed/attached to a display, stay hidden or blank until `start`.
- **`ready` is a promise, not a status update.** Send it only when a `start`
  arriving one millisecond later would be fine. The skip button and the
  vote wait on your `ready` — an optimistic one makes the whole party stutter.
- **Don't gate `ready` on anything interactive.** No "press any button",
  no sign-in, no save-select. Sensible defaults, always.

### When loading is genuinely slow

`ready` is a promise, and the guidance above ("send it only when a `start`
one millisecond later would be fine") assumes you *can* keep that promise.
Some games can't: a 3D racer loading a track, an engine that streams assets,
anything whose level load is measured in seconds. Warm sessions were built
for exactly these games, so don't read the rule as "GameNight is only for
games that load instantly."

What to do, in order of preference:

1. **Load during `prepare` and take the time.** This is the whole point of
   the warm slot — you're loading behind another game that's still being
   played, so eight seconds costs the party nothing. Send `progress` while
   you work so the overlay shows something truthful:

   ```json
   { "type": "progress", "session": "9be2…", "percent": 40, "label": "loading track" }
   ```

   Then `ready` when you're actually done. Send `progress` as often as is
   useful; the daemon keeps the latest and puts it in every snapshot.

2. **If your engine can't load without rendering** — many can't; the loader
   is wired into the main loop and entering a level means entering the
   render loop — then load anyway, and keep the screen black and the audio
   muted until `start`. A hidden window or a blank frame is fine. What is
   *not* fine is showing your loading screen over the game the party is
   still playing.

3. **Never gate `ready` on the load if you can't finish it.** A `ready` you
   can't honour is worse than a slow one: the party transitions to a black
   screen. If you truly can't preload, hold `ready` until you can, and let
   `progress` explain the wait.

The one thing to avoid is silence. A game that takes nine seconds and says
so is a good citizen; a game that takes nine seconds and says nothing looks
broken, and someone will reach for Skip.

### Seats, not controllers

You receive **seats** — playable positions with stable indices. Seat 1 is
seat 1 all night, across every game; that's how "player 2 stays player 2"
works. Occupant kinds:

| kind | meaning | what you do |
|---|---|---|
| `local` | a person on this machine | spawn their pawn, label it with the player's `name` |
| `remote` | a networked player (future — already on the wire) | treat as local for now |
| `ai` | the party wants a bot here | spawn your bot if you have one, else treat as empty |
| `empty` | nobody | hide or skip the slot |

Map seat index → your input slot 1:1 (seat 0 = your "player 1" input). The
daemon owns which physical controller feeds which seat; the optional
`controller` hint on a seat is exactly that — a hint — and most games should
ignore it. **Never** do your own controller-to-player assignment screen in
game-night mode; that's the friction this whole system deletes.

**If your engine has its own device manager** — a `DeviceManager`, an input
map, a "press A to join" flow that binds pads to player slots — the
translation is: for each non-`empty` seat in index order, create one local
player bound to the *n*-th connected gamepad, in the engine's own device
order. That's it. Don't try to match specific hardware: the daemon hands
out seats in the order people joined, and gamepad enumeration order on every
desktop OS follows connection order too, so index-to-index is right in
practice and self-correcting when it isn't (people just swap pads, or the
party swaps the seats).

Two seats must never share one device. If you have fewer pads than seated
players — someone unplugged one — create the players you can and leave the
rest out rather than doubling up, which silently makes two karts steer
together. Keyboard-and-mouse counts as a device here: handing it to a second
seat as a fallback is the same bug, one mouse turning two heads.

**Enumerate the pads on `start`, not on `prepare`.** Warming happens while
you are off-screen and unfocused, and a pad that connects — or gets picked up
— while the party is still in the lobby need not be enumerated for a
background process yet. Bind the seats to devices in the same breath as
taking the screen; `prepare` is for loading, which needs no pads at all.

If the party is smaller than your declared `min_players`, the daemon fills
the empty seats with `ai` before it sends them (see
[protocol.md](protocol.md#daemon--game)) — so spawn one bot per `ai` seat and
you're done. You don't need a fallback of your own for "only one human
turned up".

Names and avatars: `players[]` gives you display names keyed by `player_id`.

### Showing player avatars

Players draw a small pixel-art face for themselves in the profile studio. It
arrives on `Player.avatar` as an opaque string — decode it with
`Avatar::parse` rather than reading the string, so your game keeps working
when the encoding changes:

```rust
use gamenight_protocol::Avatar;

for player in &party.players {
    let Some(art) = player.avatar.as_deref().and_then(Avatar::parse) else {
        continue; // no avatar, or nothing drawn yet
    };
    let (w, h, rgba) = art.to_rgba_scaled(4);
    // upload `rgba` as a w x h RGBA8 texture
}
```

`to_rgba()` gives you `width * height * 4` bytes directly;
`to_rgba_scaled(n)` nearest-neighbours it first, which is what you want for
pixel art — a renderer's default bilinear filter will smear a 16x16 face into
mush. Transparent pixels come back fully zeroed. `is_blank()` tells you the
player has an avatar record but hasn't drawn anything, which is worth
skipping rather than rendering as an empty box.

This is optional depth. A game that ignores avatars entirely is still a
perfectly good GameNight integration — but showing the face someone drew
above their character is one of the cheapest ways to make a party feel like
*these specific people* are playing.
Use them — a scoreboard that says "Ada" instead of "P1" is the cheapest
delight you can ship.

---

## Step 3 — `start`: you have one second

```json
{ "type": "start", "session": "9be2e2f0-…" }
```

The previous game is being disposed *right now*. The party is staring at
your first frame. Target: **gameplay in under a second.** A brief animated
"Round 1 — FIGHT" is great; a 20-second unskippable intro is a bug report.

If your game normally shows menus between "launched" and "playing" —
character select, map vote, rules screens — pick defaults at `prepare` time
or drive them from your own quick in-game flow *after* start. When in doubt:
start the match. People grabbed controllers to play, not to configure.

---

## Step 4 — `finished` (optional): the match is over, you are not

This step is entirely optional. If your game doesn't have a clean "the set
is over" moment — round-based games where playing indefinitely is normal
and fine — skip it and jump to [Step 5](#step-5--dispose-eject-the-record).
The party can always end your session early with the overlay's **Skip**
button, whether or not you ever send `finished`.

If your game *does* have a natural stopping point, sending `finished` is a
nicety worth adding: it opens the party vote the instant that point is
reached, rather than waiting for someone to notice and reach for the
overlay themselves. When your win condition triggers:

```json
{ "type": "finished", "session": "9be2e2f0-…" }
```

Send it when the *match* ends — not when your outro finishes. The daemon
opens the party vote (replay / skip / next game / quit) the moment it hears
this, and players vote **while your victory screen is still up**. Keep
rendering: scoreboard, confetti, slow-mo replays. You'll get one of:

- `dispose` — the party moved on. Tear down (next section).
- a fresh `prepare` — the party voted *replay*. It's a brand-new session of
  your game; go back to Step 2 with the new session id.

Don't add your own "play again? Y/N" UI in game-night mode — the party
votes in the overlay, and two competing prompts is exactly the friction this
replaces.

---

## Step 5 — `dispose`: eject the record

```json
{ "type": "dispose", "session": "9be2e2f0-…" }
```

Free the session's resources, then **go back to waiting for `prepare`** —
do not exit. Your process stays resident all night precisely so the next
prepare is cheap. `dispose` can also arrive mid-match (someone hit skip):
stop immediately and silently. No "are you sure?", no save prompts.

The one time your process should exit on its own: the socket closes and
doesn't come back — the daemon is gone, the night is over.

---

## Optional but appreciated

**`pause` / `resume`** — sent when someone opens the party overlay or hits
pause. Freeze the simulation and mute audio on `pause`; the overlay is being
drawn over you. If a pause was in flight while your match ended, your
`finished` still wins — the daemon handles that race; just send it.

**`request_start`** — send it whenever your window gains focus. A warm game is
a real process with a real window, and the OS will hand it focus without
consulting GameNight; when a player Cmd+Tabs to you, they are asking to play
you. Report it and the daemon decides (warm → start, paused → resume,
otherwise nothing). Two lines of code, and it turns "I switched to the game
and it just sat there" into the obvious thing happening.

`resume` means what `start` means: **take the screen back**. Calling up the
party hands the couch's attention to the lobby (it is a whole other app, not
an overlay drawn on you), so coming back is a real window/app activation —
raise, unminimise, go fullscreen, unmute. A game that only unfreezes its
simulation on `resume` leaves the party looking at the lobby while the match
runs invisibly behind it, with no way back in.

**`party_state`** — broadcast whenever anything changes (someone joins,
seats swap, votes move). Games that adapt mid-session (spawn a pawn when a
player joins mid-match, relabel on seat swap) feel magic, but this is
strictly optional — seats are re-delivered on every `prepare` anyway.

**Match settings** — declare the knobs your game would normally hide in an
options menu (items on/off, stock, arena) and the party can turn them from
the overlay — or by just *asking*: an LLM connected through
[`gamenight-mcp`](llm-control.md) maps "hey GameNight, disable items" onto
your declared keys. One message after connecting:

```json
{ "type": "declare_settings", "settings": [
  { "key": "items", "label": "Items", "kind": "toggle", "default": true,
    "description": "Whether power-up items spawn during a match." },
  { "key": "stock", "label": "Stock", "kind": "number",
    "default": 3, "min": 1, "max": 99 }
] }
```

Changes arrive as `{ "type": "setting_changed", "key": "items", "value":
false }` — apply live if you can, from the next match if you can't. The
daemon owns validation and the current values (they survive your process
reconnecting), so **don't build a settings menu in game-night mode** — same
rule as lobbies and play-again prompts. Write the `description`s well:
they're the words the overlay shows and the LLM reads. Wire spec:
[protocol.md — Match settings](protocol.md#match-settings).

**Errors** — `{ "type": "error", "message": "…" }` is informational; the
connection stays open. Log it, don't crash.

**Forward compatibility** — ignore unknown message types and unknown fields.
That's how the protocol grows without breaking your shipped build.

---

## The contract, condensed

Your obligations:

| | rule |
|---|---|
| ✅ | `hello` first, with your title id (+ token when launched) |
| ✅ | on `prepare`: load fully, bind seats, then `ready` — nothing on screen |
| ✅ | on launch: don't take the screen, and don't take focus ([why](#owning-the-screen-what-the-os-actually-does)) |
| ✅ | on `start`: gameplay within ~1 second, and the screen is yours to claim |
| ✅ | on `pause`: freeze *and* step off the screen — the lobby cannot take it from you |
| ✅ | on `resume`: take the screen back, exactly as `start` does |
| ✅ | on `dispose`: tear down and wait for the next `prepare` — don't exit |
| ✅ | ignore unknown messages and fields |
| 🙂 | *(optional)* send `finished` when the match ends; keep rendering until `dispose` |
| 🙂 | *(optional)* `request_start` when your window gains focus — Cmd+Tab is a "go" |
| 🙂 | *(optional)* `declare_settings` for your match options; apply `setting_changed` |
| ❌ | no menus, lobbies, sign-ins, controller-assignment screens, unskippable intros |
| ❌ | no audio/video before `start` |
| ❌ | no "play again?" prompts — the party votes |

What you can rely on:

- lifecycle order is guaranteed; session ids are never reused
- seats are stable across the whole night (seat 1 is always seat 1)
- `start` only ever arrives after your `ready`
- replay = fresh session, same process
- the daemon reconciles crashes: if you die, the night rolls on without you
  (and the daemon may relaunch you later)

---

## Ways to integrate

**Godot 4** — install the [addon](../sdk/godot/README.md), connect four
signals, call two methods. The addon handles the environment detection,
connection, reconnection and JSON.

**Rust** — use [`gamenight-sdk`](../crates/gamenight-sdk/src/lib.rs):
`GameNight::connect_from_env()`, loop on `next_event()`, call `ready()` /
`finished()`. The [demo game](../examples/demo-game/src/main.rs) is a
complete integration in ~100 lines including its fake gameplay.

**C / C++** — drop [`sdk/c/gamenight.h`](../sdk/c/gamenight.h) into your
source tree. Single header, C99, no dependencies, no build-system changes:
it speaks the plain transport, so there's no WebSocket library and no JSON
library to add to a project that has neither (which is most C++ engines).

```c
#define GAMENIGHT_IMPLEMENTATION
#include "gamenight.h"

gn_client gn;
if (gn_connect_from_env(&gn, "my-game") == GN_OK) {   // GN_ERR_NOT_LAUNCHED
    gn_event ev;                                      // => boot standalone
    while (gn_poll(&gn, &ev) >= 0) {                  // non-blocking
        if (ev.type == GN_PREPARE) {
            load_for_seats(ev.seats, ev.seat_count);  // names already resolved
            gn_ready(&gn, ev.session);
        } else if (ev.type == GN_START) {
            go();
        }
    }
}
```

`gn_poll` never blocks, so it drops into an existing game loop as one call
per frame. Seats arrive with the player's name already joined onto them —
you never have to walk `players[]` yourself. A full worked example is
[`examples/c-game.c`](../examples/c-game.c), which is certified by the same
harness as every other integration.

**Anything else** — it's a socket and seven JSON messages. A complete,
runnable integration in dependency-free JavaScript is at
[`examples/tiny-game.mjs`](../examples/tiny-game.mjs) — 60 lines, half of
them comments. If your engine can open a socket, you can integrate without
waiting for us to ship an SDK. The protocol is the product; SDKs are
convenience.

---

## Testing your integration

### The one-command certification

The repo ships a conformance harness that runs a scripted night against your
game and grades the checklist for you:

```sh
# recommended: let the harness launch your game (tests the env handshake too)
cargo run -p gamenight-certify -- my-game -- /path/to/my-game --your-flags

# or: start your game by hand against the printed address
cargo run -p gamenight-certify -- my-game --port 7912
```

```
─────────────────────────────────────────────────────
 GameNight conformance · my-game
─────────────────────────────────────────────────────
 ✔ process connects and says hello  (487 ms)
 ✔ prepare -> ready -> instant start  (warm in 42 ms)
 ✔ match ends with a single `finished`  (vote opened)
 ✔ replay vote -> fresh session, same process
 ✔ pause and resume tolerated mid-match
 ✔ mid-match skips: dispose, re-prepare, stay resident  (5 skips, avg 43 ms)
 ✔ process resident for the whole night
─────────────────────────────────────────────────────
 7/7 passed — my-game is party-ready 🎉
```

It exercises exactly one human-played match (`--match-timeout` defaults to
5 minutes; automated games finish in seconds) — everything else is driven by
the harness: the replay vote, pause/resume, and `--cycles` rapid mid-match
skips. Exit code 0 means party-ready, so it drops straight into CI. The
items a protocol harness can't see (rendering, audio, input feel) are
printed as a manual checklist at the end.

### The five-minute loop (a one-line library, no launch spec needed)

1. Give the daemon a one-entry library naming your title — no `launch` spec,
   since you're starting the game by hand:
   `echo '[{"id":"your-game","title":"Your Game"}]' > /tmp/mine.json`
2. Start the daemon: `GAMENIGHT_LIBRARY=/tmp/mine.json cargo run -p gamenight-daemon`
3. Start **your game** by hand (no env needed — token-less hello is fine).
4. Your game gets `prepare` → answer `ready` → it auto-starts (first game of
   an empty night starts the moment it's warm).

Watch it with `cargo run -p gamenight-overlay` if you want eyes on party
state while you iterate: `finished` should open the vote; *replay* should
land a fresh `prepare` on you; **⏭ Next game** should `dispose` you mid-match
without complaint.

### The full-launch loop

Add your game to a library file and let the daemon do everything:

```json
[ { "id": "my-game", "title": "My Game",
    "tagline": "One line that sells it.",
    "emoji": "🎯", "color": "#7c5cff", "players": "2–4",
    "cover": "https://…/cover.png",
    "launch": { "command": "/path/to/my-game", "args": [] } } ]
```

```sh
GAMENIGHT_LIBRARY=my-shelf.json cargo run -p gamenight-daemon
```

Your game now appears on the overlay's shelf with cover art (or a generated
poster from `color` + `emoji` if you don't provide one), and **Play next**
must take it from process-not-running to warm-and-ready with no human
touching your binary. This is the test that matters.

### The checklist

This is what the harness grades (plus the manual items). Run one full night
against your game and check every box:

- [ ] boots into game-night mode when `GAMENIGHT=1`, standalone otherwise
- [ ] `ready` sent only when an instant `start` would look flawless
- [ ] nothing rendered / no audio before `start`
- [ ] `start` → gameplay in under a second, correct pawns for the seats given
- [ ] empty seats hidden; `ai` seats handled (bot or hidden)
- [ ] player names from the snapshot shown in your UI
- [ ] *(optional, if you send `finished`)* it fires exactly once, at match end, outro keeps rendering
- [ ] *(optional, if you send `finished`)* replay vote → fresh session works twice in a row
- [ ] *(optional, if you declare settings)* a `set_setting` from the overlay reaches your game and sticks
- [ ] skip mid-match (`dispose` while running, with or without a prior `finished`) exits silently to warm state
- [ ] `pause` freezes sim + audio; `resume` continues cleanly
- [ ] process survives 10 prepare/dispose cycles without leaking memory
- [ ] daemon killed mid-match → your game exits (or returns to its own menu)

### Common mistakes, from the trenches

- **Sending `ready` from your loading screen.** `ready` means *done*, not
  *started loading*. The transition waits on you.
- **Binding input to controller indices instead of seat indices.** The seat
  order is the party's truth. Trust it.
- **Exiting on `dispose`.** That kills the warm-session model — the next
  `prepare` now pays full process-boot cost. Stay resident.
- **Treating `dispose` mid-match as an error.** It's the skip button. It's
  a feature. Exit the match silently.
- **Prompting on quit/skip.** Any modal you show after `dispose` is a modal
  drawn over somebody else's game.
- **Hiding a warm session by drawing black over it.** A black rectangle is not
  "off screen" — it's a window the size of the screen, painted black, sitting
  on top of the lobby the party is looking at. Get the window out of the way.
- **Treating `pause` as freeze-only.** The party asked for the lobby; if you
  stay on screen they don't get it, and on macOS they *can't* get it (see
  [platform notes](#owning-the-screen-what-the-os-actually-does)).
- **Letting last session's players into the next one.** Staying resident means
  your globals outlive the match. Bots you spawned to fill empty seats, and
  players your own couch-coop flow added, are still in whatever roster you
  keep — and the next `prepare` rebuilds them from it, usually as ordinary
  players, since nothing recorded which were which. The party's second match
  of the night then has a motionless "player" in it and a seat fewer than they
  asked for. On `prepare`, forget everyone you invented; the seats you were
  just handed are the whole player list.
- **Warming by running the match with input disabled.** Warm means loaded, not
  playing. If your window is ever seen, it should be a still image — not a
  match already in progress that someone can walk into — and it shouldn't be
  spending a core on a game nobody is watching.

---

## Owning the screen: what the OS actually does

Everything above says *when* you should have the screen. This is what it takes
to actually get it, and it is where every integration so far has lost a day.
The rules are not GameNight's — they're the window server's, and they bite in
the same three places every time: your process launches, your session starts,
and the party goes back to the lobby.

Below is what we measured, on the platform we measured it on. Where a claim is
untested, it says so — a plausible-sounding guess about someone else's window
manager is worse than no line at all.

### macOS

**Launching a process activates it.** The daemon starts your game long before
anyone asks to play it, usually while another game is running. macOS brings a
newly launched app to the front the moment it puts up a window, so warming
steals the screen from the match in progress — the one thing warming must
never do. Create your window *without* taking focus, and clear that once you
are the game being played (a no-focus window ignores keyboard input, so it
cannot stay that way). In Godot: `display/window/size/no_focus=true`, then
`DisplayServer.window_set_flag(WINDOW_FLAG_NO_FOCUS, false)` on `start`.

**A background app cannot take focus from the frontmost one.** Since macOS 14
the OS simply declines — no error, nothing happens. Focus handoff is therefore
*cooperative*: whoever currently has the screen has to step aside before the
next thing can take it. This is why `pause` is not only "freeze the
simulation": on `pause` you must also get out of the way (minimise, or hide),
or the lobby will ask for the screen, be refused, and the party will sit
looking at a game that has stopped running. The same applies in reverse on
`dispose`.

**Don't boot fullscreen.** It's a project setting, so it applies before a line
of your code runs — the party watches a game they didn't pick take the screen
a second after the daemon warms it. Fullscreen is what `start` means. Move it
to a runtime decision, and make the daemon-launched path skip it.

Do not assume a command-line flag can save you here: Godot 4.7 ignores
`--windowed`, `--position` *and* `--resolution` when the project setting says
fullscreen (all three measured). The setting itself was the only lever.

**Window-mode changes are animated, and asking again restarts them.** Minimise
and fullscreen both animate. A retry loop that re-requests every frame keeps
restarting the animation, so it never completes and the mode never changes —
which looks exactly like the request being ignored. Ask, wait ~250 ms, ask
again. Use wall-clock time, not a frame count: while you're loading, a frame
can take the better part of a second, so a frame-counted wait is dead time the
party spends looking at your window.

One interval does not fit every transition. *Leaving* fullscreen takes about a
second — macOS slides a whole Space away — and a second request that lands
during it toggles fullscreen straight back on, so the window flaps between the
two states for as long as you keep asking. Give that leg ~1.2 s before asking
again, and only then start asking to minimise. A game that got this wrong sat
in a window over the lobby for the rest of the night.

**Minimising a fullscreen window goes via windowed**, so a warm game that boots
fullscreen and then hides itself is seen to open fullscreen, shrink, and
vanish. Deminiaturising is animated too, and a fullscreen request that lands
while the window is still climbing out of the Dock is dropped on the floor:
restore first, wait for it to land, *then* claim the screen.

**Native fullscreen puts you on a Space of your own.** That is fine for a game
and wrong for anything that has to reappear reliably: when another app takes
the screen, your window is on an inactive Space, and activating the app does
not bring that Space forward — the menu bar says your name while the party
looks at the desktop. For the lobby, a borderless window sized to the screen
(with the menu bar and Dock auto-hidden) looks identical and always lives on
whatever Space is in front.

**Have a way to lose.** Every request above can be declined, and a retry loop
with no exit condition will keep asking forever while the party looks at a
game they dismissed. Give getting off the screen a deadline — a few seconds —
and a fallback for when it expires: drop focus and move the window off the
side of the display. It is a poor substitute for minimising, since the window
still exists and still costs a compositor pass, but "the game they closed is
still on the TV" is the one outcome that must never survive a refusal.

**A refused fullscreen transition is not a no-op.** If your engine wraps winit
(Bevy does), `window_did_fail_to_enter_fullscreen` re-locks a mutex it already
holds and your main thread never returns. The app stays alive at 0% CPU,
renders nothing, and processes no further daemon messages — an outage that
looks exactly like a hang, because it is one. Only ask for fullscreen while
your app is genuinely active (`NSApplication.isActive`, not your window's
`focused` flag, which is `true` for a window whose app was never activated),
or don't use native fullscreen at all.

**An off-screen window may stop being updated.** Don't put anything the daemon
depends on behind your render loop if you can avoid it.

### Windows and Linux

Untested — GameNight's own development has been on macOS so far. The parts of
the above that are pure protocol (step aside on `pause`, take the screen on
`start` and `resume`, don't boot fullscreen, report `request_start` on focus)
should hold anywhere, because they're about who is *allowed* to be on screen
rather than about AppKit. The mechanisms almost certainly differ: focus-steal
prevention on Windows is a different rule set again, and on Linux it's whatever
your compositor decided this week. If you integrate on either, a PR correcting
this section is worth more than the rest of this document.

### Engine notes

**Godot.** Window mode and no-focus are project settings before they are API
calls; see above. If you pause the tree while warm — and you should, so a warm
process is loaded rather than *playing* — then the node that owns your daemon
socket needs `PROCESS_MODE_ALWAYS`, or you will pause yourself and never hear
the `start` that would unpause you. Capping `Engine.max_fps` turns a frozen
match from a busy core into a rounding error — but cap it *after* you have
sent `ready`, never before. Loading is what those frames are for: a game that
throttles itself from boot streams its terrain ten times more slowly, and the
daemon sits waiting on a `ready` that is being drip-fed to it. Lift the cap on
`start`.

**Bevy / winit.** `WindowMode::BorderlessFullscreen` is *native* fullscreen on
macOS, Space and all — not a borderless window. If you want the latter, set
`decorations = false` and size the window to the monitor yourself.

---

## FAQ

**My game is round-based — when do I send `finished`?**
When the *set* ends, not each round — and only if you want to. Handle
rounds internally with your own quick transitions. Rule of thumb: `finished`
when you'd naturally show a final scoreboard. If your game doesn't have one
(best-of-forever, endless waves), don't send it at all — the party's Skip
button ends the session whenever they're ready to move on.

**Can I get more than 4 players?**
Seat count comes from the daemon's party (default 4). Render whatever seats
you're given — don't hardcode 4.

**What if my game needs a minimum player count?**
Play with bots or degrade gracefully. `prepare` with one `local` seat and
three `empty` is a normal Tuesday. Never block `ready` on player count.

**A player joined after `prepare` — do I see them?**
Not in this session (seats are fixed per session) unless you opt into
`party_state` updates. They'll be seated in the next session's `prepare`.
Fixed-per-session is the intended simple path.

**Do I need to handle `pause` if my game is turn-based?**
You still get the message; a no-op is acceptable. Mute audio anyway — the
overlay is up.

**Can two instances of my game run at once?**
Not today (one connection per title id). Tournament brackets may lift this
later — another reason to key everything on session id, not game id.

**How do I get on the shelf with real cover art?**
Locally: ship a library entry (`GameMeta`) with your `cover` URL and `launch`
spec — see [protocol.md](protocol.md#the-library-cover-art-and-all-that).
Publicly: submit your game to [the catalogue](../catalog/README.md) — player
counts, hardware requirements, where to get it, and your integration level.
Certified entries (paste your `gamenight-certify` output in the PR) are what
discovery will surface first.

---

*The guiding question for every integration decision:*

> **Does this make game night feel faster, smoother, and more fun?**

If your game boots into gameplay before anyone puts their drink down, you've
nailed it.

### AFK and instant join

Opt into [player participation](protocol.md#player-activity-sleep-and-joining-during-play)
after Prepare. Report real controller input and handle `party_updated` for warning,
sleep, and wake states. Set `instant_join:true` only when you can insert players into
a running round without resetting it. Player IDs and controller bindings survive sleep.
