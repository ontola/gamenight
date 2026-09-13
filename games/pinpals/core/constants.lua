--- Single source of truth for physical and timing constants.
--- Per technical-choices.md §4.2: agents must never hardcode these at call sites.
--- Pure Lua. No love.* here.

local C = {}

C.TRANSIT_AIM_LIMIT = math.rad(20)
C.TRANSIT_AIM_RATE = math.rad(90) -- radians per second while a button is held

-- §4.2 World scale -----------------------------------------------------------
-- Box2D is tuned for bodies of 0.1m-10m. A real pinball is 27mm, well under
-- that floor, so the whole game runs at 10x real-world scale.
C.SCALE          = 10          -- real-world multiplier
C.METER          = 64          -- pixels per Box2D meter
C.GRAVITY_MS2    = 11.0        -- ~1.11 m/s^2 down-playfield at 6.5deg, x10
C.GRAVITY_PX     = C.GRAVITY_MS2 * C.METER

-- Board dimensions in world pixels. 7m x 15m at 64 px/m. Grown from 6m x 12m
-- in boards-v2 (docs/boards-v2.md): the ball did not change size, so the whole
-- table got roomier rather than merely zoomed. Each board carries its own
-- `size`, which is what sim/ and app/ read; these are the reference values.
C.BOARD_W        = 448
C.BOARD_H        = 960

-- Ball: 27mm x10 = 0.27m diameter.
C.BALL_RADIUS    = 0.135 * C.METER   -- 8.64 px
C.BALL_DENSITY   = 1.5
C.BALL_RESTIT    = 0.30
C.BALL_FRICTION  = 0.04
C.BALL_DAMPING   = 0.05
-- Velocity ceiling. At 10x scale distances are 10x and gravity is 10x, so
-- speeds scale by sqrt(10): a real 10 m/s ball is ~32 m/s here. Above ~34 the
-- ball covers more than its own diameter in a 240 Hz step and thin static
-- edges start to leak, energy-adding bumpers being the usual culprit.
C.BALL_MAX_SPEED = 34 * C.METER      -- 2176 px/s = 9.1 px per fixed step

-- Curves (core/curve.lua) ----------------------------------------------------
-- Board geometry is authored with curve nodes and expanded into polylines at
-- load time, so these decide how many straight segments a curve becomes.
--
-- CURVE_TOL is how far a chord may sag away from the true curve. Sub-pixel,
-- because the boards are drawn at roughly 1:1 and a 1px flat spot on an arc
-- is visible.
C.CURVE_TOL      = 0.75
-- ...and a floor on how short the chords may get. Two segments of a chain
-- that are one segment apart sit exactly one chord from each other, so a
-- curve tessellated finely enough starts to look, to core/geometry.lua's
-- throat check, like a gap the ball cannot fit through. The floor plus that
-- check's own along-the-chain exemption is what keeps a smooth curve from
-- reading as a defect.
C.CURVE_MIN_CHORD = 6
-- Backstop against a typo'd radius turning one node into ten thousand edge
-- fixtures. Nothing on either board comes close.
C.CURVE_MAX_STEPS = 256
-- The same backstop for Beziers, which subdivide rather than step: 2^10
-- segments is far past any board and stops a degenerate control polygon from
-- recursing until the stack gives out.
C.CURVE_MAX_DEPTH = 10
-- How much chain has to run between two segments before core/geometry.lua
-- will call the gap between them a throat. Two segments one segment apart on
-- a curve sit exactly one chord from each other, so without this every curve
-- tighter than the chord floor reports itself as a wedge. Two ball diameters
-- of chain is far less than any real throat -- the shipped one (board B's
-- converging rails) was between two different polylines, which this cannot
-- exempt at all -- and far more than a tessellation step.
C.THROAT_RUN     = C.BALL_RADIUS * 4
-- There is deliberately no margin on top of the ball's own width here, and it
-- was tried. A ramp foot once left an 18.0px gap against the tip of a wall --
-- 0.7px more than the ball is wide, so the check passed it -- and the soak
-- found the ball parked in it for eight of ten minutes. Widening the bar to
-- 1.25x caught that, and also flagged a 20.0px gap beside one of
-- Glasshouse's targets that has never held anything in any soak.
--
-- The two cases are 2px apart and a width threshold cannot tell them apart,
-- because what makes a gap a trap is not how narrow it is but whether it
-- dead-ends. So the static check stays a lower bound -- a gap narrower than
-- the ball is always wrong -- and the thing that catches a near miss is the
-- stuck-ball invariant in tests/probe_soak.lua, which found this one.

-- Ramps (core/ramp.lua) ------------------------------------------------------
-- A ramp is a lane that climbs off the playfield, crosses over whatever is
-- underneath it and comes down again. The ball is on one of two Box2D
-- collision layers at any moment, so "over" and "under" are a real physical
-- distinction and not a drawing trick.
--
-- What it costs to climb. The playfield is a plane tilted 6.5deg, and
-- GRAVITY_PX is the component of gravity running down it; the far larger
-- component presses the ball INTO that plane, and it is that one a ramp turns
-- against the ball when the lane starts to rise. cot(6.5deg) is the ratio
-- between them, so a 0.3 gradient fights the ball with 2.6x the force the
-- open playfield ever does.
--
-- This is why a ramp needs a real shot rather than a dribble, and it is
-- measured rather than tuned: it is the same tilt the gravity constant above
-- was derived from, used consistently.
C.PLAYFIELD_TILT = math.rad(6.5)
C.RAMP_CLIMB_G   = C.GRAVITY_PX / math.tan(C.PLAYFIELD_TILT)
-- How much ramp counts as its mouth: the run at each end within which a ball
-- may get on or off. Wide enough that a ball crossing it in one 240Hz step at
-- the speed ceiling (9.1px) cannot skip it, and short enough that it is
-- unambiguously the entrance rather than the ramp.
C.RAMP_MOUTH     = 26
-- ...and the floor on how fast the ball has to be going INTO the mouth to
-- commit to the climb. Mostly this is not the binding number: core/ramp.lua
-- raises it per ramp to sqrt(2 * RAMP_CLIMB_G * height), the speed below
-- which the ball provably cannot reach that ramp's crown.
--
-- That is the whole rule, and it was measured into existence. With a flat
-- 192px/s threshold the ball entered Foundry's skyway 36 times in 120s and
-- spent a third of its life on it -- almost all of them dribbles that climbed
-- a few pixels and rolled straight back out, during which the ball is on the
-- ramp layer and the playfield underneath it might as well not exist. A ramp
-- you can fall into without being able to climb is a trap, not a lane.
C.RAMP_ENTER_SPEED = 3 * C.METER
-- There is deliberately no headroom multiplier on that budget. One was
-- written -- the budget is frictionless and the ball is not -- and then
-- measured away: sweeping it over 1.00..1.40 moved neither entries nor
-- completions by a single shot on either board, because a flipper shot that
-- reaches the skyway's mouth at all arrives at 1511-1622 px/s against a
-- 1039 px/s gate. The climb is never what decides a shot here; the angle it
-- arrives at is. tests/probe_skyway.lua has the distribution.
-- The steepest gradient a ramp may be authored with. At 1.0 the climb costs
-- nearly nine times playfield gravity, which no shot on either board can pay.
C.RAMP_MAX_SLOPE = 0.60
-- How much air a ramp needs under it before the ball can go beneath it.
--
-- A ramp is a solid object, not a decal: near its feet the lane is inches off
-- the playfield and nothing can pass under it, and only once it has climbed
-- clear does the space underneath open up. RAMP_DECK is the lane's own
-- thickness, so the gap a ball has to fit through is the height minus that.
--
-- Without this the rails existed only on the ramp layer and a playfield ball
-- walked straight through the side of a ramp resting on the floor, which is
-- what makes the whole thing read as a drawing rather than a structure.
C.RAMP_DECK      = 4
C.RAMP_CLEARANCE = C.BALL_RADIUS * 2 + C.RAMP_DECK
-- Where the ramp is too low to duck under, its sides are solid and its lane
-- is closed off by a wall slanted across it. Slanted, not square: a ball that
-- did not make the climb has to be sent back down the lane, and a square wall
-- at the end of a channel two rails wide is a pocket to rest in. This is how
-- far the two ends of that wall are offset along the lane, either side of
-- where the ramp lifts clear.
C.RAMP_BACKSTOP  = 20

-- Offset rails pinch to nothing on the outside of a hard corner without a
-- miter, and run away to infinity with an unclamped one. A ramp that turns
-- this hard is a defect core/geometry.lua reports; the clamp only stops the
-- picture exploding before the message arrives.
C.RAMP_MITER_MAX = 3
-- Presentation: where the light is, so a ramp's shadow says how high it is.
-- Down and to the right, matching nothing in particular -- it only has to be
-- consistent across both boards for height to read at a glance.
C.RAMP_SHADOW_X  = 0.45
C.RAMP_SHADOW_Y  = 0.62
-- How finely the drawn lane is cut across, in pixels of ramp. The gradient
-- and the shadow's shear both follow the height profile, and the profile
-- climbs over ~80px inside path segments that can be 270px long -- so
-- colouring at the path's own vertices puts the whole climb into one linear
-- blend and leaves a seam where the segment ends. Cutting the strip finer
-- than the climb is the fix; it costs vertices in a mesh built once.
C.RAMP_MESH_STEP = 8

-- §4.1 Fixed timestep --------------------------------------------------------
C.TICK_HZ        = 240
C.FIXED_DT       = 1 / C.TICK_HZ
-- Backstop against a death spiral, in sim steps per frame. It must sit above
-- what a legitimately slow frame needs: a 30 fps frame is already 8 steps at
-- 240 Hz, so a low cap silently drops time and the game runs in slow motion on
-- a slow machine. The real spiral guard is the 0.25s clamp in Match:advance;
-- this should effectively never fire.
C.MAX_CATCHUP    = 60          -- 0.25s of simulation, matching that clamp

-- Flippers -------------------------------------------------------------------
-- The bat is sized against the BOARD, not against a real flipper, and the two
-- disagree. At 0.76m it was 2.81 ball diameters -- a real bat is 2.82 -- but
-- the board is 25.9 ball diameters wide where a real playfield is 19.1, so
-- correctly-scaled flippers defended 25.0% of Foundry's width and 28.6% of
-- Glasshouse's against the 34.6% every real table has used for eighty years.
-- The bottom of both boards was proportionally under-defended and the side
-- furniture correspondingly bloated: 9.14 ball widths a side against 6.24.
--
-- Growing the ball instead would fix every ratio in one edit and is ruled out
-- above: a dozen measured thresholds are baked to the radius.
--
-- 1.00m is not a taste, it is the ceiling. Tip speed is FLIPPER_SPEED *
-- FLIPPER_LEN, and past BALL_MAX_SPEED the clamp in sim/ silently eats the
-- flipper's energy and the device stops being linear:
--
--     FLIPPER_LEN <= BALL_MAX_SPEED / FLIPPER_SPEED = 2176 / 34 = 64.0 px
--
-- which is 3.70 ball diameters and takes coverage to 31.0% / 34.5%. Reaching
-- 34.6% on Foundry needs 73.4px and a slower FLIPPER_SPEED; that is a second
-- global feel change and was deliberately not made at the same time as this
-- one. See docs/boards-v3.md 3.
C.FLIPPER_LEN    = 1.00 * C.METER    -- 100mm x10, 64px, 3.70 ball diameters
C.FLIPPER_THICK  = 0.16 * C.METER
C.FLIPPER_DENSITY= 14
C.FLIPPER_TORQUE = 5.0e6
C.FLIPPER_SPEED  = 34                -- rad/s
C.FLIPPER_REST   = 0.52              -- rad below horizontal, at rest
C.FLIPPER_UP     = -0.36             -- rad above horizontal, when flipped

-- §5 The link ----------------------------------------------------------------
C.TRANSIT_TIME   = 0.80        -- seconds in the tube (latency budget, §6)
C.TRANSIT_MIN_SP = 12 * C.METER
-- Pinned to the ball's own ceiling rather than set independently. At 40 m/s
-- the top 384 px/s of this clamp was dead range: sim/ clamps the ball to
-- BALL_MAX_SPEED on the very next step, so an arrival could never actually
-- reach it and the constant quietly lied about the range.
C.TRANSIT_MAX_SP = C.BALL_MAX_SPEED

-- §9 Scoring: the multiplier lives on passing, not on shots ------------------
-- Heat is earned only by crossing the tube, and then multiplies everything.
-- That is what makes a rally simultaneously more valuable and more likely to
-- end -- a risk curve generated entirely by cooperation, with no timer and no
-- difficulty setting behind it.
C.HEAT_MAX       = 10          -- x10 ceiling, so a long rally still has a top
C.SCORE_PASS     = 1000        -- awarded per crossing, at the new heat
C.SCORE_BUMPER   = 50          -- chaos: cheap, frequent, not aimed
-- A slingshot fires because the ball happened to roll past it, so it pays
-- less than a bumper you at least aimed the ball into. It is worth points at
-- all because a table where the furniture is silent reads as scenery.
C.SCORE_SLING    = 25
C.SCORE_TARGET   = 250         -- precision: you meant to hit this
C.SCORE_BANK     = 2500        -- clearing a whole bank, before the multiplier
-- The outlane guard (§6.2). Worth more than a slingshot and less than a
-- bumper: nobody aimed the ball into it, but somebody decided in advance that
-- this was the side to protect, and that decision is the thing being paid for.
C.SCORE_GUARD    = 100

-- §7 Cross-board state: completing something on A arms something on B.
-- Foundry's bumpers charge Glasshouse's vault; clearing the vault lights
-- Foundry's bumpers. Neither board can run the loop alone, which is what
-- makes the pass structural rather than optional. The wiring itself lives in
-- the board data (§5.3), not here -- these are only its magnitudes.
C.CHARGE_MAX     = 10          -- a vault charge worth x11 on the bank bonus
C.LIT_HITS       = 12          -- bumper hits granted by clearing a vault
C.LIT_MULT       = 5           -- what a lit bumper pays, against an unlit one
-- There is deliberately no bumper cooldown constant. One was written, then
-- measured away: see the note in sim/board.lua:_begin and the numbers in
-- tests/probe_scoring.lua.

-- §9 "worth more, AND MOVING FASTER". Heat raises the speed the ball arrives
-- at, so the rally gets physically harder to hold as it gets valuable.
--
-- Deliberately NOT done by shortening transit: §5 and §11 make that 800ms the
-- online latency budget, so spending it on escalation would foreclose network
-- play to buy something a speed multiplier already gives us.
C.HEAT_SPEED_STEP = 0.05       -- +5% arrival speed per crossing
C.HEAT_SPEED_MAX  = 1.55       -- ceiling on that multiplier

-- Match flow -----------------------------------------------------------------
C.SERVE_SPEED    = 1050        -- px/s off the plunger; enough to reach the gate
-- No two plunger pulls are the same, so a serve is not a fixed shot.
--
-- These are small on purpose, and tests/probe_serve.lua is why: the OUTCOME
-- saturates far below them. Foundry's serve bounces off the top arc, and that
-- bounce is chaotic -- at +/-0.6deg it already lands anywhere from x=18 to
-- x=429 (sd 170px), and doubling the jitter to +/-2.4deg does not widen that
-- by a pixel. So the size of the jitter buys nothing above a fraction of a
-- degree, while a large one only risks the serve's actual job. They are set
-- to what a hand on a plunger plausibly does: over 200 serves, every one
-- still climbs past the tube mouth and one drained untouched inside 3s.
--
-- What the jitter changed is what a REPEATED serve was worth. The fixed serve
-- flew one line into Foundry's west bumper every ball -- 192 of that bumper's
-- 209 hits over 48 seeds of random play came from it -- so the cluster's
-- measured liveness falls from 0.21 to 0.12 hits/s. That is the recording
-- being taken away, not the bumper becoming scenery; tests/sim/spec.lua's
-- reachability test now samples enough seeds to tell the difference.
C.SERVE_SPEED_VAR = 0.04       -- +/- fraction on that speed, so 1008-1092 px/s
C.SERVE_ANGLE_VAR = 0.021      -- +/- radians off the lane, ~1.2 degrees
-- §5.1 wants a match to replay from its intent stream plus a seed, so the
-- jitter above is drawn from the match's own generator rather than the global
-- one. This is the seed a Match uses when nobody hands it one: a headless
-- gate, a probe and a --shot all want the same match twice, and only a played
-- session asks for a fresh one.
C.RNG_SEED       = 20260907

C.SERVE_DELAY    = 0.60        -- pause before a ball is served
C.DRAIN_DELAY    = 0.90        -- pause after a drain before re-serve

-- §8 Purgatory rescue. A drained ball does not die immediately: it hangs for
-- this long, and the PARTNER -- the player who was not holding it -- can pull
-- it back by raising the post on the board that just lost it. "My mistake
-- becomes your chance to be a hero, which is the best feeling co-op can
-- produce."
--
-- The window has to clear the post's own travel time or the rescue is not a
-- decision, it is a reflex test: 0.26s of that 1.9s is the post moving.
C.PURGATORY_TIME = 1.90

-- Impacts (presentation only) ------------------------------------------------
-- sim/ reports ball contacts so app/ can sound and light them. The floor
-- separates a hit from a lean: a ball merely resting on a surface still
-- solves a contact impulse every step, and at 240 Hz an unfiltered feed is a
-- machine-gun rather than a set of hits.
--
-- That resting impulse is not a matter of taste, it is the ball's own weight
-- carried for one step: m*g*dt, reported by Box2D in pixel units. Measuring
-- 240s of play put 90% of wall contacts at 0.249-0.250 against a predicted
-- 0.2519 -- the cluster IS the ball sitting still. So the floor is defined as
-- a margin above that, and any real bounce clears it comfortably: an impact
-- at v m/s solves about m*v*(1+e)*METER, so even a 0.05 m/s nudge lands at
-- 0.34. Event rate across the cliff: 96.9/s at 0.20, 7.2/s at 0.30.
C.BALL_MASS           = C.BALL_DENSITY * math.pi * 0.135 * 0.135   -- kg
C.IMPACT_REST_IMPULSE = C.BALL_MASS * C.GRAVITY_MS2 * C.FIXED_DT * C.METER
C.IMPACT_MIN_IMPULSE  = C.IMPACT_REST_IMPULSE * 1.19   -- 0.300
C.IMPACT_MAX_PER_STEP = 4      -- one ball cannot meaningfully hit more

-- §6.1 Operator devices: persistent states, never impulses.
C.GATE_THICK     = 9           -- gate arm thickness; core/geometry.lua needs it
-- Travel times are deliberately long enough to read across a room.
C.GATE_TRAVEL    = 0.30
C.PADDLE_TRAVEL  = 0.26
-- §6.2 The outlane guard: one barrier that seals the left outlane or the
-- right one, never both, moved by the operator. Long enough to be a real cost
-- -- for these 300ms NEITHER lane is sealed, so switching sides in a panic is
-- how the ball goes down the side you just left.
C.GUARD_TRAVEL   = 0.30
-- ...and it is good for exactly one save, then it drops out of play for this
-- long. §6.2's OPEN question asked whether operator actions should cost a
-- resource and proposed per-device cooldowns; this is that answer, on the one
-- device that was otherwise free.
--
-- Read against a measured ball life of 5-15s, thirty seconds is deliberately
-- longer than a ball. The guard is not a lane you close, it is one save you
-- spend, and choosing WHICH side to spend it on is the whole decision. See
-- tests/probe_guard.lua for what it is worth at this number.
C.GUARD_COOLDOWN = 30

return C
