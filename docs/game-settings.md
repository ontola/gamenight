# Game settings

GameNight can display a game's settings in the lobby and phone interface. Games
must declare their options and implement the changes. Having the protocol or SDK
in a project does not expose its gameplay rules automatically.

## Available controls

The shared LÖVE pack and the Mineclonia catalog game declare these settings. These are source capabilities;
installed releases need newly built packages before the controls appear.

| Game | Controls | When they apply |
| --- | --- | --- |
| Neon Trails | Speed 50–175%; round pause 0.5–5 seconds | Next round |
| Blast Party | Crate density 20–85%; crate pickup chance 0–60%; bomb fuse 1–4 seconds | Next round |
| Neon Siege | Relaxed, standard or intense enemy pressure; gravity 0–175% | Next run, not the next wave |
| Volley Trouble | Court; exploding ball; rotating rules; 1–21 points to win | Next match, not the next point |
| Stack Together | 4–40 rows to win; falling speed 50–175% | Next round |
| Bubble Buddies | 2–12 shared hearts; 1–10 waves; 30–150 seconds per wave | Next run |
| Mineclonia | Gravity, jump, movement speed, air steering, sneaking speed, clock time, day/night speed and bounce pads; [ranges and effects](https://github.com/ontola/gamenight-mineclonia#reversible-live-changes) | Live, after the world acknowledges the change |

The default values preserve the existing games. Blast Party's pickup chance
controls drops from crates; its two opening prizes remain. Neon Siege's enemy
count remains capped. Disabling gravity also removes the black hole.

## Godot game controls

These independent game repositories use the same typed contract. Source builds
have been tested against the real daemon, including setting changes and Undo.

| Game | Controls | Timing and reference |
| --- | --- | --- |
| SpaceRacer | Laps, difficulty, world, seed, graphics; boost cost and duration, energy regeneration, crash recovery, weapon pickups | Boost, energy and recovery controls work during a race. Track rules and pickup stations wait for the next race. [All ranges](https://github.com/joepio/spaceracer/blob/main/docs/gamenight-settings.md) |
| Growing Guns | Rounds to win, modifier chance, card choice time; gravity, bullet drop, body shot damage, random pickup rate | Match goal waits for a new match; physics and combat wait for the next round; card time affects the next choice. [All ranges](https://github.com/ontola/growing-guns/blob/main/docs/gamenight-settings.md) |
| Ballkickers | Match length, matchup; running speed, shot speed, rolling friction, goalkeeper movement, passive super charge, super shots | Match structure waits for a new match. Movement and ball physics are live; shot changes affect the next shot. [All ranges](https://github.com/joepio/ballkickers/blob/main/docs/gamenight-settings.md) |
| Frog Fighter | Mode, arena, lives; running speed, jump impulse, frog gravity, damage, supply interval, bot reaction delay | Mode, arena and lives wait for a new round. Physics are live; jumps, hits, supplies and aiming use the new value on their next event. [All ranges](https://github.com/joepio/frog-fighter/blob/main/docs/gamenight-settings.md) |

Defaults preserve the existing games. Percentages are relative to those defaults,
not raw engine units. Growing Guns multiplies its round modifiers and replicates
the applied round snapshot to network peers. Ballkickers' charge rate only changes
passive refill; successful actions still earn charge. Frog Fighter's gravity
control applies to frogs, including rope movement, not every object in the world.

The host still owns seats and controller assignments. Settings cannot remap
controllers, create human players or write arbitrary engine variables.

Run each game's headless settings suite in its own repository. For the complete
source-to-host path, build the GameNight daemon and run:

~~~sh
export GODOT=/path/to/godot
export GAMENIGHT_GODOT_SOURCES='{"spaceracer":"/path/to/spaceracer","growing-guns":"/path/to/growing-guns","ballkickers":"/path/to/ballkickers","frog-fighter":"/path/to/frog-fighter"}'
python3 scripts/test-godot-settings.py
~~~

This launches isolated game processes and a daemon without using physical
controllers. It verifies the declared controls, received values and Undo.
The games' simulation tests separately check gameplay effects and apply timing.
Source checks do not certify older downloadable binaries or physical input.

Ion Rush still has source declarations for laps and graphics quality in a local
game import; it is not a catalog release. The lobby and retired demo games are
not playable catalog entries and are excluded.

## Declare and apply

The wire protocol accepts `toggle`, `choice` and integer `number` settings. Labels
must include units and say when a change takes effect. For fractional durations,
use readable choices such as `"1.4 s"` and convert inside the game. Unknown keys, wrong types and
out-of-range values must leave the last valid value intact.

In a shared LÖVE game:

```lua
local Game = { id = "my-game" }
require("shared.settings").bind(Game, {
    { key = "speed", label = "Speed % (next round)",
      kind = "number", default = 100, min = 50, max = 175 },
    { key = "pickups", label = "Pickups (next round)",
      kind = "toggle", default = true },
})

function Game.new(players)
    return { players = players, settings = Game.preferences() }
end

function Game.update(state, dt, inputs)
    local speed = 200 * state.settings.speed / 100
    -- Use speed in your movement simulation.
end
return Game
```

The helper provides `settings`, `setting(key, value)` and `preferences()`. The
shared runner declares the specs after `welcome` and forwards `setting_changed`.
`preferences()` returns a copy. A running round keeps its copy until the game
creates the next round. Call it in an internal reset too if the game starts
rounds without returning to the runner. Do not mutate active state just to make
a slider look responsive.

A declaration makes controls available once the game connects, usually during
preloading. It is not static catalog metadata. GameNight remembers party choices
and sends them back when a game declares settings again. It does not yet have a
separate acknowledgement for "applied in gameplay". A saved value may therefore
be pending the next round. See the [protocol reference](/docs/protocol).

A game's own menu can change its settings too: send `set_setting` for one of
your keys (Godot `GameNight.set_setting(key, value)`, Rust
`GameNight::set_setting`). GameNight validates it, stores it as the party's
choice and echoes `setting_changed`, so the app and the assistant show the
value players picked in the game.

Mineclonia maps its integer percentages onto the existing world physics factors.
It applies them on a worker, coalesces repeated edits and retries mailbox
conflicts. Mod installation waits for an in-flight settings update. These two
controls do not install arbitrary mods. Edits made directly through the separate
world bridge are not automatically republished into GameNight's setting values.

## Per-player settings

Some choices belong to one player, not the party: their character, their stick
sensitivity, inverted look. Declare those with `"scope": "player"` in the same
`declare_settings` call. Kinds, ranges and validation are the same.

```gdscript
GameNight.declare_settings([
    {key = "rounds", label = "Rounds to win", kind = "number",
     default = 3, min = 1, max = 9},
    {key = "sensitivity", label = "Stick sensitivity %", kind = "number",
     default = 100, min = 40, max = 250, scope = "player"},
    {key = "character", label = "Character", kind = "choice",
     default = "frog", options = ["frog", "cat", "robot"], scope = "player"},
])
GameNight.player_settings_changed.connect(func(player_id, values):
    aim_speed[player_id] = values["sensitivity"] / 100.0)
```

- Every player has their own value. The game receives `player_settings
  {game, player_id, values}` (all per-player keys, defaults merged in) after
  `declare_settings`, with every `prepare` and `party_updated`, and whenever the
  player changes one. In Godot: the `player_settings_changed` signal and
  `GameNight.player_setting(player_id, key, fallback)`.
- Change one from the game's own menu with `set_player_setting {player_id, key,
  value}` (Godot `GameNight.set_player_setting`, Rust `set_player_setting`).
  Phones send the same message for their own player.
- A player with a profile keeps their values between nights: the host saves them
  in its [player store](player-store.md). A guest's values last for the night;
  when the guest signs in, they move to their profile.
- Party writes (`set_setting`, `control_settings`) cannot change a per-player
  key, and `GameSettings.values` only holds party values. `GameSettings.players`
  shows each present player's own values, for the apps.

## Saved progress

Settings are knobs. Progress (unlocked characters, a spell book, best times)
is data only the game understands. Save it per player and per game:

```gdscript
GameNight.player_data_changed.connect(func(player_id, data):
    grimoire[player_id] = data.get("spells", []))
GameNight.save_player_data(player_id, {"spells": grimoire[player_id]})
```

- `save_player_data {player_id, data, expected_revision}` stores any JSON up to
  64 KB, replacing what was there. The host answers with `player_data
  {game, player_id, data, revision}`, and sends the same with every `prepare`,
  `party_updated` and `players_updated` for players that have any. No message
  means nothing is saved yet. Godot: `player_data(player_id)`,
  `save_player_data(player_id, data)` and the `player_data_changed` signal; Rust
  `save_player_data` and `GameEvent::PlayerData`.
- `expected_revision` is the revision of the last `player_data` you got (0 for
  none). A save against an older copy is refused, so two hosts never silently
  overwrite each other: merge in the newer data and save again. The Godot addon
  fills it in for you.
- Unlocks belong to a person. While playing, everyone in the room may use what
  anyone has unlocked (`GameNight.party_union("unlocks")`), but never save that
  union into a player's own data. What the group earns together counts for
  everyone present: `GameNight.unlock_for_present(item)` adds it to each of
  their `unlocks` lists.
- Like settings: a guest's progress lasts the night and moves to their profile
  when they sign in (unless that profile already has progress in this game).
  Worlds and other large saves do not belong here.

## Phone and lobby assistant

The standard desktop cloud bridge and the custom lobby relay publish these same
declarations for the active game, or the prepared game if none is running. Numeric
values, toggles and named choices all use the same contract. No engine-specific
model integration is needed: declare your settings and handle `setting_changed`.

The assistant sends a typed batch through `control_settings`. The daemon checks
the player, game session and settings revision, then validates every value before
changing any of them. Undo restores the preceding batch; Keep clears that undo.
A stale request is refused instead of overwriting a newer change. Normal
`set_setting` writes also advance the revision.

Host acceptance does not mean a next-round setting is already active in gameplay.
Keep the timing in the label and description. The assistant must not promise an
immediate gameplay change when your game waits for a new round or match. Account
configs store these scalar values, not world saves or arbitrary mod code.

Voice and account features belong to the optional GameNight service. The public
game contract remains usable offline, without an AI provider.

## Verify changes

From the repository root:

```sh
python scripts/test-love-simulation.py --love /path/to/love
# Linux, with LÖVE installed: real host and game processes, no display needed.
cargo build -p gamenight-daemon
python scripts/test-live-settings.py
# Mineclonia lives in ontola/gamenight-mineclonia; fetch-game-sources.py checks
# out its pinned revision beside this repository.
cd ../gamenight-mineclonia
python -m unittest test_settings test_managed test_mod_lifecycle
```

The live-settings process test checks typed batches, stale/invalid rejection and
undo against observations from all seven running games. It does not test a
microphone, physical controllers or newly downloaded release packages.

The LÖVE suite checks all seven active modules: declarations, host message
routing, invalid values, snapshots and gameplay effects. `--settings-output settings.json` exports the
tested declarations for UI previews. The Mineclonia tests cover value validation,
nonblocking updates, coalescing and mailbox conflicts. Packaged process tests also require a nonempty declaration and prepare each game
with non-default values. Native integration tests check lifecycle and input.
Run a real host/world test
before claiming a downloaded build or a physical controller session is verified.

Build new `.love` packages with `scripts/package-love-party.py`. Publishing those
packages and updating catalog URLs/checksums is a separate release step.
