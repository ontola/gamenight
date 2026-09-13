--- Measurement, not a gate: does one bumper hit produce one score?
---
--- A ball leaving a bumper with restitution > 1 might register several
--- begin-contacts on the way out, and each would score. This probe was
--- written to size a cooldown against that -- and instead showed there was
--- nothing to filter: 0.02s suppresses exactly as many repeats as 0.00s, so
--- the repeats are real re-hits 50-400ms apart, not solver jitter. The
--- cooldown was removed on the strength of these numbers. Kept so that a
--- future agent tempted to add one again can re-run it first.
---
---   PINPALS_SUITE=tests.probe_scoring love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd()
    return { flippers = { left = false, right = false },
             devices  = { gate = { commanded = false },
                          post = { commanded = false } } }
  end

  --- Fire the ball straight at one bumper from `dist` away and count the
  --- scoring events that come back out.
  --- `cooldown` is applied by this probe itself; sim/ has none. Re-running
  --- this is how you check whether that is still the right call.
  local function hits_for(cooldown, trials)
    math.randomseed(7)
    local def = boards.a
    local total, contacts = 0, 0
    for t = 1, trials do
      local b = def.bumpers[(t % #def.bumpers) + 1]
      local board = Board.new(def)
      local ang = math.random() * math.pi * 2
      local d   = b.r + C.BALL_RADIUS + 6
      local sp  = 400 + math.random() * 900
      board:spawn(b.x + math.cos(ang) * d, b.y + math.sin(ang) * d,
                  -math.cos(ang) * sp, -math.sin(ang) * sp)
      -- Counted per bumper: the question is whether ONE bumper double-fires
      -- on a single approach, not whether the ball goes on to reach another.
      local per, last_hit = {}, {}
      local t_now = 0
      for _ = 1, math.floor(0.5 * C.TICK_HZ) do
        t_now = t_now + C.FIXED_DT
        for _, ev in ipairs(board:step(cmd(), true)) do
          if ev.kind == "bumper" then
            -- The filter under test, applied here rather than in sim/.
            if t_now - (last_hit[ev.index] or -1e9) >= cooldown then
              last_hit[ev.index] = t_now
              per[ev.index] = (per[ev.index] or 0) + 1
            end
          end
        end
      end
      local worst = 0
      for _, n in pairs(per) do if n > worst then worst = n end end
      if worst > 1 then contacts = contacts + 1 end
      total = total + worst
    end
    return total, contacts
  end

  print("")
  print("repeat scoring on a SINGLE bumper (0.5s window, 120 approaches)")
  print(("%-12s %14s %16s"):format("cooldown", "worst/bumper", "double-fires/120"))
  for _, cd in ipairs({ 0, 0.02, 0.05, 0.10, 0.20, 0.40 }) do
    local total, doubles = hits_for(cd, 120)
    print(("%-12.2f %14.2f %16d"):format(cd, total / 120, doubles))
  end
  print("")
  return true
end
