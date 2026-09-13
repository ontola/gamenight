# Boards v3 — empty the middle, fill the board

**Status:** plan, partly built · 2026-09-08 · companion to `boards-v2.md`, which this
supersedes on layout, and to `table-design.md`, which is the evidence behind it

---

## 1. The diagnosis

`make shot TICKS=1` says it faster than any table can:

- The **skyway owns the board**. An arch from y=190 to y=570 spanning x=94..347, on a
  448x960 playfield. Two of Foundry's three bumpers sit inside its own footprint.
- The **tube funnel owns the centre**. Channel walls, a roof, and a gate device from
  y=358 to y=560, dead centre, guarding a mouth at (236,398).
- **Everything below y=570 is bare.** Four hundred pixels — more than a third of the
  table — holding two slingshots and nothing else.

So "nothing is happening on these boards" is not a content shortage. It is two large
structures standing in the space content would occupy, and a third of the playfield
that was never given anything at all.

`table-design.md` §9 has the measurements. The four that drive this plan:

| | measured | should be |
|---|---|---|
| flipper pivot span, % of board width | 25.0% / 28.6% | 34.6% |
| skyway reached by a swept shot | 7.9% / 2.9% | "a good chance" (Sharpe 3) |
| Foundry bumper hits | 0.12/s | 0.6/s (its own doc) |
| inlane content | none | rollovers (`boards-v2.md` §4) |

## 2. What v3 is

| | v2 (as built) | v3 |
|---|---|---|
| Flipper bat | 48.6px, 2.81 balls | **64px, 3.70 balls** |
| Pivot span | 112 / 128px (25.0% / 28.6%) | **~139 / ~155px (31.0% / 34.5%)** |
| The pass | centre channel + roof + gate device | **the top of an orbit, always open** |
| Centre of board | pass funnel | **open field** |
| Skyway | centre arch, 918px of lane | **a side ramp, angled approach, feeds an inlane** |
| Orbits | incidental gaps beside the skyway feet | **real lanes with guides that feed a flipper** |
| Inlanes | bare geometry | **rollovers** |
| Element kinds | walls, slingshots, bumpers, targets | **+ rollovers, drop targets, spinner** |
| Operator devices | gate, post | **post + one new device** (§7, open) |

The ball, gravity and the board rectangle do not change. `constants.lua` and
`boards-v2.md` §2 both rule out touching the ball radius — a dozen measured thresholds
are baked to it — so where the ratios are wrong, the *furniture* moves.

## 3. Phase 0 — the flippers **BUILT 2026-09-08**

The flippers are exactly real-scale against the ball (2.81 diameters against 2.82) and
the board is 36% oversized against the same ball. Both are true, and the consequence is
that the flipper pair defends 25.0% of Foundry's width and 28.6% of Glasshouse's where
every real table since the 1940s defends 34.6%. The bottom of both boards is
proportionally under-defended, and the side furniture is correspondingly bloated: 9.14
ball widths per side against a real 6.24.

**The ceiling on the fix is a clean number.** Tip speed is `FLIPPER_SPEED × FLIPPER_LEN`
= 34 × 48.64 = 1654 px/s, against a `BALL_MAX_SPEED` of 2176. Past that ceiling the
clamp in `sim/` starts silently eating the flipper's energy and the device stops being
linear. So:

```
  FLIPPER_LEN <= BALL_MAX_SPEED / FLIPPER_SPEED = 2176 / 34 = 64.0 px
```

64px is therefore both the largest bat the current speed allows and, by coincidence
worth naming, close to what the proportions want. `probe_identity` defines the drain
gap as `span - 2·cos(FLIPPER_REST)·FLIPPER_LEN`, so holding each board's gap while the
bat grows fixes the span:

```
  board        gap    span now    span at L=64    coverage now -> then
  Foundry     27.6      112           138.7        25.0%  ->  31.0%
  Glasshouse  43.6      128           154.7        28.6%  ->  34.5%
```

Going all the way to 34.6% on Foundry needs L=73.4, which puts the tip at 2496 px/s and
over the ceiling. That is available at `FLIPPER_SPEED = 30` — recorded here as the
option it is, not taken, because flipper speed is a feel constant and this phase is
already a global feel change.

**What moves with them.** `core/geometry.lua` rejects anything inside a flipper's swept
arc, and reach is `FLIPPER_LEN + FLIPPER_THICK/2` — 53.8px now, **69.1px** at L=64.
Foundry's left slingshot corner (140,822) is 64.4px from its pivot, so it is *inside*
the new arc and the gate will say so. Both slingshots on both boards move, and so do
the inlane chain ends, which currently stop 9.9px outside pivots that are about to
travel 13px outward.

That coupling is the phase: one constant, four pivots, four slingshots, four chain ends.

**As built**, and it cost two things the plan did not predict.

- The slingshots had to move **up 16px, not inward**. Moving them in is what the plan
  implied and it is wrong: the inlane is the channel between the lane divider and the
  slingshot's outer edge, so pulling that edge toward the pivot narrows the inlane to
  13-15px against a 17.3px ball. The geometry gate caught it, twelve times. Raising the
  triangle instead clears the bigger arc while keeping the kick face its full 89px.
- **The post had to move down 7px, to y=912.** The bat's tip at rest fell from 26.7px
  below the pivot to 31.8px, so the old y=905 ended up *above* a ball sitting on the
  flipper and the post became an absolute block again — 0/28 passes with it up, which is
  precisely the failure `design.md` §6.2 exists to prevent. `board_a.lua` carries the
  re-sweep; 912 keeps 70% of Foundry's pass rate and 41% of Glasshouse's, within a point
  of what 905 kept before the bat grew. One sim fixture also moved: it dropped a ball at
  x=192 to "drop onto the post" and had in fact been landing on the flipper first, so it
  had a silent dependency on flipper length.

Measured after, against the same probes before:

```
  probe_reach, 50 swept contacts        pass    drain    L orbit   R orbit
    Foundry            before            50%      28%        32%       28%
    Foundry            after             62%      32%        26%       22%
    Glasshouse         before            50%      46%        22%       36%
    Glasshouse         after             64%      32%        10%       22%

  probe_identity                    gap    ball life   drains/s   survival   pts/s
    Foundry            before      27.6      11.07s     0.0753        17%        5
    Foundry            after       26.9       9.19s     0.0780        28%        7
    Glasshouse         before      43.6       6.95s     0.1272        10%      271
    Glasshouse         after       42.9       7.61s     0.1182         7%      270
```

The pass got substantially easier on both boards, 50% to 62-64%, and Glasshouse's swept
drain rate fell by a third. Foundry's **survival** — passes over passes-plus-drains —
went 17% to 28%, which is also why its mean ball life *fell*: a ball that leaves by
crossing the tube ends its life on that board sooner than one that rattles until it
drains. That is the trade going the right way.

Two regressions, both in the region phases 1 and 2 demolish anyway, and neither is
accepted as permanent: **orbit reach fell on both boards** (Glasshouse's left orbit
halved, 22% to 10%) because a longer bat aims more of the sweep at the centre channel,
and **Glasshouse's survival slipped 10% to 7%** despite being measurably less deadly per
second. Re-measure both after phase 1 rebuilds the orbits; if the orbits are still down
once they are real lanes rather than the gaps beside a ramp foot, it is the bat and not
the layout.

## 4. Phase 1 — evict the centre

Delete, on both boards:

- the pass channel walls and the roof over the ramp head;
- the `gate` device entirely.

The gate goes because a pass you can be prevented from making is not a hazard. With the
mouth always open, a flailed shot up the orbit sends the ball to your partner whether or
not either of you wanted it — which is the failure mode this game should have and
currently cannot.

**The mouth moves to the top of an orbit lane.** This is the change that pays for the
rest: it removes the largest object in the middle of the board and puts the pass on a
shot that already exists in every real table's vocabulary. It also means building real
orbits — lanes with guides running up the side and over the top — where today the
"orbits" `probe_reach` counts are just the gaps either side of the skyway's feet.

`table-design.md` §3 has the one rule that matters for them: **an orbit's guide must
aim the returning ball at a flipper, not at a slingshot tip.** An orbit that returns
onto a sling punishes the player for making it.

Boards should use opposite sides, so the two passes are different shots and the skill
does not transfer — the same reasoning `board_a.lua` already applies to the post.

## 5. Phase 2 — the skyway, to the side

Keep the ramp; stop it being the board. The current one is a 918px arch crossing the
whole playfield, reached by 7.9% of swept shots on Foundry and 2.9% on Glasshouse — and
completed by **100%** of those that reach it. The climb is not the problem and never
was; `board_a.lua` says so itself ("the angle it arrives at is"). The approach is.

- Re-path it up **one side**, not across the top.
- **Angle the mouth** into the shot line rather than presenting it square, so a shot
  that is close counts. `probe_ramp` already sweeps mouth height against funnel and
  channel width; it has never been swept against approach angle or foot x.
- **Exit into an inlane**, the way a real flow ramp does, so making it hands the player
  their next shot instead of ending the sequence.

Target: a shot a swept probe finds 20-30% of the time, still completing at or near
100%.

## 6. Phase 3 — the kit that was specified and never built

`boards-v2.md` §4 specified four element kinds and shipped one. `core/validate.lua`
accepts `walls, slingshots, bumpers, targets, guards, devices, ramps` — no `rollovers`,
no `drop`, no `spinners`.

Build all three, in this order, each as data + `validate` + `geometry` + `sim` + `render`:

1. **Rollovers.** Sensor circles in a named group; lighting the group awards and resets,
   reusing the bank rule that already exists. Two per inlane, both boards. This is the
   cheapest item in the whole plan and it fixes the most visible defect: four lanes the
   ball travels down regularly that score nothing, light nothing and say nothing.
2. **Drop targets.** `targets` gain `drop = true`; a struck target becomes a sensor
   until its bank completes, then all reset. Clearing a bank *physically opens the shot
   behind it* — the best value-for-effort mechanic in pinball, and `boards-v2.md` costs
   it at one boolean in the step loop.
3. **Spinner.** A sensor lane awarding proportional to crossing speed. Put it in an
   orbit, where a hard shot earns more than a soft one, which is the whole point of it.

## 7. Phase 4 — fill what is now empty

- **Foundry's nest**, re-swept on the board as it now is (`table-design.md` §9.4). It
  runs at 0.12 hits/s from three bumpers in positions no sweep chose, against 0.66/s
  documented, which also stretches the vault fill from the 17s in `design.md` §7.1 to
  **83s** — seven and a half Foundry ball-lives.
- **The lower band**, y=570..790, which is bare on both boards. `probe_where` says
  where a returning ball actually crosses; the stacking rule (AGENTS.md lesson 5) bites
  hardest down here, so content goes in a band and never in a stack.
- **The freed centre.** Open field is a legitimate answer for some of it — a fan layout
  needs shot lines, not objects — but not for all 400px of it.

## 8. Open, and blocking nothing yet

- **The operator loses a device.** Deleting the gate leaves the operator with the post
  and the guard, and frees the `operator_gate` binding. That is an opening, not a loss:
  `design.md` §6.2 wants devices that give and take, and the freed centre is where a new
  one would go. What it should be is undecided.
- **Glasshouse's drain gap** is 43.6px, 2.52 ball widths, 68% past the widest real
  table. Phase 0 leaves it alone deliberately — one global feel change at a time — but
  `table-design.md` §10 P3 still stands, and phase 0 makes it cheaper to attempt.
- **Whether the boards keep an identical skyway.** They already do not (`347` against
  `354`); phase 2 is the moment to make that a decision instead of a residue.
