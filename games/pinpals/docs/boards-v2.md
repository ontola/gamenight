# Boards v2 — bigger, more traditional, actually reachable

**Status:** plan, not built · 2026-09-06 · companion to `design.md` §7

---

## 1. The diagnosis, measured

The brief was "the boards need to be bigger and have more features, with two
slingshots and two side lanes, and the ramp is way too close to the flippers".
Running `probe_reach` first turns three of those into one root cause.

Foundry, 50 swept flipper shots — the reachable map:

```
       0   0   1   2     (x00 px)
 168         =*             the ramp channel, and
 240         #*             nothing else above y=280
 336   -- =  %+
 432  .:.=-::.##
 552 +*-:.-+***+-::+.       everything else lives
 648   #@%%****%@@@@*       in the bottom 150px
```

    pass 54%   drain 44%   left orbit 14%   right orbit 0%

Board B is the same shape: pass 66%, left orbit 6%, right orbit 10%.

**The upper playfield is not sparse, it is unreachable.** The pass ramp is a
106px-wide channel running from y=540 to y=150 through the dead centre of a
384px board — a wall across the middle with 39px of playfield either side of
it. A ball leaving a flipper at a realistic angle travels 70–100px sideways
before it reaches y=540, so it cannot get past the channel. That is *also* why
the ramp feels too close to the flippers (mouth 148px above the pivots) and why
adding features to the current boards would be adding things nothing can hit.

Board A's own comments already record this being fought at the wrong end: the
mouth was raised 600 → 540 to buy 14%/10% orbit reach, and the note admits the
trade is monotonic — every pixel of reach is bought with pass rate. It is
monotonic because the *width* of the obstruction was never the variable.

So the three complaints have one fix: **stop putting a 106×390px wall down the
middle of the board, and use the space that frees up.**

## 2. What v2 is

| | now | v2 |
|---|---|---|
| Playfield | 384 × 768 | **448 × 960** |
| Ball as % of width | 4.5% | 3.9% (a real table is 5.2%) |
| Mouth above pivots | 148px | **≥ 275px** |
| Bottom furniture | flippers, one centre drain | **outlane / divider / inlane / slingshot, both sides** |
| Drain paths | 1 | **3** (centre + two outlanes) |
| Element kinds | walls, bumpers, standups | + slingshots, rollovers, drop targets, spinner |
| Pass shot | identical centre channel on both boards | **different in kind per board** |

The ball, gravity, flipper length and every tuned threshold stay put. Growing
the board and not the ball is the whole point: it is what buys room, and it is
also the one thing here that changes feel globally, so §7 isolates it.

Honest trade recorded up front: at 448 wide the ball is *relatively smaller
than on a real table*, and at 960 tall it spends longer crossing the board
under unchanged gravity. Expect ball life up and points/s down before any
retuning. If it reads as floaty the knob is gravity, not ball radius — radius
is baked into a dozen measured thresholds.

## 3. The traditional bottom

Every real table spends its bottom 25% on the same five things, and we have
none of them. Budget per side at 448 wide (153px from wall to flipper pivot,
which is 34% of the width — the same fraction a Williams playfield uses):

```
  x=14 ── outer wall
  14..40    outlane        26px, 1.5 ball widths
  40..48    lane divider   8px
  48..76    inlane         28px
  76..150   slingshot      74px triangle, kick face on the hypotenuse
  x=167 ── left flipper pivot
```

Vertically: rollover buttons at the lane tops (y≈700), slingshots y≈786..848,
pivots y=858, drain_y=935.

**Slingshots** are the one place this design has to argue with itself.
`design.md` §6.1 forbids impulses — but that rule is about *operator* actions,
and a slingshot is table furniture, not something a player fires. It is built
the way bumpers already are: a static fixture with restitution > 1, no new
machinery, and the same "no debounce needed" measurement applies.

**Outlanes are the interesting half.** They give the board a second way to lose
the ball, and that fixes a real defect: today the post guards the *only* drain,
so a raised post stops 100% of drains and the geometry note in `board_a.lua`
worries — correctly — that a guard which costs nothing gets held up forever.
With outlanes the operator can no longer seal the board. It also sharpens §8:
a ball down an outlane is unrescuable, so the rescue stops being a universal
undo. Both effects are large and both must be measured, not assumed.

## 4. New element kinds

Each is data (`§5.3`), validated in `core/validate.lua`, geometry-checked in
`core/geometry.lua`, built in `sim/board.lua`, drawn in `app/render.lua`.

- **`slingshots`** — three points; the named face gets restitution ~1.35 and
  reports a `sling` event. Geometry check: not inside a flipper's swept arc,
  and no sub-ball-width throat against the inlane wall.
- **`rollovers`** — sensor circles in a group (`lane = "abc"`). Lighting the
  whole group awards and resets, reusing the bank rule shape. This is what
  gives an inlane a reason to exist.
- **drop targets** — `targets` gain `drop = true`. A struck drop target goes
  down (fixture → sensor) and stays down until its bank completes, then all
  reset. Clearing a bank therefore *physically opens the shot behind it*,
  which is the cheapest good mechanic in pinball and needs one boolean in the
  step loop.
- **`spinners`** — a sensor lane that awards proportional to crossing speed,
  with a blade the renderer spins. Phase 5.

Deliberately **not** built: scoops/saucers (hold-and-eject needs a state
machine and flirts with "nobody waits"), captive balls, magnets.

## 5. The two boards

The upper field is where `design.md` §7's remaining open item lives: *"the two
boards differ in what they are for, but not yet in how they are played."* v2
answers it by making the pass shot itself a different shape on each board.

### Foundry — the pass is an orbit, and the gate is a diverter

- Full **left and right orbits** running up the sides and over the top, with
  the right orbit's exit feeding the tube mouth.
- The **gate becomes a diverter** at the top of the orbit: open, the orbit
  dumps into the tube (the pass); closed, the orbit carries on round and
  returns down the habitrail into the inlane. §6.2's stated trade — "opens the
  pass, closes the safe return loop" — becomes literally true instead of
  approximately true, and it is the most traditional device on any real table.
- A **bumper pod**: four bumpers in a pocketed nest in the upper left, entered
  through a mouth, rather than three naked circles beside a lane. Foundry's
  declared chaos should come from a place you shoot *into*.
- Two centre standups so the middle of the board is not empty once the channel
  is gone.

### Glasshouse — the pass is a short centre ramp

- A **36–40px** ramp, entrance at y≈600, tube at y≈300: 300px of channel
  instead of 390px of channel that is also 106px wide. It stops being a wall.
- A **three-target drop bank** across the right orbit's entrance: clear it and
  the orbit opens. Precision board, precision reward, and the reveal is
  physical.
- A **spinner** in the left orbit — the classic "fast ball pays more", which is
  the one scoring line that rewards Glasshouse's flatter, faster geometry.
- Still no bumpers.

## 6. What this makes stale

Every measured table in `board_a.lua`, `board_b.lua`, `design.md` §7 and
`prototype.md` §5 is a measurement of the geometry being replaced. The mouth-
height sweeps, the post's 711/713/715 cliff, the bumper x/r sweep, the board
identity table, the pass rates, ball life, points/s — **none of it carries
over.** They get deleted and re-measured, not edited. Writing a number forward
because it used to be true is exactly the failure `CLAUDE.md` lists fourth.

`core/validate.lua` also needs relaxing in one place: it hard-requires exactly
two devices, one gate and one paddle. Phase 5 may want a third.

## 7. Phases

Each phase ends green on `make check`, with a screenshot **looked at**, and
every probe number averaged over ≥6 seeds.

**0 — room. DONE.** The render layout derives from the real window size and the
window takes what the display can spare. Boards are 448×960.

> **The phase as planned was incoherent and the build said so.** "Resize the
> boards, measure the resize alone" assumes there is a neutral place to put the
> new room. There is not. Putting all 192px at the top lengthened the orbit
> climb and made Foundry's bumper 1 and Glasshouse's entire bank unreachable —
> caught by the existing reachability tests, not by anything static. The room
> has to go where the complaint is, between the flippers and the ramp, and
> that is a design change, not a resize. Phases 0, 2 and 3 landed as one edit
> for the same reason.

**1 — element kinds. PART DONE.** Slingshots exist end to end: validated,
geometry-checked, built, scored, drawn and sounded. `core/geometry.lua` now
checks targets and slingshots through one `solids_of` list, so the next solid
kind is checked by construction rather than by remembering.
*Not done:* rollovers, drop targets.

**2 — the traditional bottom. DONE.** Outlane, divider, inlane and slingshot
down each side of both boards.

**3 — break the centre wall. DONE.** Both channels end at y=380 instead of
running to y=150. This was the phase the plan was for, and its gate is met
comfortably: ≥25% of swept shots reaching above the ramp was the bar, and both
boards now put 30–40% up *each* orbit.

**4 — upper playfield. PART DONE.** Foundry's bumper nest and Glasshouse's bank
are re-placed and every element is struck in play. But the boards are still
visibly empty — the whole right half of Foundry above y=560, and the band
between the ramp mouth and the slingshots on both. **This is the next work.**

**5 — spinner, shooter lane, third device.** Not started.

**6 — rebalance and rewrite. DONE for what exists.** Every measured table in
the board files and `design.md` §7 was re-measured, not carried forward.

### What placing content actually taught us

Four upper-field placements were authored and measured dead before the ones
that shipped. The rule they were all breaking is specific to a top-down board:
**the ball arrives on a mostly vertical path, so anything sitting under
anything else is in its shadow.** A real bumper nest stays live because the
ball enters it at every angle; ours does not produce those angles up there. So
content is spread across a band, never stacked, and `tests/probe_where.lua`
now answers "where does a falling ball actually cross this line" before
anything is placed rather than after it measures zero.

## 8. The risks worth naming

1. **Three drain paths may make both boards far too drainy. THIS HAPPENED.**
   Glasshouse went from 0.0777 drains/s to 0.1533 and its mean ball life from
   9.86s to 5.76s; Foundry from 0.0725 to 0.0793 and 12.19s to 9.46s. The
   *relationship* is better than ever — Glasshouse used to drain only 7%
   faster than Foundry despite a 16px wider gap, and now drains 93% faster, so
   the identity is a fact rather than a claim. Whether 5.76s a ball is too
   short is the open question, and outlane width is the knob. **Tune this
   before adding anything else.**
2. **The rescue gets rarer and the post gets weaker.** That is intended, but
   §8's 1.9s window was tuned against a post that stopped everything. Expect to
   retune it, and check the rescue does not become a mechanic nobody sees.
3. **A bigger board under unchanged gravity plays slower.** Phase 0 measures
   this alone precisely so it is not confounded with phases 2–4.
4. **The orbit-as-pass on Foundry could be much harder than a centre channel.**
   If the pass rate collapses below ~35% the boards stop being able to hand the
   ball back and forth, and the game has no rally. `probe_reach` in phase 3 is
   the early warning.
5. **Scope.** Phases 0–4 are the brief. 5 is not.
