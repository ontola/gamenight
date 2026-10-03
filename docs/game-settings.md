# Game settings

GameNight can display a game's settings in the lobby and phone interface. Games
must declare their options and implement the changes. Having the protocol or SDK
in a project does not expose its gameplay rules automatically.

## Available controls

The shared LÖVE pack now declares these settings. These are source capabilities;
installed releases need newly built packages before the controls appear.

| Game | Controls | When they apply |
| --- | --- | --- |
| Neon Trails | Speed 50–175%; round pause 0.5–5 seconds | Next round |
| Blast Party | Crate density 20–85%; crate pickup chance 0–60%; bomb fuse 1–4 seconds | Next round |
| Neon Siege | Relaxed, standard or intense enemy pressure; gravity 0–175%; wormholes on/off | Next run, not the next wave |
| Ricochet Club | 0–10 wall bounces; shot speed 50–160%; destructible cover on/off | Next round |
| Volley Trouble | Court; exploding ball; rotating rules; 1–21 points to win | Next match, not the next point |
| Stack Together | 4–40 rows to win; falling speed 50–175% | Next round |
| Bubble Buddies | 2–12 shared hearts; 1–10 waves; 30–150 seconds per wave | Next run |
| Pinpals | Simulation speed 60–125% | Next game instance |
| Mineclonia prototype | Gravity, jump, movement speed, air steering, sneaking speed, clock time, day/night speed and bounce pads; [ranges and effects](https://github.com/ontola/gamenight/blob/main/examples/mineclonia/README.md) | Live, after the world acknowledges the change |

The default values preserve the existing games. Blast Party's pickup chance
controls drops from crates; its two opening prizes remain. Neon Siege's enemy
count remains capped. Disabling gravity also removes gravitational hazards;
wormholes have their own switch. Pinpals changes simulation speed, including its
simulation timers, while keeping the physics fixed step.

Additional source audits found existing declarations in the separate projects:

| Game | Existing controls | Audit source |
| --- | --- | --- |
| SpaceRacer | Laps, track difficulty, world, track seed, graphics quality | `joepio/spaceracer`, `src/main.gd`, commit `c5bb5eb9eb05a1a3dc3273453a5f1e49e36edfcb` |
| Ballkickers | Match length, team size | Local `goal-rush` checkout, `src/party.gd` and `src/main.gd` |
| Frog Fighter | Mode, arena | Local `frog-fighter` checkout, `src/main.gd` |
| Ion Rush | Laps, graphics quality | Local game import, `src/main.gd`; not a catalog release |
| Growing Guns | 1–30 rounds to win (next match), modifier chance 0–100% (next round), card choice time 3–30 seconds (next pick) | [ontola/growing-guns](https://github.com/ontola/growing-guns), `scripts/gamenight_settings.gd`; added and engine-tested |

These audits do not certify the options in downloaded release binaries. The
lobby and retired demo games are not playable catalog entries and are excluded.

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

Mineclonia maps its integer percentages onto the existing world physics factors.
It applies them on a worker, coalesces repeated edits and retries mailbox
conflicts. Mod installation waits for an in-flight settings update. These two
controls do not install arbitrary mods. Edits made directly through the separate
world bridge are not automatically republished into GameNight's setting values.

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
cd examples/mineclonia
python -m unittest test_settings test_managed test_mod_lifecycle
```

The live-settings process test checks typed batches, stale/invalid rejection and
undo against observations from all eight running games. It does not test a
microphone, physical controllers or newly downloaded release packages.

The LÖVE suite checks all eight active modules: declarations, host message
routing, invalid values, snapshots and gameplay effects. It stages the Pinpals
modules as the release pack does. `--settings-output settings.json` exports the
tested declarations for UI previews. The Mineclonia tests cover value validation,
nonblocking updates, coalescing and mailbox conflicts. Packaged process tests also require a nonempty declaration and prepare each game
with non-default values. Native integration tests check lifecycle and input.
Run a real host/world test
before claiming a downloaded build or a physical controller session is verified.

Build new `.love` packages with `scripts/package-love-party.py`. Publishing those
packages and updating catalog URLs/checksums is a separate release step.
