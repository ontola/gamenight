# GameNight LÖVE Party Pack

Three original local multiplayer prototypes for 2–4 people. MIT licensed.
No assets or accounts to download, no internet connection during play.
Requires LÖVE 11.5; GameNight downloads this shared runtime separately.

| Game | Goal | Controls |
| --- | --- | --- |
| Bumper Royale | Knock friends out of a shrinking ring; +3 knockout, -1 fall | Move, A to dash |
| Neon Trails | Survive the trails; last rider earns +3, then everyone respawns | Turn; no reversing |
| Meteor Dash | Collect stars (+5), avoid hits (-10), survive (+1/second) | Move, A for shield dash |

Matches last 60 seconds. Ties share victory. Every game supports 2, 3 or 4
players, bots for automated testing, and consistent seat colours (using GameNight player colours when supplied).
Scores are displayed by the game; protocol v1 reports match completion but
has no cross-game score submission message.

## Play

Run `love games/love-party` from the repository. Choose a game with 1/2/3 or
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

Produces three deterministic `.love` files, checksums, a collection ZIP and
an optional `shelf.json` with absolute local paths. Merge those shelf entries
with your lobby entry when configuring `GAMENIGHT_LIBRARY`. The build never
changes the Windows installer's contents or assumes an unpublished download URL.

For a release, pass `--base-url https://your-host/immutable-release` to also
generate Windows catalogue entries. Publish the `.love` files at that URL,
then add the generated entries to the starter catalogue. The shared LÖVE
runtime is reused, not included three times.

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
