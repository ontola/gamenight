# GameNight

`love .` still starts the normal standalone game. When launched with
`GAMENIGHT=1`, Pinpals instead joins a GameNight party over newline-delimited
TCP using LuaSocket (included with LÖVE 11.5). No separate bridge process or
LuaRocks installation is needed. `gamenight.json` carries the game's catalog
metadata for distributions.

The daemon supplies `GAMENIGHT_ADDR` (`host:port`, default `127.0.0.1:7912`),
`GAMENIGHT_GAME_ID` (default `pinpals`), and `GAMENIGHT_TOKEN`. The token is
echoed in the initial `hello`, never printed.

- `prepare` creates both physics worlds, binds party seats, and sends `ready`.
  The window stays hidden (minimized if native SDL symbols are unavailable) and the simulation is frozen until `start`.
- `start` opens desktop fullscreen and begins play. `pause` stops audio, releases
  held controls, freezes simulation, and hides the window; `resume` restores play.
- `dispose` destroys both worlds and clears inputs. The same process accepts
  the next `prepare`, including mid-match skips and replay.
- A closed daemon connection exits the game. Focusing a prepared or paused
  game requests a start/resume from the daemon.

Seat 0 is P1 and seat 1 is P2, regardless of which board holds the ball.
Those seats use their corresponding gamepad slots, plus the usual disjoint
keyboard clusters. Empty and AI seats accept no input (there are no bots).
Missing controllers are never shared; the assigned seat retains its keyboard
fallback. Parties larger than two should rotate players through GameNight.
Player names appear beside their roles. Board geometry stays visible even
when a seat is empty: both boards are essential to the shared ball's path.

Pinpals is continuous co-op, so it does not send `finished` or invent a timed
match boundary. Use the party to pause, replay or skip. Standalone debug,
reload, restart and pause shortcuts are disabled while GameNight owns play.

From a GameNight checkout with this branch cloned at `crates/pinpals`:

```sh
GAMENIGHT_LIBRARY=examples/party-shelf.json cargo run -p gamenight-daemon
cargo run -p gamenight-certify -- pinpals --cycles 10 --match-timeout 1 \
  --timeout 45 -- love crates/pinpals
```

`make check` covers the protocol's partial TCP reads/writes, sparse seat and
controller binding, and ten lifecycle cycles with real physics. For a
headless protocol run, prefix the certification command with
`PINPALS_HEADLESS=1`. This does not replace testing screen focus, sound, and
physical controllers together on the target couch setup.

The JSON codec is vendored from [rxi/json.lua](https://github.com/rxi/json.lua)
(version 0.1.2); its MIT notice is preserved in `app/vendor/json.lua`.

## Verification (2026-09-08, LÖVE 11.5 on Linux/WSL)

- `make check`: lint/types/layers/geometry clean, 155 core and 61 physics tests passed.
- Graphical `gamenight-certify`: 7 passed, 3 optional checks skipped, exit 0;
  ten skips survived, 44 ms preparation and 293 ms average dispose-to-running.
  Skips: no direct binary download, no `finished` replay vote, no match settings.
- Instrumented graphical launch: window invisible in idle/ready/paused, visible
  in running; player-name screenshot inspected; socket closure exited with code 0.
- Native Windows: all checks pass with the physics suite running under Windows
  LÖVE; hidden prewarming, fullscreen presentation and hiding on pause were
  visually checked. A physical-controller couch run confirmed LB/RB input and
  focus handoff from the Windows GameNight lobby.
- Windows requires the foreground lobby to grant foreground permission when
  starting/resuming an already warm game (`AllowSetForegroundWindow`). That
  launcher-side change belongs to GameNight, not this repository.
- A simultaneous two-controller couch run and macOS focus behavior remain
  unverified.
