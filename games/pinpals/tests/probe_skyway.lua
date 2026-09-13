--- Is the elevated ramp a shot, and what does taking it cost?
---
--- The skyway is the first thing on either board that a ball can be ON rather
--- than merely near, and three separate numbers have to be true at once for it
--- to be content rather than scenery:
---
---   * a flipper shot can reach the mouth at all;
---   * a shot that gets on completes the loop rather than rolling back out;
---   * the ball comes off the far end into live playfield, not into a drain.
---
--- The entry gate (core/ramp.lua:entry_speed) is a frictionless energy budget
--- with C.RAMP_ENTER_MARGIN on top, so "completed / entered" is the direct
--- measurement of whether that margin is right. Well under 1.0 means the ramp
--- admits shots it then spits back out, which is what turned both orbits into
--- dead ends the first time this was built.
---
---   PINPALS_SUITE=tests.probe_skyway love . --test [a|b]

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()
  -- Optional layout sweep; normal runs always measure the authored boards.
  local foot_y = tonumber(os.getenv("PINPALS_RAMP_FOOT_Y"))
  if foot_y then
    for _, def in pairs(boards) do
      for _, r in ipairs(def.ramps) do
        r.path[2], r.path[#r.path] = foot_y, foot_y
      end
      require("core.ramp").prepare(def)
    end
  end

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- One flipper shot, followed until it resolves.
  ---
  --- Contact point alone is not enough variety, and the first version of this
  --- probe was fooled by exactly that: stepping `frac` finely produced 98
  --- shots that were really three or four, in clusters of adjacent fractions
  --- that all did the same thing. Every rate came out as 20/98 or 10/98 --
  --- CLAUDE.md's third lesson, in the wild. So each shot also gets a small
  --- random nudge, and the sweep runs many seeds at a few contact points
  --- rather than many contact points once.
  ---@return string outcome, number|nil highest z reached
  local function shot(def, side, frac, jitter)
    local b = Board.new(def)
    local spec
    for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
    local sign = (side == "left") and 1 or -1
    local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
    local d    = C.FLIPPER_LEN * frac
    b:spawn(spec.x + math.cos(ang) * d * sign + (math.random() - 0.5) * jitter,
            spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2
              - math.random() * jitter,
            (math.random() - 0.5) * jitter * 8, 0)
    for _ = 1, math.floor(0.12 * C.TICK_HZ) do b:step(cmd(), true) end

    local held    = cmd(true, false, side == "left", side == "right")
    local rested  = cmd(true, false)
    local release = math.floor(0.22 * C.TICK_HZ)
    local c = held
    local entered, exited, completed, top = false, false, false, 0
    for tick = 1, math.floor(9.0 * C.TICK_HZ) do
      if tick == release then c = rested end
      for _, ev in ipairs(b:step(c, true)) do
        if ev.kind == "ramp" and ev.at == "enter" then entered = true end
        if ev.kind == "ramp" and ev.at == "exit" then
          exited, completed = true, ev.complete
        end
        if ev.kind == "drain" then
          return entered and (completed and "made" or "fell back") or "no entry", top
        end
        if ev.kind == "tube" then
          return entered and (completed and "made" or "fell back") or "no entry", top
        end
      end
      local g = b.on_ramp and b.on_ramp.geom
      if g then top = math.max(top, b:ball_z() / g.height) end
      -- A completed loop is one that crested and then left; a ball that
      -- entered and came back out of the same mouth never reaches the crown.
      if exited and entered then
        return completed and "made" or "fell back", top
      end
    end
    return entered and "stuck on ramp" or "no entry", top
  end

  local which = nil
  for _, v in ipairs(arg or {}) do if v == "a" or v == "b" then which = v end end
  for _, id in ipairs(which and { which } or { "a", "b" }) do
    local def = boards[id]
    local g   = def.ramps[1].geom
    print(("\n%s -- skyway needs %.0f px/s in at either mouth (%.0fpx of lane, %gpx crown)")
      :format(def.name, g.enter_speed.start, g.length, g.height))
    print("  flipper   shots   entered   made   fell back   stuck")
    local tally = { ent = 0, made = 0, stuck = 0, n = 0 }
    for _, side in ipairs({ "left", "right" }) do
      local n, ent, made, back, stuck = 0, 0, 0, 0, 0
      for _, frac in ipairs({ 0.34, 0.48, 0.62, 0.76, 0.90 }) do
        for seed = 1, 14 do
          math.randomseed(9700 + seed * 31)
          local out = shot(def, side, frac, 5)
          n = n + 1
          if out ~= "no entry" then ent = ent + 1 end
          if out == "made" then made = made + 1 end
          if out == "fell back" then back = back + 1 end
          if out == "stuck on ramp" then stuck = stuck + 1 end
        end
      end
      tally.n, tally.ent = tally.n + n, tally.ent + ent
      tally.made, tally.stuck = tally.made + made, tally.stuck + stuck
      print(("  %-8s  %4d    %5d   %4d   %9d   %5d"):format(side, n, ent, made, back, stuck))
    end
    print(("  %d of %d shots reached the mouth; %d of those completed the loop%s")
      :format(tally.ent, tally.n, tally.made,
              tally.ent > 0 and (" (%.0f%%)"):format(tally.made / tally.ent * 100) or ""))
    if tally.stuck > 0 then
      print(("  WARNING: %d shots were still on the ramp after 9s"):format(tally.stuck))
    end
  end
  return true
end
