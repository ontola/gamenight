# "Hey GameNight" — LLM control

GameNight ships an [MCP](https://modelcontextprotocol.io) server,
`gamenight-mcp`, that turns the party into something you can *talk to*.
Connect any MCP-capable assistant — Claude, a voice pipeline, a home
automation — and it becomes a member of the party that can read the room and
turn the knobs:

> "Hey GameNight, let's disable items" → `set_setting {key: "items", value: false}`
> "Make the matches shorter" → `set_setting {key: "match_seconds", value: 60}`
> "Queue up TowerFall next" → `play_next {game: "towerfall"}`

No integration work per game: any game that declares
[match settings](protocol.md#match-settings) is automatically steerable, and
the tool layer is just another overlay-role client of the daemon.

## Setup

```sh
cargo install --path crates/gamenight-mcp   # or: cargo build -p gamenight-mcp
claude mcp add gamenight -- gamenight-mcp
```

Start the daemon as usual; `gamenight-mcp` connects to `GAMENIGHT_ADDR`
(default `127.0.0.1:7912`) and speaks MCP on stdio. That's the whole setup —
now ask Claude to disable items.

## The tools

| tool | what it does |
|---|---|
| `party_status` | who's seated where, what's playing, what's warming, playlist, library, the active game's settings, any open vote |
| `list_settings {game?}` | a game's declared knobs — key, label, description, allowed values — plus current values |
| `set_setting {key, value, game?}` | change one knob; `game` defaults to whatever is being played |
| `play_next {game}` | make a game the next one up (starts warming immediately) |
| `skip` | instant transition to the warm game, no vote |
| `pause` / `resume` | pause or resume the active game |

## Design notes

- **The LLM has no special powers.** Every tool maps 1:1 onto overlay
  protocol messages; the daemon validates writes exactly as it would for a
  human. An assistant cannot put a game into a state the party couldn't.
- **Errors are the prompt.** Daemon rejections pass through verbatim —
  `'towerfall' has no setting 'itemz'; available: items, stock, arena` — so
  the model corrects itself in one round instead of guessing.
- **Sloppy values are coerced, using the declared spec.** A voice transcript
  produces `"5"` where a number belongs and `"true"` where a bool belongs;
  the server maps those onto the declared kind before sending.
- **Confirmation is observed, not assumed.** After a write, the server waits
  for the party snapshot to reflect the change (or the daemon's rejection)
  before answering, so "Done" means *done*.

The mandatory game-side surface is unchanged — settings are optional, like
`finished`. But a well-described settings declaration is what turns "pass me
the controller, I'll dig through the options menu" into a sentence said out
loud. See [Integrating your game](integrating-your-game.md) for the
one-message declaration.
