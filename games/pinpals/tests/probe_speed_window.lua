--- How does a ball's ARRIVAL SPEED change how hard it is to flip?
---
--- Written while chasing item 14 -- why Foundry's receiving window is 20ms
--- against Glasshouse's 50ms -- and it did not answer that. It did produce a
--- more general result worth keeping: on BOTH boards the timing window
--- narrows sharply as the ball arrives faster.
---
---     arrival speed   Foundry window   Glasshouse window
---               150             40ms                20ms
---               250             20ms                20ms
---               400             15ms                15ms
---               600             15ms                10ms
---               850             10ms                10ms
---
--- Two things follow. A fast ball is harder to time on any board, which
--- matters because §9 makes relay heat raise arrival speed by up to 55% -- a
--- hot rally is harder to hold for this reason as well as the intended one.
--- And at MATCHED speeds the two boards behave almost identically, so
--- whatever makes Foundry harder to receive on is not the flipper geometry.
---
--- Note this probe drops the ball straight onto the flipper, which is NOT a
--- faithful model of a real descent: it reproduces Foundry's real 20ms but
--- not Glasshouse's real 50ms. The difference therefore lives in the approach
--- path, which is where item 14 should look next.
---
---   PINPALS_SUITE=tests.probe_speed_window love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()
  local function cmd(l,r) return { flippers={left=l or false,right=r or false},
    devices={gate={commanded=true},post={commanded=false}} } end

  --- Same receive-and-flip policy as probe_timing, but the ball is DROPPED
  --- just above the flipper at a chosen speed, so arrival speed is the
  --- independent variable instead of an outcome of the descent.
  local function pass_at(def, speed, lead, trials)
    local made = 0
    for i = 1, trials do
      math.randomseed(31 + i * 977)
      local b = Board.new(def)
      for _ = 1, math.floor(0.45*C.TICK_HZ) do b:step(cmd(), true) end
      -- Drop onto whichever flipper the entry side feeds.
      local side = (def.entry.x < def.size.w/2) and "left" or "right"
      local spec
      for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
      local x = spec.x + (math.random()*2-1) * 10
      b:spawn(x, 560, (math.random()*2-1)*40, speed)
      local fired, held, got = false, 0, false
      for _ = 1, math.floor(4*C.TICK_HZ) do
        local bx, by = b:ball_pos()
        if not bx then break end
        local _, vy = b:ball_velocity()
        if not fired and vy > 0 and by < 688 and (688-by)/vy <= lead then
          fired, held = true, 0
        end
        local flipping = false
        if fired then held = held + 1; flipping = held < math.floor(0.22*C.TICK_HZ) end
        local over = false
        for _, ev in ipairs(b:step(cmd(flipping and side=="left", flipping and side=="right"), true)) do
          if ev.kind == "tube" then got = true; over = true end
          if ev.kind == "drain" then over = true end
        end
        if over then break end
      end
      if got then made = made + 1 end
    end
    return made / trials
  end

  -- Does the ball reach the tube WITHOUT anyone flipping? If so, part of the
  -- measured "pass rate" is not a shot at all, and any lead looks fine
  -- because the flip is not what is doing the work.
  local C2, Match = C, require("sim.match")
  local function no_flip_rate(def, trials)
    local made = 0
    for i = 1, trials do
      math.randomseed(555 + i * 7717)
      local b = Board.new(def)
      local e = def.entry
      local speed = C2.TRANSIT_MIN_SP + (C2.TRANSIT_MAX_SP - C2.TRANSIT_MIN_SP) * math.random()
      local ang = math.atan2(e.dir.y, e.dir.x) + (math.random()*2-1) * 0.10
      for _ = 1, math.floor(0.45*C2.TICK_HZ) do b:step(cmd(), true) end
      b:spawn(e.x + (math.random()*2-1)*6, e.y, math.cos(ang)*speed, math.sin(ang)*speed)
      local got = false
      for _ = 1, math.floor(8*C2.TICK_HZ) do
        local over = false
        for _, ev in ipairs(b:step(cmd(), true)) do   -- never flips
          if ev.kind == "tube" then got = true; over = true end
          if ev.kind == "drain" then over = true end
        end
        if over then break end
      end
      if got then made = made + 1 end
    end
    return made / trials
  end
  local _ = Match

  print("")
  print("pass rate with NOBODY FLIPPING (a received ball left alone)")
  for _, id in ipairs({ "a", "b" }) do
    print(("  %-12s %3.0f%%"):format(boards[id].name, 100 * no_flip_rate(boards[id], 60)))
  end

  print("")
  print("pass rate vs ARRIVAL SPEED, sweeping flip lead (window = leads at >= half peak)")
  print(("%-12s %8s %8s %10s"):format("board", "speed", "peak", "window"))
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    for _, speed in ipairs({ 150, 250, 400, 600, 850 }) do
      local peak, curve = 0, {}
      for ms = 5, 80, 5 do
        local r = pass_at(def, speed, ms/1000, 24)
        curve[ms] = r
        if r > peak then peak = r end
      end
      local lo, hi
      for ms = 5, 80, 5 do
        if curve[ms] >= peak/2 and peak > 0 then lo = lo or ms; hi = ms end
      end
      print(("%-12s %8d %7.0f%% %8dms"):format(def.name, speed, 100*peak,
            (hi or 0) - (lo or 0)))
    end
  end
  print("")
  return true
end
