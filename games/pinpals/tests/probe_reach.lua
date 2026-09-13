--- Where can a flipper shot actually GO?
---
--- Board layouts are hand-authored coordinates, and the last time anyone
--- checked this (prototype.md §3) the answer moved the pass ramp across the
--- board: shots crossed y=560 between x=145 and x=239, and the lane was at
--- x=328, so the pass existed 1 time in 30. Everything about placing content
--- on the upper playfield depends on the same question.
---
--- Two maps, because they answer different things:
---   reach  -- sweep every contact point on both flippers, trace each shot.
---            "Where CAN a good shot put the ball."
---   play   -- random operator + flipper timing over many serves.
---            "Where does the ball ACTUALLY spend its time."
---
---   PINPALS_SUITE=tests.probe_reach love . --test [board]

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local CELL = 24

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  local function new_grid(def)
    local g = { w = math.ceil(def.size.w / CELL), h = math.ceil(def.size.h / CELL), n = 0 }
    for i = 0, g.w * g.h do g[i] = 0 end
    return g
  end

  local function mark(g, x, y)
    local cx = math.floor(x / CELL)
    local cy = math.floor(y / CELL)
    if cx < 0 or cy < 0 or cx >= g.w or cy >= g.h then return end
    local i = cy * g.w + cx
    g[i] = g[i] + 1
    g.n = g.n + 1
  end

  --- Drop the ball onto a point on a flipper, let it settle, then flip.
  --- This is the shot a player is actually trying to make.
  --- Outcome of one swept shot, which is the number that matters: a heat map
  --- shows where the ball went, this says whether the shot was worth taking.
  local function trace_shot(def, side, frac, grid, tally)
    local b = Board.new(def)
    local spec
    for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
    local sign = (side == "left") and 1 or -1
    local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
    local d    = C.FLIPPER_LEN * frac
    local x = spec.x + math.cos(ang) * d * sign
    local y = spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2
    b:spawn(x, y, 0, 0)
    for _ = 1, math.floor(0.12 * C.TICK_HZ) do b:step(cmd(), true) end
    -- A real flip is a press and a release, not a hold. Holding the flipper
    -- up for the whole trace parks it out of the way and leaves a notch at
    -- the pivot that nothing can ever clear, which shows up as a stuck ball
    -- that a player would never actually see.
    local held    = cmd(true, false, side == "left", side == "right")
    local rested  = cmd(true, false, false, false)
    local release = math.floor(0.22 * C.TICK_HZ)
    local c = held
    ---@type string|nil     -- "pass" | "drain" | "alive" | "STUCK"
    local done
    local high_left, high_right = false, false
    -- 6s, not 3s: a shot that enters an orbit is still travelling at 3s, and
    -- cutting there scored a live ball as "stalled" -- which read as a
    -- regression when it was the new shot working.
    for tick = 1, math.floor(6.0 * C.TICK_HZ) do
      if tick == release then c = rested end
      for _, ev in ipairs(b:step(c, true)) do
        if ev.kind == "tube" then
          done = "pass"
        elseif ev.kind == "drain" then
          done = "drain"
        end
      end
      local bx, by = b:ball_pos()
      if bx then
        mark(grid, bx, by)
        -- "Got up the board outside the ramp" -- the orbit lanes. The ramp
        -- channel is centred on the tube mouth and 52px wide on both boards,
        -- so derive it rather than hardcoding board A's numbers: B's ramp is
        -- 46px further left and the fixed thresholds silently measured the
        -- wrong lanes there.
        local mouth = def.tube.mouth.x
        if by < 520 then
          if bx < mouth - 35 then high_left  = true end
          if bx > mouth + 35 then high_right = true end
        end
      end
      if done then break end
      if not bx then break end
    end
    if not done then
      -- Still on the board after 6s. Moving = a long orbit or a bumper
      -- rattle, which is a fine outcome. Stopped = a pocket, which is a bug
      -- the geometry gate is supposed to catch.
      done = (b:ball_speed() > 20) and "alive" or "STUCK"
      if done == "STUCK" and tally then
        local sx, sy = b:ball_pos()
        tally.stuck_at = tally.stuck_at or {}
        tally.stuck_at[#tally.stuck_at+1] =
          ("(%3.0f,%3.0f) from %s flipper at %.2f"):format(sx, sy, side, frac)
      end
    end
    if tally then
      tally.n = tally.n + 1
      tally[done] = (tally[done] or 0) + 1
      if high_left  then tally.left_orbit  = tally.left_orbit  + 1 end
      if high_right then tally.right_orbit = tally.right_orbit + 1 end
    end
  end

  local function play_map(def, seconds, grid, seed, hits)
    math.randomseed(seed)
    local b = Board.new(def, seed)
    b:serve()
    local steps = math.floor(seconds * C.TICK_HZ)
    local c = cmd()
    for i = 1, steps do
      if i % 30 == 0 then
        c = cmd(math.random() < 0.55, math.random() < 0.2,
                math.random() < 0.35, math.random() < 0.35)
      end
      local dead = false
      for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
        if ev.kind == "drain" or ev.kind == "tube" then dead = true end
        if ev.kind == "bumper" and hits then
          hits[ev.index] = (hits[ev.index] or 0) + 1
          hits.total = hits.total + 1
        end
      end
      if dead then b:serve() end
      local bx, by = b:ball_pos()
      if bx then mark(grid, bx, by) end
    end
  end

  --- Density as a single character, log-scaled: the ball spends most of its
  --- time in a few places and a linear scale prints one hot cell and 500
  --- blanks.
  local RAMP = " .:-=+*#%@"
  local function render(def, grid, title)
    local peak = 0
    for i = 0, grid.w * grid.h do peak = math.max(peak, grid[i] or 0) end
    print("")
    print(("%s -- board %s, %d samples, peak cell %d")
      :format(title, def.id, grid.n, peak))
    -- Column ruler in board pixels, every 4 cells.
    local ruler = "     "
    for cx = 0, grid.w - 1 do
      ruler = ruler .. ((cx % 4 == 0) and tostring(math.floor(cx * CELL / 100)) or " ")
    end
    print(ruler .. "  (x00 px)")
    for cy = 0, grid.h - 1 do
      local row = ("%4d "):format(cy * CELL)
      for cx = 0, grid.w - 1 do
        local v = grid[cy * grid.w + cx] or 0
        if v == 0 then
          row = row .. " "
        else
          local u = math.log(v) / math.log(math.max(2, peak))
          local k = math.max(2, math.min(#RAMP, math.ceil(u * #RAMP)))
          row = row .. RAMP:sub(k, k)
        end
      end
      print(row)
    end
  end

  local which = nil
  for _, v in ipairs(arg or {}) do if v == "a" or v == "b" then which = v end end

  for _, id in ipairs(which and { which } or { "a", "b" }) do
    local def = boards[id]

    local reach = new_grid(def)
    local tally = { n = 0, left_orbit = 0, right_orbit = 0 }
    for _, side in ipairs({ "left", "right" }) do
      for step = 0, 24 do
        trace_shot(def, side, 0.30 + 0.70 * step / 24, reach, tally)
      end
    end
    render(def, reach, "REACH: 50 flipper shots swept across both flippers")
    print("")
    print(("  shot outcomes over %d swept contact points:"):format(tally.n))
    for _, k in ipairs({ "pass", "drain", "alive", "STUCK" }) do
      print(("    %-10s %3d  (%.0f%%)")
        :format(k, tally[k] or 0, 100 * (tally[k] or 0) / tally.n))
    end
    print(("    %-10s %3d  (%.0f%%)   <- shots that got up the LEFT of the ramp")
      :format("left orbit", tally.left_orbit, 100 * tally.left_orbit / tally.n))
    print(("    %-10s %3d  (%.0f%%)   <- and up the RIGHT")
      :format("right orbit", tally.right_orbit, 100 * tally.right_orbit / tally.n))
    if tally.stuck_at then
      print("    balls that stopped dead:")
      for _, where in ipairs(tally.stuck_at) do print("      " .. where) end
    end

    -- Averaged over seeds. Pinball is chaotic: a single 180s run of one seed
    -- moved bumper hits from 80 to 129 on a radius change of 4px, which is
    -- noise wearing the costume of a result. Anything tuned off one run here
    -- is tuned off nothing.
    local SEEDS, SECONDS = 6, 120
    local play = new_grid(def)
    local hits = { total = 0 }
    local runs = {}
    for k = 1, SEEDS do
      local before = hits.total
      play_map(def, SECONDS, play, 20260906 + k * 7717, hits)
      runs[k] = hits.total - before
    end
    render(def, play, ("PLAY: %d x %ds of random flipper + operator timing")
                        :format(SEEDS, SECONDS))
    local lo, hi, sum = math.huge, 0, 0
    for _, v in ipairs(runs) do
      lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
    end
    local mean = sum / SEEDS
    local var = 0
    for _, v in ipairs(runs) do var = var + (v - mean) ^ 2 end
    print(("  BUMPER HITS: mean %.1f per %ds (sd %.1f, range %d-%d over %d seeds) = %.2f/s")
      :format(mean, SECONDS, math.sqrt(var / SEEDS), lo, hi, SEEDS, mean / SECONDS))

    -- The specific question item 12 asks.
    for i, bmp in ipairs(def.bumpers or {}) do
      local cx, cy = math.floor(bmp.x / CELL), math.floor(bmp.y / CELL)
      print(("    bumper %d at (%3d,%3d) r%d: %4d hits   grid reach %d, play %d")
        :format(i, bmp.x, bmp.y, bmp.r, hits[i] or 0,
                reach[cy * reach.w + cx] or 0, play[cy * play.w + cx] or 0))
    end
  end
  print("")
  return true
end
