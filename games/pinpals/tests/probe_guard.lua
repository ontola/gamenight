--- §6.2 The outlane guard: does the barrier do what the board data claims?
---
--- Three separate claims, and the boards' own comments assert all three:
---
---   1. a ball entering the GUARDED lane comes back into play, rather than
---      being stopped, parked, or handed straight back to the drain;
---   2. the UNGUARDED lane still drains, or the device is not a trade;
---   3. the guard costs the board something at the whole-board level, and it
---      is worth knowing how much before it goes in a design doc.
---
--- CLAUDE.md, rule 4: measure the thing you are about to assert.
---
---   PINPALS_SUITE=tests.probe_guard love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd(guard, gate, post, left, right, cooldown)
    return { guard = guard, guard_cooldown = cooldown or 0,
             flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- Where the lane is, read off the board data rather than retyped: the
  --- outer shell is the first wall chain and the lane dividers are the next
  --- two, so a lane is "between the guard's two ends, at the guard's height".
  local function lane_of(def, side)
    for _, g in ipairs(def.guards) do
      if g.side == side then return g end
    end
  end

  ---------------------------------------------------------------------------
  -- 1 & 2. One lane at a time
  ---------------------------------------------------------------------------

  --- Drop a ball straight into one outlane and see what becomes of it.
  ---
  --- Spawned ABOVE the lane mouth and left to fall, not placed on top of the
  --- bar: CLAUDE.md rule 2 -- the last time a probe placed a ball a few pixels
  --- from the thing it was measuring, it erased the device's entire effect.
  --- 40px of fall is enough to arrive at a realistic speed and short enough
  --- that the ball is still in the lane when it gets there.
  ---
  --- Outcomes are deliberately four, not two. "Did not drain" is not a save
  --- if the ball is still sitting in the lane when the clock runs out.
  local function drop_into(def, side, guard, trials)
    local g = lane_of(def, side)
    local out = { escaped = 0, drained = 0, parked = 0, hits = 0 }
    local b = Board.new(def)
    local c = cmd(guard)
    -- Let the bars finish travelling before the first ball, so this measures
    -- the guard rather than the guard arriving.
    for _ = 1, math.ceil(C.GUARD_TRAVEL * 2 * C.TICK_HZ) do b:step(c, false) end
    for i = 1, trials do
      math.randomseed(4242 + i * 131)
      -- Spread across the lane's own width and give it a little sideways
      -- drift, because a ball that only ever arrives dead centre measures one
      -- pixel of a bar rather than a bar.
      local x  = g.up.x + (i / trials - 0.5) * 16
      local vx = (math.random() - 0.5) * 120
      b:spawn(x, g.up.y - 40, vx, 120)
      local done, hits = nil, 0
      for _ = 1, 6 * C.TICK_HZ do
        for _, ev in ipairs(b:step(c, true)) do
          if ev.kind == "drain" then done = "drained" end
          if ev.kind == "guard" then hits = hits + 1 end
        end
        if done then break end
        local bx, by = b:ball_pos()
        -- Out of the lane and back on the playfield: past the divider in x,
        -- or up over the mouth in y.
        if by and (by < g.up.y - 60 or (g.side == "left" and bx > g.up.x + 40)
                                    or (g.side == "right" and bx < g.up.x - 40)) then
          done = "escaped"
          break
        end
      end
      out[done or "parked"] = out[done or "parked"] + 1
      out.hits = out.hits + hits
      b:despawn()
    end
    return out
  end

  ---------------------------------------------------------------------------
  -- 3. The whole board
  ---------------------------------------------------------------------------

  --- Random play, averaged over seeds, with the guard in each of its states.
  --- CLAUDE.md rule 1: pinball is chaotic, so one run measures nothing.
  ---
  --- `start` matters more than it looks and is why it is a parameter rather
  --- than always `serve`. Glasshouse's plunger sits at x=48, a ball's width
  --- from the mouth of its LEFT outlane, so a serve-only sample would credit
  --- the left guard with saving balls the harness put there (CLAUDE.md rule
  --- 2). In a rally most balls arrive out of the tube instead, from the far
  --- corner, so both starts get measured and reported separately.
  ---
  --- `cooldown` runs §6.2's rule: one save, then GUARD_COOLDOWN seconds with
  --- the bar out of play. It is a parameter rather than always on, because
  --- "what would this device be worth if it never ran out" is the only way to
  --- see what the cooldown itself costs.
  ---
  --- The rule is reimplemented here in two lines -- spend on the contact,
  --- decay by dt every tick -- because this probe drives sim/ directly for
  --- speed and never builds a core/ match. They mirror core/state.lua, and a
  --- rule this loop does not copy is a rule it does not measure.
  ---
  --- The cooldown clears on a ball LOSS and not on a pass, exactly as core/
  --- has it, so the unit the guard is scarce within is one ball. Getting that
  --- wrong in either direction moves this table a long way: never clearing it
  --- charges a save against the next two balls as well, and clearing it on
  --- every ball end hands one back for free every time the rally continues.
  local function board_life(def, guard, seeds, balls, start, cooldown)
    local drains, passes, saves, seconds = 0, 0, 0, 0
    -- §6.2 says the wall that guards the outlane blocks a scoring shot. A
    -- guard contact made while the ball is travelling UP the board is that
    -- cost being paid: an orbit shot that hugged the shell and hit the bar
    -- instead of getting round. Split them out rather than reporting one
    -- number that quietly mixes a save with a robbery.
    local blocks = 0
    -- How much of the ball's life the guard was actually there for. With the
    -- cooldown on, this is the number that says whether the device is present
    -- in the game at all.
    local armed_ticks, total_ticks = 0, 0
    for s = 1, seeds do
      math.randomseed(90210 + s * 7919)
      local b = Board.new(def, 90210 + s * 7919)
      local cool = 0
      for _ = 1, balls do
        if start == "arrive" then b:arrive(C.TRANSIT_MIN_SP) else b:serve() end
        local t, over = 0, nil
        local c = cmd(guard, false, false, false, false, cool)
        while not over and t < 30 * C.TICK_HZ do
          t = t + 1
          total_ticks = total_ticks + 1
          if cool > 0 then
            cool = math.max(0, cool - C.FIXED_DT)
            c.guard_cooldown = cool
          else
            armed_ticks = armed_ticks + 1
          end
          if t % 30 == 0 then
            c = cmd(guard, math.random() < 0.5, math.random() < 0.2,
                    math.random() < 0.35, math.random() < 0.35, cool)
          end
          -- BEFORE the step, not after. Contacts are reported from inside
          -- world:update and drained once it has returned, by which time the
          -- kick has already reversed the ball -- read the velocity then and
          -- every save reads as a block. First version of this probe did
          -- exactly that and reported the device backwards.
          local _, vy_in = b:ball_velocity()
          for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
            if ev.kind == "drain" then drains = drains + 1; over = "drain" end
            if ev.kind == "tube"  then passes = passes + 1; over = "pass"  end
            if ev.kind == "guard" and cool <= 0 then
              if vy_in < 0 then blocks = blocks + 1 else saves = saves + 1 end
              if cooldown then cool = C.GUARD_COOLDOWN; c.guard_cooldown = cool end
            end
          end
        end
        -- The new ball gets its guard back; a ball that left through the
        -- tube is still the same ball and keeps the cooldown running.
        if over == "drain" then cool = 0 end
        seconds = seconds + t / C.TICK_HZ
        b:despawn()
      end
    end
    local balls_total = seeds * balls
    return { life = seconds / balls_total, drains_s = drains / seconds,
             survival = passes / balls_total, saves_s = saves / seconds,
             blocks_s = blocks / seconds, armed = armed_ticks / total_ticks }
  end

  ---------------------------------------------------------------------------

  print("")
  print("=== the outlane guard ============================================")
  print("")
  print("A ball dropped 40px above one outlane mouth, 40 per cell.")
  print("'parked' is the failure that matters: the ball is neither saved nor")
  print("lost, it is sitting in the lane six seconds later.")
  print("")
  print("board       lane    guard      escaped  drained  parked   hits/ball")
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    for _, side in ipairs({ "left", "right" }) do
      for _, guard in ipairs({ side, "none" }) do
        local r = drop_into(def, side, guard ~= "none" and guard or nil, 40)
        print(("%-11s %-7s %-10s %6d   %6d   %6d      %6.2f")
          :format(def.name, side, guard == "none" and "(none)" or "on this side",
                  r.escaped, r.drained, r.parked, r.hits / 40))
      end
    end
  end

  print("")
  print("Whole-board random play: 12 seeds x 8 balls per cell.")
  print("'served' starts at the plunger, 'arrived' out of the tube. They are")
  print("separate because the plungers do not sit in the same place relative")
  print("to the lanes, and the serve alone would flatter one guard.")
  print("")
  print("board        start    guard     ball life   drains/s   survival   saves/s  blocks/s")
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    for _, start in ipairs({ "serve", "arrive" }) do
      for _, guard in ipairs({ "left", "right", "none" }) do
        local r = board_life(def, guard ~= "none" and guard or nil, 12, 8, start, true)
        print(("%-11s  %-7s  %-8s  %8.2fs   %8.4f   %7.0f%%   %7.3f   %7.3f")
          :format(def.name, start, guard, r.life, r.drains_s,
                  r.survival * 100, r.saves_s, r.blocks_s))
      end
    end
  end

  print("")
  print(("What the %ds cooldown costs. Same runs, with and without the rule:")
    :format(C.GUARD_COOLDOWN))
  print("'armed' is the share of ball time the bar was actually in the lane.")
  print("")
  print("board        start    guard      armed   drains/s   if it never ran out")
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    for _, start in ipairs({ "serve", "arrive" }) do
      for _, guard in ipairs({ "left", "right" }) do
        local on  = board_life(def, guard, 12, 8, start, true)
        local off = board_life(def, guard, 12, 8, start, false)
        print(("%-11s  %-7s  %-8s  %5.0f%%   %8.4f               %8.4f")
          :format(def.name, start, guard, on.armed * 100, on.drains_s, off.drains_s))
      end
    end
  end
  print("")
  return true
end
