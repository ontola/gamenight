# Pinpals — Game Design Document

**Status:** draft v0.1 · **Scope of this doc:** the game, not the code (see `technical-choices.md`)

Items marked **DECIDED** are settled. Items marked **OPEN** need a call before they block work.

---

## 1. Pitch

Two players. Two *different* pinball tables, physically linked by tubes. **One ball.**

Whoever has the ball plays the flippers. Whoever doesn't reaches into their partner's
table and starts messing with it — sliding gates open, raising walls, charging magnets —
trying to help. The moment the ball crosses a tube, the roles swap.

It is a game about handing something fragile to a friend, and about the friend
rearranging the floor beneath it while shouting about what they're doing.

## 2. Design pillars

1. **Nobody waits.** There is no state in which a player has nothing to do. Ball position
   assigns roles; both roles are active at all times.
2. **The pass is the game.** Passing isn't transport, it's the central skill. A pass
   carries difficulty: where the ball arrives, how fast, and how prepared the receiving
   board is are all the sender's responsibility.
3. **Talking is a mechanic.** The operator can't act well without telling the flipper what
   they're about to do. We design for two people shouting at each other in one room.
4. **Generosity under pressure.** Almost every choice is "do I take the safe thing for me,
   or set up the good thing for you." That tension is the whole game.

## 3. Scope — v1 **DECIDED**

| | v1 | Later |
|---|---|---|
| Players | 2 | 3–4 (ring topology) |
| Balls | 1 | Multiball as an escalation |
| Boards | 2, different, interconnected | More boards |
| Multiplayer | Local, one screen, two inputs | Online (see §11) |

Starting at one ball is deliberate: it keeps the role-swap clean, and it *preserves
multiball as an escalation* we can spend later. If balls-per-player were the baseline we'd
have burned pinball's best card on the tutorial.

## 4. Core loop

```
        ┌─────────────────── ball crosses a tube ───────────────────┐
        │                                                           │
        ▼                                                           │
  Player A: FLIPPER                                       Player B: FLIPPER
  - owns board A's flippers                               - owns board B's flippers
  - scores, chases modes                                  - scores, chases modes
  - decides when and where to pass                        - decides when and where to pass
        +                                                           +
  Player B: OPERATOR                                      Player A: OPERATOR
  - controls devices ON BOARD A                           - controls devices ON BOARD B
  - opens/closes routes, saves, sets traps                - opens/closes routes, saves, sets traps
        │                                                           │
        └─────────────────── ball crosses a tube ───────────────────┘
```

Both players are always looking at the same board — the one with the ball. Roles are
implicit in ball position; there is no role-select UI and no mode switch.

## 5. The link

**DECIDED:** Boards are connected by tubes. A ball entering a tube on one board emerges at
a defined entry point on the other.

- **Multiple exits, multiple entries.** Each board has several tube mouths; each maps to a
  different arrival point on the partner board. Choosing which tube to shoot is choosing
  how hard your partner's next ten seconds are.
- **The pass carries state.** A clean ramp shot arrives controllable; a desperate flail
  arrives fast. A bad pass is a real thing you can do to your friend.

  **As built (2026-09-06), only the SPEED survives, not the direction or the spin.** The
  tube carries a scalar, and the receiving board launches the ball along its own entry
  vector at that speed. That is deliberate for direction — an arrival that kept its
  original heading could emerge travelling into a wall — but it does mean a pass is
  currently one number, and "arrives high and controllable" versus "fast and low" is
  only the fast/slow half of that sentence. Spin is not transferred at all. If the pass
  should carry more, this is the place it would go in.
- **Transit is visible and takes time.** ~700–900ms, animated along the tube where both
  players can see it. This is the telegraph, the breath between phases, and (later) the
  network latency budget. See `technical-choices.md` §6.
- **Passing must be tempting, not compulsory.** Some scoring lines reward staying home and
  grinding your own board. If progress *requires* a pass every cycle, the tube stops being
  a decision and becomes a corridor.

**OPEN:** How many tubes per board? Are any one-way? Proposal: 3 per board, all one-way,
so the topology is a directed cycle and "can I even get back?" is a real question.

## 6. The operator

The ball-less player acts on the *active* board. This is what makes one ball work.

### 6.1 The cardinal rule **DECIDED**

**Operator actions are persistent states, never instantaneous impulses.**

- ✅ **Good:** a gate that takes ~300ms to slide open; a wall that holds a raised position;
  a ramp that lifts; a magnet that grabs for a forgiving ~400ms window; a spinner you
  charge up; a post that stays extended.
- ❌ **Bad:** anything decided at a precise contact moment — a snapping flipper, a kicker
  fired on impact, a one-frame bumper.

Two reasons. First, it makes operator play *readable* — you can see what your partner did
and is doing, which is what allows the flipper to plan around it. Second, it's the single
constraint that makes online play viable later, at zero cost today. A remote flipper would
be unshippable over a network; a remote **paddle that holds a raised position** has the
same tactical feel at ~200ms granularity and is completely lag-proof.

### 6.2 Every operator action is a trade **DECIDED**

If opening the gate is always correct, the operator is a button-presser. Each device
should give and take:

- The gate that opens the jackpot ramp **closes the safe return lane.**
- The magnet that saves the ball **kills the combo timer.**
- The wall that guards the outlane **blocks a scoring shot.**
- Raising the paddle **opens the lane underneath it.**

This is what forces the talking. The operator has to announce, and the flipper has to trust.

**OPEN:** Do operator actions cost a resource? Proposal for v1: per-device cooldowns, no
shared meter. Simpler to read, and the trade-offs above already provide the restraint.
*Answered for one device — see §6.3, which is on a cooldown and nothing else is.*

### 6.3 The outlane guard, as built **PROVISIONAL (2026-09-06)**

The third bullet above, built. Each board has **one** barrier across the mouth of an
outlane, and it is on the left lane or the right lane, never both. The operator switches
it with **either flipper button** — the two controls their role otherwise leaves them
nothing to do with — and the swap takes `GUARD_TRAVEL` (300ms), during which *neither*
lane is sealed.

It bumps rather than blocks: restitution 1.30, tilted inward-and-down, so a ball that was
about to be lost is thrown back across the playfield and scores `SCORE_GUARD`. A guard
that merely stopped the ball would hand it straight back to the same drain.

**It is good for one save per ball.** The contact spends it: the bar retracts and both
outlanes are live for `GUARD_COOLDOWN` (30s) before it comes back. The cooldown is longer
than a ball lives (5–15s) *on purpose* — that is what makes it one save and not a lane the
operator opens and closes at will — and it **clears the moment the ball is lost**, on both
boards, so the ball that pays for a save is the ball that spent it. Charging a save near
the end of one ball against the start of the next two would be a cost the player who spent
it does not pay.

A **rescue** (§8) does not clear it: the ball was never lost, so it keeps the rally *and*
keeps the guard spent. You do not get a fresh save for nearly dropping it. Neither does a
pass — a crossing is not a ball loss, and the cooldown follows the board across the rally.

This is the §6.2 OPEN question above, answered for this one device. The side stays
switchable while it recharges, because choosing where the next save happens is the only
decision left; the board draws an empty outline filling on that lane so the choice is
visible before it matters.

Measured (`tests/probe_guard.lua`), 40 balls dropped into each lane:

```
  lane                escaped   drained   parked   guard hits/ball
  guarded                  40         0        0              1.00
  unguarded                 5        34        0              0.00
```

One contact per save, no rattling, and nothing ever parks in the lane. The trade is
real: guarding one side leaves the other at ~86% drain, and a spent guard leaves *both*
sides at that number until it recharges.

The **side is a genuine decision**, which is the part that was not designed. Whole-board
random play, 96 balls a cell, drains/s:

```
  board       ball from      guard left   guard right   no guard
  Foundry     the plunger        0.0755        0.0766     0.0951
  Foundry     the tube           0.0860        0.0680     0.0761
  Glasshouse  the plunger        0.0537        0.1619     0.1792
  Glasshouse  the tube           0.1267        0.1142     0.1270
```

No board has a side that is right in both columns, so the operator has to know both the
board and where the ball came in. Glasshouse's enormous plunger-column bias is mostly an
artifact of its plunger sitting a ball's width from the left lane, which is why the two
starts are reported separately and not averaged.

**What the cooldown costs**, same runs with and without the rule. `armed` is the share of
ball time the bar was actually in its lane:

```
  board       ball from      guard   armed   drains/s   if it never ran out
  Foundry     the plunger     left     85%     0.0812                0.0816
  Foundry     the plunger     right    81%     0.0770                0.0671
  Foundry     the tube        left     87%     0.0857                0.0884
  Foundry     the tube        right    80%     0.0858                0.0779
  Glasshouse  the plunger     left      7%     0.1156                0.0994
  Glasshouse  the plunger     right    93%     0.1764                0.1754
  Glasshouse  the tube        left     89%     0.1197                0.1326
  Glasshouse  the tube        right    90%     0.1210                0.0985
```

30s against a 5–15s ball reads like a device that is absent most of the time. Measured, it
is armed **80–93%** of ball time under random play, because the bar is only spent when a
ball actually goes down the lane it is standing in — uncommon — and because the loss reset
hands it back with every new ball. It is one save you have to time, not a device that
disappears. (Without the reset the same runs measure 61–76%, so the reset is worth roughly
a fifth of the guard's presence.)

The 7% cell is the exception, and it is the plunger again: Glasshouse serves a ball's
width from its left lane, and the served ball drops straight back into it. That guard is
spent inside the first second of nearly every ball, which is also why the loss reset does
nothing for it — it just gets spent again immediately. It is still a genuine save (0.1792
→ 0.1156 drains/s), but it is a save the board makes for you rather than one the operator
places.

**OPEN, and now sharper.** Glasshouse's outlanes are barely where a tube-arrival dies, and
its plunger eats the left guard before the ball is properly in play — the one thing the
loss reset cannot help, because the spend happens on the new ball too. Either the guard
moves on that board, the plunger does, or Glasshouse is simply not a board the guard is
for.

## 7. Boards **DECIDED**

The two boards are **different, and interconnected by state**. Not mirrors.

- Each player has a home board they'll learn deeply. Passing means handing the ball to the
  person whose board suits what you're trying to do.
- **Cross-board state:** completing something on board A arms something on board B. You
  play A to prepare B, then pass and cash in — which arms A again.
- **The dormant board keeps its state.** Your unlocks sit there waiting. Arriving on a
  board you prepared should feel like coming home to something.
- The dormant board is shown as a small panel that lights up when cross-board state
  changes, so you always know what you've built up over there.

**PROVISIONAL (2026-09-06):** Board identities/themes, and what each is *good at*.

**Foundry is where a rally survives. Glasshouse is where it pays.**

| | Foundry | Glasshouse |
|---|---|---|
| Character | chaotic, forgiving, cheap | clean, precise, expensive |
| Content | a five-bumper nest across the top | two target banks, four standups |
| Drain gap | 27.6px | 43.6px |
| Mean ball life | 10.76s | 5.40s |
| Drains per second | 0.0666 | 0.1543 |
| Pass rate from a swept flip | 50% | 50% |
| Pass rate from a *received* ball | 32% | 62% |
| **Points per second** | **14** | **242** |

That puts §6.2's trade — "the safe thing for me or the good thing for you" — one level
up, onto the pass itself: do I keep the rally alive, or send it somewhere it can
actually score? And because §9 makes a hot rally worth more, the temptation to cash in
on Glasshouse grows at exactly the rate the cost of losing it does.

Glasshouse pays roughly 17× per second of ball time and kills the ball 2.3× as fast.
Neither number was chosen; both fell out of giving each board content its own shape can
actually deliver to the ball.

> **Re-measured 2026-09-06 on the boards-v2 layout** (448×960, outlanes, slingshots,
> short ramps — see `docs/boards-v2.md`). The two boards diverged, which is the point:
> Glasshouse used to drain only 7% faster than Foundry despite a 16px wider flipper
> gap, so the identity was a claim more than a fact. It now drains 2.3× faster.
>
> Foundry barely moved (12.19s → 10.76s a ball) and is actually *safer* per second
> than before despite gaining two outlanes, because its bumper nest keeps the ball up
> the board. Glasshouse lost nearly half its ball life, 9.86s → 5.40s: a wider flipper
> gap also means a longer unguarded run down each side, so outlanes cost it far more.
>
> Whether 5.40s a ball is *too* short is open, and the knob is outlane width.
> `docs/boards-v2.md` §8 flags it as the first thing to tune.
>
> The points-per-second figures moved partly because `probe_identity` was wrong: it
> treated every target on a board as one bank and cleared the lit set at the start of
> each ball, where `core/state.lua` completes per bank and keeps lit state for the
> life of the match. Accurate while Glasshouse had two targets in one bank, silently
> wrong the moment it had four in two — it reported one completion where the rules
> produce twenty-one. Fixed, and this table is measured after the fix.

**Was open underneath this, and is now partly answered:** the two boards differ in what
they are *for*, and as of boards-v2 also in how they are *played* — Foundry's pass is
the left flipper's shot and Glasshouse's is the right flipper's, and the reach maps put
Foundry's traffic up the left orbit against Glasshouse's down the middle-left. What is
still missing is a *skill* one board rewards and the other punishes.

### 7.1 The cross-board loop, as built **PROVISIONAL (2026-09-06)**

The §7 hook, concretely:

```
  Foundry bumpers  ──charge──▶  Glasshouse vault
        ▲                              │
        │                          clear it
     lit x5                            │
        └──────────arms────────────────┘
```

1. **Grind Foundry.** Each bumper hit charges Glasshouse's vault, up to ×10. At the
   measured 0.6 hits/s that fills in ~17 seconds.
2. **Pass.** Past the cap, Foundry pays only its own 24 points/s — the cap is what
   makes the pass the only way to cash, which is §5's "tempting, not compulsory"
   resolved in the direction that keeps the tube a decision.
3. **Clear the vault.** The bank bonus is multiplied by everything Foundry built, so a
   full vault pays many times a cold one.
4. **Which arms Foundry again** — its bumpers light for 12 hits at ×5, and those hits
   recharge the vault. The loop closes.

Neither board can run this alone, which is what makes the pass structural rather than
optional. The wiring lives in the board data (`links`), not in the rules, so a new
cross-board relationship is a table entry rather than a branch — and `core/validate.lua`
rejects a link naming a board, meter or target that does not exist, because a typo here
would be a mechanic that silently never fires.

## 8. Failure and rescue **DECIDED**

- **Shared ball pool.** Team lives, not per-player. Pinball is random enough that
  per-player lives just manufacture blame.
- **Purgatory rescue.** A ball that drains doesn't die immediately — it enters a brief
  purgatory, and the *partner* can rescue it back into play by hitting a save shot within a
  few seconds. My mistake becomes your chance to be a hero, which is the best feeling co-op
  can produce.

**PROVISIONAL (2026-09-06):** Rescue window length, and whether the rescue is on the
drained board or the partner board. **Built as: 1.9s, on the drained board, using the
post the operator already has.**

- **The post is the rescue.** No new device and no new binding: the operator raises the
  same post they use to guard. It cannot have been up already — a raised post stops
  100% of drains, so if the ball drained, the post was down. Reaching for it is
  therefore always a real action taken inside the window.
- **1.9s**, which has to clear the post's own 0.26s of travel with room to spare or the
  rescue is a reflex test rather than the decision §8 describes.
- **The rally survives.** Relay count, rally score and the drain counter are all
  untouched until the window actually expires. That is the point: what the two of them
  built is not thrown away by one bad bounce.
- **It costs every vault charge on both boards** (§7.1). Without a cost, rescuing is
  always correct and the operator is a button-presser again (§6.2). With one, the
  question is live and has to be answered in under two seconds while being shouted at:
  *keep the rally, or keep the preparation?*

Shared ball pool and team lives are **still not built** — a failed rescue simply
re-serves, as before. That waits on session structure (§13.2).

## 9. Scoring

The multiplier lives on **passing**, not on shots. **DECIDED**

- **Relay heat. BUILT 2026-09-06.** A ball relayed back and forth without draining gets
  hotter with each crossing — worth more, and moving faster. The multiplier *is* the
  crossing count, so ×7 means "we have passed seven times without dropping it": a
  ten-crossing rally is worth 55,000 against 10,000 for the same ten passes spread over
  ten drains, 5.5×. "Moving faster" is a separate and much gentler curve, +5% arrival
  speed per crossing to +55%, because speed is a difficulty knob and a tunneling risk
  where score is free.
- **Simultaneity objectives** for the big jackpots: both boards holding a state at once,
  or matching shots within a window. Shots you cannot make alone. **Not built.**
- **Home-grind lines. BUILT, as the vault cap.** Foundry's bumpers charge Glasshouse's
  vault (§7.1) at ~0.6 hits/s to a ceiling of ×10, so staying home pays for about 17
  seconds and then stops. That is what makes the pass the only way to cash without
  making it compulsory — §5's temptation rule expressed as a number rather than a hope.

**OPEN:** Session structure. Endless high-score run? A goal-based run with an ending?
Roguelite meta between runs (drafting board segments)? This determines a lot of scaffolding
and should be answered before scoring is tuned.

> **That sequencing was not followed, and it is worth knowing.** The scoring above was
> built on 2026-09-06 while this question was still open, which means it assumes an
> endless session throughout: nothing resets, nothing ends, and `best_rally_score` is
> the only number that behaves like a result. Deciding on team lives or a run length
> will likely require revisiting the curve — a rally worth 5.5× more is a very
> different proposition when you have three balls than when you have infinite ones.
>
> It was built anyway because "it works but it isn't fun" needed answering and a score
> was the cheapest part of that. But the doc warned about exactly this ordering, so the
> debt is recorded rather than discovered later.

## 10. Presentation

All four are **built as of 2026-09-06**; the notes say how.

- **One shared camera on the active board.** Because both players are always attending to
  the same board, we need no split screen and make no compromise on framing. This falls out
  of the one-ball decision and is a large part of why it's the right call.
- **Dormant board as a live side panel**, small, with change highlights. The panel
  outlines itself when its cross-board state moves (§7.1), so a charge landing on the
  board nobody is watching is visible on that board.
- **Tube transit gets its own beat** — both boards pull back, the ball arcs between them
  leaving a wake, and rings collapse onto the entry point it is heading for. The HUD
  stays up throughout, which it did not originally: hiding it was what made the beat
  read as dead air, since §4.5 hands the sender the destination board's devices for
  exactly those 800ms.
- **Audio does the warning work.** Thirteen synthesized voices, no asset files. Incoming
  ball, operator devices arming, the purgatory window, and relay heat pitching the whole
  kit up as the rally gets hotter. The drain sound deliberately does not play when the
  ball crosses the line — the ball may still be rescued, and saying otherwise would be
  a lie told 1.9 seconds early.

## 11. Designing for online, while shipping local

Local co-op is the target. But the following are cheap now and expensive to retrofit:

- The operator rule in §6.1 (persistent states, not impulses) is the whole ballgame. Keep
  it and online is a networking problem; break it and online is a redesign.
- Tube transit time (§5) is a real latency budget — ~750ms of slack at 100ms RTT.
- Never assume the two players share a screen *in the simulation*. Presentation may; game
  logic must not.

Note the structural consequence: because the operator inputs into the *active* board, we do
**not** get clean one-client-owns-the-ball handoff. Both players' inputs affect one
simulation continuously. That's exactly why §6.1 matters — it's what makes plain
host-authoritative netcode sufficient instead of needing something exotic.

## 12. Non-goals for v1

- Online play (architected for, not built)
- More than 2 players
- Multiball
- Roguelite / meta progression
- Table editor
- Tilt / nudge mechanics — **OPEN** whether these exist at all, and who owns them

## 13. Open questions, consolidated

1. ~~Board identities — what is each board *for*?~~ **PROVISIONAL, see §7**
2. Session structure — endless, goal-based, or run-based? (blocks scoring)
3. Tube count and directionality
4. Operator resource model — cooldowns only, or a meter?
5. ~~Rescue window mechanics~~ **PROVISIONAL, see §8**
6. Does nudge/tilt exist, and is it an operator power?

## 14. First prototype

Build the smallest thing that answers *"does the rally feel good?"*:

- Two crude boards, one ball, one screen, two keyboards/gamepads
- One tube each way, working transit animation
- Two operator devices per board (one gate, one paddle) with real trade-offs
- No scoring, no modes, no cross-board unlocks

If the rally is fun and the tube transit reads clearly, everything else in this document is
worth building. If it isn't, nothing else saves it.
