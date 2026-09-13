# Pinpals — Prototype 0.1

**Status:** built and running · **Companion to:** `design.md` §14, `technical-choices.md`

The §14 prototype: the smallest thing that can answer *"does the rally feel good?"*

```
make run                  play
make check                every gate (§7), ~0.7s
make shot TICKS=420       render N fixed steps to a PNG and quit
```

Controls, shared keyboard. Your keys do different things depending on where the
ball is — that is the game, not a bug.

| | Player 1 (Foundry) | Player 2 (Glasshouse) |
|---|---|---|
| Flippers, when the ball is on **your** board | `A` / `D` | `←` / `→` |
| Gate, when it is on **their** board | `W` | `↑` |
| Post, when it is on **their** board | `S` | `↓` |

`R` restart · `F1` debug readout · `Esc` quit

Quitting writes a **session log** to LÖVE's save directory and prints the path. It
holds a readable summary — rally length distribution, drains per board, operator duty
cycle — followed by the tick-stamped intent stream, which is enough to replay the
session (§5.1). Play, quit, and paste the summary: that turns an impression into
something an agent can act on.

---

## 1. What is in it

§14's list, plus what the 2026-09-06 overnight pass added. §14 asked for no scoring,
no modes and no cross-board unlocks; there are now all three, because "it works but
it isn't fun" turned out to be mostly about the things §14 deferred.

The original list:

- Two crude, non-mirrored boards; one ball; one screen; two players
- One tube each way, with the transit beat animated between both boards (§5, §10)
- Two operator devices per board, both persistent states with real trade-offs (§6)
- Roles implicit in ball position, no role UI (§4)

Added since:

- **Sound.** Eleven voices, synthesized at load, no asset files. Relay heat pitches
  the whole kit up (§10).
- **Impact feedback.** Rings, sparks, lit bumpers, a ball trail, restrained shake —
  driven by the same event stream as the audio, so a hit looks and sounds like one hit.
- **Scoring on relay heat (§9).** The multiplier is the crossing count. A ten-crossing
  rally is worth 5.5x the same ten passes spread across ten drains.
- **Content on both boards.** Foundry's bumper cluster now sits where the ball
  actually goes; Glasshouse has a target bank. Both boards have a second shot.
- **Cross-board state (§7).** Foundry's bumpers charge Glasshouse's vault; clearing
  the vault lights Foundry's bumpers. See design.md §7.1.
- **A session log.** Quitting writes rally distributions, drain locations and operator
  duty cycles, plus the intent stream.

Still absent: team lives, a session ending, purgatory rescue, multiball, any meta.

The architecture is the one in `technical-choices.md` §5, enforced by a gate rather
than by good intentions: `core/` is pure Lua, `sim/` may touch `love.physics` and
nothing else, dependencies run `app → sim → core`. `scripts/check_layers.sh` fails
the build if that erodes.

## 2. The two devices

Both are persistent states with a visible travel time (§6.1), and both give and
take (§6.2). They interlock, which is where the shouting comes from.

**Gate** (~300ms) — seals the top of the pass ramp.
Closed, a ramp shot comes back down to you: the ramp is a safe return loop and
you keep the ball. Open, the ramp feeds the tube and the ball is your partner's
problem. You cannot pass without your partner opening it for you.

**Post** (~260ms) — rises from the floor between the flippers.
Up, it guards the centre drain, which is the only drain on either board — 100% of
drop-ins stopped, against 68% getting through with it down.

It used to sit at y=676, *above* the flipper pivots and directly in the launch path,
where it measured 0% pass **and** 0% drains: not a trade but a pause button, with
nothing to do and nothing to fear for as long as it was held. Lowered to y=713 it
costs the pass without ending it — Foundry 58% → 40%, Glasshouse 69% → 31%.

The cost is sharply asymmetric, which is the best thing about it. Each board's ramp
is off-centre, so the post blocks whichever flipper must shoot *across* the middle:
Foundry's left drops 58% → 25% while its right barely notices, and Glasshouse's right
drops 63% → 8%. A raised post therefore does not stop the pass, it **moves** it — you
have to work the ball to the near flipper — and the two boards are blocked on opposite
sides, so the skill does not transfer. That fell out of the geometry rather than being
designed, and is now deliberate.

## 3. What measuring changed

The headless harness earned its keep before a human ever played it.

- **The pass shot did not exist.** The first layout put the pass lane down the
  right wall, the way a pinball orbit usually runs. A sweep of flipper contact
  points showed shots crossing that height between x=145 and x=239 — the lane was
  at x=328. It was hit **1 time in 30**. The lane moved to a flared centre ramp,
  where shots actually go, and now lands ~60% from a clean flip. `tests/sim/spec.lua`
  keeps it there.
- **Flippers were mounted wrong.** Box2D takes a revolute joint's reference angle
  from the bodies' angles at construction, so building the flipper already rotated
  silently redefined its limits. It swung into the floor.
- **Flippers chattered.** Driving the motor toward a target angle compared each
  step reverses every other step once the limit overshoots slightly. Drive at the
  limit and let the limit hold it.
- **The ball ceiling was ~2x too fast.** At 10x scale, distances and gravity are
  10x, so speeds scale by sqrt(10), not 10. The old ceiling let the ball cross more
  than its own diameter per step, and bumpers with restitution > 1 pumped it there.
- **A 30fps frame ran the game in slow motion.** `MAX_CATCHUP` was 8 steps; a
  30fps frame legitimately needs 8 at 240Hz, so the cap fired in normal play and
  silently dropped time.

None of these are visible by looking at the screen for a few seconds, and all of
them would have been blamed on "Box2D feels bad" — the exact §11 risk.

## 3a. Playtest 1 — 2026-09-05

Verdict: **physics feel fine, boards were bad.** That is the good half of the
§11 risk table clearing — Box2D can carry this game — and the bad half being a
layout problem, which is cheap to fix because layouts are data (§5.3). Nothing
in `core/`, `sim/` or `app/` changed to fix any of the below.

Reported: the ball gets stuck in several places, and the flippers poke out far
enough that a slow ball wedges beside them. Found and fixed:

- **Two wall chains had a local minimum.** Board A's lower right turned back
  *up* at the end to meet the flipper pivot, putting a V at (300,702) that
  swallowed the ball. Board B's lower left had the same at (84,702). Wall
  chains that feed a flipper now descend monotonically. Any local minimum in a
  chain is a pocket.
- **The wall ended underneath the flipper pivot.** That put the wall's endpoint
  inside the flipper's own rectangle and left a notch *behind* the pivot, where
  a slow ball sat unreachable by a flipper that rotates away from it. Walls now
  stop just outside and above the pivot: a ~7px gap, which the 17px ball cannot
  enter, and clear of the swept arc.
- **The closed gate was a shelf.** A level bar across a channel holds a ball
  forever, and tilting it only moves the resting place into the corner against
  the wall — every downward-facing corner is a wedge. Fixed by roofing the ramp
  head so nothing can land on the gate at all.
- **Board B's two rails crossed** into a funnel that caught 19 of 182 test
  drops. They no longer touch.

The scan that found these also flags a shelf on top of the closed gate inside
the now-sealed ramp head. That one is a scan artifact: 720 simulated seconds of
random play and 640 adversarial gate-slams at every ball speed and every closing
moment never put a ball there, because anything with enough speed to enter the
head has enough to reach the mouth. Both probes are now regression tests.

## 3b. The geometry gate

`core/geometry.lua`, run by `make geometry` and as part of `make check`. Board
layouts are hand-authored coordinates, and every board bug so far has been a
coordinate typo found by simulating thousands of ball drops — or by you playing.
All of them are visible in the data. Four checks, no physics:

| Check | Finds |
|---|---|
| **bowl** | a wall vertex lower than everything it joins. A peak sheds the ball and is fine, so this is not "chains must be monotone", it is "chains must never turn back up". Vertices are keyed by position, so a bowl formed *between* two polylines is caught the same way as one inside a chain. |
| **flipper-jam** | wall geometry inside a flipper's swept arc — either it jams the flipper, or it leaves a notch behind the pivot that the flipper rotates away from. |
| **wedge** | any two surfaces closer than the ball is wide: wall/wall, bumper/wall, bumper/bumper, target/wall, target/target. Proximity, not intersection — board B's rails never crossed, they converged to 10.8px. The target-to-target check was added after three standups authored 33px apart at 34px wide overlapped into a single bar; only a screenshot caught it. |
| **gate-leaks / gate-blocks / post-misses / post-stuck-out** | devices that do not do what they claim: a gate whose closed tip does not reach a wall, or whose open position leaves less than a ball of clearance; a post that does not span the drain gap, or does not retract below the drain line. |

Reintroducing the bug from playtest 1 gives, instantly:

```
geometry: 2 defect(s)
  board a [bowl] wall vertex (300, 702) is lower than everything it joins: the ball settles here
  board a [flipper-jam] wall 3 passes through the right flipper's swept arc at (251, 692), 4.0px from the pivot
```

`tests/core/geometry_spec.lua` reconstructs all eight shipped bugs and asserts
each is caught, plus two legitimate shapes (a chevron peak, a dangling wall end)
that must *not* be flagged. A validator nobody has tested against real bugs is
decoration.

**Not implemented:** a "the closed gate is a horizontal shelf" check. It cannot
be made precise — the post is a horizontal shelf on purpose, and the gate is
7.4 degrees off horizontal and perfectly safe because it is roofed. Whether a
surface is a trap depends on whether the ball can reach its upper side, which is
a reachability question that static analysis cannot answer. That class stays
covered by the two stuck-ball tests in `tests/sim/spec.lua`.

## 4. Calls made to unblock the build

These answer `design.md` §13 questions **provisionally**, for the prototype only.
They are choices to react to, not decisions.

1. ~~**Board identities (§13.1).**~~ **Answered and measured — see design.md §7.**
   Foundry is where a rally survives (12.19s mean ball life, 24 points/s);
   Glasshouse is where it pays (9.05s, 351 points/s). The old text here —
   "Foundry forgiving, Glasshouse punishing to sit on" — was never measured and
   was backwards: Glasshouse had the *higher* survival rate of the two, and
   Foundry drained more often per second despite a narrower gap.
2. **Tube count (§13.3).** One each way, per §14.
3. **Operator resource model (§13.4).** Still neither cooldowns nor a meter. The
   devices' own trade-offs are the restraint, and the post's is now real rather than
   nominal (§2). Worth testing before adding any economy on top.
3a. **Session structure (§13.2) is still open**, and is now the largest unanswered
   question in the document. There is a score, and nothing that ends. No team lives,
   no goal, no run. Everything else built overnight assumes an endless session, so
   this is the next call with real consequences.
4. **Rescue (§13.5).** Not built. A drain re-serves on the board that lost it
   after ~0.9s. Purgatory rescue is a second mechanic on top of the one being
   tested, and §14 does not ask for it.
5. **The operator acts on the destination board during transit.** The moment the
   ball enters the tube the destination becomes active, so for those ~800ms the
   sender is already the operator over there, preparing the landing. This falls
   straight out of §4 and makes the transit beat active for both players.
6. **The centre gap is the only drain.** Both side lanes feed the flippers. It
   makes the post the single clear guardian and keeps the prototype about the
   rally rather than about cheap outlane losses.

## 5. Known soft spots

- ~~The post may be too absolute~~ **Fixed, and it was worse than this said.**
  It blocked 100% of pass shots *and* 100% of drains — a pause button rather than a
  trade. Lowered below the flipper pivots (§2); the cost is now real and asymmetric.
- ~~The pass may be too easy~~ **It is not.** Measured from a ball that actually
  arrives out of the tube, with a player who predicts contact rather than flipping on
  a fixed cue, the peak rates are 63% (Foundry) and 85% (Glasshouse) — but the
  *timing window* is the real number, and it is narrow:

  | board | peak | window at ≥ half peak |
  |---|---|---|
  | Foundry | 63% | **20ms** |
  | Glasshouse | 85% | 50ms |

  A 60fps frame is 17ms, so receiving on Foundry gives the player roughly one frame
  of usable information. That is a playability concern in the opposite direction from
  the one this bullet used to raise, and it needs a human at the keyboard to judge.

  Not the bumper cluster: removing it raises Foundry's peak to 72% and leaves the
  window at 20ms. What actually sets the window is still open.
- ~~Glasshouse is thin~~ **It has a target bank and a measured identity** (§4.1,
  design.md §7). One of its two bare rails became the bank; the other still feeds it.
- ~~The upper playfields are empty~~ **They were not empty, they were unreachable.**
  A sweep of 50 flipper contact points found board A could reach exactly one place:
  the ramp. Nothing above y=550 outside that channel was reachable from any contact
  point on either flipper, and all three bumpers measured zero. Raising the ramp
  mouth opened the orbits; both boards now have a second shot.
- ~~No audio~~ **Eleven synthesized voices**, pitched by relay heat (§1).
- **Foundry's receiving window is ~20ms**, about one 60fps frame, against
  Glasshouse's 50ms. Ruled out: the bumper cluster. Still open: what does set it.
  This is the most likely thing to make the game feel unfair at the keyboard.
- **Nothing ends.** There is a score and no session structure at all (§4.3a). Every
  system built overnight assumes an endless run.
- **The rescue may make the ball too hard to lose.** A 60-minute soak of random play
  took 156 rescues against 25 drains — an 86% save rate. Random play mashes the post
  far more than a person would, so that number is not a verdict; but if a human session
  also lands anywhere near it, §8's purgatory window is too generous and the drain has
  stopped meaning anything. The session log reports rescues, so one playtest settles it.
- **Nobody has heard the audio.** It is verifiably not silent and not clipping, but
  its peaks sit around half scale — deliberate headroom for overlapping voices, and
  also a kit that may simply be too quiet. Raise the `gain` values in `app/audio.lua`'s
  KIT if so, not the playback volumes.
- **None of the overnight work has been played.** Every number in this document
  comes from a headless probe. They say the systems function; they cannot say the
  game is fun.
- **The §7 lint and static-analysis gates are live.** `luarocks` had been broken
  by a Homebrew `lua` bump to 5.5 that left its shebang pointing at a deleted
  `lua5.4`; upgrading it to 3.13 fixed that. `luacheck` and `lua-language-server`
  are installed and wired into `make check` as hard gates, configured by
  `.luacheckrc` and `.luarc.json`. Both are clean across all 29 files.
- `busted` is installable again (`luarocks install --local busted`, and it is
  installed) but nothing uses it yet: `tests/harness.lua` stays the
  dependency-free stand-in with the same API, so `make test-core` needs no rocks.
  Switching the specs over to `busted` is a separate call, not a blocked one.
  Note `~/.luarocks/bin` is not on `PATH`, so `busted` needs its full path.

## 5a. What has actually been run

Everything below is headless except where noted. `make check` is the gate; the probes
are measurement tools (see `CLAUDE.md`).

| | status |
|---|---|
| `make check` — layers, lint, types, geometry, 97 core, 38 sim, 60s soak | green, 3.6s |
| `love .` — the real frame loop, window and audio | runs clean, writes a session log |
| `make shot` — §7 visual check | four reference frames, used to verify a refactor |
| 60-minute soak with per-tick invariants | 864,000 ticks, all held |
| Replay determinism (§5.1) | two runs of one intent stream agree, checksummed |
| Frame cost (§3) | 26µs per 60fps frame, 0.2% of budget |
| The audio kit | 13 voices, none silent, none clipping, all centred |

What has **not** been run is a person. Every number in this document came from a probe.

## 6. The question

Play it. The prototype exists to answer one thing, and only a human at the keyboard
can: **does the rally feel good, and does the tube transit read clearly?** If yes,
everything in `design.md` is worth building. If not, nothing else saves it.

Nothing in §3 or in the 2026-09-06 overnight pass changes that. Those measurements
say the systems work — the pass is makeable, the bumpers are reachable, the loop
closes, the post costs something. Whether any of it is *fun* is not a property a
headless harness can observe, and no amount of it substitutes for ten minutes at the
keyboard.

Three things specifically worth attending to while playing, because they are the
places the measurements point at and cannot settle:

1. **Receiving on Foundry.** ~20ms of usable timing, about one frame. Does it feel
   like a skill or like a coin flip?
2. **The post.** It now costs the pass on one flipper and barely touches the other,
   depending on the board. Does that read as tactical, or just as inconsistent?
3. **The cross-board loop.** Charge Foundry, pass, clear the vault, come home to lit
   bumpers. Does that arc survive contact with two people actually shouting at each
   other, or is it bookkeeping happening somewhere off-screen?

Quit with `Esc` and the session log will have the numbers for whatever you felt.
