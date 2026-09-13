# Pinpals

A co-op pinball game.

## About this file

Keep this file short and concise.
Do not use this as a progress log.
Only add important information an agent should know to efficiently work on the project.

## Code quality

Make sure the code is well-organized.
Break down large functions into smaller contained functions.
Use descriptive variable and function names.
It's okay to take your time on good architecture.

Since this is a game, performance might take precedence over code quality in critical areas.

## Tooling

`love .` watches `data/tables/*.lua` and reloads the boards on save -- a board that
will not compile or will not validate leaves the running game alone and puts the
error on screen, so a typo mid-edit cannot end a playtest. `--no-hot` turns the
watcher off. In-game keys: `P` pause (freezes the simulation, not the camera or
the watcher), `1` debug readout, `2` the coordinate overlay (every number the data
file names, plus the cursor's own position; `TAB` swaps which board it reads, and
a click copies the coordinate under the cursor to the clipboard -- left as
`230, 85`, right as `x = 230, y = 85` -- snapped to a labelled point when one is
within reach),
`3` force a reload, `R` restart. The number row rather than function keys: on a
Mac every F-key is a chord with fn. `make coords BOARD=b` captures that overlay
to a PNG.

`make check` is the only gate that matters: layers, lint, types, static board geometry,
core tests, headless physics, and a 60s integration soak. ~6s. Run it before claiming
anything is done. `make run` plays; `make shot TICKS=N` renders a frame to a PNG —
**look at it**, several bugs this project has shipped were invisible to the gates and
obvious in the picture.

## Measuring

Board layouts are data (`data/tables/`), and every board bug so far has been a
coordinate whose consequences nobody had measured. `tests/probe_*.lua` are measurement
tools, not gates — run one with `PINPALS_SUITE=tests.probe_reach love . --test`:

| probe | answers |
|---|---|
| `reach` | where can a flipper shot actually go, and what do shots do |
| `serve` | what a serve does, what the jitter changes, and what it costs in play |
| `identity` | ball life, drain rate and points/s per board (§13.1) |
| `timing`, `approach`, `speed_window` | how hard is it to receive a pass, and why |
| `post`, `impulses`, `scoring` | device trade-offs, contact thresholds |
| `guard` | does the outlane guard save that lane, and what does the side cost |
| `where` | where a falling ball crosses a line, and what an arrival does |
| `ramp` | mouth height vs funnel width vs channel width, swept together |
| `skyway` | is the elevated ramp shootable, and does a shot that gets on finish |
| `soak`, `perf` | everything at once for 10 minutes; frame cost |
| `audio` | the synthesized kit is audible, unclipped and centred (`luajit tests/probe_audio.lua`) |

Six things this project has learned the hard way, all of which cost a wrong conclusion
first:

1. **Pinball is chaotic — average over seeds.** A single 180s run moved a bumper count
   by 60%. One run measures nothing.
2. **Harness details dominate.** Spawning a ball 15.9px above a flipper instead of
   10.6px erased a device's entire measured effect. Holding a flipper up for a whole
   trace invented a 10% stuck-ball rate that does not exist.
3. **Check the shape, not just the number.** Rates that are all multiples of 1/7 mean
   seven samples, not twenty-eight.
4. **Measure the thing you are about to assert.** Both board identities and the post's
   trade-off shipped documented backwards, because the claims were written and never
   checked.
5. **The ball falls straight down, so nothing may sit under anything else.** Four
   upper-field placements measured exactly zero hits before this was written down.
   Content goes in a band, never a stack; `probe_where` says where the band is.
   The one exception is a RAMP (`ramps` in the board data): it runs on its own
   Box2D collision layer, so the ball is either on it or under it and the space
   beneath it stays live. Everything else still obeys the rule.
6. **The plunger lane is a lane, and nothing may stand in it.** Glasshouse put a
   standup target directly above its plunger; the serve hit it 240 times out of
   240 and stopped 176px up, so 81% of that board's balls never reached the
   height of its own tube mouth. It survived review because the target's hit
   count looked healthy -- the hits were the plunger. `probe_serve` now splits
   target hits by whether they landed within a second of the serve, and a probe
   that leaves the flippers parked measures the serve rather than the game.

## Curves and ramps

Wall and ramp paths may carry curve nodes -- `{ round = r }` to fillet the corner
it follows, `{ to =, via = }` / `{ to =, c1 =, c2 = }` for Beziers, `{ arc = {...} }`
for a circular arc. `core/curve.lua` expands them into ordinary polylines at load
time, so sim/, the geometry gate and the renderer only ever see flat x,y lists;
the authored form survives on `path.spec`, which is what the coordinate overlay
labels. Adding a curve node to a board file is the only place any of this is
visible.

A ramp is a centreline, a width, a crown height and a slope at each end. The
slope is the STEEPEST gradient on that incline, and climbing costs
`C.RAMP_CLIMB_G` -- about 8.8x playfield gravity -- so a ramp needs a real shot.
`core/ramp.lua` computes the speed a mouth demands from the ramp's own energy
budget; a ramp that admits balls it cannot lift turns the lane it sits in into a
dead end, which is measured and documented at `C.RAMP_ENTER_SPEED`. Ramps are the
one thing allowed outside the playfield rectangle.

**A ramp foot is a solid object, and this is what makes placing one hard.** Near
its feet the lane is inches off the playfield, so a ball cannot pass under it:
`core/ramp.lua` generates a *skirt* there -- the rails, plus a slanted wall
closing the lane so a shot that did not commit is sent back out rather than
pocketed. That is a 54 x 71px block standing in whatever lane the foot is in,
and both boards are nearly full at the height a foot needs. Expect placing one
to be constrained from four directions at once; board_a.lua's `ramps` note walks
through what closed in on the numbers there.
