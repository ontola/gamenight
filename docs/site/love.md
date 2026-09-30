# LÖVE / Lua

Use the shared runner in `games/love-party`. It handles the GameNight connection, hidden preparation, pause/resume, window switching and host controller input. The bundled games use this path.

## Run the reference game

Install LÖVE 11.5, clone the repository and run from its root:

```sh
love games/love-party
```

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
GNLOVE_HEADLESS=1 GNLOVE_TEST=1 love games/love-party
python scripts/package-love-party.py --output dist/my-party-build
```

The output directory must be new. Packaging builds the registered titles; it does not automatically publish them. Run the [integration suite](/docs/testing) against the resulting packages, then check real controllers and window switching on each target OS.
