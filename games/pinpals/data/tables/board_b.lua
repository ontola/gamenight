-- Current layout: skyway feet at y=460; rollover lanes build relay jackpots.
-- Measurements in the historical design notes below describe earlier layouts.
-- See docs/gameplay-iteration.md for this revision and reproducible measurements.
--- Board B - "Glasshouse". Player 2's home board.
---
--- design.md §13.1 -- what is each board FOR? -- answered PROVISIONALLY here
--- and in docs/design.md. The short version: Foundry is where a rally
--- SURVIVES, Glasshouse is where it PAYS.
---
--- Re-measured on the boards-v2 layout (probe_identity + probe_reach):
---
---   Foundry     chaotic, forgiving, cheap. A five-bumper nest across the top
---               keeps the ball alive and crowds the aim. Ball life 10.76s,
---               14 points/s, swept pass 50%, drains 0.0666/s.
---   Glasshouse  clean, precise, expensive. No bumpers, two target banks, and
---               a drain gap 16px wider. Ball life 5.40s, 242 points/s,
---               swept pass 50%, drains 0.1543/s.
---
--- Glasshouse pays 17x per second of ball time and kills the ball 2.3x as
--- fast. That makes the pass the decision design.md §6.2 asks for,
--- one level up from the devices: do I keep the rally safe, or send it
--- somewhere it can actually score?
---
--- BOTH ROWS ARE STALE, and one of them is stale because of an edit below.
--- The same probe_identity run today reads:
---
---   Foundry     11.07s,   5 points/s, swept pass 50%, drains 0.0753/s
---   Glasshouse   6.95s, 271 points/s, swept pass 50%, drains 0.1272/s
---
--- Glasshouse moved because the plunger-lane target went (see `targets`):
--- it was 6.59s / 183 pts/s / 0.1113 before that edit, so the identity got
--- SHARPER, not softer -- still the deadlier board, and now the expensive one
--- by a wider margin. Foundry moved without anyone touching Foundry, and
--- 14 -> 5 points/s is not noise; nothing in this file explains it and the
--- "17x" above should not be quoted again until someone measures why.
---
--- The gap between the boards WIDENED when they grew. Glasshouse used to
--- drain only 7% faster than Foundry despite its wider gap, which made the
--- identity a claim more than a fact; the outlanes cost it far more than they
--- cost Foundry, because a wider flipper gap also means a longer unguarded
--- run down each side. That was not designed and it is worth keeping.
---
--- Both rows predate the outlane guards and were measured with neither
--- deployed, which is what tests/probe_identity.lua still does so the numbers
--- stay comparable. tests/probe_guard.lua measures the guard on its own.
---
--- Deliberately not a mirror of A (design.md §7): the handedness is flipped so
--- the two boards read differently at a glance, but the upper field differs in
--- kind, not just in layout.
---
--- Grown to 448 x 960 in boards-v2 phase 0. x shifts +32 everywhere; y shifts
--- +192 for the flipper furniture only, so the ramp mouth ends up 340px above
--- the pivots instead of 148px and the new room lands in the approach rather
--- than above the arc. board_a.lua carries the full note, including the
--- version of this edit that did it the other way round and broke both
--- boards' upper content.

return {
  id   = "b",
  name = "Glasshouse",
  size = { w = 448, h = 960 },

  walls = {
    -- Outer shell: right wall, top arc, left wall.
    -- Outer shell: right wall, top arc, left wall. Both side walls run past
    -- the drain line -- they are the outer wall of an outlane.
    { 438,948,  438,90,  372,14,  76,14,  10,90,  10,948 },
    -- The traditional bottom, same construction as Foundry's -- see
    -- board_a.lua for what each chain is and why the outlanes matter. The
    -- inlane floors end further apart here because Glasshouse's flippers
    -- are, which is the board's whole identity.
    { 36, 700, 39, 810,
      { to = { 140, 873 }, c1 = { 40, 849 }, c2 = { 96, 862 } } },
    { 412, 700, 409, 810,
      { to = { 308, 873 }, c1 = { 408, 849 }, c2 = { 352, 862 } } },
    -- The pass ramp, left of centre: the right flipper's cross-body shot,
    -- where Foundry's is the left flipper's. Shortened to end at y=380 for
    -- the reason given at length in board_a.lua -- a long centre channel is a
    -- wall across the board, and it is why neither board's upper playfield
    -- was reachable.
    --
    --   swept shots        pass   drain   left orbit   right orbit
    --   old 384x768 board   66%     34%           6%          10%
    --   boards-v2           50%     44%          36%          30%
    --
    -- Glasshouse gave up 16 points of pass rate for a playfield with six
    -- times the reach. It is still the board you pass FROM by received-ball
    -- rate -- 62% against Foundry's 32% -- which is the number that decides
    -- whether a rally continues.
    --
    -- x=201 is reachable from both flippers (3 left / 6 right of 8 contact
    -- points swept). The right-flipper bias is the handedness: Foundry's ramp
    -- reads 5 left / 3 right at x=236.
    --
    { 148,560,  175,500,  175,380 },
    { 254,560,  227,500,  227,380 },
    -- Roof over the ramp head -- see board_a.lua for why this is not optional.
    { 175,380,  201,358,  227,380 },
    -- The deflector rail is gone. It survived two redesigns as "one rail left
    -- in the upper right, to feed the bank below it", and both times the bank
    -- it fed measured a dead target: a single sloping rail does not split a
    -- stream, it aims one. probe_where puts Glasshouse's falling traffic down
    -- the LEFT of the ramp, so the bank went there instead and the rail had
    -- nothing left to do.
  },

  bumpers = {},  -- none: chaos is Foundry's job

  -- Flush rollover switches add shots without blocking the orbit or return lanes.
  rollovers = {
    { x = 38, y = 330, w = 36, h = 26, label = "L" },
    { x = 410, y = 330, w = 36, h = 26, label = "R" },
    { x = 224, y = 690, w = 68, h = 26, label = "C" },
  },

  -- Tall, narrow slings leave a broad return lane behind their outer edge.
  slingshots = {
    { p = { 84, 714, 132, 806, 84, 814 } },
    { p = { 364, 714, 316, 806, 364, 814 } },
  },


  -- B's character, and the only aimed scoring content in the game. Placed
  -- along the line the lower rail used to occupy, which the reach map puts
  -- squarely in the right field a flipper shot can get to.
  --
  -- A bank: each target lights when struck, and lighting all three pays
  -- SCORE_BANK on top and resets them. Hitting a lit target still scores,
  -- but does not re-count -- otherwise the cheapest way to clear a bank is to
  -- rattle against one target.
  -- Spaced 50px along the rail line against a 28px width, so the gaps are
  -- 22px -- wider than the 17.3px ball. The first draft used 34px targets
  -- 33px apart, which overlapped into a single bar on screen and formed
  -- throats between them in the physics. core/geometry.lua now has a
  -- target-to-target wedge check because of it.
  -- A TWO-target bank, not three, and that is measured rather than tidy.
  -- The rail above splits the falling ball into two streams, at roughly
  -- x=244 and x=336, with nothing coming down the middle. A three-target row
  -- across that span puts its middle at x=290 -- geometry forbids closer,
  -- since the gaps must clear a 17.3px ball -- and there it took 4 hits
  -- against its neighbours' 50 and 52. A bank whose middle target is
  -- unreachable is a bank that never completes, which is worse than no bank:
  -- it is a mechanic that visibly exists and silently cannot be finished.
  --
  -- Trying to feed the middle by moving the rail produced the other failure
  -- mode: at (214,250)-(296,318) the distribution balanced beautifully at
  -- 18/24/12 and the board became a ball trap -- mean ball life 30.00s, the
  -- probe's timeout, with a drain rate of exactly zero. The ball rattled in
  -- the bank forever. Balance is not worth a board the ball cannot leave.
  -- B's character, and the aimed scoring content in the game.
  --
  -- A bank: each target lights when struck, and lighting all of them pays
  -- SCORE_BANK on top -- multiplied by everything Foundry charged into the
  -- vault meter (§7.1) -- and resets them. Hitting a lit target still scores
  -- but does not re-count, or the cheapest way to clear a bank is to rattle
  -- against one target.
  --
  -- Placed against measured streams, which took three attempts and one
  -- outright failure. probe_where puts Glasshouse's falling traffic in a
  -- narrow left column around x=80-110 and a broad right stream from x=240
  -- to 400. A row only survives across the broad one:
  --
  --   position          hits per 720s of play
  --   ( 56,470)   left column          154
  --   (124,470)   left column, wide     13   <- dropped
  --   (300,480)   right stream          25
  --   (352,480)   right stream          27
  --   (404,480)   right stream          32
  --
  -- The 12:1 split between the two left-column targets is what made the bank
  -- stop completing: with those two as the whole vault it cleared 16 times in
  -- a probe run, and adding a second bank next to them dropped it to ZERO.
  -- A bank whose slowest member is twelve times slower than its fastest is a
  -- mechanic that visibly exists and effectively cannot be finished -- the
  -- same failure this board shipped once before with a middle target nothing
  -- could reach, arrived at from the opposite direction.
  --
  -- So the wide left target is gone, and the bank is the balanced right-hand
  -- row plus the live left one. Four targets, none of them scenery, and it
  -- fills the right half of the board that used to be empty.
  -- TWO banks, and which targets belong to which is the whole decision.
  --
  -- The vault is the §7.1 cross-board loop: Foundry charges it, clearing it
  -- arms Foundry again, and if it does not clear regularly the loop is a
  -- diagram rather than a mechanic. So the vault gets the two targets that
  -- measure IDENTICAL -- 28 hits each -- because a bank completes at the rate
  -- of its slowest member and nothing else.
  --
  -- A four-target vault was tried and is the cautionary version: every target
  -- live, 19 completions in a raw 720s probe, and exactly ONE in a real match
  -- run. Glasshouse's ball lives 5.4s, so a bank needing four separate
  -- targets spans a dozen balls, and the ball is usually on the other board.
  -- Points per second went 192 -> 87 on that alone.
  --
  -- The gallery is the consolation bank: it pays on its own and charges
  -- nothing across the tube, so its members can be unbalanced without
  -- breaking anything.
  --
  -- EVERY hit count above is void, and so is the reasoning built on it. The
  -- gallery's left member used to stand at (56,470), which is DIRECTLY ABOVE
  -- THE PLUNGER at (48,660): the board serves straight up that lane, so the
  -- target was the backboard the serve hit. tests/probe_serve.lua now splits
  -- target hits by whether they landed within a second of the serve, and the
  -- split was total --
  --
  --   target        off the serve   in real play   (240 served balls)
  --   ( 56,470)               240              9
  --   (300,480)                 0             51
  --   (352,480)                 0             27
  --   (404,480)                 0             48
  --
  -- 240 of 240. Its "154 hits, the live one" was the plunger firing into it
  -- once per ball, and as content it was the DEADEST thing on the board. The
  -- 12:1 split that condemned (124,470) was measured the same way, against a
  -- number that was not a measurement of play at all.
  --
  -- What it cost was the rest of the board. The serve stopped 176px up, fell
  -- back down its own lane at x=48 -- a ball's width from the left outlane --
  -- and:
  --
  --                                     was     now
  --   serve apex y                      484      36   (tube mouth y=398)
  --   drained within 3s of the serve    26%      5%   (random flipper play)
  --   served balls that ever reached
  --     the tube mouth's height         19%    100%
  --   target hits per 60 balls          100     201   (probe_identity)
  --   bank completions per 60 balls      19      25
  --   points/s                          183     271
  --
  -- Eighty-one percent of Glasshouse's balls never got as high as the tube
  -- mouth. The skyway, the orbits and most of this target row were content on
  -- a board most balls never reached. Nothing about that was designed -- the
  -- plunger and the target arrived in the same commit and neither knew about
  -- the other. The board is MORE itself afterwards, not less: ball life 6.59
  -- -> 6.95s against Foundry's 11.07s, drains 0.1113 -> 0.1272/s against
  -- Foundry's 0.0753. Clean and deadly, and now also worth shooting.
  --
  -- One number moves the wrong way and it is not a regression in the ramp:
  -- the SERVED ball's pass rate falls 15% -> 5%. The broken serve was
  -- dropping every ball onto the LEFT flipper, which the post table below
  -- shows is Glasshouse's stronger passer (75% against the right's 63%), so
  -- the old rate was a gift and not a property of the board. Measured from
  -- the flipper instead of from the plunger nothing moved: the swept-shot
  -- pass rate is 50% before and after, and the received-ball pass gate in
  -- tests/sim/spec.lua still passes. Foundry serves to the top of the board
  -- too and passes 22% of served balls, so 5% is worth a look on its own --
  -- but it is a question about the ramp and the gate, not about the plunger.
  --
  -- WHERE the target went, and why not anywhere nearer. With the lane clear
  -- the serve rides the top arc and comes down at x=371 (was x=48), so the
  -- left column is now fed by nothing at all: x=100/124/140 measure 0, 5 and
  -- 4 hits per 240 balls, because that column is behind the skyway's left leg
  -- and the ball does not fall there. The obvious slot -- in the row, between
  -- the ramp channel's right wall (x=227) and the vault's left member (left
  -- edge 286) -- is a 59px gap that needs 28 + 2 x 17.3 = 62.6px, so it fits
  -- only a 22px target, and a 22px target at (256,480) took the received-ball
  -- pass rate from over 30% to 13%: it stands exactly where a ball falling
  -- toward the flippers has to get through. (256,620) is worse, on the right
  -- flipper's cross-body line to the ramp. So it went UP, to (256,250), in
  -- the upper field the serve fix just made reachable -- 57 hits per 240
  -- balls against the old position's 9, clear of both pass lines, and with
  -- nothing above or below it (CLAUDE.md's stacking rule: the vault row
  -- occupies x=286..418, so a second row is only legal left of it).
  --
  -- And the vault's right member moved 480 -> 466, which is a stuck ball. The
  -- skyway's right foot generates a skirt whose top corner is at (327,499),
  -- and the geometry gate cleared it at 17.8px from that target's lower-left
  -- corner against a 17.3px ball -- half a pixel of margin, which is not a
  -- clearance, it is a notch. Nothing ever reached it while 81% of balls
  -- stayed below y=398; with the serve fixed the two-minute stall gate found
  -- a ball parked at (331,491) inside a hundred and twenty seconds. Raising
  -- the target 14px opens the notch to 30.5px. Moving it RIGHT instead (to
  -- x=358, 21.7px) still stalled, and moving the whole row up broke the pass
  -- shot -- this is the four-directions-at-once the ramp note warns about.
  targets = {
    { x = 300, y = 480, w = 28, h = 9, angle = 0, bank = "vault" },
    -- Above the shortened skyway foot so the right ramp remains shootable.
    { x = 352, y = 340, w = 28, h = 9, angle = 0, bank = "vault" },
    -- The gallery's second member, out of the plunger lane at last.
    { x = 256, y = 250, w = 28, h = 9, angle = 0, bank = "gallery" },
    { x = 398, y = 590, w = 28, h = 9, angle = -0.30, bank = "gallery" },
  },

  -- The outlane guards. Same numbers as Foundry's, because both bottoms are
  -- the same shape down the sides; board_a.lua says what each one is for and
  -- why every one of them is load-bearing.
  --
  -- They matter more here. Glasshouse's flipper gap is 16px wider, which also
  -- means a longer unguarded run down each side, and the outlanes cost it
  -- nearly half its ball life when they were added (5.40s against Foundry's
  -- 10.76s). This is the board where knowing which side your partner has
  -- covered is worth the most.
  guards = {
    start = "left",
    kick  = 1.30,
    { side = "left",  angle =  0.34, w = 30, h = 11,
      up = { x = 24,  y = 694 }, down = { x = 24,  y = 986 } },
    { side = "right", angle = -0.34, w = 30, h = 11,
      up = { x = 424, y = 694 }, down = { x = 424, y = 986 } },
  },

  flippers = {
    -- Wider gap than A. B drains.
    { side = "left",  x = 147, y = 880 },
    { side = "right", x = 301, y = 880 },
  },

  devices = {
    {
      id     = "post",
      kind   = "paddle",
      travel = 0.26,
      -- Lowered from y=676, which was ABOVE the flipper pivots at y=688 and
      -- therefore sat directly in the launch path. Measured, the old post was
      -- not a trade at all but a pause button: with it raised the pass rate
      -- was 0% AND the drain rate was 0%. Nothing could happen in either
      -- direction, which leaves the flipper player with nothing to do and
      -- nothing to fear -- pillar 1 ("nobody waits") and §6.2 ("every
      -- operator action is a trade") broken by the same 12 pixels.
      --
      -- At y=713 it sits below the pivots, where a draining ball still meets
      -- it but a shot leaving the flipper mostly clears it:
      --
      --   post y    Foundry pass   Glasshouse pass   drains stopped
      --      676              0%                0%             100%
      --      711              8%               15%             100%
      --      713             40%               31%             100%   <- here
      --      715             73%               60%             100%
      --      726             58%               69%             100%
      --   (down)             58%               69%              32%
      --
      -- 726 is the opposite failure: a guard that costs nothing would simply
      -- be held up forever. 713 keeps 69% of Foundry's pass rate and 45% of
      -- Glasshouse's, so raising it is a decision rather than a reflex.
      --
      --
      -- The cost is sharply ASYMMETRIC, and that is the best thing about the
      -- device. Each board's ramp is off-centre, so the post mainly blocks
      -- whichever flipper has to shoot ACROSS the middle:
      --
      --                    left flipper   right flipper
      --   Foundry     down          58%             58%
      --   Foundry     UP            25%             54%
      --   Glasshouse  down          75%             63%
      --   Glasshouse  UP            54%              8%
      --
      -- So a raised post does not stop the pass, it moves it: you have to get
      -- the ball to the near flipper first. The flipper player has something
      -- to do while their partner guards, which is what pillar 1 asks for,
      -- and the two boards are blocked on opposite sides so the skill does
      -- not transfer. None of this was designed -- it fell out of the ramps
      -- being on opposite sides -- but it is worth keeping deliberately.
      --
      -- NOTE this is a steep slope -- roughly 16 percentage points of pass
      -- rate per pixel between 711 and 715 -- because the post is a flat bar
      -- and a shot either clears it or does not. Treat any edit to this
      -- number as a redesign of the device and re-run tests/probe_post.lua.
      -- Re-swept for boards-v3 phase 0, and it had to be: the bat grew from
      -- 48.6px to 64px, so the flipper's tip at rest dropped from 26.7px
      -- below the pivot to 31.8px, and the old y=905 was suddenly ABOVE the
      -- ball sitting on the flipper rather than below it. Measured, that made
      -- the post an absolute block again -- 0/28 passes with it up -- which is
      -- the exact failure the sweep below was built to avoid.
      --
      -- 912 is 32px under the pivots, which puts it level with the tip at
      -- rest, the same relationship the old 905 had to the old bat. The band
      -- is as steep as it ever was, ~10 points of pass rate per pixel:
      --
      --   post y   Foundry pass   Glasshouse pass   drains stopped
      --      909            18%               14%             100%
      --      911            39%               21%             100%
      --      912            50%               29%             100%   <- here
      --      913            54%               36%             100%
      --      914            71%               54%             100%
      --   (down)           71%               71%               0%
      --
      -- 914 and up is the plateau where the post costs nothing; 909 and below
      -- is the pause button. 912 keeps 70% of Foundry's pass rate and 41% of
      -- Glasshouse's, which is within a point of what y=905 kept before the
      -- bat grew (69% / 45%). Re-run tests/probe_post.lua after any edit.
      up     = { x = 224, y = 912 },
      down   = { x = 224, y = 982 },
      w = 52, h = 12,
      tradeoff = "Guards the centre drain; the pass gets much harder.",
      label_closed = "OPEN",
      label_open   = "GUARD",
    },
  },


  -- The skyway. board_a.lua carries the note on what this ramp is, what it
  -- costs to shoot, and why a ramp FOOT is a solid block rather than a mark
  -- on the floor.
  --
  -- The right foot is at x=353 where Foundry's is at 347, and that 6px is the
  -- reason the two boards no longer carry the same loop. Glasshouse's vault
  -- targets sit at x=286..314 and x=338..366, and the topmost corner of the
  -- foot's skirt has to thread the 24px gap between them: anywhere outside
  -- x=324..328 and the skirt is within a ball's width of a standup. Foundry's
  -- window is set by wall 5's tip instead, and the two do not overlap.
  --
  -- Glasshouse has no bumpers for the skyway to cross, but the elevated part
  -- of it runs directly over the vault target at (352,466), which stays
  -- reachable underneath -- the whole point of an elevated lane, and the one
  -- thing CLAUDE.md's stacking rule could not previously allow.
  ramps = {
    {
      id          = "skyway",
      path        = { 94, 460,
                      94, 190, { round = 110 },
                      354, 190, { round = 110 },
                      354, 460 },
      width       = 54,
      height      = 30,
      entry_slope = 0.58,
      exit_slope  = 0.58,
      enter       = "both",
    },
  },

  -- §7 Cross-board state, the return half. Clearing the vault cashes the
  -- charge Foundry built, and lights Foundry's bumpers on the way back -- so
  -- arriving on a board you prepared feels like coming home to something.
  -- The loop only closes if both players keep passing.
  links = {
    { when = "bank:vault", lights = { board = "a", what = "bumpers" } },
  },

  tube  = { mouth = { x = 201, y = 398, r = 14 }, to = "a" },
  entry = { x = 370, y = 104, dir = { x = -0.32, y = 1 } },
  -- Straight up the left lane, and for a long time straight into a standup
  -- target parked on top of it -- `targets` has the measurement and the fix.
  -- Nothing may stand in x=39..57 above this point: at double serve jitter
  -- the ball crosses y=470 anywhere in x=39..56, plus its own 8.65px radius.
  serve = { x = 48,  y = 660, dir = { x = 0, y = -1 } },

  drain_y = 940,
}
