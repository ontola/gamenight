# Gameplay iteration — 2026-09-08

The boards now offer a repeatable co-op objective alongside the existing vault:
fill eight charge inserts, ask the operator to open the gate, and shoot the pass
for a relay jackpot. Bumpers, newly lit targets and newly lit rollover lanes each
add one charge; completed banks and full skyway rides add three. Charge survives
a drain so a short ball still advances something. Collecting the jackpot resets
charge, and successive collections on that board raise the base award from 2,500
to 12,500 in five steps. Relay heat multiplies all awards.

Three flush rollover switches on each board give the outside orbits and centre
return a purpose without narrowing the shots. Each crossing pays 75, each newly
lit lane adds charge, and lighting all three pays another 500 and resets the set.
Repeat contacts have a half-second debounce. The switches only see playfield
balls, so passing above one on the skyway cannot collect it.

Foundry has a two-target Forge bank at (151,340) and (313,340). Glasshouse keeps
its Vault and Gallery banks. Its right Vault target moves to (352,340), clear of
the ramp entrance; the outer Gallery target moves to (398,590), tilted inward.
The tilt matters: a flat target at (404,530) passed the short gate but stalled in
two of eight longer seeded matches. The final placement stalled in none.

Both skyways end at y=460 instead of 570. This shortens the climb and opens the
middle playfield. A complete ride pays 750 and lights a 12-second pass combo
worth another 1,500. Only exiting the opposite mouth counts: mounting, rolling
back or falling off the side awards nothing. The combo clock runs during active
play, and a drain cancels it. Ramps are translucent enough to see targets below.

The HUD and playfield show charge, lane lights, target bank names, skyway mouths,
jackpot instructions and combo time. Scoring shots have audio feedback, and a
jackpot announcement survives the camera handoff.

## Measurements

These are automated shot and random-play measurements, not a claim that human
players have rated the result as fun. Existing historical commentary in the board
files describes earlier layouts and should not be used as current balance data.

- `PINPALS_SUITE=tests.probe_skyway love . --test`: 140 seeded flipper shots per
  board. Baseline: zero entries on either board. Final: Foundry 19 complete rides,
  Glasshouse 9; every entry completed, none stalled. Optional
  `PINPALS_RAMP_FOOT_Y` sweeps mouth height without changing board files.
- `PINPALS_SUITE=tests.probe_fun love . --test`: eight 180-second matches, seeds
  8277, 9254, 10231, 11208, 12185, 13162, 14139, 15116. Final: 55 passes,
  21 complete rides, 36 jackpots, 38 bank clears, zero stalled seeds.
  Foundry target hits: 32/19; Glasshouse: 20/28/17/63. All six rollover switches
  were used (Foundry 67/75/163, Glasshouse 63/54/113).
- `PINPALS_SUITE=tests.probe_soak love . --test`: ten minutes, 144,000 ticks,
  all invariants held; longest slow spell 0.76 seconds.
- `PINPALS_SUITE=tests.probe_identity love . --test`: five seeds, twelve balls
  each. Foundry mean ball life 9.92s (baseline 9.19s), drains/s 0.0622 (0.0780),
  pass survival 37% (28%). Glasshouse 7.88s (7.61s), drains/s 0.1015 (0.1182),
  pass survival 20% (7%). This older probe omits the new lane/ramp/jackpot points;
  its points/s is not total game scoring. Forge clears remain relatively rare
  in this isolated-board harness; whole-match play completed the bank nine times.

`make check` covers rule tests, rollover physics, full-ramp completion reporting,
existing physics/soak tests, lint, types, layers and geometry. Both boards were
rendered and visually inspected. Relaunch the game to load the changed rule and
render modules; board hot reload alone only reloads board data.
