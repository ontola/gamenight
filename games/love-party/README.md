# GameNight LÖVE Party Pack

Five original local multiplayer prototypes for 2–4 people. MIT licensed.
No assets or accounts to download, no internet connection during play.
Requires LÖVE 11.5; GameNight downloads this shared runtime separately.

| Game | Goal | Controls |
| --- | --- | --- |
| Bumper Royale | Knock friends out of a shrinking ring; +3 knockout, -1 fall | Move, A to dash |
| Neon Trails | Survive the trails; last rider earns +3, then everyone respawns | Turn; no reversing |
| Blast Party | Destroy crates, collect powers and be the last alive | Move, A to place a bomb, B to detonate remote bombs |
| Neon Siege | Survive together; shared score and combo, no friendly fire | Move, right stick to aim, A to dash, B for pulse |
| Meteor Dash | Collect stars (+5), avoid hits (-10), survive (+1/second) | Move, A for shield dash |

Competitive matches last 60 seconds. Ties share victory. Neon Siege is a
90-second cooperative survival match, ending early if the entire team falls. Every game supports 2, 3 or 4
players, bots for automated testing, and consistent seat colours (using GameNight player colours when supplied).
Scores are displayed by the game; protocol v1 reports match completion but
has no cross-game score submission message.

## Play

Run `love games/love-party` from the repository. Choose a game with 1/2/3/4/5 or
the controller D-pad, Enter/A to start, F2 to choose 2–4 players.
A packaged `.love` file opens its game directly. Escape/Back returns to the
standalone menu; Enter/A starts a rematch after the result screen.

Controllers use the left stick or D-pad and A. Keyboard seats:

1. WASD + Space
2. Arrows + Right Ctrl
3. IJKL + U
4. TFGH + R

Controllers follow seat order. Unplugging one preserves the other seats;
a new controller fills the first vacant active seat. Mixed controller APIs
can enumerate devices differently, so verify seat order on your hardware.
Remote phone controls are not implemented. Games support local controllers
and shared keyboard input; declared AI seats use bots.

## GameNight

`GAMENIGHT=1` enables the shared adapter. It reads `GAMENIGHT_ADDR`,
`GAMENIGHT_GAME_ID` and `GAMENIGHT_TOKEN`; authenticates; prepares hidden;
reports ready; shows fullscreen on Start; freezes and hides on Pause;
resumes; reports Finished once; and disposes without leaving a window.
Back/Escape requests the lobby. Daemon disconnection exits the game.

Use each game's ID in the table's source module or generated shelf. The
existing Pinpals catalogue entry remains independent of this pack.

## Build

```sh
python scripts/package-love-party.py --output dist/party --love /path/to/love
```

Produces five deterministic `.love` files, checksums, a collection ZIP and
an optional `shelf.json` with absolute local paths. Merge those shelf entries
with your lobby entry when configuring `GAMENIGHT_LIBRARY`. The build never
changes the Windows installer's contents or assumes an unpublished download URL.

For a release, pass `--base-url https://your-host/immutable-release` to also
generate Windows catalogue entries. Publish the `.love` files at that URL,
then add the generated entries to the starter catalogue. The shared LÖVE
runtime is reused, not included five times.

## Develop and test

Pure simulation lives in `games/`; `shared/` owns rendering, devices and the
GameNight lifecycle. Copy a game module to add another game, then register it
in `main.lua` and the packaging script. Keep simulation free of LÖVE APIs.

```sh
GNLOVE_HEADLESS=1 GNLOVE_TEST=1 love games/love-party
GNLOVE_DEMO=1 GNLOVE_GAME=bumper-royale love games/love-party
```

`GNLOVE_MATCH_SECONDS` and `GNLOVE_SEED` support reproducible tests. Native
Windows CI runs simulation tests and GameNight certification for every archive.
Physical controller/focus testing is still needed before calling these stable.

Transport/window helpers derive from Polle Pas's MIT-licensed Pinpals
GameNight integration. Its license is retained in `vendor/PINPALS-LICENSE`.
`vendor/json.lua` is rxi's MIT JSON library and retains its license header.
All other game code and geometric artwork are original GameNight contributions.

## Blast Party

A Bomberman-inspired arena game with original artwork. Each round generates a
new symmetric 19×11 arena, with destroyable crates and safe spawn exits. Fixed
walls never divide the arena into inaccessible regions. Some pillars are absent,
creating different lanes and open spaces. Five visible prizes invite an early
scramble; further power-ups drop from crates.

- **Remote (R):** new bombs wait for B rather than a timer. B detonates all your
  remote bombs. Enemy explosions can still set them off. If their owner is
  eliminated, they arm a normal fuse.
- **Kick (K):** walk into a bomb to kick it. It slides until it hits terrain,
  another bomb or a player, preserving its owner and remaining fuse.
- **Diagonal (X):** four diagonal rays instead of the ordinary cross.
- **Beam (I):** two long rays along the direction you faced when placing it.
- **Star (*):** eight rays, cardinal and diagonal.
- **Range (+), capacity (2), speed (S):** increase blast reach, simultaneous
  bombs or movement speed, with caps. Cross (C) restores the classic shape.

Upgrades apply to newly placed bombs. Bomb markings show the explosion shape;
cyan antennas mark remote bombs. Bomb shapes, boots and remote antennas show your equipped powers.
Walls stop every ray. Crates absorb a ray and reveal loot; other bombs chain.
Flames are briefly dangerous, so wait for the fire to clear before grabbing loot.

Normal fuses last 2.3 seconds. Placement and detonation trigger once per press.
The last survivor earns +3, knocking someone out gives +1, elimination costs -1.
Everyone returns for the next arena after a short pause; upgrades reset and
scores persist until the match ends. Shared match ties remain shared victories.

Keyboard secondary buttons: P1 Left Shift, P2 Right Shift, P3 O, P4 Y.
Use the normal action keys for placement (Space, Right Ctrl, U, R).
There is no friendly-fire immunity; your own explosions are dangerous too.

The tests cover 120 seeded arenas, blast shapes, walls/crates, chain reactions,
remote ownership, kicking, press edges, upgrades and round resets. Bot soak tests
exercise all four games with 2, 3 and 4 players.

## Neon Siege

A fast geometric co-op arena shooter for 2–4 local players. Weapons fire
continuously. Aim with the right stick; releasing it auto-targets the nearest
active enemy, so shared keyboard players can focus on moving and dodging.
A/action dashes through danger with brief immunity (1.2-second cooldown).
B/secondary clears nearby enemies and bullets (10-second cooldown).

Chasers rush, weavers weave, splitters break into three shards, and forts shoot.
New waves arrive every ten seconds; spawn rates increase with time and team size.
Kills build a shared multiplier up to x5; damage or a 2.5-second gap resets it.
Pickups grant spread, piercing or rapid fire for nine seconds, or repair one HP.

Each player has three HP. Stay close to a fallen teammate for 1.2 seconds to
revive them; they also return after six seconds if someone remains alive.
An entire team down for two seconds ends the match. Everyone shares the score.
Player bullets never hurt teammates. Shapes, particles and synthesized sounds
are generated in code; there are no external art assets.

Simulation tests cover swept bullet collisions, piercing, immunity, revives,
team wipes, pulse cooldowns, splitters, pickups, aim deadzones and entity caps.
A 270-second bot simulation exercises two, three and four players, with a
220-enemy ceiling and bounded projectile/particle counts. Performance timing is
reported for diagnosis, without a machine-dependent CI threshold.

## Presentation

During play, games show a compact player/score/timer row and the arena. Titles,
taglines, control bars and power-up legends stay off the playfield. The standalone
selection screen shows the selected game's controls; full keyboard bindings and
power-up details are documented above. Arenas enlarge without changing simulation
coordinates or stretching their shapes. Neon Siege keeps a small shared combo
score below the arena and health indicators beside players.
