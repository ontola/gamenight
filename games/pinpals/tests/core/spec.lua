--- Pure-Lua tests. No LÖVE, runs in a bare interpreter in milliseconds (§7).

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local C        = require("core.constants")
  local intents  = require("core.intents")
  local validate = require("core.validate")
  local state    = require("core.state")
  local boards   = require("data.tables.init").load()

  describe("board data", function()
    it("both boards validate", function()
      local ok, errs = validate.set(boards)
      A.truthy(ok, errs and table.concat(errs, "; "))
    end)

    it("tubes point at each other and land on a real entry", function()
      A.equal("b", boards.a.tube.to)
      A.equal("a", boards.b.tube.to)
      A.truthy(boards.a.entry and boards.b.entry)
    end)

    it("rejects a device with no travel time (design.md §6.1)", function()
      local bad = { id = "a", name = "x", size = { w = 10, h = 10 },
                    walls = { {0,0,1,1} }, flippers = {}, devices = {
                      { id = "g", kind = "gate", travel = 0, tradeoff = "x",
                        pivot = {x=1,y=1}, length = 1, closed = 0, open = 1 } } }
      local ok, errs = validate.board(bad)
      A.falsy(ok)
      local found = false
      for _, e in ipairs(errs) do if e:find("travel", 1, true) then found = true end end
      A.truthy(found, "expected a travel-time complaint")
    end)

    it("rejects a device that does not state its trade-off (§6.2)", function()
      local b = boards.a
      local saved = b.devices[1].tradeoff
      b.devices[1].tradeoff = nil
      local ok = validate.board(b)
      b.devices[1].tradeoff = saved
      A.falsy(ok)
    end)

    it("rejects a board that passes to itself", function()
      local b = boards.a
      local saved = b.tube.to
      b.tube.to = "a"
      local ok = validate.board(b)
      b.tube.to = saved
      A.falsy(ok)
    end)
  end)

  describe("roles", function()
    it("are implicit in ball position, never selected", function()
      A.equal("flipper",  intents.role_of(1, "a"))
      A.equal("operator", intents.role_of(2, "a"))
      A.equal("operator", intents.role_of(1, "b"))
      A.equal("flipper",  intents.role_of(2, "b"))
    end)

    it("never leave a player with nothing to do (pillar 1)", function()
      for _, active in ipairs({ "a", "b" }) do
        local r1, r2 = intents.role_of(1, active), intents.role_of(2, active)
        A.truthy(r1 ~= r2, "both players ended up in the same role")
      end
    end)

    it("rejects an unknown action", function()
      A.error_matches("unknown action", function() intents.new(1, "nudge", true, 0) end)
    end)
  end)

  describe("intents", function()
    local s
    local function fresh() s = state.new(boards); s.phase = "play" end

    it("give flippers only to the player whose board holds the ball", function()
      fresh()
      state.apply_intent(s, intents.new(1, "flip_left", true, 0))
      A.truthy(s.boards.a.flippers.left)
      state.apply_intent(s, intents.new(2, "flip_right", true, 0))
      A.falsy(s.boards.a.flippers.right, "the operator must not get flippers")
    end)

    it("give devices on the ACTIVE board to the ball-less player", function()
      fresh()
      state.apply_intent(s, intents.new(2, "operator_paddle", true, 0))
      A.truthy(s.boards.a.devices.post.commanded, "operator acts on the active board, not their own")
      A.falsy(s.boards.b.devices.post.commanded)
    end)

    it("ignore flipper input when there is no ball", function()
      fresh(); s.phase = "serve"
      state.apply_intent(s, intents.new(1, "flip_left", true, 0))
      A.falsy(s.boards.a.flippers.left)
    end)
  end)

  --- §6.2 The outlane guard: the operator's flipper buttons move it.
  describe("the outlane guard", function()
    local s
    local function fresh() s = state.new(boards); s.phase = "play" end

    it("starts where the board data says", function()
      fresh()
      A.equal(boards.a.guards.start, s.boards.a.guard)
      A.equal(boards.b.guards.start, s.boards.b.guard)
    end)

    it("switches sides on either of the operator's flipper buttons", function()
      fresh()
      local was = s.boards.a.guard
      state.apply_intent(s, intents.new(2, "flip_left", true, 0))
      A.equal(was == "left" and "right" or "left", s.boards.a.guard)
      state.apply_intent(s, intents.new(2, "flip_right", true, 1))
      A.equal(was, s.boards.a.guard, "the other button must toggle too, not pick a side")
    end)

    it("does not move on the release, or a tap would flip it twice", function()
      fresh()
      local was = s.boards.a.guard
      state.apply_intent(s, intents.new(2, "flip_left", true, 0))
      state.apply_intent(s, intents.new(2, "flip_left", false, 1))
      A.equal(was == "left" and "right" or "left", s.boards.a.guard)
    end)

    it("is not something the flipper player can touch", function()
      fresh()
      local was = s.boards.a.guard
      state.apply_intent(s, intents.new(1, "flip_left", true, 0))
      A.equal(was, s.boards.a.guard, "the flipper's buttons are flippers")
      A.truthy(s.boards.a.flippers.left, "...and still are")
    end)

    it("acts on the board the ball is on, not the operator's own", function()
      fresh()
      local was_b = s.boards.b.guard
      state.apply_intent(s, intents.new(2, "flip_left", true, 0))
      A.equal(was_b, s.boards.b.guard, "P2 moved the guard on their own board")
    end)

    it("is preparable during transit, like every other operator control", function()
      fresh()
      -- Mid-pass the destination is already active, so the sender spends the
      -- flight arranging the floor the ball is about to land on (§5).
      s.active, s.phase = "b", "transit"
      local was = s.boards.b.guard
      state.apply_intent(s, intents.new(1, "flip_right", true, 0))
      A.equal(was == "left" and "right" or "left", s.boards.b.guard)
    end)

    it("leaves no held-key residue behind (the release bug next door)", function()
      fresh()
      state.apply_intent(s, intents.new(2, "flip_left", true, 0))
      A.falsy(s.held[2].flip_left, "a guard toggle is not a held device command")
    end)

    --- One save, then thirty seconds gone (§6.2's OPEN question, answered:
    --- per-device cooldowns).
    local function save_on(board)
      state.consume(s, { { kind = "guard", board = board, side = s.boards[board].guard,
                           x = 0, y = 0 } })
    end

    it("starts armed", function()
      fresh()
      A.equal(0, s.boards.a.guard_cooldown)
      A.equal(0, s.boards.b.guard_cooldown)
    end)

    it("is spent by the save it makes", function()
      fresh()
      save_on("a")
      A.equal(C.GUARD_COOLDOWN, s.boards.a.guard_cooldown)
      A.truthy(s.last_award and s.last_award.kind == "guard", "the save did not score")
      A.equal(0, s.boards.b.guard_cooldown, "the other board's guard was spent too")
    end)

    it("works ONCE: a second contact neither scores nor re-arms the timer", function()
      fresh()
      save_on("a")
      -- The bar takes GUARD_TRAVEL to retract and can catch the ball again on
      -- the way down. That is the same save.
      for _ = 1, 12 do state.update(s) end
      local after_first = s.boards.a.guard_cooldown
      local banked = s.stats.score
      save_on("a")
      A.falsy(s.last_award, "the retracting bar scored a second time")
      A.equal(banked, s.stats.score)
      A.truthy(s.boards.a.guard_cooldown <= after_first,
               "a second contact restarted the cooldown")
    end)

    it("recharges on the clock, and on the board you are not looking at", function()
      fresh()
      save_on("b")                      -- spent on the DORMANT board
      A.equal("a", s.active, "this test needs board B to be the idle one")
      local half = math.floor(C.GUARD_COOLDOWN * C.TICK_HZ / 2)
      for _ = 1, half do state.update(s) end
      A.between(C.GUARD_COOLDOWN * 0.45, C.GUARD_COOLDOWN * 0.55,
                s.boards.b.guard_cooldown)
      for _ = 1, half + 4 do state.update(s) end
      A.equal(0, s.boards.b.guard_cooldown,
              "a guard spent on a board you then left never came back")
    end)

    it("can still be switched sides while it is spent", function()
      fresh()
      save_on("a")
      local was = s.boards.a.guard
      state.apply_intent(s, intents.new(2, "flip_left", true, 0))
      A.equal(was == "left" and "right" or "left", s.boards.a.guard,
              "choosing where the next save happens is the decision that is left")
    end)

    it("comes back with the new ball, on both boards", function()
      fresh()
      save_on("a")
      save_on("b")
      A.equal(C.GUARD_COOLDOWN, s.boards.a.guard_cooldown)
      A.equal(C.GUARD_COOLDOWN, s.boards.b.guard_cooldown)
      -- Lose it, all the way through purgatory to a confirmed drain.
      state.consume(s, { { kind = "drain", board = "a" } })
      A.equal("purgatory", s.phase)
      for _ = 1, math.ceil(C.PURGATORY_TIME * C.TICK_HZ) + 2 do state.update(s) end
      A.equal("drain", s.phase)
      A.equal(0, s.boards.a.guard_cooldown, "the new ball starts with no guard")
      A.equal(0, s.boards.b.guard_cooldown, "the dormant board was left spent")
    end)

    it("does NOT come back for a rescue -- the ball was never lost", function()
      fresh()
      save_on("a")
      state.consume(s, { { kind = "drain", board = "a" } })
      -- §8: post down at the moment of the drain arms the rescue, a fresh
      -- raise makes it.
      s.boards.a.devices.post.commanded = false
      state.update(s)
      s.boards.a.devices.post.commanded = true
      state.update(s)
      A.equal("serve", s.phase, "this test needs the rescue to have happened")
      A.truthy(s.boards.a.guard_cooldown > 0,
               "a rescue handed back a save the team had already spent")
    end)

    it("survives a pass: a crossing is not a ball loss", function()
      fresh()
      save_on("a")
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      for _ = 1, C.TICK_HZ do state.update(s) end
      A.equal("b", s.active)
      A.truthy(s.boards.a.guard_cooldown > 0,
               "passing the ball away refilled the guard behind it")
    end)

    it("is longer than a ball, which is the point and not an accident", function()
      -- Measured ball life is 5-15s (probe_identity). With the cooldown
      -- clearing on every ball loss, this constant's whole job is to be
      -- longer than one ball: that is what makes it ONE save per ball rather
      -- than a lane the operator closes and reopens at will.
      A.truthy(C.GUARD_COOLDOWN > 15,
               ("GUARD_COOLDOWN is %gs, inside a single ball"):format(C.GUARD_COOLDOWN))
    end)
  end)

  describe("the pass", function()
    it("lets only the sender aim, stops on release, and carries the bounded angle", function()
      for _, from in ipairs({ "a", "b" }) do
        local s = state.new(boards); s.phase, s.active = "play", from
        state.consume(s, { { kind = "tube", board = from, speed = 1500 } })
        local sender = from == "a" and 1 or 2
        local receiver = 3 - sender
        local guard = s.boards[s.active].guard
        state.apply_intent(s, intents.new(receiver, "flip_left", true, 0))
        state.update(s)
        A.equal(0, s.transit.aim)
        state.apply_intent(s, intents.new(sender, "flip_left", true, 0))
        state.update(s)
        A.truthy(s.transit.aim > 0)
        A.equal(guard, s.boards[s.active].guard)
        state.apply_intent(s, intents.new(sender, "flip_right", true, 0))
        local held = s.transit.aim
        state.update(s)
        A.equal(held, s.transit.aim, "both buttons cancel")
        state.apply_intent(s, intents.new(sender, "flip_left", false, 0))
        for _ = 1, 75 do state.update(s) end
        A.equal(-C.TRANSIT_AIM_LIMIT, s.transit.aim)
        state.apply_intent(s, intents.new(sender, "flip_right", false, 0))
        state.update(s)
        A.equal(-C.TRANSIT_AIM_LIMIT, s.transit.aim)
        local arrival
        while s.transit do
          for _, c in ipairs(state.update(s)) do arrival = c end
        end
        A.near(-C.TRANSIT_AIM_LIMIT, arrival.aim, 1e-9)
        A.equal(1500, arrival.speed)
        state.consume(s, { { kind = "tube", board = s.active, speed = 1500 } })
        A.equal(0, s.transit.aim, "each pass starts centered")
      end
    end)

    it("hands the board over and clamps the speed it carries (§5)", function()
      local s = state.new(boards); s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 1e9 } })
      A.equal("transit", s.phase)
      A.equal("b", s.active, "the destination becomes active immediately")
      A.equal(C.TRANSIT_MAX_SP, s.transit.speed)
      A.equal(1, s.stats.passes)
    end)

    it("keeps a dribbled pass moving", function()
      local s = state.new(boards); s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 1 } })
      A.equal(C.TRANSIT_MIN_SP, s.transit.speed)
    end)

    it("lets the sender operate the destination during flight", function()
      local s = state.new(boards); s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      -- P1 sent the ball; P1 is now the operator on B, mid-flight.
      A.equal("operator", intents.role_of(1, s.active))
      state.apply_intent(s, intents.new(1, "operator_paddle", true, 0))
      A.truthy(s.boards.b.devices.post.commanded)
    end)

    it("arrives after exactly the transit time and hands over the speed", function()
      local s = state.new(boards); s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 1500 } })
      local arrived, steps = nil, 0
      for _ = 1, C.TICK_HZ * 3 do
        steps = steps + 1
        for _, c in ipairs(state.update(s)) do
          if c.kind == "arrive" then arrived = c break end
        end
        if arrived then break end
      end
      A.truthy(arrived, "the ball never came out of the tube")
      ---@cast arrived -nil
      A.equal("b", arrived.board)
      A.equal(1500, arrived.speed)
      A.near(C.TRANSIT_TIME, steps * C.FIXED_DT, C.FIXED_DT * 2)
      A.equal("play", s.phase)
    end)

    it("releases held flippers when the ball leaves", function()
      local s = state.new(boards); s.phase = "play"
      state.apply_intent(s, intents.new(1, "flip_left", true, 0))
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      A.falsy(s.boards.a.flippers.left, "a held key must not strand a flipper")
    end)
  end)

  describe("draining", function()
    it("resets the relay and re-serves on the same board", function()
      local s = state.new(boards); s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      for _ = 1, C.TICK_HZ do state.update(s) end        -- land on B
      A.equal("play", s.phase)
      A.equal(1, s.stats.relay)
      state.consume(s, { { kind = "drain", board = "b" } })
      -- §8: a drained ball goes to purgatory first, and keeps the rally while
      -- it hangs there. Nothing is lost until the window actually expires.
      A.equal("purgatory", s.phase)
      A.equal(1, s.stats.relay, "the rally died before the rescue window did")
      for _ = 1, math.ceil(C.PURGATORY_TIME * C.TICK_HZ) + 2 do state.update(s) end
      A.equal("drain", s.phase)
      A.equal(0, s.stats.relay)
      A.equal(1, s.stats.best_relay, "the best relay must survive the drain")

      local served
      for _ = 1, C.TICK_HZ * 3 do
        for _, c in ipairs(state.update(s)) do if c.kind == "serve" then served = c end end
        if served then break end
      end
      A.truthy(served, "no re-serve after the drain")
      A.equal("b", served.board, "re-serve happens where the ball was lost")
    end)
  end)

  describe("device commands persist (§7 dormant board keeps its state)", function()
    it("a device left open on a board is still open when you come back", function()
      local s = state.new(boards); s.phase = "play"
      state.apply_intent(s, intents.new(2, "operator_paddle", true, 0))
      A.truthy(s.boards.a.devices.post.commanded)
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      for _ = 1, C.TICK_HZ do state.update(s) end
      A.truthy(s.boards.a.devices.post.commanded, "board A forgot what the operator did")
    end)

    it("still lets a player let go of a device after their role swaps",
       function()
      -- The other half, and it was broken. The operator acts on the ACTIVE
      -- board, so a player can press the gate on board A and still be holding
      -- it when the ball lands on B and makes them the flipper. That release
      -- used to be discarded -- a flipper has no operator actions -- leaving
      -- board A's gate commanded open forever with their finger off the key.
      -- §6.2 makes an open gate close the safe return loop, so the ball came
      -- back later to a board whose safe return had quietly gone.
      local s = state.new(boards); s.phase = "play"
      state.apply_intent(s, intents.new(2, "operator_paddle", true, 0))
      A.truthy(s.boards.a.devices.post.commanded)

      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      for _ = 1, C.TICK_HZ do state.update(s) end
      A.equal("b", s.active)
      A.equal("flipper", intents.role_of(2, s.active), "the role did not swap")

      state.apply_intent(s, intents.new(2, "operator_paddle", false, 1))
      A.truthy(not s.boards.a.devices.post.commanded,
               "board A's gate stayed open after the player let go")
    end)

    it("sends a release to the board it was pressed on, not the active one",
       function()
      -- Routing it to whatever board is active now would close a gate on the
      -- wrong table, which is a different bug wearing the same shape.
      local s = state.new(boards); s.phase = "play"
      state.apply_intent(s, intents.new(2, "operator_paddle", true, 0))
      state.consume(s, { { kind = "tube", board = "a", speed = 900 } })
      for _ = 1, C.TICK_HZ do state.update(s) end
      -- Board B's gate was never touched and must stay that way.
      state.apply_intent(s, intents.new(2, "operator_paddle", false, 1))
      A.truthy(not s.boards.b.devices.post.commanded,
               "the release closed a gate on the wrong board")
    end)
  end)
  ---------------------------------------------------------------------------
  -- §5 layering. Impacts are presentation: sim/ reports them so app/ can
  -- sound and light them, and the rules must stay blind to them. A scoring
  -- rule that quietly started keying off contact strength would break the
  -- headless tests and the online plan at the same time.
  ---------------------------------------------------------------------------
  describe("presentation events are not rules", function()
    it("ignores impacts entirely", function()
      local s = state.new(boards)
      s.phase = "play"
      local before = {
        phase = s.phase, passes = s.stats.passes,
        drains = s.stats.drains, relay = s.stats.relay, active = s.active,
      }
      state.consume(s, {
        { kind = "impact", board = "a", what = "bumper", x = 1, y = 2, impulse = 99 },
        { kind = "impact", board = "a", what = "wall",   x = 3, y = 4, impulse = 0.4 },
      })
      A.equal(before.phase,  s.phase)
      A.equal(before.active, s.active)
      A.equal(before.passes, s.stats.passes)
      A.equal(before.drains, s.stats.drains)
      A.equal(before.relay,  s.stats.relay)
    end)
  end)

  ---------------------------------------------------------------------------
  -- §9 Scoring. The multiplier lives on passing, not on shots.
  ---------------------------------------------------------------------------
  describe("relay heat", function()
    local score = require("core.score")

    it("is the crossing count, floored at x1", function()
      A.equal(1, score.heat(0), "a fresh ball must still score")
      A.equal(1, score.heat(1), "the first pass of a life is base rate")
      A.equal(5, score.heat(5))
    end)

    it("has a ceiling", function()
      -- Without one, a long rally makes every earlier rally unreadable and
      -- the multiplier stops being a number anyone can hold in their head.
      A.equal(C.HEAT_MAX, score.heat(C.HEAT_MAX + 40))
    end)

    it("scales arrival speed far more gently than score", function()
      -- Score can escalate wildly and cost nothing. Arrival speed is a
      -- difficulty knob AND a tunneling risk, so the two curves are separate
      -- on purpose and this is the assertion that keeps them separate.
      A.equal(1, score.speed_scale(0))
      A.truthy(score.speed_scale(4) < 1.25, "speed ramps as fast as score")
      A.equal(C.HEAT_SPEED_MAX, score.speed_scale(999))
    end)
  end)

  describe("scoring", function()
    local score = require("core.score")

    local function fresh()
      return { relay = 0, score = 0, rally_score = 0, best_rally_score = 0 }
    end

    it("pays the current multiplier", function()
      local st = fresh()
      st.relay = 3
      A.equal(C.SCORE_PASS * 3, score.award(st, "pass"))
      A.equal(C.SCORE_PASS * 3, st.score)
    end)

    it("keeps the session total but drops the rally on a drain", function()
      local st = fresh()
      st.relay = 2
      score.award(st, "pass")
      local banked = st.score
      A.equal(banked, st.rally_score)
      score.end_rally(st)
      A.equal(banked, st.score,            "a drain took the session score")
      A.equal(0,      st.rally_score,      "the rally survived its own drain")
      A.equal(banked, st.best_rally_score, "best rally was not remembered")
    end)

    it("makes one long rally worth far more than the same passes scattered",
       function()
      -- This is §9 itself, as a test: "the rally becomes simultaneously more
      -- valuable and more likely to end". If these two ever come out equal,
      -- the multiplier has stopped doing the only job it has.
      local together = fresh()
      for _ = 1, 5 do
        together.relay = together.relay + 1
        score.award(together, "pass")
      end
      local scattered = fresh()
      for _ = 1, 5 do
        scattered.relay = 1
        score.award(scattered, "pass")
        scattered.relay = 0
        score.end_rally(scattered)
      end
      -- Measured: 15,000 together against 5,000 scattered at five crossings,
      -- and the gap widens with length (45,000 vs 9,000 at nine).
      A.truthy(together.score >= scattered.score * 3,
               ("a 5-rally paid %d against %d scattered -- the curve is flat")
                 :format(together.score, scattered.score))
    end)
  end)

  describe("scoring through the match rules", function()
    local score = require("core.score")

    it("awards a pass at the heat the crossing just created", function()
      -- Awarding at the OLD heat pays the escalation one pass late, which
      -- makes the readout disagree with the number that floats up.
      local s = state.new(boards)
      s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 1200 } })
      A.equal(1, s.stats.relay)
      A.equal(C.SCORE_PASS * score.heat(1), s.stats.score)
      A.equal(C.SCORE_PASS * score.heat(1), s.last_award.value)
    end)

    it("sends the ball on faster as the rally heats up", function()
      local cold = state.new(boards)
      cold.phase = "play"
      state.consume(cold, { { kind = "tube", board = "a", speed = 1200 } })

      local hot = state.new(boards)
      hot.phase = "play"
      hot.stats.relay = 8
      state.consume(hot, { { kind = "tube", board = "a", speed = 1200 } })

      A.truthy(hot.transit.speed > cold.transit.speed,
               "heat did not reach the ball (§9: worth more AND moving faster)")
      A.truthy(hot.transit.speed <= C.TRANSIT_MAX_SP, "heat outran the clamp")
    end)

    it("takes the rally, not the session, when the ball drains", function()
      local s = state.new(boards)
      s.phase = "play"
      state.consume(s, { { kind = "tube", board = "a", speed = 1200 } })
      local banked = s.stats.score
      s.phase = "play"
      state.consume(s, { { kind = "drain", board = "b" } })
      for _ = 1, math.ceil(C.PURGATORY_TIME * C.TICK_HZ) + 2 do state.update(s) end
      A.equal(0,      s.stats.relay)
      A.equal(0,      s.stats.rally_score)
      A.equal(banked, s.stats.score)
      A.equal(banked, s.stats.best_rally_score)
    end)

    it("scores a bumper on the board that reported it", function()
      local s = state.new(boards)
      s.phase = "play"
      state.consume(s, { { kind = "bumper", board = "a", index = 1, x = 95, y = 250 } })
      A.equal(C.SCORE_BUMPER * score.heat(0), s.stats.score)
      A.equal("bumper", s.last_award.kind)
    end)
  end)

  ---------------------------------------------------------------------------
  -- §13.1 Board identity, and the target banks that carry it.
  ---------------------------------------------------------------------------
  describe("target banks", function()
    local score = require("core.score")

    local function banked_board() return "b", boards.b end

    it("offers aimed banks on both boards", function()
      for _, id in ipairs({ "a", "b" }) do
        A.truthy(#boards[id].targets >= 2)
      end
    end)

    it("lights a target when it is hit, and pays for it", function()
      local id = banked_board()
      local s = state.new(boards)
      s.phase = "play"
      state.consume(s, { { kind = "target", board = id, index = 1, x = 1, y = 2 } })
      A.truthy(s.boards[id].targets[1].lit, "a struck target did not light")
      A.equal(C.SCORE_TARGET * score.heat(0), s.stats.score)
    end)

    it("pays a struck target again but does not re-count it", function()
      -- Otherwise the cheapest way to clear a bank is to rattle one target.
      local id, def = banked_board()
      local s = state.new(boards)
      s.phase = "play"
      local hit = { kind = "target", board = id, index = 1, x = 1, y = 2 }
      state.consume(s, { hit })
      local after_one = s.stats.score
      state.consume(s, { hit })
      A.equal(after_one * 2, s.stats.score, "a repeat hit stopped scoring")
      local lit = 0
      for i = 1, #def.targets do
        if s.boards[id].targets[i].lit then lit = lit + 1 end
      end
      A.equal(1, lit, "one target counted twice toward its bank")
    end)

    it("pays a bonus and resets when the whole bank is lit", function()
      local id, def = banked_board()
      local s = state.new(boards)
      s.phase = "play"
      local plain = 0
      for i = 1, #def.targets do
        state.consume(s, { { kind = "target", board = id, index = i, x = 0, y = 0 } })
        if i < #def.targets then plain = s.stats.score end
      end
      A.truthy(s.stats.score > plain + C.SCORE_TARGET,
               "clearing the bank paid nothing over the last target")
      for i = 1, #def.targets do
        A.truthy(not s.boards[id].targets[i].lit,
                 ("target %d stayed lit after the bank cleared"):format(i))
      end
    end)
  end)

  describe("board identity (§13.1)", function()
    --- The geometric half of the identity, which is pure data and therefore
    --- worth asserting cheaply here: Foundry is the forgiving board, and
    --- "forgiving" is mostly the width of the gap the ball falls through.
    --- Behavioural confirmation (ball life, points/s) lives in
    --- tests/probe_identity.lua, which is too slow to be a gate.
    local function drain_gap(def)
      local left, right
      for _, f in ipairs(def.flippers) do
        if f.side == "left" then left = f else right = f end
      end
      local reach = math.cos(C.FLIPPER_REST) * C.FLIPPER_LEN
      return (right.x - reach) - (left.x + reach)
    end

    it("gives Foundry the narrower drain", function()
      -- This was measurably backwards before 2026-09-06: the board documented
      -- as forgiving drained MORE often per second than the one documented as
      -- punishing.
      A.truthy(drain_gap(boards.a) < drain_gap(boards.b) - 8,
        ("Foundry %.1fpx vs Glasshouse %.1fpx: the boards have stopped differing")
          :format(drain_gap(boards.a), drain_gap(boards.b)))
    end)

    it("keeps the ball wider than neither gap", function()
      -- A gap under a ball width is a wall, not a drain, and would quietly
      -- turn one board into a board that cannot lose.
      for _, id in ipairs({ "a", "b" }) do
        A.truthy(drain_gap(boards[id]) > C.BALL_RADIUS * 2,
          ("board %s cannot drain: gap %.1f, ball %.1f")
            :format(id, drain_gap(boards[id]), C.BALL_RADIUS * 2))
      end
    end)
  end)

  ---------------------------------------------------------------------------
  -- §7 Cross-board state. "You play A to prepare B, then pass and cash in --
  -- which arms A again."
  ---------------------------------------------------------------------------
  describe("cross-board state", function()
    local score = require("core.score")

    local function bump(s, n)
      for _ = 1, n do
        state.consume(s, { { kind = "bumper", board = "a", index = 1, x = 0, y = 0 } })
      end
    end

    local function clear_vault(s)
      for i = 1, #boards.b.targets do
        state.consume(s, { { kind = "target", board = "b", index = i, x = 0, y = 0 } })
      end
    end

    it("charges the partner board, not the one being played", function()
      -- The whole mechanic: Foundry's chaos is worth little here and fills
      -- something over there.
      local s = state.new(boards)
      s.phase = "play"
      bump(s, 3)
      A.equal(3, s.boards.b.meters.vault, "Foundry's bumpers did not charge Glasshouse")
      A.equal(nil, s.boards.a.meters.vault, "the charge landed on the wrong board")
    end)

    it("caps the charge, so grinding one board cannot be the whole game", function()
      -- §5: passing must be tempting, not compulsory. The cap is what stops
      -- "stay on Foundry forever" from dominating -- past it, Foundry pays
      -- its own low rate and the only way to cash is to pass.
      local s = state.new(boards)
      s.phase = "play"
      bump(s, C.CHARGE_MAX + 25)
      A.equal(C.CHARGE_MAX, s.boards.b.meters.vault)
    end)

    it("pays the bank bonus scaled by what the partner board built", function()
      local cold = state.new(boards)
      cold.phase = "play"
      clear_vault(cold)

      local charged = state.new(boards)
      charged.phase = "play"
      bump(charged, C.CHARGE_MAX)
      local before = charged.stats.score
      clear_vault(charged)
      local hot_bank = charged.stats.score - before

      A.truthy(hot_bank > cold.stats.score * 4,
        ("a fully charged vault paid %d against a cold %d: preparation is not paying")
          :format(hot_bank, cold.stats.score))
    end)

    it("spends the charge when the vault is cashed", function()
      local s = state.new(boards)
      s.phase = "play"
      bump(s, 5)
      clear_vault(s)
      A.equal(0, s.boards.b.meters.vault, "the vault kept its charge after paying out")
    end)

    it("lights the partner board's bumpers, closing the loop", function()
      local s = state.new(boards)
      s.phase = "play"
      A.equal(0, s.boards.a.lit.bumpers)
      clear_vault(s)
      A.equal(C.LIT_HITS, s.boards.a.lit.bumpers,
              "clearing Glasshouse's vault did not arm Foundry")
    end)

    it("pays more for a lit bumper, and spends the lighting", function()
      local s = state.new(boards)
      s.phase = "play"
      clear_vault(s)
      local before = s.stats.score
      bump(s, 1)
      local lit_value = s.stats.score - before
      A.equal(C.SCORE_BUMPER * score.heat(0) * C.LIT_MULT, lit_value)
      A.equal(C.LIT_HITS - 1, s.boards.a.lit.bumpers, "a lit hit was free")
    end)

    it("keeps cross-board state through a drain", function()
      -- §7: "the dormant board keeps its state". If a drain wiped it, every
      -- rally would start from nothing and there would be no reason to
      -- prepare anything.
      local s = state.new(boards)
      s.phase = "play"
      bump(s, 4)
      clear_vault(s)
      s.phase = "play"
      state.consume(s, { { kind = "drain", board = "a" } })
      for _ = 1, math.ceil(C.PURGATORY_TIME * C.TICK_HZ) + 2 do state.update(s) end
      A.equal(C.LIT_HITS, s.boards.a.lit.bumpers, "a drain unlit the bumpers")
      -- The drain put the match into its drain phase, where nothing scores.
      -- Serving the next ball is what resumes play, and the question is
      -- whether the board still remembers what was built before the loss.
      s.phase = "play"
      bump(s, 2)
      A.equal(2, s.boards.b.meters.vault, "the vault forgot its charge on a drain")
    end)
  end)

  ---------------------------------------------------------------------------
  -- §8 Purgatory rescue. "My mistake becomes your chance to be a hero, which
  -- is the best feeling co-op can produce."
  ---------------------------------------------------------------------------
  describe("purgatory rescue", function()
    local function to_purgatory(relay)
      local s = state.new(boards)
      s.phase = "play"
      for _ = 1, (relay or 0) do
        s.phase = "play"
        state.consume(s, { { kind = "tube", board = s.active, speed = 900 } })
        s.phase = "play"
      end
      s.phase = "play"
      state.consume(s, { { kind = "drain", board = s.active } })
      return s
    end

    local function run(s, seconds)
      for _ = 1, math.ceil(seconds * C.TICK_HZ) do state.update(s) end
    end

    it("hangs the ball instead of killing it", function()
      local s = to_purgatory(2)
      A.equal("purgatory", s.phase)
      A.equal(0, s.stats.drains, "the drain was counted before the window closed")
      A.truthy(s.stats.relay > 0, "the rally died on contact with the drain")
    end)

    it("lets the partner pull it back by raising the post", function()
      local s = to_purgatory(3)
      local relay, score_before = s.stats.relay, s.stats.score
      s.boards[s.active].devices.post.commanded = true    -- the rescue
      run(s, 0.2)
      A.equal("serve", s.phase, "raising the post did not rescue the ball")
      A.equal(relay, s.stats.relay, "the rescue cost the rally")
      A.equal(score_before, s.stats.score, "the rescue cost points")
      A.equal(0, s.stats.drains, "a rescued ball still counted as a drain")
      A.equal(1, s.stats.rescues)
    end)

    it("does not rescue for free from a post that was already up", function()
      -- The rescue must be an action taken inside the window, not a state
      -- that happens to be true when the ball arrives in it. A 10-minute
      -- soak of random play with the old rule produced 29 rescues against 1
      -- drain: the operator could idle with the post up and never lose a
      -- ball. Releasing and re-pressing still works -- that is an action.
      local s = state.new(boards)
      s.phase = "play"
      s.boards[s.active].devices.post.commanded = true
      state.consume(s, { { kind = "drain", board = s.active } })
      run(s, C.PURGATORY_TIME + 0.05)
      A.equal("drain", s.phase, "a post left up rescued the ball by itself")
      A.equal(0, s.stats.rescues)
    end)

    it("rearms when the operator releases and presses again", function()
      local s = state.new(boards)
      s.phase = "play"
      local post = s.boards[s.active].devices.post
      post.commanded = true
      state.consume(s, { { kind = "drain", board = s.active } })
      run(s, 0.1)
      post.commanded = false                          -- release: arms it
      run(s, 0.1)
      post.commanded = true                           -- press: the save
      run(s, 0.1)
      A.equal("serve", s.phase, "a deliberate re-press did not rescue")
      A.equal(1, s.stats.rescues)
    end)

    it("loses the ball if nobody acts", function()
      local s = to_purgatory(3)
      run(s, C.PURGATORY_TIME + 0.05)
      A.equal("drain", s.phase)
      A.equal(1, s.stats.drains)
      A.equal(0, s.stats.relay)
      A.equal(0, s.stats.rescues)
    end)

    it("spends every vault charge to do it (§6.2)", function()
      -- The trade. A rescue is otherwise strictly good, and an operator
      -- action that is always correct makes the operator a button-presser.
      -- Keep the rally or keep the preparation, decided in under two seconds.
      local s = to_purgatory(1)
      s.boards.b.meters.vault = 7
      s.boards[s.active].devices.post.commanded = true
      -- s.rescue is a one-frame signal, cleared at the top of the next tick
      -- exactly like s.last_award, so it has to be caught on the tick it
      -- happens. sim/match.lua puts it on the presentation feed for app/.
      local reported
      for _ = 1, math.ceil(0.2 * C.TICK_HZ) do
        state.update(s)
        reported = reported or s.rescue
      end
      A.equal("serve", s.phase)
      A.equal(0, s.boards.b.meters.vault, "the rescue was free")
      A.truthy(reported, "the rescue was never signalled")
      A.equal(7, reported.spent, "the cost was not reported for the readout")
    end)

    it("leaves the charge alone when the rescue is not made", function()
      local s = to_purgatory(1)
      s.boards.b.meters.vault = 7
      run(s, C.PURGATORY_TIME + 0.05)
      A.equal("drain", s.phase)
      A.equal(7, s.boards.b.meters.vault, "losing the ball also burned the vault")
    end)

    it("gives the partner time to react, not just reflexes", function()
      -- The post takes PADDLE_TRAVEL to rise. A window that does not clear it
      -- comfortably is a reflex test rather than a decision, and §8 wants the
      -- second one.
      A.truthy(C.PURGATORY_TIME > C.PADDLE_TRAVEL * 4,
        ("the rescue window is %.2fs against %.2fs of post travel")
          :format(C.PURGATORY_TIME, C.PADDLE_TRAVEL))
    end)
  end)

  ---------------------------------------------------------------------------
  -- §7: the loop has to be legible, or it is two numbers moving in private.
  ---------------------------------------------------------------------------
  describe("objective readout", function()
    local objective = require("core.objective")
    local names = {}
    for id, def in pairs(boards) do names[id] = def.name end

    local function at(mut)
      local s = state.new(boards)
      s.phase = "play"
      mut(s)
      return objective.current(s, names)
    end

    it("sends a fresh ball to charge the partner board", function()
      local o = at(function() end)
      A.truthy(o.text:find("CHARGE"), "fresh ball got: " .. o.text)
      A.truthy(o.here, "the first thing to do is not on the board being played")
    end)

    it("asks for a pass once the partner's vault is worth cashing", function()
      local o = at(function(s) s.boards.b.meters.vault = 4 end)
      A.truthy(o.text:find("PASS"), "charged vault got: " .. o.text)
      A.truthy(not o.here, "it pointed at the board already being played")
      A.equal("b", o.board)
    end)

    it("shouts when the vault is full", function()
      local o = at(function(s) s.boards.b.meters.vault = C.CHARGE_MAX end)
      A.truthy(o.urgent, "a full vault is not urgent: " .. o.text)
    end)

    it("says cash it when you are standing on it", function()
      local o = at(function(s)
        s.active = "b"
        s.boards.b.meters.vault = 6
      end)
      A.truthy(o.text:find("CLEAR"), "standing on a charged vault got: " .. o.text)
      A.truthy(o.here)
    end)

    it("puts lit bumpers above everything, because they expire", function()
      -- A charged vault waits. A lit board is a timer running out, so it has
      -- to outrank the vault even while the vault is full.
      local o = at(function(s)
        s.boards.b.meters.vault = C.CHARGE_MAX
        s.boards.a.lit.bumpers  = 7
      end)
      A.truthy(o.text:find("LIT"), "lit bumpers lost to a full vault: " .. o.text)
      A.equal("a", o.board)
    end)

    it("always says something", function()
      -- A readout that can be blank is a readout players stop looking at.
      for _, id in ipairs({ "a", "b" }) do
        local o = at(function(s) s.active = id end)
        A.truthy(o.text and #o.text > 0, "no objective on board " .. id)
        A.truthy(#o.text < 34, "too long to read at a glance: " .. o.text)
      end
    end)
  end)

  ---------------------------------------------------------------------------
  -- §7 wiring validation. A link that points at nothing is a mechanic that
  -- silently never fires, which is the worst failure available to something
  -- two players are supposed to be building toward together.
  ---------------------------------------------------------------------------
  describe("cross-board wiring validation", function()
    local function copy(v)
      if type(v) ~= "table" then return v end
      local t = {}
      for k, x in pairs(v) do t[k] = copy(x) end
      return t
    end

    local function mutated(f)
      local set = { a = copy(boards.a), b = copy(boards.b) }
      f(set)
      local ok, errs = validate.set(set)
      return ok, table.concat(errs or {}, " | ")
    end

    it("accepts the shipped boards", function()
      local ok, why = mutated(function() end)
      A.truthy(ok, "the real board set does not validate: " .. why)
    end)

    it("rejects a link to a board that does not exist", function()
      local ok, why = mutated(function(set)
        set.a.links[1].charges.board = "z"
      end)
      A.truthy(not ok, "a link to board 'z' was accepted")
      A.truthy(why:find("no such board"), "wrong complaint: " .. why)
    end)

    it("rejects a charge no bank will ever cash", function()
      -- The meter name has to match a bank on the destination or the charge
      -- accumulates somewhere nothing reads.
      local ok, why = mutated(function(set)
        set.a.links[1].charges.meter = "strongroom"
      end)
      A.truthy(not ok, "a charge into a nonexistent bank was accepted")
      A.truthy(why:find("no 'strongroom' bank"), "wrong complaint: " .. why)
    end)

    it("rejects lighting something the destination does not have", function()
      -- This one caught a real experiment mid-flight: removing Foundry's
      -- bumpers to test a hypothesis left Glasshouse lighting a cluster that
      -- no longer existed, and the loader refused the board set rather than
      -- running a game with a dead link in it.
      local ok, why = mutated(function(set) set.a.bumpers = {} end)
      A.truthy(not ok, "lighting a board with no bumpers was accepted")
      A.truthy(why:find("no bumpers to light"), "wrong complaint: " .. why)
    end)

    it("rejects a target with no bank", function()
      local ok, why = mutated(function(set) set.b.targets[1].bank = nil end)
      A.truthy(not ok, "a bankless target was accepted")
      A.truthy(why:find("bank"), "wrong complaint: " .. why)
    end)
  end)

end
