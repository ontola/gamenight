# Game playbook

How to go from an idea to a game in the GameNight store quickly. It is written
for AI coding agents as much as for people: every step can run headless, from
the command line, without someone watching the screen.

## Start from the template

```sh
git clone https://github.com/ontola/gamenight
python3 gamenight/scripts/new-godot-game.py my-game my-game "My Game"
cd my-game && git init && git add -A && git commit -m "Start My Game"
```

You get a small, working Godot 4 couch game with:

| Part | What it does |
| --- | --- |
| `main.gd` | the game: GameNight lifecycle, seats, bots, dev flags |
| `gamenight.json` | the store and catalog entry: title, tagline, players, tags |
| `tests/lifecycle.py` | a fake GameNight host drives prepare, start, controller input, pause, resume, dispose |
| `tools/capture_preview.sh`, `tools/encode_preview.py` | the five-second store clip, frame by frame |
| `.github/workflows/ci.yml` | tests, Windows export, release, store page |
| `AGENTS.md` | the commands and rules for whoever works on it next |

The GameNight addon is installed from the SDK. CI fails when your copy falls
behind; run `python3 gamenight/sdk/godot/sync.py my-game` to update it.
Keep one repository per game.

Replace the orb game with yours one step at a time, and keep the tests green
after every step. Other engines work too (see [Engine support](/docs/engines)),
but only the Godot template exists so far.

## The loop

Run all three after every change:

```sh
godot --headless --import                                         # parse errors
godot --headless --fixed-fps 60 --path . -- --sim 4000 --seed 1   # bots play a round
python3 tests/lifecycle.py --godot godot                          # GameNight host
```

- **Import first.** A GDScript parse error makes later headless runs hang
  instead of failing. Look for `SCRIPT ERROR` or `Parse Error`.
- **Bots play the real game.** The sim counts what happened (dashes, pickups,
  rounds) and fails when something never did. Add a counter for every mechanic
  you build, so a broken mechanic fails CI.
- **The fake host checks what players notice.** Extend `tests/lifecycle.py`
  for each control: send controller frames, wait for the trace line.

Put rules that need many cases (damage tables, combinations) in plain
scripts and test them with `godot --headless --script`.

## Make it deterministic from day one

Seed the global RNG once from `--seed` and move the simulation only in
`_physics_process`. With `--fixed-fps`, the same seed then replays the same
run: the template's sim prints a state hash, and its store clip comes out
bit for bit the same. A second unseeded `RandomNumberGenerator`, or gameplay
that reads the clock, breaks this quietly. Retrofitting it into a big game is
much harder than starting with it.

## See the game without a person

Build flags for everything you would otherwise set up by hand:

- `--shot out.png --frames 90`: bots play and frame 90 is saved. Render
  under `xvfb-run` for a real GPU path.
- `--players N`, `--seed N`, and as the game grows: where to start (a level,
  metres along a path), what to spawn round the players, a closer camera.
- `GAME_TRACE=1` prints what happens, for tests and for debugging.

Look at the screenshots yourself after visual changes. Text over characters
and HUD clutter read badly on a TV; let shapes and colour carry the state.

## Couch rules that matter

- Controllers follow seats. Read `GameNight.frame_for_seat(seat)`, never
  joystick indices, when GameNight launched the game.
- Bots fill seats. The host can seat AI players; the same bots power your
  sim and your store clip.
- Prepare loads everything while hidden, then `notify_ready`. Start shows it.
  Pause freezes play, timers and audio. Finishing a round calls
  `notify_finished` and starts the next one: players leave with Back.
- See [Game lifecycle](/docs/lifecycle), [Controllers & players](/docs/controllers)
  and [Faces & colours](/docs/faces).

## The store clip

The store needs a five-second clip of real gameplay. Read the
[gameplay preview guide](https://github.com/ontola/gamenight/blob/main/docs/gameplay-previews.md):
quick, varied, readable cuts.

```sh
GODOT=godot tools/capture_preview.sh /tmp/takes
python3 tools/encode_preview.py /tmp/takes assets/gamenight
```

Each take is the real game with bots, rendered with `--write-movie` at a
fixed 30 FPS, so it is slow to record but exact. The cut list in
`encode_preview.py` is the whole edit, and encoding is bit-exact. Write down
the seeds and commit next to the clip, so anyone can make it again.

Add `cover.png` (portrait 360x480), `icon.png` (128x128) and `gameplay.png`
(16:9) to `assets/gamenight/`.

## Release and store page

1. [Register the game](/developers) in the developer portal and create a
   publish key. Save it as the `GAMENIGHT_API_TOKEN` secret of the repository.
2. Run the CI workflow by hand with `release` set to `v0.1.0`. It tests,
   exports Windows, publishes the GitHub release and fills the store page.
3. Or fill the store page from your machine:

```sh
GAMENIGHT_API_TOKEN=gn_pub_... python3 gamenight-publish.py store
```

It reads `gamenight.json` and uploads what is in `assets/gamenight/`. See
[Publish a game](/docs/publishing) for builds, channels and review.

## Pitfalls we hit

- Headless Godot hangs on a parse error; untyped values from arrays and
  dictionaries are the usual cause. Give them a type (`var c: Vector3 = ...`).
- Agents often cannot push git tags. Release with the workflow input instead.
- Never run a downloaded script with your publish key in CI. Check out a
  pinned copy of `ontola/gamenight` and run its `scripts/gamenight-publish.py`.
- The first frames of a `--write-movie` take can show the engine warming up.
  Start cuts at frame 20 or later.
- A big level needs the camera close enough to read on a phone; check the clip
  at phone size.
