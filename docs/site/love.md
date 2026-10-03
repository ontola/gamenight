# LÖVE / Lua

Use the [shared runner](https://github.com/ontola/gamenight-games/tree/main/love-party) in the separate `ontola/gamenight-games` repository. It handles the GameNight connection, hidden preparation, pause/resume, window switching and host controller input. The bundled games use this path.

## Run the reference game

Install LÖVE 11.5, clone the repository and run from its root:

```sh
python scripts/fetch-game-sources.py
love ../gamenight-games/love-party
```

The fetch command checks out the revision in `game-sources.json` beside the host repository. For local edits, set `GAMENIGHT_GAMES_DIR` to your game checkout before testing or packaging.

This starts the standalone menu. The host supplies `GAMENIGHT=1`, its address, game ID and launch token when launching a managed build. Do not set a made-up token yourself.

## Add your game module

Keep simulation in a game module and leave lifecycle handling in the runner. A module defines `new(players, rng)` and `update(state, dt, inputs)`. This is the beginning of the real Neon Trails module:

::: source lua games/love-party/games/trails.lua "function M.new(players, rng)" "\ts.clock = s.clock + dt"

The input entries belong to the supplied player slots. Do not replace them with `love.joystick.getJoysticks()` in managed mode. The shared input adapter neutralises disconnected devices and frames older than 250 ms.

Register a new module in `modes` in [main.lua](../../games/love-party/main.lua), add its renderer and add its ID to `GAMES` in [the packaging script](../../scripts/package-love-party.py). These are explicit registries, not automatic plugin discovery. Use an existing game as the full worked example.

## Draw a player face

```lua
local Face = require("shared.face")
Face.drawFace(player, x, y, 24, { facing = -1 })
```

`x` and `y` are the centre of the head. The helper draws the skin circle before the transparent artwork, retains space for hats and handles live artwork changes. See [Faces & colours](/docs/faces).

## Keep the shared window path

Use `shared.window` and `shared.back_gate`. Prepare before showing the window. Back needs a fresh press after release, and a focus event must never resume a paused game. Keep borderless fullscreen and the helper’s Windows presentation workaround.

## Package and test

```sh
python scripts/test-love-simulation.py
python scripts/package-love-party.py --output dist/my-party-build
```

The output directory must be new. Packaging builds the registered titles; it does not automatically publish them. Run the [integration suite](/docs/testing) against the resulting packages, then check real controllers and window switching on each target OS.

## Optional performance diagnostics

The bundled launcher samples application frame intervals while running and reports them every ten active seconds. It includes GPU, OS and pixel dimensions; CPU and RAM are unavailable. Standalone games send nothing. See the [protocol reference](../protocol.md#session-diagnostics) for counters, limits and missing-data semantics. These diagnostics contain no accounts, behavioral history or recommendation logic.

## Game settings

Use the [settings helper and game reference](/docs/settings) to expose choices, toggles and bounded numbers to the lobby and phone. Validate each change and snapshot round rules when creating a round.
