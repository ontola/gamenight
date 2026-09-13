--- How hard is the pass when the ball is MOVING?
---
--- Every pass-rate number in this repo so far comes from a ball resting on a
--- flipper that is then flipped: a perfectly timed shot from a perfectly
--- placed ball. That is not the game. prototype.md §5 flags it -- "the pass
--- may be too easy at ~60%... a real moving ball is harder".
---
--- Here the ball arrives the way it actually does, out of the tube at the
--- entry point, falls, and is flipped on a trigger line with human timing
--- error. Two things come out:
---
---   1. the pass rate a receiving player actually experiences, and
---   2. how forgiving the shot is -- the width of the timing window, which is
---      what "too easy" really means. A shot you can hit from anywhere is
---      easy no matter what its peak rate is.
---
---   PINPALS_SUITE=tests.probe_timing love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- One received ball. Arrives at the entry the way a real pass does, with
  --- the spread a real pass has -- exit speed, and a little scatter in where
  --- and how it comes out of the tube. Without that scatter every trial at a
  --- given speed is the same trial, and a "28-sample" rate is really 7
  --- samples repeated: the first version of this probe reported 0%, 14%, 57%
  --- and 100% and nothing else, which are just multiples of 1/7.
  ---
  --- Timing is modelled as a delay after the ball crosses an arming line well
  --- above the flippers, so a flip can be genuinely EARLY as well as late.
  --- Triggering on a y-line cannot do that -- the first version's "-80ms"
  --- and "0ms" columns were identical because neither could fire sooner than
  --- the line itself.
  ---@return "pass"|"drain"|"lost"
  local function receive(def, delay_s, seed)
    math.randomseed(seed)
    local b = Board.new(def)
    local e = def.entry
    local speed = C.TRANSIT_MIN_SP
                + (C.TRANSIT_MAX_SP - C.TRANSIT_MIN_SP) * math.random()
    local ang = math.atan2(e.dir.y, e.dir.x) + (math.random() * 2 - 1) * 0.10
    local base = cmd(true, false)      -- gate open: this is the flipper's problem
    for _ = 1, math.floor(0.45 * C.TICK_HZ) do b:step(base, true) end
    b:spawn(e.x + (math.random() * 2 - 1) * 6, e.y,
            math.cos(ang) * speed, math.sin(ang) * speed)

    -- An aiming player, not a metronome. The first version flipped at a
    -- FIXED delay after an arming line while arrival speeds varied randomly,
    -- which mistimes almost every ball by construction and reported a 96%
    -- drain rate that said more about the harness than the game.
    --
    -- Here the policy predicts contact -- time until the ball reaches the
    -- flipper plane, from its live position and velocity -- and flips that
    -- far ahead, offset by `error_s`. Sweeping the offset then measures the
    -- thing worth knowing: how wrong you can be and still make the pass.
    local PLANE = 688                  -- the flipper pivot line on both boards
    local mid   = def.size.w / 2
    local fired, ticks_held, side = false, 0, nil
    for _ = 1, math.floor(8 * C.TICK_HZ) do
      local bx, by = b:ball_pos()
      if not bx then return "lost" end
      local _, vy = b:ball_velocity()

      if not fired and vy > 0 and by < PLANE then
        local tt = (PLANE - by) / vy   -- seconds until it reaches the flippers
        if tt <= delay_s then
          fired, ticks_held = true, 0
          -- Side chosen HERE rather than on arming: a ball can drift across
          -- the board between the two, and flipping the far flipper is not a
          -- mistiming, it is a different mistake.
          side = (bx < mid) and "left" or "right"
        end
      end

      local flipping = false
      if fired then
        ticks_held = ticks_held + 1
        flipping = ticks_held < math.floor(0.22 * C.TICK_HZ)
      end
      local c = cmd(true, false, flipping and side == "left",
                                 flipping and side == "right")
      for _, ev in ipairs(b:step(c, true)) do
        if ev.kind == "tube"  then return "pass"  end
        if ev.kind == "drain" then return "drain" end
      end
    end
    return "lost"
  end

  --- Rate plus the full outcome breakdown. A pass rate on its own cannot
  --- distinguish "the shot is hard" from "the ball never got to the flipper",
  --- and those want completely different fixes.
  local function outcomes(def, delay_s, trials, seed0)
    local o = { pass = 0, drain = 0, lost = 0 }
    for i = 1, trials do
      local r = receive(def, delay_s, (seed0 or 700) + i * 7717)
      o[r] = o[r] + 1
    end
    o.n = trials
    return o
  end

  local function rate(def, delay_s, trials, seed0)
    return outcomes(def, delay_s, trials, seed0).pass / trials
  end

  -- Lead time before predicted contact. 0.02s is "flip as it arrives";
  -- larger values flip progressively earlier.
  -- Negative lead is not an error case, it is the ordinary pinball shot: the
  -- ball is already resting on the flipper, below the pivot line, when you
  -- flip. Sweeping only positive leads truncates the curve, and the first
  -- version of this probe reported Foundry's window as 20ms by measuring
  -- nothing but the falling tail of a peak that sits off the left edge.
  local DELAYS = {}
  for ms = -60, 85, 5 do DELAYS[#DELAYS+1] = ms / 1000 end

  print("")
  print("pass rate from a RECEIVED ball, by how early the flip is aimed")
  print("(60 trials each, with real scatter in arrival speed, angle and place)")
  print("")
  local best = {}
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    local curve, top, top_d = {}, -1, 0
    for _, d in ipairs(DELAYS) do
      local r = rate(def, d, 60)
      curve[d] = r
      if r > top then top, top_d = r, d end
    end
    -- The window that still lands half the peak. This, not the peak, is what
    -- "too easy" or "too hard" means for a timed shot: a 90% shot you can
    -- only hit within one frame is not an easy shot.
    local half, lo, hi = top / 2, nil, nil
    for _, d in ipairs(DELAYS) do
      if curve[d] >= half then lo = lo or d; hi = d end
    end
    best[id] = { d = top_d, r = top, window = (hi or 0) - (lo or 0) }

    print(("%-12s peak %2.0f%% aiming %dms ahead"):format(def.name, 100 * top,
          math.floor(top_d * 1000)))
    local row = "             "
    for _, d in ipairs(DELAYS) do
      if math.abs(d * 1000) % 20 == 0 then
        row = row .. ("%4.0f"):format(100 * curve[d])
      end
    end
    print(row .. "   (% pass at lead -60,-40,-20,0,20,40,60,80ms)")
    print(("             half-peak window: %dms  (a 60fps frame is 17ms)")
      :format(math.floor(best[id].window * 1000)))
  end
  print("")
  print("outcome breakdown at each board's best delay")
  print(("%-12s %8s %8s %8s"):format("board", "pass", "drain", "lost"))
  for _, id in ipairs({ "a", "b" }) do
    local o = outcomes(boards[id], best[id].d, 60)
    print(("%-12s %7d%% %7d%% %7d%%")
      :format(boards[id].name, 100 * o.pass / o.n, 100 * o.drain / o.n,
              100 * o.lost / o.n))
  end
  print("")
  return true
end
