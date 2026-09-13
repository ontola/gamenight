-- Current layout: skyway feet at y=460; rollover lanes build relay jackpots.
-- Measurements in the historical design notes below describe earlier layouts.
-- See docs/gameplay-iteration.md for this revision and reproducible measurements.
--- Board A - "Foundry". Player 1's home board.
---
--- Character: chaotic and forgiving, and as of this edit that is measured
--- rather than asserted. See board_b.lua for the answer to design.md §13.1 in
--- full; the half that lives here is "Foundry is where a rally SURVIVES".
---
--- Re-measured on the boards-v2 layout (tests/probe_identity.lua, 2026-09-06):
---
---   board        gap   mean ball life   drains/s   survival   points/s
---   Foundry     27.6           10.76s     0.0666        26%         14
---   Glasshouse  43.6            5.40s     0.1543        17%        242
---
--- The ball lives twice as long here and pays a seventeenth as much. That is
--- the trade the pass is choosing between, and both halves of it got sharper
--- when the boards grew: Glasshouse now drains 2.3x as fast as Foundry, where
--- before it was only 7% faster and the identity was a claim rather than a
--- fact.
---
--- Foundry is barely changed on ball life (12.19s -> 10.76s) and is actually
--- SAFER per second than before (0.0725 -> 0.0666 drains/s) despite gaining
--- two outlanes, because the five-bumper nest keeps the ball up the board.
--- Glasshouse lost nearly half its ball life (9.86s -> 5.40s): a wider flipper
--- gap also means a longer unguarded run down each side, so the outlanes cost
--- it far more. That was not designed and it is worth keeping.
---
--- Both rows were measured with NO outlane guard deployed, which is what
--- tests/probe_identity.lua still does: the guard came later and every probe
--- keeps the old default so the numbers above stay comparable. What the guard
--- costs and saves is measured separately, in tests/probe_guard.lua.
---
--- Coordinates are world pixels (core/constants.lua: 64 px = 1 m), y down,
--- origin at the board's top-left. Playfield is 448 x 960.
---
--- Grown from 384 x 768 in boards-v2 phase 0. Nothing is stretched: every
--- shape keeps its exact dimensions and only moves. x shifts +32 everywhere,
--- so the board is 64px wider with the shell further out. y shifts +192 for
--- the flipper furniture ONLY -- flippers, post, lower wall chains, serve,
--- drain line -- while the ramp, the bumpers, the gate, the tube and the top
--- arc stay exactly where they were.
---
--- That is where the 192px goes, and it is the whole point of the resize: the
--- ramp mouth was 148px above the flipper pivots, which is what made the ramp
--- feel like it was sitting on top of them, and is also why a flipper shot
--- could never travel far enough sideways to get past the channel. It is now
--- 340px above. See docs/boards-v2.md §1 for the reach map that says so.
---
--- The first attempt put the room at the top instead, translating everything
--- below the arc by +192. That lengthened the orbit climb by 192px and made
--- bumper 1 and Glasshouse's whole bank unreachable -- the existing
--- reachability tests caught it. Worth recording: there is no such thing as a
--- neutral resize here, only a choice about where the new room goes.

return {
  id         = "a",
  name       = "Foundry",
  size       = { w = 448, h = 960 },

  -- Static geometry. Each entry is a polyline: a flat list of x,y pairs.
  walls      = {
    -- Outer shell: left wall, top arc, right wall.
    -- Outer shell: left wall, top arc, right wall. Both side walls now run
    -- past the drain line: they are the outer wall of an outlane, and an
    -- outlane that stops above the drain is a shelf.
    { 10,  948, 10,  90,  76,  14, 372, 14, 438, 90, 438, 948 },
    -- The traditional bottom (docs/boards-v2.md §3). Down each side, in order
    -- from the outer wall: an OUTLANE that drains, a lane divider, an INLANE
    -- that feeds the flipper, and a slingshot above it. Before this the ball
    -- simply funnelled down one chain into the flipper and the sides of the
    -- board did nothing.
    --
    -- The outlanes are the point of the exercise. They give each board a
    -- second and third way to lose the ball, which the post cannot guard --
    -- and a post that stopped 100% of drains was a guard costing nothing,
    -- which board_a.lua's own note worried about. It also means a ball lost
    -- down the side cannot be rescued (§8), so the rescue stops being a
    -- universal undo.
    --
    -- Each side is one chain: divider first, then the inlane floor, so the
    -- two cannot drift apart and leave a gap the ball falls through. The
    -- cubic rounds the bottom continuously into the flipper feed
    -- and ends 9.9px outside its pivot, the offset measured for the old
    -- lower-wall chains and kept for the same reason.
    { 36, 700, 39, 810,
      { to = { 148, 873 }, c1 = { 40, 849 }, c2 = { 104, 862 } } },
    { 412, 700, 409, 810,
      { to = { 300, 873 }, c1 = { 408, 849 }, c2 = { 344, 862 } } },
    -- The pass ramp. A short channel high on the board, not the 390px
    -- corridor that used to run from y=150 to y=540 through the dead centre.
    --
    -- That corridor was the single worst thing on either board, and it took a
    -- reach map to see it: 106px wide down the middle of a 384px board, it
    -- was a WALL a flipper shot could not travel far enough sideways to get
    -- past. Foundry measured 0% right-orbit reach and nothing at all above
    -- y=280 outside the channel. The upper playfield was never sparse; it was
    -- unreachable. docs/boards-v2.md §1 has the map.
    --
    -- Two changes, and the second is the one that mattered:
    --
    --   * the mouth is now 320px above the flipper pivots instead of 148px,
    --     which is what "the ramp is too close to the flippers" asked for;
    --   * the channel ENDS at y=380 instead of y=150, so the whole top third
    --     of the board is open field rather than two rails.
    --
    -- Raising the mouth alone made the pass unmakeable -- 0 of 8 from the
    -- right flipper. Shortening the channel gave it all back and more, which
    -- is why the two are one edit and not two:
    --
    --   swept shots        pass   drain   left orbit   right orbit
    --   old 384x768 board   54%     44%          14%           0%
    --   tall mouth only     26%     64%          46%          32%
    --   and short channel   50%     28%          40%          30%   <- here
    --
    -- Same pass rate, drains cut by a third, and the orbits went from one
    -- working lane to two. tests/probe_ramp.lua is the sweep behind this.
    --
    -- x=236 is measured too, and it is the one number here with a cliff under
    -- it: the mouth has to be reachable from BOTH flippers, and it stops being
    -- so within about 24px either way.
    --
    --   ramp x   reachable from left / right flipper, of 8 contact points
    --      200            1 / 4
    --      212            4 / 5
    --      224            6 / 4
    --      236            5 / 3   <- here
    --      248            5 / 1
    --      272            6 / 0
    --
    { 183, 560, 210, 515, 210, 380 },
    { 289, 560, 262, 515, 262, 380 },
    -- Roof over the ramp head. Without it the closed gate is a shelf the ball
    -- lands on from the upper playfield and sits on forever; tilting the gate
    -- only moves the resting place into the corner against the wall. The peak
    -- sheds anything that lands on it, and it seals the ramp head so the only
    -- two outcomes are "through the mouth" or "back down the ramp".
    { 210, 380, 236, 358, 262, 380 },
  },

  -- Flush rollover switches add shots without blocking the orbit or return lanes.
  targets    = {
    { x = 151, y = 340, w = 28, h = 9, bank = "forge" },
    { x = 313, y = 340, w = 28, h = 9, bank = "forge" },
  },

  rollovers  = {
    { x = 38,  y = 330, w = 36, h = 26, label = "L" },
    { x = 410, y = 330, w = 36, h = 26, label = "R" },
    { x = 224, y = 690, w = 68, h = 26, label = "C" },
  },

  -- Tall, narrow slings leave a broad return lane behind their outer edge.
  slingshots = {
    { p = { 84, 714, 140, 806, 84, 814 } },
    { p = { 364, 714, 308, 806, 364, 814 } },
  },

  -- A's character: a bumper cluster. Chaotic, keeps the ball alive.
  -- Downward-pointing triangle: two upper bumpers feed a lower centre.
  bumpers    = {
    { x = 224, y = 210, r = 22, restitution = 1.15 }, -- bottom
    { x = 157, y = 112, r = 22, restitution = 1.15 }, -- upper left
    { x = 292, y = 112, r = 22, restitution = 1.15 }, -- upper right
  },

  -- §6.2 "the wall that guards the outlane", and the answer to the outlanes
  -- being the one way to lose the ball that nothing could stop.
  --
  -- ONE barrier with two possible homes. It seals the left outlane or the
  -- right one, never both, and the OPERATOR moves it with either flipper
  -- button -- the two controls their role otherwise leaves them nothing to do
  -- with. So while the flipper player is busy keeping the ball alive, their
  -- partner is choosing which side of the board is safe, out loud, and being
  -- wrong about it in public.
  --
  -- It is a BUMPER, not a wall: kick > 1, so a ball that was about to be lost
  -- is thrown back up the lane and across the playfield rather than dribbling
  -- out of a dead end. A guard that merely stops the ball would hand it
  -- straight back to the same drain.
  --
  -- And it is good for exactly ONE save per ball. The contact spends it and
  -- the bar is gone for GUARD_COOLDOWN seconds -- longer than a ball lives,
  -- so this is not a lane the operator closes, it is a save they decide when
  -- to spend -- and losing the ball hands it back. Choosing where it comes
  -- back is the only decision left to them while it recharges, which is why
  -- the renderer draws an empty outline filling up on the lane it will
  -- return to.
  --
  -- Every number below is load-bearing and core/geometry.lua checks each:
  --
  --   * It sits at the MOUTH of the lane, level with the divider's top
  --     vertex, not down inside it. A bar across a 29px shaft is a shelf the
  --     ball comes to rest on; at the mouth it is a deflector with the whole
  --     playfield to throw the ball back into.
  --   * It tilts INWARD-AND-DOWN -- +0.34 rad on the left, -0.34 on the right
  --     -- so the kick and the roll agree. A fast ball is reflected up and
  --     inward off the face; a ball too slow for Box2D to apply restitution
  --     to at all rolls down the same slope and off the inner end onto the
  --     lane divider, which feeds the inlane. Tilt it the other way and both
  --     of those go outward, into a pocket against the shell.
  --   * Both ends overlap what they meet -- the shell at x=10, the divider at
  --     x=36 -- because a guard that leaves a ball's width of gap is a guard
  --     the ball goes around. They are kinematic against static bodies, which
  --     Box2D never collides, so the overlap costs nothing.
  --   * Retracted it parks below the drain line and off the playfield, the
  --     way the post does, and the renderer's scissor hides it there.
  --
  -- Both boards carry the same numbers because both bottoms are the same
  -- shape; see board_b.lua, which points back here.
  guards     = {
    start = "left", -- arbitrary: the first toggle is a second into play
    kick  = 1.30,
    {
      side = "left",
      angle = 0.34,
      w = 30,
      h = 11,
      up = { x = 24, y = 694 },
      down = { x = 24, y = 986 }
    },
    {
      side = "right",
      angle = -0.34,
      w = 30,
      h = 11,
      up = { x = 424, y = 694 },
      down = { x = 424, y = 986 }
    },
  },

  -- The drain gap is 27.6px, 16px narrower than Glasshouse's, and it is the
  -- whole of Foundry's identity: the board that was documented as forgiving
  -- once measured as the deadlier of the two, which is a bug rather than a
  -- character. It is now forgiving by the numbers in the header.
  --
  -- The gap survived the move to 448x960 unchanged, because the pivots moved
  -- together with everything else. The sweep that chose it (33.6 / 27.6 /
  -- 21.6px) was run on the old board and is not repeated here: 21.6px against
  -- a 17.3px ball barely drained at all, which is a wall, not a board.
  flippers   = {
    { side = "left",  x = 155, y = 880 },
    { side = "right", x = 293, y = 880 },
  },

  -- §6.1: both devices are persistent states with a visible travel time.
  -- §6.2: both give and take.
  devices    = {
    {
      id           = "post",
      kind         = "paddle",
      travel       = 0.26,
      -- The post sits BELOW the flipper pivots, where a draining ball still
      -- meets it but a shot leaving the flipper mostly clears it. Above them
      -- it was not a trade at all but a pause button: pass rate 0% AND drain
      -- rate 0%, which leaves the flipper player with nothing to do and
      -- nothing to fear -- pillar 1 and §6.2 broken by the same 12 pixels.
      --
      -- The sweep that picked the offset (711 / 713 / 715 on the old board,
      -- roughly 16 percentage points of pass rate per pixel) is not carried
      -- forward: those are pre-resize coordinates and the geometry under them
      -- has changed. The offset from the pivots is preserved at 25px, and it
      -- is still a steep slope, so treat any edit to it as a redesign of the
      -- device and re-run tests/probe_post.lua.
      --
      -- What HAS changed, and changed the device's meaning: the post no
      -- longer guards the only drain. Each board now has two outlanes it
      -- cannot reach, so a raised post stops the centre and nothing else. It
      -- was previously a 100% guard, which is a guard costing nothing, and
      -- §8's rescue rode on top of that -- a ball lost down an outlane cannot
      -- be rescued at all now. Both effects are intended and both still need
      -- re-measuring against tests/probe_post.lua.
      --
      -- The asymmetry is still the best thing about it: each board's ramp is
      -- off-centre, so the post mainly blocks whichever flipper has to shoot
      -- ACROSS the middle, and the two boards are blocked on opposite sides
      -- so the skill does not transfer.
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
      up           = { x = 224, y = 912 }, -- extended: spans the drain gap
      down         = { x = 224, y = 982 }, -- retracted below the playfield
      w            = 52,
      h            = 12,
      tradeoff     = "Guards the centre drain; the pass gets much harder.",
      label_closed = "OPEN",
      label_open   = "GUARD",
    },
  },


  -- The skyway: the first elevated ramp on either board, and the thing that
  -- makes "elevated" mean something. It leaves the left orbit at (94,570),
  -- climbs, crosses the board over the west and east bumpers -- which stay
  -- live underneath it -- and comes back down into the right orbit at
  -- (347,570). Shootable from either end.
  --
  -- Where the feet go was not a choice, it was what survived. A ramp foot is
  -- a SOLID structure (core/ramp.lua's skirt): where the lane is still too
  -- low for a ball to duck under, its sides are walls and a slanted wall
  -- closes the lane between them. That makes a foot a 54 x 71px block sitting
  -- in a lane, and both boards are nearly full at the height a foot needs.
  -- Four separate constraints closed in on these numbers:
  --
  --   * y=570 is as high as the feet can go. Below that the mouths are too
  --     close to the flippers for a shot to have spread out sideways enough
  --     to find them -- the same 300px the pass ramp's own note records --
  --     and swept shots reaching the mouth fall off a cliff: 10/140 at y=570,
  --     2/140 at y=595, 0/140 at y=620.
  --   * ...and as low as they can go on Glasshouse, whose target row sits at
  --     y=476..485. A foot any lower puts its skirt inside the bank.
  --   * x=94 clears Glasshouse's plunger lane (it serves up x=48) and stays
  --     left of its ramp channel. At 56 the foot sat ON that lane and every
  --     serve went up the ramp at 1050px/s.
  --   * x=347 is the one that had to give. Foundry and Glasshouse want
  --     DIFFERENT right feet -- 347 here, 353 there -- because Foundry's
  --     lower-right is bounded by wall 5's tip at (289,560) and Glasshouse's
  --     by the gap between its two vault targets, and the two windows do not
  --     overlap. So the boards no longer carry an identical loop, and the
  --     note that said they did is gone rather than quietly wrong.
  --
  -- x=334 also passed every static gate, with an 18.0px gap against wall 5's
  -- tip -- 0.7px wider than the ball. The soak found the ball parked in it,
  -- motionless, for eight of ten minutes. That is where the stuck-ball
  -- invariant in tests/probe_soak.lua comes from, and why 347 leaves 31px.
  --
  -- What it costs to make. The climb is fought by C.RAMP_CLIMB_G and the
  -- 380px it travels up-board by ordinary gravity, so a shot has to arrive at
  -- the mouth with
  --
  --     sqrt(2 * (6179*30 + 704*380)) = 952 px/s
  --
  -- and core/ramp.lua turns everyone slower away rather than swallowing them.
  -- That is the whole reason the gate exists: admitting shots that cannot
  -- climb turned both orbits into dead ends, measured at the time as
  -- Foundry's east bumper going from 40 hits in eight minutes to zero.
  --
  -- As shipped: 11 of 140 swept flipper shots reach a mouth on Foundry and 4
  -- of 140 on Glasshouse, and ALL of them complete the loop. 100% is what a
  -- gate computed from the ramp's own energy budget produces, and it is a
  -- real trade -- there is no rattling a ramp here, you either had the shot
  -- or you never got on. tests/probe_skyway.lua is that measurement.
  --
  -- The corners are `round` nodes (core/curve.lua): the path is authored as
  -- the three straight runs it obviously is, and the two 110px fillets are
  -- what stop the ball meeting a corner it cannot take.
  ramps   = {
    {
      id          = "skyway",
      path        = { 94, 460,
        94, 190, { round = 110 },
        347, 190, { round = 110 },
        347, 460 },
      -- 54px of lane against a 17.3px ball, swept rather than chosen. The
      -- entry window is the lane narrowed by a ball radius -- core/ramp.lua
      -- will not close the rails around a ball already overlapping one -- so
      -- a wider lane admits shallower shots, and on the sweep that chose this
      -- (38/46/54/62/70) Foundry's completion collapsed from 55% to 7% above
      -- 54 while reaching the mouth got no easier. 54 was the only width both
      -- boards could reach and complete.
      --
      -- The sweep predates the solid skirt and the entry gate that followed
      -- it, so treat the number as inherited rather than current: re-run
      -- tests/probe_skyway.lua before moving it.
      width       = 54,
      height      = 30,
      entry_slope = 0.58,
      exit_slope  = 0.58,
      enter       = "both",
    },
  },

  -- §5 The link.
  -- The mouth sits directly above the ramp exit, so clearing the gate is the
  -- pass. The right orbit is the plunger lane and the way back down.
  -- §7 Cross-board state. Foundry is the charging board: the chaos here is
  -- worth little on its own (24 points/s) but it fills the vault waiting on
  -- Glasshouse. You play A to prepare B.
  links   = {
    { when = "bumper", charges = { board = "b", meter = "vault" } },
  },

  tube    = { mouth = { x = 236, y = 398, r = 14 }, to = "b" },
  entry   = { x = 90, y = 116, dir = { x = 0.4, y = 1 } },
  -- Served into the open right field, clear of the lane furniture: a real
  -- shooter lane is phase 5, and a serve inside a 26px outlane rattles.
  serve   = { x = 400, y = 660, dir = { x = 0, y = -1 } },

  drain_y = 940,
}
