# What makes a good pinball table — and where Pinpals stands

**Status:** research + measurement · 2026-09-08 · companion to `design.md` (the game)
and `boards-v2.md` (the layout)

`design.md` is thorough about the *co-op* half of Pinpals — the pass, the operator, the
rally. It is almost silent about the *pinball* half: nothing in the repo says what a
table is supposed to do, so nothing says when a board is bad. This is that missing
half.

§1–§8 are what the pinball world says, with numbers where the source gives numbers.
§9 measures Pinpals against it. §10 is a prioritised list of what to do about it.

Everything in §9 was measured on 2026-09-08 against `main` at 50c8312, `make check`
green, using the probes named. Where a measurement contradicts a number already
written down in this repo, both are shown.

---

## 1. The unit of measurement is the ball, not the pixel

Every real-table number below is quoted as a multiple of the ball's own diameter,
because that is the only form in which it transfers to a game whose "table" is
448 px wide.

| quantity | real table | in ball diameters |
|---|---|---|
| ball | 1 1/16" | 1.00 |
| playfield width | 20.25" (widebody ~23") | 19.06 |
| playfield height | 42" | 39.5 |
| flipper pivots, centre to centre | 6 13/16"–7" | 6.4–6.6 |
| flipper pivot height above bottom edge | 7" | 6.6 |
| flipper bat | ~3" | ~2.8 |
| flipper gap at rest | "a ball + 1/8"" (Gomez); 1.5 balls is the wide end | 1.12–1.50 |
| inlane / outlane | 1 3/8" (Bally) | 1.29 |
| a shot lane you want to be *makeable* | — | **2.0 minimum**, under 1.5 is "very difficult" |

Two of these are load-bearing and worth stating as rules:

- **A flipper gap wider than 1.5 balls drains excessively.** This is not a difficulty
  slider, it is the edge of the design space. Games with a deliberately wide factory
  gap (Ghostbusters, Fish Tales) sit at the top of that range and are notorious for it.
- **A path narrower than 2 ball widths is not a shot, it is a lottery.** Below 1.5 it
  is not even that.

The third thing this table encodes is subtler: on a real table the flipper pair spans
**34.6%** of the playfield width. That fraction is how much of the bottom the player
actually defends. It is a constant across the whole industry for sixty years.

## 2. Every shot must be makeable, and the player must know it is there

Roger Sharpe's three rules of table design, in his order:

1. **The player must be told what is going on and what to shoot.** Voice, sound,
   animation and lighting all working together to say *spell this word, hit that shot,
   this is how you start the mission*.
2. **The ball must be visible at all times.** If it leaves the playfield — a lock, a
   cellar hole — the player must know where and when it comes back.
3. **The player must have a good chance of making each shot.** His own example is
   *Rollergames*' "Go For The Wall", which shipped without the magnet that made it
   hittable and was unfair until it got one.

Rule 3 is the one homebrew designs break. The Mission Pinball Framework's layout guide
puts it operationally: *every shot on the playfield must be makeable from one or more
flippers*, verified by drawing shot lines that account for ball diameter — and while
you are drawing them, check whether the backhand exists too.

The corollary from the same guide, and it is the one that kills features: **every
switch must do something immediately** — a sound, a light, a score. An element that
can be hit but produces nothing is worse than no element, because it teaches the
player that part of the board is scenery.

## 3. Flow: what "good geometry" actually means

Flow is the ability to make shots *one after another* without waiting for the ball to
settle. A flowing game returns the ball to a flipper fast, usually into an inlane,
usually on the *other* side, so the next shot is already available. The opposite —
stop-and-go — makes you shoot, then wait, then shoot.

Neither is wrong. Steve Ritchie ("the King of Flow") and Pat Lawlor (deliberate
stop-and-go, misdirection as a theme in *Funhouse*) both made great tables. What is
wrong is *not choosing*.

The mechanics that produce flow:

- **Orbits and loops** that run round the back and come down to a flipper. The lane
  guide must aim the returning ball **at the flipper**, not at the slingshot tip —
  an orbit that returns onto a sling is a shot that punishes you for making it.
- **Ramps that feed an inlane** via a wireform, so a made ramp hands you the next shot.
- **The fan layout** — 7–8 shots fanning out from the flippers toward the back, each
  with a clear line. Brian Eddy's signature; the centre shot of a fan is the risky one
  and usually holds the main toy.
- **Upper flippers** as a second dimension, reaching shots hidden behind other
  playfield objects. Access to an upper flipper should be easy (a ramp or orbit feeds
  it), because shots *from* it are already hard.

And the mechanics that destroy it:

- **Steel where the ball can hit it.** "The ball should never ever ever hit metal
  directly unless it's a ball guide." Bare steel near pop bumpers is the classic
  action-killer; rubber around a bumper nest keeps it alive, steel kills it dead.
- **Dead zones** — regions the ball reaches but nothing lives in, or regions nothing
  can reach.
- **A bigger playfield plays slower.** Distance between devices is time the ball
  spends doing nothing. Widebodies are subjectively slower than standard bodies at the
  same tilt for exactly this reason.

## 4. Risk and reward has to be spatial, not just numeric

The good version of risk/reward in pinball is *geometric*: the valuable shot is
physically more dangerous to attempt.

- The **centre shot** of a fan layout is the one that comes back down the middle if you
  miss it, so it is where the jackpot goes.
- **Outlanes** are the tuning knob for the whole game's difficulty, and every real
  machine ships with the posts adjustable — EMs had three pre-drilled holes (liberal /
  normal / difficult), modern games use sliding posts. This is worth internalising:
  *the industry's answer to "how hard should it be" is a movable post in the outlane*.
- **Drop targets** are the cheapest good mechanic there is: clearing a bank physically
  opens the shot behind it. The reward for skill is a *changed board*, not a number.
- **Rebounds and slingshots** are randomness with a purpose — they move the ball
  laterally and force you to switch which flipper you were about to use.

## 5. Depth comes from layers, not from complexity

The consensus on rulesets, and the reason the 1990s are usually named as the peak:
rules should be *intuitive but not shallow* — enough that a first-time player knows
what to shoot, enough that a good player has a plan.

The structure that produces this is layered goals:

- **Immediate**: this shot scores, right now, and says so.
- **Short**: complete this bank / lane set / mode.
- **Long**: a multiball, then a wizard mode gated behind several of the above.

The failure mode is *modes that don't pay*. If finishing four modes is worth less than
grinding one repeatable shot, the ruleset is decoration. A wizard mode should be worth
enough that the whole game is a run-up to it.

## 6. A skill ceiling means ball *control*, not just aim

The difference between a casual player and a real one is not accuracy, it is the
arsenal available when the ball arrives: **trapping** (holding a flipper up so the ball
rests against it and you can aim), the **dead bounce** (leaving both flippers down and
letting a ball hop between them), the **live catch**, the **drop catch**, the **post
pass**. All of these depend on the flipper being a physical object with rest, hold and
release states, not a swat.

This matters for a video game because it is where the hundredth hour comes from. A
fixed table with no control layer is exhausted once you can hit every shot; with a
control layer the challenge does not run out.

## 7. The plunger is the first decision of every ball

Nearly every modern table has a **skill shot** — plunge to a specific strength or
target and get paid. It costs one lane and one rule, and it turns the dead moment at
the start of each ball into a decision. Its absence is conspicuous.

## 8. Where these rules should *not* apply to Pinpals

Two of the standard rules are in genuine tension with `design.md`, and this doc is not
asking to break the game to satisfy a checklist.

- **Sharpe rule 2 (the ball is always visible)** is deliberately broken by the tube.
  `design.md` §10 already pays the debt in the right currency: transit gets its own
  visible beat, on-screen, with rings collapsing on the destination. That is the rule
  being *honoured*, not violated — the player knows where and when.
- **Flow** cannot be the whole answer here, because the ball leaves the board 800 ms at
  a time by design. Pinpals' flow unit is the *rally*, not the combo. But that makes
  the within-board flow *more* important, not less: the ~5–11 seconds a player holds
  the ball is all the pinball they get before handing it over, and dead time inside
  that window is proportionally far more expensive than on a real table.

Everything else in §1–§7 applies unchanged.

---

## 9. Pinpals, measured

### 9.1 Geometry against the real-table numbers

Measured from `core/constants.lua` and `data/tables/*.lua`. Ball diameter 17.28 px.

> **Superseded 2026-09-08 for the flipper rows.** `boards-v3.md` phase 0 grew the bat to
> 64px (3.70 balls) and spread the pivots to hold each board's drain gap: coverage is now
> **30.8%** on Foundry and **34.4%** on Glasshouse against the 25.0% / 28.6% below. The
> rest of this table still stands, including the board being 36% oversized against the
> ball — that is what made the flippers too small in the first place.

| | px | ball widths | reference | verdict |
|---|---|---|---|---|
| flipper bat | 48.6 | 2.81 | 2.8 | **exact** |
| pivot spacing, Foundry | 112 | 6.48 | 6.4–6.6 | **exact** |
| pivot spacing, Glasshouse | 128 | 7.41 | 6.4–6.6 | 13% wide |
| drain gap, Foundry | 27.6 | **1.60** | 1.12–1.50 | past the wide end |
| drain gap, Glasshouse | 43.6 | **2.52** | 1.12–1.50 | **68% past it** |
| outlane | 26 | 1.50 | 1.29 | generous, fine |
| inlane | 28 | 1.62 | 1.29 | generous, fine |
| pass channel | 52 | 3.01 | ≥2.0 | good |
| skyway lane | 54 | 3.13 | ≥2.0 | good |
| tube mouth (sensor r=14, + ball radius) | 45.3 | 2.62 | ≥2.0 | good |
| target face | 28 | 1.62 | — | fine |
| **board width** | 448 | **25.9** | 19.1 | **36% wide** |

The flipper hardware is dimensionally correct to a fraction of a percent. The *board*
is not: at 448 px the ball is 3.86% of the width where a real ball is 5.25%.

That has one consequence that nothing in the repo has named. The flipper pair spans
**25.0%** of Foundry's width and **28.6%** of Glasshouse's, against **34.6%** on every
real table ever built. Both boards ask the flippers to defend a proportionally wider
bottom than any real machine does, on top of drain gaps that are already at or past
the industry's wide end. `boards-v2.md` §2 recorded the honest trade — "at 448 wide the
ball is relatively smaller than on a real table" — and predicted ball life *up*. The
opposite happened on Glasshouse, and this is why.

Glasshouse is the sharp case: a 2.52-ball gap is not a difficult table, it is outside
the space real tables occupy. Its identity ("expensive, drains fast") is currently
bought with a number that has no precedent, rather than with content.

### 9.2 Shot inventory and makeability — Sharpe rule 3

`PINPALS_SUITE=tests.probe_reach love . --test`, 50 swept flipper contacts per board:

```
              pass   drain   alive   left orbit   right orbit
  Foundry      50%     28%     22%          32%           28%
  Glasshouse   50%     46%      2%          22%           36%
```

`PINPALS_SUITE=tests.probe_skyway love . --test`, 140 swept shots per board:

```
  board        left flipper   right flipper   reached mouth   completed
  Foundry          7 / 70          4 / 70        11 (7.9%)     11 (100%)
  Glasshouse       3 / 70          1 / 70         4 (2.9%)      4 (100%)
```

The pass is healthy on both boards. **The skyway is not a shot.** It is the largest and
most expensive structure on either board, it crosses the whole playfield, and on
Glasshouse the right flipper finds it once in seventy attempts. A swept probe is not an
aimed shot and the true aimed rate is higher — but Sharpe rule 3 asks for "a good
chance", and 1-in-70 from a sweep is not the signature of a shot that has one.

Note what the second column says, though: **everything that gets on, gets round.** The
energy-budget gate in `core/ramp.lua` is doing exactly what it was built to do. The
defect is the *approach angle*, not the climb — which is what `board_a.lua`'s own note
already says ("the climb is never what decides a shot here; the angle it arrives at
is"). It has simply never been treated as a bug.

Counting distinct destinations, each board offers about six: pass ramp/tube, two skyway
mouths, two orbits, and one content area (bumper nest / target banks). A fan layout is
7–8. Pinpals is close, and the shortfall is not "add more shots" — it is that two of
the six are effectively unreachable.

### 9.3 Dead zones: the inlanes

`boards-v2.md` §4 specified four new element kinds. Grepping `core/validate.lua` for
what a board may actually declare:

```
  built:      walls  slingshots  bumpers  targets  guards  devices  ramps
  specified,
  not built:  rollovers   drop targets   spinners
```

The inlanes were built as geometry in the same phase whose stated purpose for them was
`rollovers` — "this is what gives an inlane a reason to exist". The rollovers were not
built. So each board has two lanes, 1.62 balls wide, that the ball travels down
regularly and that score nothing, light nothing and say nothing.

That is precisely the failure MPF's guide warns about: a region the player's ball
visits with no feedback, which trains them to read it as scenery. It is also the
cheapest thing on this entire list to fix.

Drop targets are the other absence worth naming, because §4 above makes them the single
best value item in pinball — clearing a bank *opens the shot behind it* — and
`boards-v2.md` already costed the implementation at "one boolean in the step loop".

### 9.4 Live devices: Foundry's bumper nest has gone quiet

This is the finding that matters most, and it is a drift, not a design flaw.

`PINPALS_SUITE=tests.probe_reach love . --test`, 6 × 120 s of random play:

```
  Foundry bumper hits:  13.8 per 120s  (sd 2.0, range 11-16 over 6 seeds) = 0.12/s
```

Against what the repo says:

| source | claim |
|---|---|
| `design.md` §7 | "a five-bumper nest across the top" |
| `board_a.lua` | a four-arm "+" nest; sweep chose cx=224 cy=190 arm=78 at **0.66/s**, "confirmed on three independent seed bases: 0.65 / 0.65 / 0.64" |
| `design.md` §7.1 | "at the measured 0.6 hits/s [the vault] fills in ~17 seconds" |
| `constants.lua` | serve jitter dropped the cluster "from 0.21 to 0.12 hits/s" |
| **measured now** | **0.12/s, from three bumpers** |

What happened is visible in `git show e9dc7c9` (the "Ramps" commit): the south arm was
commented out and west/east were moved from (146,190)/(302,190) to (157,210)/(292,210)
— presumably to clear the skyway that commit added. The surrounding comment block,
including the sweep that justifies the old coordinates, was left in place describing a
nest that no longer exists.

The consequences compound:

- **Foundry has three bumpers, not four or five**, in positions no sweep chose.
- **Foundry scores 5 points/s.** `probe_identity`, now: `Foundry 11.07 s a ball,
  0.0753 drains/s, 0 targets, 0 banks, 5 pts/s` against `Glasshouse 6.95 s,
  0.1272 drains/s, 271 pts/s`. That is **54:1**, where `design.md` §7 documents 17:1
  and quotes 14 pts/s for Foundry. 0.12 hits/s × 50 points is 6 pts/s — the bumpers
  are essentially all of Foundry's scoring, and they are barely firing.
- **The cross-board loop is five times slower than designed.** `CHARGE_MAX` is 10 and
  one bumper hit is one charge, so at 0.12/s a full vault takes **83 seconds** of
  Foundry ball time, not the 17 s in §7.1. Foundry's mean ball life is 11.07 s. Filling
  the vault therefore costs roughly **seven and a half Foundry balls** — through a
  board whose survival rate is 17%. The loop that `design.md` §7.1 calls "what makes
  the pass structural rather than optional" is, as shipped, most of a session long.

Foundry is currently a board where you survive twice as long and earn a fifty-fourth as
much, and the mechanism that was supposed to pay you for staying there has a fill time
longer than seven of its own balls. "Chaotic, forgiving, cheap" has drifted to
"forgiving and free".

This is AGENTS.md's own lesson 4 — *measure the thing you are about to assert* — and
lesson 5, the stacking rule, arriving together: the south arm was almost certainly
removed because it sat under the skyway, and the removal was correct. Only the
bookkeeping failed.

### 9.5 Skill ceiling and the first second of a ball

- **No trapping.** Flippers have `FLIPPER_REST` and `FLIPPER_UP` and hold while the
  button is held, so the mechanism for a trap exists — but nothing in the game rewards
  or teaches it, and §6's whole arsenal (dead bounce, live catch, post pass) has never
  been measured. `probe_reach` sweeps *contacts*, which by construction measures
  reflex-free aim and nothing else. There is no probe that asks "can a good player
  hold this ball and aim it?"
- **No plunger, no skill shot.** `serve` is a fixed point and direction with
  ±1.2° of jitter, fired automatically after `SERVE_DELAY`. The first second of every
  ball is a cutscene. `constants.lua` is explicit that the jitter is *not* a difficulty
  knob (the outcome saturates below it), so nothing about the serve is currently a
  player decision.
- **Four actions total.** `core/intents.lua`: `flip_left`, `flip_right`,
  `operator_gate`, `operator_paddle`. The operator's two are `design.md` §6's whole
  design and are fine. The flipper player's two are the entire skill surface.

### 9.6 Feedback — the one place Pinpals is ahead

Thirteen synthesized audio voices, impact events filtered at a measured resting-impulse
threshold, the dormant board outlined when its cross-board state moves, transit given
its own beat with the HUD kept up, and a drain sound deliberately withheld for 1.9 s
because the ball might still be rescued. Sharpe rule 1 is in better shape here than in
plenty of shipped tables. The gap is not the feedback system — it is that §9.3's
inlanes and §9.4's quiet bumpers give it nothing to say.

---

## 10. What to do, in order

Each item names the probe that would prove it. Nothing below is a large change; the
first three are corrections rather than features.

### P0 — Foundry's nest (§9.4)

Re-run the sweep that `board_a.lua` documents, on the board as it now is with the
skyway over it, and place the cluster where the ball actually goes. The old sweep
scored on the **weakest arm** for good reason — a total rate hides a dead bumper — and
that method should be reused. Then rewrite the comment block to describe the nest that
exists, and correct §7 and §7.1 of `design.md`.

Target: back to ~0.6 hits/s, or an explicit decision that Foundry is worth ~5 pts/s and
`CHARGE_MAX` / `SCORE_BUMPER` move to match. Either is fine; the present state is
neither.
*Probe:* `probe_reach` (bumper hits/s over ≥6 seeds), then `probe_identity`.

### P1 — Give the inlanes rollovers (§9.3)

`boards-v2.md` §4 already specifies them: sensor circles in a named group, complete the
group to award and reset, reusing the bank rule that already exists. Four lanes across
two boards go from dead geometry to the thing every real table uses to make a returning
ball feel earned — and the audio kit already has voices to spend on it.
*Probe:* `probe_where` for where a returning ball actually crosses the inlane;
`probe_identity` for what it does to pts/s.

### P2 — Make the skyway a shot, or make it smaller (§9.2)

7.9% and 2.9% of swept shots reach it, and 100% of those complete. The climb is not the
problem; the approach is. Two honest options:

- **Widen the approach**, not the lane — the mouths sit at y=570 because that is as
  high as the feet can go, and the constraint that fixed x=347/354 was other geometry,
  not reach. `probe_ramp` already sweeps mouth height against funnel and channel width;
  it has never been swept against *foot x*.
- **Accept it as a low-frequency prestige shot** and pay it accordingly. A 3% shot that
  always completes is a legitimate design — it is just not currently worth anything
  special, which makes it a large object doing nothing.

Do not do both. `board_a.lua` records that raising the mouth alone made the pass
unmakeable; this structure is coupled to everything around it.
*Probe:* `probe_skyway`, plus `probe_reach` to confirm the pass rate did not move.

### P3 — Glasshouse's drain gap (§9.1)

43.6 px is 2.52 ball widths, 68% past the widest real table. The board's identity is
correct and worth keeping; the *instrument* is wrong. Buy the same drain rate with
content and lane geometry — its outlanes, its slingshot feeds, its target placement —
and bring the gap back toward 1.5 balls (≈26 px), which is where a deliberately
punishing real table sits.

This is a genuine sweep, not an edit: `board_a.lua` records that the equivalent Foundry
number was chosen from a 33.6/27.6/21.6 sweep and that 21.6 "barely drained at all,
which is a wall, not a board". Expect the same shape here.
*Probe:* `probe_identity` across a gap sweep, ≥8 seeds a cell (AGENTS.md lesson 1).

### P4 — A skill shot on the serve (§9.5)

The cheapest addition in this document. The serve already exists, already has jitter,
and already flies a measured arc past the tube mouth on both boards. Award the ball for
crossing a named region within the first N ms — a rollover in the serve's own path, or
simply "reach the tube mouth's height before the flippers touch it".

It is also the one item here that touches the co-op design directly, and in the right
direction: `design.md` pillar 1 says nobody waits, and right now the serve is exactly a
moment where both players wait. Give the *operator* the skill shot and the first second
of every ball becomes theirs — which is more interesting than giving it to the flipper
player, and requires no new binding.
*Probe:* `probe_serve` already splits serve-time hits from real play; it is the right
instrument unchanged.

### P5 — Drop targets (§9.3, §4)

`targets` gain `drop = true`; a struck target becomes a sensor until its bank completes,
then all reset. Clearing Glasshouse's vault would then physically open what is behind
it. `boards-v2.md` costs this at one boolean in the step loop, and it is the one item
on this list that adds a *mechanic* rather than repairing one.
*Probe:* `probe_where` for what the opened shot leads to; `probe_identity` for the
scoring consequence.

### Not recommended

- **Upper flippers.** §3 says they add a dimension; Pinpals has spent that dimension on
  the ramp layer already, and a third flipper competes with the operator for the
  player's two remaining buttons.
- **Widening the boards further.** §9.1 says the flippers already defend too little of
  the width. If anything moves, it moves the other way.
- **More element kinds before the existing ones are live.** Foundry's nest and the
  empty inlanes are the argument.

---

## Sources

- [Roger Sharpe's Three Rules of Good Table Design — Digital Pinball Fans](https://digitalpinballfans.com/threads/roger-sharpes-three-rules-of-good-table-design.3856/)
- [What Should You Consider When Planning a Playfield Layout? — Mission Pinball Framework](https://missionpinball.org/latest/physical_building/layout_considerations/)
- [Design — Pinball Makers wiki](https://pinballmakers.com/wiki/index.php?title=Design)
- [Tips on playfield design for a homebrew machine — Pinside](https://pinside.com/pinball/forum/topic/tips-on-playfield-design-for-a-homebrew-machine)
- [General lane widths and flipper spacing — Pinside](https://pinside.com/pinball/forum/topic/general-lane-widths-and-flipper-spacing)
- [What is the regular distance between flippers — Pinside](https://pinside.com/pinball/forum/topic/what-is-the-regular-distance-between-flippers)
- [Design Theory Discussion 1: Flow — Pinside](https://pinside.com/pinball/forum/topic/design-theory-discussion-1-flow)
- [What is Flow? — Pinside](https://pinside.com/pinball/forum/topic/what-is-flow)
- [How to adjust or tweak your pinball machine for better gameplay — Flippers.be](https://www.flippers.be/basics/101_adjust_pinball.html)
- [Pinball Machine Dimensions — Flippers.be](https://www.flippers.be/basics/101_pinball_dimensions.html)
- [Wizard Modes — Mission Pinball Framework](https://missionpinball.org/latest/game_design/wizard_modes/)
- [Best Era for Pinball Rule Design? — Pinside](https://pinside.com/pinball/forum/topic/best-era-for-pinball-rule-design)
- [A Beginner's Guide to Pinball Designers — Kineticist](https://www.kineticist.com/news/a-beginners-guide-to-pinball-designers)
- [Pinball Terms Glossary — Kineticist](https://www.kineticist.com/news/pinball-terms-glossary)
- [Skills for the Advanced Pinball Player — IPDB](https://www.ipdb.org/playing/advanced.html)
- [An Animated Guide to Flipper Skills in Pinball — MAYA Pinball](https://mayapinball.com/blog/flipper-skills-guide/)
