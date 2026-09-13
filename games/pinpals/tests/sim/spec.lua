--- Headless physics tests. Run under `love . --test` with the window module
--- disabled: love.physics needs no window (§7).
---
--- These exist for risks table row 1 -- "Box2D can't deliver satisfying
--- pinball feel" -- which technical-choices.md §11 says to test FIRST.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local C       = require("core.constants")
  local intents = require("core.intents")
  local Board   = require("sim.board")
  local Match  = require("sim.match")
  local ramps  = require("core.ramp")
  local boards = require("data.tables.init").load()

  describe("aimed arrival", function()
    it("rotates launch velocity without changing its speed on either board", function()
      for _, def in pairs(boards) do
        local b = Board.new(def, 42)
        for _, aim in ipairs({ -C.TRANSIT_AIM_LIMIT, 0, C.TRANSIT_AIM_LIMIT }) do
          b:arrive(1500, aim)
          local vx, vy = b.ball:getLinearVelocity()
          local angle = math.atan2(def.entry.dir.y, def.entry.dir.x) + aim
          A.near(math.cos(angle) * 1500, vx, 0.01)
          A.near(math.sin(angle) * 1500, vy, 0.01)
        end
        b.world:destroy()
      end
    end)
  end)

  --- A core-shaped command block, so sim tests don't need core/state.
  --- `guard` is nil by default, which retracts both outlane guards: the older
  --- measurements in this file and in every probe were taken on a board with
  --- no guards, and silently deploying one would move all of them.
  local function cmd(gate, post, left, right, guard, cooldown)
    return { guard = guard, guard_cooldown = cooldown or 0,
             flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  local function run(board, seconds, c, sink)
    local n = math.floor(seconds * C.TICK_HZ)
    for _ = 1, n do
      for _, ev in ipairs(board:step(c, board.ball ~= nil)) do
        if sink then sink[#sink+1] = ev end
      end
    end
  end

  describe("rollover switches", function()
    it("scores a crossing without blocking or bouncing the ball", function()
      local b = Board.new(boards.a)
      b:spawn(224, 650, 0, 300)
      local evs = {}
      run(b, 0.16, cmd(), evs)
      local hits = 0
      for _, ev in ipairs(evs) do
        if ev.kind == "rollover" and ev.index == 3 then hits = hits + 1 end
      end
      local _, y = b:ball_pos()
      local _, vy = b.ball:getLinearVelocity()
      A.equal(1, hits)
      A.truthy(y > 690 and vy > 300, "the flush switch obstructed a falling ball")
    end)
  end)

  describe("world construction", function()
    for _, id in ipairs({ "a", "b" }) do
      it(id .. " builds with two flippers and two devices", function()
        local b = Board.new(boards[id])
        A.truthy(b.flippers.left and b.flippers.right)
        A.truthy(not b.devices.gate and b.devices.post)
        A.equal(64, love.physics.getMeter(), "world scale must come from constants (§4.2)")
      end)
    end
  end)

  --- §6.2 The outlane guard. core/geometry.lua already checks that the bar
  --- spans its lane and parks clear of the drain; these are the claims only
  --- the physics can settle.
  describe("the outlane guard", function()
    --- Drop a ball into one outlane mouth and report what became of it.
    ---
    --- Three outcomes, not two. "Did not drain" is not a save: a ball still
    --- sitting in the lane when the clock runs out has been PARKED, which is
    --- exactly what a bar placed deep inside a 29px shaft produces, and it
    --- would pass a test that only asked about draining.
    ---
    --- The run stops the moment the ball is back on the playfield, because
    --- what it does next is the board's business and not the guard's -- an
    --- unattended ball drains down the middle within a couple of seconds and
    --- would otherwise be charged to the device.
    local function drop(def, side, guard, seconds, cooldown)
      local g
      for _, spec in ipairs(def.guards) do if spec.side == side then g = spec end end
      local b = Board.new(def)
      local c = cmd(false, false, false, false, guard, cooldown)
      -- Let both bars finish travelling first, so this measures the guard and
      -- not the guard arriving.
      run(b, C.GUARD_TRAVEL * 2, c)
      b:spawn(g.up.x, g.up.y - 40, 0, 120)
      local evs, outcome = {}, nil
      for _ = 1, math.floor(seconds * C.TICK_HZ) do
        for _, ev in ipairs(b:step(c, true)) do
          if ev.kind == "drain" then outcome = "drained" end
          if ev.kind == "guard" then evs[#evs+1] = ev end
        end
        if outcome then break end
        local x, y = b:ball_pos()
        local clear = (side == "left") and (x > g.up.x + 40) or (x < g.up.x - 40)
        if y < g.up.y - 60 or clear then outcome = "escaped" break end
      end
      b:despawn()
      return { outcome = outcome or "parked", events = evs }
    end

    for _, id in ipairs({ "a", "b" }) do
      for _, side in ipairs({ "left", "right" }) do
        it(("%s: the %s guard turns that outlane back"):format(id, side), function()
          local r = drop(boards[id], side, side, 4)
          A.equal("escaped", r.outcome,
                  "a guarded outlane must put the ball back on the playfield")
          A.truthy(r.events[1], "the ball went down the lane and never met the bar")
          A.equal(side, r.events[1].side)
        end)

        it(("%s: guarding %s leaves the other outlane open"):format(id, side), function()
          local other = (side == "left") and "right" or "left"
          local r = drop(boards[id], side, other, 4)
          A.equal("drained", r.outcome,
                  "guarding one side must not protect the other (§6.2)")
        end)
      end
    end

    for _, id in ipairs({ "a", "b" }) do
      it(("%s: a spent guard is not in the lane at all"):format(id), function()
        -- §6.2's cooldown, in the physics. core/ stops SCORING a spent guard;
        -- this is the half that has to stop STOPPING the ball, or the device
        -- would keep saving for free and the cooldown would be a scoreboard
        -- rule rather than a cost.
        local r = drop(boards[id], "left", "left", 4, C.GUARD_COOLDOWN)
        A.equal("drained", r.outcome, "a spent guard still guarded")
        A.falsy(r.events[1], "a spent guard was still reporting contacts")
      end)
    end

    it("only ever has one bar deployed", function()
      local b = Board.new(boards.a)
      run(b, C.GUARD_TRAVEL * 2, cmd(false, false, false, false, "left"))
      A.near(1, b:guard_progress("left"), 0.02)
      A.near(0, b:guard_progress("right"), 0.02)
      -- And switching moves both, which is what leaves the window where
      -- neither lane is sealed.
      run(b, C.GUARD_TRAVEL * 2, cmd(false, false, false, false, "right"))
      A.near(0, b:guard_progress("left"), 0.02)
      A.near(1, b:guard_progress("right"), 0.02)
    end)

    it("comes back on the side chosen while it was spent", function()
      local b = Board.new(boards.a)
      -- Spent, and the operator switches to the right lane while it is gone.
      run(b, C.GUARD_TRAVEL * 2, cmd(false, false, false, false, "right", 12))
      A.near(0, b:guard_progress("left"), 0.02)
      A.near(0, b:guard_progress("right"), 0.02, "a spent guard deployed anyway")
      run(b, C.GUARD_TRAVEL * 2, cmd(false, false, false, false, "right", 0))
      A.near(1, b:guard_progress("right"), 0.02)
      A.near(0, b:guard_progress("left"), 0.02)
    end)

    it("takes GUARD_TRAVEL to switch, so the swap is visible (§6.1)", function()
      local b = Board.new(boards.a)
      run(b, C.GUARD_TRAVEL * 2, cmd(false, false, false, false, "left"))
      local c = cmd(false, false, false, false, "right")
      -- Halfway through the travel neither lane is sealed. That gap is the
      -- cost of changing your mind and it has to actually exist.
      run(b, C.GUARD_TRAVEL * 0.5, c)
      A.between(0.05, 0.95, b:guard_progress("left"), "the leaving bar teleported")
      A.between(0.05, 0.95, b:guard_progress("right"), "the arriving bar teleported")
    end)
  end)

  describe("tunneling (§11)", function()
    it("a ball fired hard from anywhere never leaves through the geometry", function()
      math.randomseed(20260905)
      for _, id in ipairs({ "a", "b" }) do
        local def = boards[id]
        local b = Board.new(def)
        for trial = 1, 60 do
          local x = 30 + math.random() * (def.size.w - 60)
          local y = 40 + math.random() * 560
          local ang = math.random() * math.pi * 2
          local sp  = C.BALL_MAX_SPEED * (0.7 + 0.3 * math.random())
          b:spawn(x, y, math.cos(ang) * sp, math.sin(ang) * sp)
          for _ = 1, math.floor(1.5 * C.TICK_HZ) do
            local drained = false
            for _, ev in ipairs(b:step(cmd(), true)) do
              if ev.kind == "drain" then drained = true end
            end
            -- Draining is a legitimate exit; leaving any other way is not.
            if drained then break end
            local bx, by = b:ball_pos()
            local where = ("%s trial %d from (%.0f,%.0f)"):format(id, trial, x, y)
            A.between(-20, def.size.w + 20, bx, where .. ": escaped sideways")
            A.between(-20, def.drain_y, by, where .. ": escaped through the bottom")
          end
        end
        b:despawn()
      end
    end)

    it("never exceeds the speed at which thin edges start to leak", function()
      local def = boards.a
      local b = Board.new(def)
      b:spawn(192, 120, 900, 1600)
      local peak = 0
      for _ = 1, math.floor(4.0 * C.TICK_HZ) do
        b:step(cmd(), true)
        peak = math.max(peak, b:ball_speed())
      end
      A.truthy(peak <= C.BALL_MAX_SPEED * 1.02,
               ("bumpers pumped the ball to %.0f px/s"):format(peak))
      -- The ceiling has to keep per-step travel under one ball diameter.
      A.truthy(C.BALL_MAX_SPEED * C.FIXED_DT < C.BALL_RADIUS * 2,
               "the speed ceiling allows a step longer than the ball is wide")
    end)
  end)

  describe("always-open board links", function()
    it("passes on both boards without an operator command", function()
      for _, id in ipairs({ "a", "b" }) do
        for _, commanded in ipairs({ false, true }) do
          local def = boards[id]
          local b = Board.new(def, 7919)
          A.falsy(b.devices.gate)
          b:spawn(def.tube.mouth.x, def.tube.mouth.y + 352, 0, -C.SERVE_SPEED)
          local events = {}
          run(b, 1.5, cmd(commanded, false), events)
          local passed = false
          for _, event in ipairs(events) do
            if event.kind == "tube" then passed = true end
          end
          A.truthy(passed, id .. ": link must stay open")
        end
      end
    end)
  end)

  describe("the post (§6.2: guards the drain, blocks the shots)", function()
    -- Straight down the middle, from BELOW the ramp mouth. Board centre is
    -- also the centre of the ramp channel, so a drop from half-way up starts
    -- inside the ramp and tests the ramp rather than the drain -- which is
    -- exactly what it silently did once the channel moved.
    local function down_the_middle(def)
      return def.size.w / 2, def.size.h * 0.64
    end

    it("raised, it catches a ball headed straight down the middle", function()
      local def = boards.a
      local b = Board.new(def)
      local c = cmd(false, true)
      run(b, 0.35, c)
      A.between(0.98, 1.02, b:device_progress("post"))
      local ev = {}
      b:spawn(down_the_middle(def))
      run(b, 2.5, c, ev)
      for _, e in ipairs(ev) do A.truthy(e.kind ~= "drain", "the post let the ball through") end
    end)

    it("retracted, the same ball drains", function()
      local def = boards.a
      local b = Board.new(def)
      local ev = {}
      b:spawn(down_the_middle(def))
      run(b, 2.5, cmd(false, false), ev)
      local drained = false
      for _, e in ipairs(ev) do if e.kind == "drain" then drained = true end end
      A.truthy(drained, "the centre gap should be a real drain")
    end)

    it("settles the ball instead of jittering it forever", function()
      local def = boards.a
      local b = Board.new(def)
      local c = cmd(false, true)
      run(b, 0.35, c)
      b:spawn(down_the_middle(def))
      run(b, 3.0, c)
      A.truthy(b:ball_speed() < 2.0 * C.METER,
               "resting contact is jittering at " .. tostring(b:ball_speed()))
    end)
  end)

  describe("flippers", function()
    it("throw a resting ball hard enough to reach the top of the board", function()
      local def = boards.a
      local b = Board.new(def)
      local f = def.flippers[1]
      -- Placed on the flipper face, not dropped: a resting flipper is a 30
      -- degree slope, so a dropped ball rolls off the tip before you can hit it.
      b:spawn(f.x + 19, f.y - 2, 0, 0)
      local peak = 0
      local c = cmd(false, false, true, false)
      for _ = 1, math.floor(0.35 * C.TICK_HZ) do
        b:step(c, true)
        peak = math.max(peak, b:ball_speed())
      end
      -- The bar is the board's own pass shot, not a fixed number: reaching the
      -- tube mouth from the flipper line needs sqrt(2*g*h) of upward velocity,
      -- and a flipper that cannot manage it cannot make the pass.
      local need = math.sqrt(2 * C.GRAVITY_PX * (f.y - def.tube.mouth.y))
      A.truthy(peak > need,
        ("flipper launch too weak: %.0f px/s, needs %.0f"):format(peak, need))
    end)
  end)

  describe("the pass shot is makeable (design.md §5)", function()
    -- The prototype cannot answer "does the rally feel good?" if the pass
    -- cannot be made. An earlier layout put the ramp where no flipper shot
    -- reached: shots cross y=560 between x=145 and x=239, and the ramp was at
    -- x=328. It was hit 1 time in 30. This test exists so that cannot come
    -- back silently after a board-data edit.
    local on_flipper
    function on_flipper(fx, fy, side, k)
      local sgn = (side == "left") and 1 or -1
      local a = C.FLIPPER_REST
      return fx + sgn * C.FLIPPER_LEN * k * math.cos(a),
             fy + C.FLIPPER_LEN * k * math.sin(a)
                 - (C.BALL_RADIUS + C.FLIPPER_THICK / 2) / math.cos(a)
    end

    for _, id in ipairs({ "a", "b" }) do
      for fi, side in ipairs({ "left", "right" }) do
        it(("%s: the %s flipper can reach the tube"):format(id, side), function()
          local def = boards[id]
          local made, tried = 0, 0
          for k = 0.25, 0.90, 0.09 do
            local b = Board.new(def)
            run(b, 0.40, cmd(true, false))                  -- gate already open
            b:spawn(on_flipper(def.flippers[fi].x, def.flippers[fi].y, side, k))
            run(b, 12 * C.FIXED_DT, cmd(true, false))       -- settle into contact
            local c = cmd(true, false, side == "left", side == "right")
            local got = false
            for _ = 1, math.floor(3.5 * C.TICK_HZ) do
              for _, ev in ipairs(b:step(c, true)) do
                if ev.kind == "tube" then got = true end
              end
              if got then break end
            end
            tried = tried + 1
            if got then made = made + 1 end
          end
          A.truthy(made >= 2,
            ("the pass is not reachable from here: %d/%d"):format(made, tried))
        end)
      end
    end

    it("a: the ramp is not the only shot on the board", function()
      -- The companion to the test above, and the more important one. With the
      -- ramp mouth at y=600 the pass test passed at 62% while the board had
      -- exactly ONE shot: a sweep of 50 contact points found 0% reaching
      -- anywhere else on the playfield. A board where every shot has the same
      -- outcome gives the flipper player nothing to decide, which is pillar 1
      -- ("nobody waits") broken in the geometry rather than in the rules.
      --
      -- So: some shot, from somewhere on some flipper, must get the ball up
      -- the board OUTSIDE the ramp channel.
      -- Same spawn geometry as tests/probe_reach.lua, which is where the
      -- 14%/10% orbit figures in board_a.lua's comments come from. Resting
      -- the ball ON the flipper and then flipping is the shot a player is
      -- actually trying to make.
      local def, escaped, tried = boards.a, 0, 0
      for _, side in ipairs({ "left", "right" }) do
        local spec
        for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
        local sign = (side == "left") and 1 or -1
        local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
        for frac = 0.30, 1.00, 0.06 do
          local b = Board.new(def)
          local d = C.FLIPPER_LEN * frac
          b:spawn(spec.x + math.cos(ang) * d * sign,
                  spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2, 0, 0)
          run(b, 0.12, cmd())                       -- settle onto the flipper
          local held = cmd(true, false, side == "left", side == "right")
          local rest = cmd(true, false)
          local c, out = held, false
          for tick = 1, math.floor(4.0 * C.TICK_HZ) do
            if tick == math.floor(0.22 * C.TICK_HZ) then c = rest end
            local gone = false
            for _, ev in ipairs(b:step(c, true)) do
              if ev.kind == "tube" or ev.kind == "drain" then gone = true end
            end
            if gone then break end
            local bx, by = b:ball_pos()
            if not bx then break end
            -- Above the ramp neck and outside its channel: an orbit lane.
            -- Both bounds hang off the tube mouth, which is what the channel
            -- is centred on, so they follow the ramp instead of describing
            -- where it used to be.
            local m = def.tube.mouth
            if by < m.y + 352 and (bx < m.x - 35 or bx > m.x + 35) then out = true break end
          end
          tried = tried + 1
          if out then escaped = escaped + 1 end
        end
      end
      A.truthy(escaped >= 2,
        ("board a has only one shot again: %d of %d swept shots left the ramp")
          :format(escaped, tried))
    end)

    it("a: every bumper is reachable in play", function()
      -- Foundry's declared character is a bumper cluster that "keeps the ball
      -- alive". Two of its three bumpers were once hit exactly zero times in
      -- 180s, because the cluster sat in a dead band between the orbit lane
      -- and the ramp. A bumper nothing can reach is scenery, and this is the
      -- test that says so out loud.
      --
      -- Twelve seeds, not three. Serves carry jitter (C.SERVE_ANGLE_VAR), and
      -- what that exposed is that three seeds had never been enough: the old
      -- fixed serve flew one exact line into the west bumper on every ball,
      -- which is where 192 of its 209 hits over 48 seeds came from, while the
      -- east bumper was already silent in 34 of those 48. Both numbers were a
      -- single trajectory being counted over and over. With the serve varying
      -- per seed each bumper is live in roughly two seeds in five, so a dozen
      -- of them is what it takes for "reachable" to mean reachable rather
      -- than lucky.
      local def = boards.a
      local seen, total = {}, 0
      local SEEDS = 12
      for seed = 1, SEEDS do
        math.randomseed(4100 + seed)
        -- The board gets the seed as well, or all twelve runs share one serve.
        local b = Board.new(def, 4100 + seed)
        b:serve()
        local c = cmd()
        for i = 1, math.floor(40 * C.TICK_HZ) do
          if i % 30 == 0 then
            c = cmd(math.random() < 0.55, math.random() < 0.2,
                    math.random() < 0.35, math.random() < 0.35)
          end
          local dead = false
          for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
            if ev.kind == "drain" or ev.kind == "tube" then dead = true end
            if ev.kind == "bumper" then
              seen[ev.index] = (seen[ev.index] or 0) + 1
              total = total + 1
            end
          end
          if dead then b:serve() end
        end
      end
      for i = 1, #def.bumpers do
        A.truthy((seen[i] or 0) > 0,
          ("bumper %d is unreachable: it is scenery, not a device"):format(i))
      end
      -- Measured 0.12/s over 48 seeds of this harness (0.21/s before the serve
      -- stopped repeating one line into the cluster). The floor is half that,
      -- well under the seed-to-seed noise.
      local secs = SEEDS * 40
      A.truthy(total / secs > 0.06,
        ("the cluster is barely live: %.2f hits/s"):format(total / secs))
    end)

    it("a received ball can be passed on -- the rally can actually continue",
       function()
      -- Every other pass test here starts from a ball resting on a flipper,
      -- which is a perfectly timed shot from a perfectly placed ball. The
      -- rally is made of RECEIVED balls: they arrive from the tube, fall, and
      -- have to be caught and sent back. A board where that is impossible has
      -- no rally regardless of how good its static pass rate looks.
      --
      -- Re-measured on the boards-v2 layout with a player who predicts contact
      -- and can flip more than once: 32% on Foundry and 62% on Glasshouse at
      -- best timing, against 63% and 85% on the old corridor boards. Both
      -- boards got harder to receive on, and that is the price of the upper
      -- playfield becoming reachable at all -- a board where every shot ends
      -- at the ramp is easy to pass from because there is nowhere else to go.
      local function received_pass_rate(def, lead)
        local made, tried = 0, 0
        for i = 1, 16 do
          math.randomseed(4242 + i * 977)
          local b = Board.new(def)
          local e = def.entry
          local speed = C.TRANSIT_MIN_SP
                      + (C.TRANSIT_MAX_SP - C.TRANSIT_MIN_SP) * math.random()
          local ang = math.atan2(e.dir.y, e.dir.x) + (math.random() * 2 - 1) * 0.10
          run(b, 0.45, cmd(true, false))
          b:spawn(e.x + (math.random() * 2 - 1) * 6, e.y,
                  math.cos(ang) * speed, math.sin(ang) * speed)
          local fired, held, side = false, 0, nil
          local SWING = math.floor(0.22 * C.TICK_HZ)
          local mid, got = def.size.w / 2, false
          for _ = 1, math.floor(6 * C.TICK_HZ) do
            local bx, by = b:ball_pos()
            if not bx then break end
            local _, vy = b:ball_velocity()
            local fy = def.flippers[1].y
            if not fired and vy > 0 and by < fy and (fy - by) / vy <= lead then
              fired, held = true, 0
              side = (bx < mid) and "left" or "right"
            end
            local flipping = false
            if fired then
              held = held + 1
              flipping = held < SWING
              -- Rearm, so the model is a player rather than a single reflex.
              -- One flip per ball was enough to measure the old boards because
              -- every shot on them ended at the ramp or the drain; on a board
              -- with an actual playfield a ball that is flipped and not passed
              -- comes back down, and a human flips it again. Measured, the
              -- difference is entirely in CENTRE drains -- 60 of them across
              -- 200 attempts with one flip, 3 with re-arming -- while outlane
              -- losses are unchanged. That is the shape of real pinball: the
              -- flipper defends the middle, and the sides are what kill you.
              if held >= SWING * 2 then fired = false end
            end
            local over = false
            for _, ev in ipairs(b:step(cmd(true, false,
                                  flipping and side == "left",
                                  flipping and side == "right"), true)) do
              if ev.kind == "tube" then got = true; over = true end
              if ev.kind == "drain" then over = true end
            end
            if over then break end
          end
          tried = tried + 1
          if got then made = made + 1 end
        end
        return made / tried
      end

      for _, id in ipairs({ "a", "b" }) do
        local best = 0
        for _, lead in ipairs({ 0.01, 0.02, 0.03, 0.04, 0.05 }) do
          best = math.max(best, received_pass_rate(boards[id], lead))
        end
        A.truthy(best >= 0.30,
          ("board %s cannot pass a ball it received: %.0f%% at best timing")
            :format(id, 100 * best))
      end
    end)

    it("and the raised post makes it harder without making it impossible (§6.2)",
       function()
      -- Both halves matter, and the device previously failed both.
      --
      -- If raising the post cost nothing, the operator would hold it up
      -- forever and there would be no conversation to have. But if it costs
      -- EVERYTHING -- which it did, measuring 0% pass and 0% drains while
      -- raised -- then the flipper player has nothing to do and nothing to
      -- fear for as long as it is held, which is pillar 1 broken by a device
      -- that looks like it is helping.
      --
      -- So this asserts a band, not a floor: the post must cost real pass
      -- rate and must leave the shot on the table.
      -- Both flippers, because the post's cost is sharply asymmetric and
      -- sweeping one of them measures the wrong thing. Each board's ramp is
      -- off-centre, so the post mainly blocks whichever flipper has to shoot
      -- ACROSS the middle: on Foundry that is the left one (58% -> 25%, while
      -- the right barely notices at 58% -> 54%), and on Glasshouse it is the
      -- right (63% -> 8%). An earlier version of this test swept Foundry's
      -- right flipper only and concluded the post cost nothing.
      local function passes_with(post_up)
        local def = boards.a
        local made, tried = 0, 0
        for fi, side in ipairs({ "left", "right" }) do
          local spec = def.flippers[fi]
          local sign = (side == "left") and 1 or -1
          local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
          for k = 0.25, 0.95, 0.05 do
            local b = Board.new(def)
            run(b, 0.45, cmd(true, post_up))          -- let the post finish travelling
            -- Resting the ball ON the flipper, the way tests/probe_post.lua
            -- does. The shared `on_flipper` helper starts it 15.9px clear
            -- rather than 10.6px, which is enough for it to bounce before the
            -- flip lands and washed the post's effect out entirely: the same
            -- sweep measured 13/28 down against 14/28 up, versus 58% and 40%
            -- from a ball actually sitting on the flipper. Worth knowing that
            -- these two harnesses do not agree.
            local d = C.FLIPPER_LEN * k
            b:spawn(spec.x + math.cos(ang) * d * sign,
                    spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2, 0, 0)
            run(b, 12 * C.FIXED_DT, cmd(true, post_up))
            local held = cmd(true, post_up, side == "left", side == "right")
            local rest = cmd(true, post_up)
            local c, got = held, false
            for tick = 1, math.floor(3.5 * C.TICK_HZ) do
              if tick == math.floor(0.22 * C.TICK_HZ) then c = rest end
              for _, ev in ipairs(b:step(c, true)) do
                if ev.kind == "tube" then got = true end
              end
              if got then break end
            end
            tried = tried + 1
            if got then made = made + 1 end
          end
        end
        return made, tried
      end

      local down, tried = passes_with(false)
      local up = passes_with(true)
      A.truthy(down > 0, "the pass is not makeable at all with the post down")
      A.truthy(up < down,
        ("the raised post costs nothing: %d/%d up vs %d/%d down")
          :format(up, tried, down, tried))
      A.truthy(up > 0,
        ("the raised post is an absolute block again: %d/%d with it up, %d down")
          :format(up, tried, down))
    end)
  end)

  describe("the fixed timestep (§4.1)", function()
    it("consumes real time in fixed chunks and never varies dt", function()
      local m = Match.new(boards)
      -- Deliberately ugly frame times: the simulation must not notice.
      local frames = { 1/60, 1/59.7, 1/144, 0.033, 1/60, 0.0001, 1/61.3 }
      local total, steps = 0, 0
      for _, dt in ipairs(frames) do
        total = total + dt
        steps = steps + m:advance(dt)
      end
      A.equal(steps, m.state.tick, "every fixed step must advance exactly one tick")
      -- The invariant that matters: real time is conserved. What has been
      -- simulated plus what is still owed equals what actually elapsed.
      A.near(total, steps * C.FIXED_DT + m.acc, 1e-9, "time was invented or lost")
      A.truthy(m.acc < C.FIXED_DT, "a whole step was left unconsumed")
      A.between(0, 1, m.alpha, "interpolation alpha out of range")
    end)

    it("discards a long hitch instead of spiralling to catch up", function()
      local m = Match.new(boards)
      local steps = m:advance(5.0)                 -- e.g. the window was dragged
      A.truthy(steps <= C.MAX_CATCHUP, "the catch-up cap did not hold: " .. steps)
      A.near(0.25 / C.FIXED_DT, steps, 1.5, "the 0.25s clamp is what should bound this")
      A.truthy(m.acc < C.FIXED_DT, "4.75 seconds of debt must be dropped, not banked")
    end)

    it("keeps up with a legitimately slow frame without dropping time", function()
      -- A 30 fps frame is 8 fixed steps. If the catch-up cap can fire here the
      -- game silently runs in slow motion on a slow machine.
      local m = Match.new(boards)
      local total = 0
      for _ = 1, 20 do total = total + 1/30; m:advance(1/30) end
      A.near(total, m.state.tick * C.FIXED_DT + m.acc, 1e-9, "time was dropped on a slow frame")
    end)
  end)

  describe("input bindings (§9)", function()
    local input = require("app.input")
    it("route both devices to the same intents", function()
      local k = input.from_key("a", true, 7)
      ---@cast k -nil
      A.equal(1, k.player); A.equal("flip_left", k.action); A.truthy(k.pressed); A.equal(7, k.tick)
      local k2 = input.from_key("down", false, 9)
      ---@cast k2 -nil
      A.equal(2, k2.player); A.equal("operator_paddle", k2.action); A.falsy(k2.pressed)
      A.falsy(input.from_key("q", true, 0), "unbound keys must produce no intent")
    end)

    it("give each player a full set of both roles' controls", function()
      for p = 1, 2 do
        local L = input.legend(p)
        for _, action in ipairs({ "flip_left", "flip_right", "operator_gate", "operator_paddle" }) do
          A.truthy(L[action], ("player %d has no binding for %s"):format(p, action))
        end
      end
    end)
  end)

  describe("the ball never gets stuck (playtest, 2026-09-05)", function()
    -- A wall chain with a local minimum is a pocket, and a level bar across a
    -- channel is a shelf. Both were in the first layout and both were found by
    -- playing, not by reading the data. These two tests look for them the way
    -- a player does: by using the board.
    local function on_flipper(def, x, y)
      for _, f in ipairs(def.flippers) do
        local sgn = (f.side == "left") and 1 or -1
        local dx = sgn * C.FLIPPER_LEN * math.cos(C.FLIPPER_REST)
        local dy = C.FLIPPER_LEN * math.sin(C.FLIPPER_REST)
        local t = math.max(0, math.min(1, ((x-f.x)*dx + (y-f.y)*dy) / (dx*dx + dy*dy)))
        if math.sqrt((x - f.x - dx*t)^2 + (y - f.y - dy*t)^2) < 24 then return true end
      end
      return false
    end

    it("survives two minutes of random play without stalling", function()
      local ACTIONS = { "flip_left", "flip_right", "operator_gate", "operator_paddle" }
      math.randomseed(7)
      local m = Match.new(boards)
      local still = 0
      for tick = 1, C.TICK_HZ * 120 do
        if tick % 14 == 0 then
          m:push(intents.new(math.random(2), ACTIONS[math.random(4)],
                             math.random() < 0.5, m.state.tick))
        end
        m:run(1)
        local s = m.state
        if s.phase == "play" then
          local b = m.boards[s.active]
          local x, y = b:ball_pos()
          if x and b:ball_speed() < 14 and not on_flipper(m.defs[s.active], x, y) then
            still = still + C.FIXED_DT
            A.truthy(still <= 1.5,
              ("ball stuck on %s at (%.0f, %.0f)"):format(s.active, x, y))
          else still = 0 end
        end
      end
    end)

    it("cannot be stranded by slamming the gate shut mid-shot", function()
      for _, id in ipairs({ "a", "b" }) do
        local def = boards[id]
        for sp = 640, 1400, 120 do
          for delay = 0, 0.60, 0.10 do
            local b = Board.new(def)
            run(b, 0.40, cmd(true, false))
            b:spawn(def.tube.mouth.x, 520, 0, -sp)
            local t, done, still = 0, false, 0
            for _ = 1, math.floor(6 * C.TICK_HZ) do
              for _, ev in ipairs(b:step(cmd(t < delay, false), true)) do
                if ev.kind == "tube" or ev.kind == "drain" then done = true end
              end
              if done then break end
              t = t + C.FIXED_DT
              local x, y = b:ball_pos()
              if b:ball_speed() < 14 and not on_flipper(def, x, y) then
                still = still + C.FIXED_DT
                A.truthy(still <= 1.5, ("%s: stranded at (%.0f, %.0f) after a %.2fs gate"):
                  format(id, x, y, delay))
              else still = 0 end
            end
          end
        end
      end
    end)
  end)

  describe("the round trip", function()
    it("serves, passes through the tube, and lands on the other board", function()
      local m = Match.new(boards)
      local s = m.state
      -- P2 operates board A: hold the gate open so the ramp shot is a pass.
      for _ = 1, C.TICK_HZ do m:run(1) end                  -- let the serve happen
      A.equal("play", s.phase)
      -- Stand in for a made ramp shot: the aiming is covered elsewhere, this
      -- test is about the handoff.
      local mouth = boards.a.tube.mouth
      m.boards.a:spawn(mouth.x, mouth.y + 352, 0, -C.SERVE_SPEED)
      local saw_transit, landed = false, false
      for _ = 1, C.TICK_HZ * 8 do
        m:run(1)
        if s.phase == "transit" then saw_transit = true end
        if saw_transit and s.phase == "play" and s.active == "b" then landed = true break end
      end
      A.truthy(saw_transit, "the ball never entered the tube")
      A.truthy(landed, "the ball never arrived on board B")
      A.equal(1, s.stats.passes)
      A.truthy(m.boards.b.ball ~= nil, "no ball on the destination board")
      A.truthy(m.boards.a.ball == nil, "the source board kept the ball too")
      local speed = m.boards.b:ball_speed()
      A.truthy(speed > C.TRANSIT_MIN_SP * 0.9, "the pass arrived dead: " .. ("%.0f"):format(speed))
    end)

    it("keeps exactly one ball in existence at all times", function()
      local m = Match.new(boards)
      for _ = 1, C.TICK_HZ * 12 do
        m:run(1)
        local n = 0
        for _, b in pairs(m.boards) do if b.ball then n = n + 1 end end
        A.truthy(n <= 1, "two balls exist at tick " .. m.state.tick)
        if m.state.phase == "play" then A.equal(1, n, "phase is play with no ball") end
      end
    end)
  end)

  describe("targets (§13.1: Glasshouse's character)", function()
    it("b: every target is reachable in play", function()
      -- Same lesson as Foundry's bumpers: a target nothing can reach is
      -- scenery. Board B's bank is the only aimed scoring content in the
      -- game, so if it is unreachable the board has no identity again.
      local def = boards.b
      local seen, total = {}, 0
      for seed = 1, 3 do
        math.randomseed(8800 + seed)
        -- The seed goes to Board.new as well, or all three runs receive the
        -- SAME serve (sim/board.lua falls back to C.RNG_SEED) and this is one
        -- sample wearing three hats. tests/probe_identity.lua carries the
        -- same note; this tripwire was missed when the serve gained jitter.
        local b = Board.new(def, 8800 + seed)
        b:serve()
        local c = cmd()
        for i = 1, math.floor(40 * C.TICK_HZ) do
          if i % 30 == 0 then
            c = cmd(math.random() < 0.55, math.random() < 0.2,
                    math.random() < 0.35, math.random() < 0.35)
          end
          local dead = false
          for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
            if ev.kind == "drain" or ev.kind == "tube" then dead = true end
            if ev.kind == "target" then
              seen[ev.index] = (seen[ev.index] or 0) + 1
              total = total + 1
            end
          end
          if dead then b:serve() end
        end
      end
      for i = 1, #def.targets do
        A.truthy((seen[i] or 0) > 0,
          ("target %d is unreachable: it is scenery, not content"):format(i))
      end
      -- Floor well under the measured rate, as with the bumpers: this is a
      -- "the bank is still live" tripwire, not a tuning target. Two targets
      -- measure ~0.29 hits/s here and ~0.4/s over the longer identity probe;
      -- 0.12 catches the bank going dead without failing on seed noise.
      A.truthy(total / 120 > 0.12,
        ("the bank is barely live: %.2f hits/s"):format(total / 120))
    end)
  end)

  ---------------------------------------------------------------------------
  -- Bumper scoring. A rule, not a contact: unlike `impact`, this one is meant
  -- to reach core/.
  ---------------------------------------------------------------------------

  describe("bumper scoring events", function()
    it("reports the bumper that was hit, by index", function()
      local def = boards.a
      local b   = Board.new(def)
      local target = 2
      local t = def.bumpers[target]
      -- Fired from directly above, so which bumper is struck is not in doubt.
      b:spawn(t.x, t.y - t.r - C.BALL_RADIUS - 8, 0, 700)
      local seen = {}
      run(b, 0.6, cmd(), seen)
      local found
      for _, ev in ipairs(seen) do
        if ev.kind == "bumper" then found = found or ev.index end
      end
      A.equal(target, found, "the wrong bumper scored, or none did")
    end)

    it("does not score a bumper the ball never touched", function()
      local b = Board.new(boards.a)
      b:spawn(340, 300, 0, 0)          -- right side, clear of the cluster
      local seen = {}
      run(b, 0.4, cmd(), seen)
      for _, ev in ipairs(seen) do
        A.truthy(ev.kind ~= "bumper", "a bumper scored with no ball near it")
      end
    end)
  end)

  describe("determinism and replay (§5.1)", function()
    it("reproduces a match exactly from the same intents", function()
      -- §5.1: "whole matches can be recorded and replayed from the intent
      -- stream plus a seed, which is worth the layer on its own for debugging
      -- pinball physics". app/record.lua writes that stream on every session
      -- and nothing had ever checked the promise it depends on.
      --
      -- §4.3 is careful about what determinism is available: identical binary
      -- and identical operation ordering, on one machine. That is exactly the
      -- case here, and exactly what a replay needs.
      local ACTIONS = { "flip_left", "flip_right", "operator_gate", "operator_paddle" }
      local function record_run()
        math.randomseed(9001)
        local stream = {}
        for i = 1, 30 * C.TICK_HZ do
          if i % 19 == 0 then
            stream[#stream+1] = {
              tick = i, player = math.random(2),
              action = ACTIONS[math.random(#ACTIONS)],
              pressed = math.random() < 0.5,
            }
          end
        end
        return stream
      end

      --- Returns a checksum of the WHOLE run, not just where it ended.
      --- Comparing only the final state is far too weak: injecting a random
      --- 0.005 px/s nudge into the sim left the end state identical (the ball
      --- happened to be gone, and the counters agreed) while breaking the
      --- tunneling test three tests earlier. A trajectory that diverges and
      --- reconverges is still a replay that does not replay.
      local function play(stream)
        local m = Match.new(boards)
        local next_i, sum = 1, 0
        for i = 1, 30 * C.TICK_HZ do
          while stream[next_i] and stream[next_i].tick == i do
            m:push(stream[next_i]); next_i = next_i + 1
          end
          m:run(1)
          if i % 7 == 0 then
            local x, y = m.boards[m.state.active]:ball_pos()
            sum = (sum * 31
                   + math.floor((x or 0) * 64)
                   + math.floor((y or 0) * 64) * 7
                   + m.state.stats.score) % 2147483647
          end
        end
        local st = m.state.stats
        return {
          checksum = sum,
          tick = m.state.tick, phase = m.state.phase, active = m.state.active,
          score = st.score, passes = st.passes, drains = st.drains,
          relay = st.relay, rescues = st.rescues,
          vault = m.state.boards.b.meters.vault,
        }
      end

      local stream = record_run()
      local a, b = play(stream), play(stream)
      for k, v in pairs(a) do
        A.equal(v, b[k],
          ("replay diverged on %s after 30s: the intent stream is not enough")
            :format(k))
      end
      -- And the run has to be doing something, or this passes vacuously.
      A.truthy(a.tick > 0 and (a.score > 0 or a.passes > 0 or a.drains > 0),
               "the determinism test replayed an empty match")
      A.truthy(a.checksum ~= 0, "the trajectory checksum never accumulated")
    end)
  end)

  describe("performance headroom (§3)", function()
    it("leaves the fixed timestep an order of magnitude of room", function()
      -- technical-choices.md §3 asserts "performance is not the
      -- discriminator". Measured: a sim step costs ~6.3us against a 4166us
      -- budget at 240 Hz, and a whole 60fps frame including fx, recording and
      -- the objective readout is ~26us. See tests/probe_perf.lua.
      --
      -- The bound here is deliberately loose -- 25% of the step budget, forty
      -- times the measured cost -- because this runs on whatever machine an
      -- agent happens to be on. It is a tripwire for someone adding an O(n^2)
      -- loop to the step, not a benchmark.
      local m = Match.new(boards)
      m:run(400)
      local t0 = os.clock()
      local n = 4000
      m:run(n)
      local per = (os.clock() - t0) / n
      A.truthy(per < C.FIXED_DT * 0.25,
        ("a sim step costs %.0fus of its %.0fus budget")
          :format(per * 1e6, C.FIXED_DT * 1e6))
    end)
  end)

  describe("everything running at once", function()
    it("holds its invariants through a minute of random play", function()
      -- Scoring, cross-board meters, purgatory rescue and the objective
      -- readout are each tested alone. This is the only test that runs them
      -- against each other for a sustained stretch, which is where the bugs
      -- that survive unit tests live. tests/probe_soak.lua is the same thing
      -- at ten minutes, for when something here starts flickering.
      local objective = require("core.objective")
      local names = {}
      for id, d in pairs(boards) do names[id] = d.name end
      math.randomseed(24601)
      local m = Match.new(boards)
      for i = 1, 60 * C.TICK_HZ do
        if i % 22 == 0 then
          local st = m.state
          for _, b in pairs(st.boards) do
            if b.devices.gate and math.random() < 0.3 then b.devices.gate.commanded = math.random() < 0.6 end
            if math.random() < 0.25 then b.devices.post.commanded = math.random() < 0.4 end
          end
          local act = st.boards[st.active]
          act.flippers.left  = math.random() < 0.4
          act.flippers.right = math.random() < 0.4
        end
        m:run(1)
        local st = m.state
        local balls = 0
        for _, b in pairs(m.boards) do if b.ball then balls = balls + 1 end end
        if st.phase == "play" then
          A.equal(1, balls, "phase play with the wrong ball count at tick " .. i)
        else
          A.truthy(balls <= 1, "more than one ball at tick " .. i)
        end
        A.truthy(st.stats.rally_score <= st.stats.score, "rally outgrew the session")
        for id, b in pairs(st.boards) do
          for name, v in pairs(b.meters) do
            A.truthy(v >= 0 and v <= C.CHARGE_MAX,
                     ("%s meter %s out of range: %d"):format(id, name, v))
          end
          A.truthy((b.lit.bumpers or 0) >= 0 and (b.lit.bumpers or 0) <= C.LIT_HITS,
                   id .. " lit counter out of range")
        end
        local o = objective.current(st, names)
        A.truthy(o and o.text and #o.text > 0, "no objective at tick " .. i)
        if i % 2000 == 0 then m:drain_events() end
      end
      A.truthy(#m.feed <= 96, "the feed grew past its cap: " .. #m.feed)
    end)
  end)

  ---------------------------------------------------------------------------
  -- Impact events. Presentation only, but they are a contract app/ relies on
  -- and the threshold behind them is the difference between a set of hits and
  -- a 240 Hz buzz.
  ---------------------------------------------------------------------------

  describe("impact events", function()
    local function impacts_of(m, ticks)
      local out = {}
      for _ = 1, ticks do
        m:run(1)
        for _, ev in ipairs(m:drain_events()) do
          if ev.kind == "impact" then out[#out+1] = ev end
        end
      end
      return out
    end

    it("reports a hit with a surface, a place and a strength", function()
      local m = Match.new(boards)
      m:run(C.TICK_HZ)                                  -- let the serve happen
      m.boards.a:spawn(215, 300, 0, 900)                -- straight down, hard
      local hits = impacts_of(m, C.TICK_HZ * 2)
      A.truthy(#hits > 0, "a ball driven into the floor reported no impact")
      for _, ev in ipairs(hits) do
        A.truthy(ev.what ~= nil and ev.x ~= nil and ev.y ~= nil, "malformed impact")
        A.truthy(ev.impulse >= C.IMPACT_MIN_IMPULSE, "impact under the floor got through")
        A.truthy(ev.what ~= "mouth", "the tube sensor must not report as a contact")
      end
    end)

    it("goes silent once the ball is only resting on something", function()
      -- The reason the threshold exists. A ball sitting on the raised post
      -- solves a contact impulse every single step; without a floor above the
      -- ball's own weight that is 240 events a second, forever.
      local m = Match.new(boards)
      m.state.boards.a.devices.post.commanded = true
      m:run(C.TICK_HZ)
      -- x=224 is the post's own centre. It used to be 192, which is 6px
      -- OUTSIDE the raised post (198..250) and only reached it by landing on
      -- the left flipper first and rolling in -- so the fixture silently
      -- depended on flipper length, and stopped settling when the bat grew to
      -- 64px in boards-v3 phase 0. Drop it where the comment above says.
      m.boards.a:spawn(224, 600, 0, 0)                  -- drop onto the post
      impacts_of(m, C.TICK_HZ * 4)                      -- settle
      local resting = impacts_of(m, C.TICK_HZ * 2)
      A.equal(0, #resting, "a resting ball is still reporting impacts")
    end)

    it("carries impacts on the feed and nowhere else", function()
      -- §5: core/ has no opinion about how hard the ball hit something. The
      -- other half of this invariant -- that core.consume ignores an impact
      -- even if one reaches it -- is asserted in the core spec, where it
      -- needs no physics.
      local m = Match.new(boards)
      local kinds = {}
      for _ = 1, C.TICK_HZ * 6 do
        m:run(1)
        for _, ev in ipairs(m:drain_events()) do kinds[ev.kind] = true end
      end
      A.truthy(kinds.impact, "no impact ever reached the presentation feed")
    end)

    it("bounds the feed when nothing drains it", function()
      -- A headless run never drains, so an uncapped feed grows one table per
      -- contact for the length of the test.
      local m = Match.new(boards)
      m:run(C.TICK_HZ * 20)
      A.truthy(#m.feed <= 96, "feed grew unbounded: " .. #m.feed)
    end)
  end)
  describe("curved walls (core/curve.lua)", function()
    local curve = require("core.curve")

    --- Board A with its shell corners rounded off. Not what ships -- the
    --- shipped shell is still the octagon every measurement in this file was
    --- taken against -- but it is the path a curved wall actually takes:
    --- authored with nodes, expanded at load, built into edge fixtures here.
    local function domed()
      local b = {}
      for k, v in pairs(boards.a) do b[k] = v end
      b.walls = {}
      for i, w in ipairs(boards.a.walls) do b.walls[i] = w end
      local flat = curve.flatten({ 10, 948,
                                   10, 90, { round = 40 },
                                   76, 14, { round = 40 },
                                   372, 14, { round = 40 },
                                   438, 90, { round = 40 },
                                   438, 948 }, "shell")
      A.truthy(flat, "the rounded shell did not expand")
      b.walls[1] = flat or {}
      return b
    end

    it("expands into more wall than it was authored with", function()
      local b = domed()
      A.truthy(#b.walls[1] > #boards.a.walls[1],
        "rounding the corners produced no extra vertices")
    end)

    it("builds a world and holds the ball inside it", function()
      -- The end-to-end claim: a wall authored as curve nodes becomes ordinary
      -- edge fixtures, and the ball meets them. A curve that expanded into a
      -- gap would let the ball straight out of the top of the board.
      local b = Board.new(domed())
      b:serve()
      local worst = 0
      for _ = 1, 8 * C.TICK_HZ do
        b:step(cmd(), b.ball ~= nil)
        local x, y = b:ball_pos()
        if x then
          if y > boards.a.drain_y then break end
          worst = math.max(worst, -y, -x, x - boards.a.size.w)
        end
      end
      A.truthy(worst <= 0, ("the ball left the rounded shell by %.1fpx"):format(worst))
    end)
  end)

  describe("elevated ramps (core/ramp.lua)", function()
    local def = boards.a
    local geom = def.ramps[1].geom

    --- Fire a ball straight into a mouth of the skyway, fast enough to be let
    --- on. Deliberately not a flipper shot: this is testing the layer, and a
    --- flipper shot puts the aim under test at the same time.
    ---
    --- The spawn point is read off the ramp rather than typed, so moving a
    --- foot in the board data moves these tests with it instead of quietly
    --- firing balls at where the ramp used to be.
    local function at_mouth()
      local x, y, tx, ty = ramps.point_at(geom, 2)
      return x - tx * C.RAMP_MOUTH, y - ty * C.RAMP_MOUTH, tx, ty
    end

    local function spawn_into(b, speed)
      local x, y, tx, ty = at_mouth()
      b:spawn(x, y, tx * speed, ty * speed)
    end

    local function launch(speed, sink)
      local b = Board.new(def)
      spawn_into(b, speed or 1600)
      run(b, 6, cmd(), sink)
      return b
    end

    it("puts the ball on the ramp and takes it off again", function()
      local evs = {}
      local b = launch(1600, evs)
      local enter, exit, complete = 0, 0, 0
      for _, ev in ipairs(evs) do
        if ev.kind == "ramp" then
          if ev.at == "enter" then enter = enter + 1 else exit = exit + 1 end
          if ev.complete then complete = complete + 1 end
        end
      end
      A.truthy(complete > 0, "full ride must report completion for scoring")
      A.truthy(enter > 0, "a 1600px/s shot into the mouth never got on the ramp")
      A.equal(enter, exit, "the ball got on the ramp more often than it got off")
      A.equal(nil, b.on_ramp, "the ball was left stranded on the ramp layer")
    end)

    it("lifts the ball off the playfield while it is up there", function()
      local b = Board.new(def)
      spawn_into(b, 1600)
      local top = 0
      for _ = 1, 6 * C.TICK_HZ do
        b:step(cmd(), true)
        top = math.max(top, b:ball_z())
      end
      A.truthy(top > geom.height * 0.9,
        ("the ball never climbed: highest z was %.1f of %g"):format(top, geom.height))
    end)

    it("is flat on the playfield whenever the ball is not on it", function()
      local b = Board.new(def)
      b:serve()
      run(b, 1.0, cmd())
      A.equal(nil, b.on_ramp)
      A.equal(0, b:ball_z(), "a ball on the playfield reported a height")
    end)

    -- Keep the collision-layer test independent of the authored bumper layout.
    local function bumper_under_crown()
      local fixture = {}
      for key, value in pairs(def) do fixture[key] = value end
      local x, y = ramps.point_at(geom, geom.length / 2)
      local bumper = { x = x, y = y, r = 22, restitution = 1.15 }
      fixture.bumpers = { bumper }
      return fixture, bumper
    end

    it("carries the ball OVER the bumpers it crosses", function()
      local fixture, w = bumper_under_crown()
      local b = Board.new(fixture)
      spawn_into(b, 1600)
      local hits, crossed = 0, false
      for _ = 1, 6 * C.TICK_HZ do
        local riding = b.on_ramp ~= nil
        for _, ev in ipairs(b:step(cmd(), true)) do
          -- Only while it is up there. What the ball does after it comes back
          -- down is ordinary play, and on Foundry it very often is a bumper.
          if ev.kind == "bumper" and riding then hits = hits + 1 end
        end
        -- Tracked in the same run rather than a second one, so a ball that
        -- quietly fell back out of the mouth cannot pass this test by never
        -- getting near a bumper in the first place.
        local x, y = b:ball_pos()
        if x and b.on_ramp
           and math.sqrt((x - w.x)^2 + (y - w.y)^2) < w.r + C.BALL_RADIUS then
          crossed = true
        end
      end
      A.truthy(crossed, "the ball never actually passed over a bumper")
      A.equal(0, hits, "a ball on the ramp set off a bumper underneath it")
    end)

    it("still lets a playfield ball hit the bumper under the ramp", function()
      local fixture, w = bumper_under_crown()
      local evs = {}
      local b = Board.new(fixture)
      b:spawn(w.x, w.y - w.r - C.BALL_RADIUS - 30, 0, 260)
      run(b, 2.0, cmd(), evs)
      local hit = false
      for _, ev in ipairs(evs) do if ev.kind == "bumper" and ev.index == 1 then hit = true end end
      A.truthy(hit, "the bumper under the ramp became unreachable from the playfield")
    end)

    it("refuses a ball too slow to reach the crown", function()
      -- Below the gate the ball is not let on at all, and carries on up the
      -- lane. A ramp you can fall into but not climb turns the orbit it sits
      -- in into a dead end -- measured, when the gate ignored the up-board
      -- climb and both boards' bumper reachability went red.
      local evs = {}
      local b = Board.new(def)
      spawn_into(b, geom.enter_speed.start * 0.75)
      run(b, 3, cmd(), evs)
      for _, ev in ipairs(evs) do
        A.truthy(ev.kind ~= "ramp", "a shot below the gate was let onto the ramp")
      end
      A.equal(nil, b.on_ramp)
    end)

    it("leaves a board with no ramps exactly as it was", function()
      local bare = {}
      for k, v in pairs(def) do bare[k] = v end
      bare.ramps = {}
      local b = Board.new(bare)
      A.equal(0, #b.ramps)
      b:serve()
      run(b, 2, cmd())
      A.equal(0, b:ball_z())
    end)
  end)

end
