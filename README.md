<p align="center"><img src="site/icon.png" width="96" alt="GameNight"></p>
<h1 align="center">One party. Many games.</h1>
<p align="center">An open local multiplayer runtime for game developers.</p>

GameNight keeps your players together between games. A game prepares quietly
in the background, takes the screen when the party starts it, and gives the
screen back when paused. Players keep their seats, names and avatars.

**Early developer preview.** The local runtime works today. This repository
includes a playable lobby, Rust/C/Godot SDKs, and a conformance tool. It does
not require an account, subscription or cloud service. Online matchmaking and
cross-game controller identity are not finished features.

[Get started](#try-it-locally) · [Integrate a game](docs/integrating-your-game.md) ·
[Protocol](docs/protocol.md) · [Contribute](CONTRIBUTING.md)

## Windows preview

A native Windows preview includes the lobby and automatically downloads Pinpals
and its shared LÖVE runtime on first launch. Cached games work offline.
[Downloads](https://github.com/ontola/gamenight/releases) ·
[Preview instructions and source versions](docs/windows-preview.md).
For releases with a `Setup.exe`, run it once to install GameNight and receive
updates automatically after closing the lobby. The portable ZIP remains available;
extract it and run `GameNight.exe`. No development tools are needed.

## Try it locally

Install a current stable Rust toolchain and Python 3. On Windows, use the
native Windows Rust toolchain with Visual Studio C++ Build Tools. On Ubuntu,
install the build dependencies listed in [development setup](docs/development.md).

```sh
python scripts/run-local.py
```

This builds and opens the GameNight lobby. Press a controller button to join.
The included **SDK Demo** is a terminal simulation for testing transitions,
not a pinball or arcade game. Walk onto the lobby's Start button and jump to
start it. Back/Select opens the lobby again.

To test a graphical game, provide a shelf with its executable and working
directory; the launcher adds the lobby automatically:

```sh
python scripts/run-local.py --shelf /path/to/games.json
```

The optional local character studio is enabled with `--studio`. It serves QR
pairing and temporary avatars on your LAN, for trusted local networks only.
No store, payments, cloud accounts or ownership database are included.

## Build a GameNight game

A game implements a small lifecycle:

```text
prepare → ready → start → finished → dispose
                    ↕
               pause / resume
```

- Prepare without showing a window or playing audio.
- Bind players to the seats received from the host.
- Show the game on start; freeze and mute it on pause.
- Dispose session state so the process can prepare another match.
- Keep normal standalone play when `GAMENIGHT=1` is absent.

Start with the [integration guide](docs/integrating-your-game.md), then choose
[Rust](crates/gamenight-sdk), [Godot 4](sdk/godot), or [C/C++](sdk/c).
[The JavaScript example](examples/tiny-game.mjs) shows the wire protocol without
a framework. Other engines can speak the same JSON protocol directly.

## Test your integration

```sh
cargo build --workspace
cargo run -p gamenight-certify -- demo-game -- target/debug/demo-game 1
```

On Windows, the executable is `target/debug/demo-game.exe`. Substitute your
game ID and executable to check a real integration. Automated checks exercise
the lifecycle; also test controller input, sound and focus on your target OS.

## What's inside

| Component | Purpose |
|---|---|
| `gamenight-protocol` | JSON messages and the compatibility contract |
| `gamenight-core` | Parties, seats, sessions, playlists and voting |
| `gamenight-daemon` | Local process host and background preparation |
| `gamenight-sdk`, `sdk/` | Game-facing integration helpers |
| `gamenight-certify` | Automated conformance checks |
| `gamenight-catalog`, `gamenight-installer` | Metadata and verified downloads |
| `gamenight-local-web` | Optional LAN character editor and QR seat claims |
| `gamenight-mcp` | Local party controls for MCP clients |
| `crates/lobby` | Controller-driven reference lobby |

## Contributing

Small integrations and reproducible bug reports are welcome. You do not need
to adopt our engine or use our hosted services to contribute. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for builds, tests and the integration checklist.

## License and credits

GameNight's original code is MIT-licensed; see [LICENSE](LICENSE).
The lobby and vendored Bones retain their own upstream notices. See
[THIRD_PARTY.md](THIRD_PARTY.md) for source revisions, modifications and media credits.
