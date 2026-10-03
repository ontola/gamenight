<p align="center"><img src="site/icon.png" width="96" alt="GameNight"></p>
<h1 align="center">Get to the next game.</h1>
<p align="center">Open-source couch multiplayer. Less setup between games.</p>

GameNight lets you play a whole evening of couch games from your controller.
Pick a game. Play a round. Try something else.

The next game loads in the background while you play. Back/Select returns to
the lobby; press it again to resume. Your controllers stay assigned to the same
players across integrated games.

[Download for Windows](https://gamenight.ontola.io/download/GameNight-Setup.exe) ·
[Download for Mac](https://gamenight.ontola.io/download/GameNight.dmg) ·
[Browse games](https://gamenight.ontola.io/catalog) ·
[Developer docs](https://gamenight.ontola.io/docs)

## Play

Install GameNight for Windows or macOS and connect your controllers. Join the lobby,
walk to a game and press Y to play. The lobby shows download and loading
progress. Downloaded games are cached for later sessions.

Scan the lobby QR code to open the character editor on your phone. Draw a face
and change the playlist. Games can use your profile too; the catalog lists
which parts of the integration have been checked.

This is an early preview. Game support varies, and controller, audio and window
behaviour still need testing across machines. See the
[Windows preview guide](docs/windows-preview.md) or
[Mac distribution notes](docs/macos-distribution.md) for installation details.

The catalog's Play button remembers your chosen game for first launch.
See [catalog onboarding](docs/catalog-onboarding.md) for the browser handoff and its limits.

## Your player comes with you

Draw a face on your phone, choose your colours and pick up your player with a
controller. Integrated games can reuse your name, skin colour and artwork.
Remember a player on a desktop to have them waiting at the door next time.

The face API places a circular head by centre and radius:

```lua
local Face = require("shared.face")
Face.drawFace(player, x, y, radius)
```

Hats keep their space around the head. See [player faces](docs/faces.md) for the
shared coordinates, mirroring and Rust API. The catalog checks face rendering
separately from colours and includes both in its integration score. Unknown or
older-build evidence is not treated as verification of the current download.

## Open protocol. Open source.

The local runtime works without an account or cloud service. You can run it,
change it and add your own games.

GameNight runs each game as a separate process. The host tells it when to
prepare, start, pause, resume and release a session. The game owns its rules,
score screen and subsequent rounds. Players choose when to switch games.

Use the [Rust SDK](crates/gamenight-sdk), [Godot SDK](sdk/godot),
[C/C++ SDK](sdk/c), or implement the [JSON protocol](docs/protocol.md) directly.
The [JavaScript example](examples/tiny-game.mjs) is a small reference.

Start with the [integration guide](docs/integrating-your-game.md).
Automated checks cover the game lifecycle; test controller input, sound and
window focus on each platform you ship. Profile colours and drawn faces are
separate capabilities.

## Build from source

Install stable Rust and Python 3. Windows builds need Visual Studio C++ Build
Tools. See [development setup](docs/development.md) for Linux dependencies.

```sh
python scripts/run-local.py --studio --shelf /path/to/games.json
```

The shelf lists your games and their launch commands. GameNight adds the lobby.
Without a shelf, the script uses a terminal SDK demo for testing the protocol.

Game sources live outside this repository. Both GameNight lobbies stay here:
[the Godot lobby](sdk/godot/lobby) and [the Rust lobby](crates/lobby).
The SDKs, catalog and integration checks also belong here.

The [shared LÖVE package](https://github.com/ontola/gamenight-games/tree/main/love-party) contains eight games:
Neon Trails, Blast Party, Neon Siege, Ricochet Club, Volley Trouble,
Stack Together, Bubble Buddies and Pinpals.

[SpaceRacer](https://github.com/joepio/spaceracer) is a standalone Godot 3D hover
racer with three procedural worlds, flight, weapons and 1–4 player split-screen.
Its source, tests and release workflow live in `joepio/spaceracer`.
The [catalog entry](catalog/games/spaceracer.json) pins a Windows ZIP and its SHA-256 checksum
from [GitHub Releases](https://github.com/joepio/spaceracer/releases).
The GameNight protocol ID is `spaceracer`, including for local debug builds.

```sh
python scripts/fetch-game-sources.py
python scripts/package-love-party.py --output dist/party
```

`game-sources.json` pins the game-source revision used by CI and release builds.
The fetch command creates a sibling `gamenight-games` checkout and refuses to
overwrite local changes. For game development, set `GAMENIGHT_GAMES_DIR` to your
working checkout. Commit and push game changes before updating the pin.

The host prepares games in the background. Each game handles its own rounds
and score screen. Use Back/Select to return to the lobby when you want to switch.
On Windows, the current controller backend supports up to four Xbox/XInput
controllers. Other controllers need an XInput-compatible mode or adapter.

For quick changes to the lobby, use the [development loop](docs/development-loop.md).
It separates restarting, building and packaging, and serves web files directly
while you work.

## Contribute

Add a game, improve an integration or report a bug we can reproduce.
[CONTRIBUTING.md](CONTRIBUTING.md) covers setup and checks.

## License

GameNight's original code is MIT-licensed. See [LICENSE](LICENSE).
The lobby and vendored dependencies retain their upstream notices.
[THIRD_PARTY.md](THIRD_PARTY.md) lists source revisions and asset credits.

Preview installers are published automatically after CI and packaging checks pass.
See [automatic releases](docs/automatic-releases.md) for the checks and limitations.
