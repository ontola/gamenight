--- Two questions that were being answered by guesswork: where does a ball
--- falling from the top of the board cross a given line, and what happens to
--- a ball that arrives through the tube?
---
--- Placing upper-field content by eye cost four wrong positions in a row --
--- every one of them a scoring element the reachability test then measured at
--- zero. This is the measurement that should have come first.
---
---   PINPALS_SUITE=tests.probe_where love . --test [board]

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- Drop a ball from (x, y0) and report every x at which it crosses `line`.
  local function crossings(def, y0, line)
    local hist = {}
    for x = 20, def.size.w - 20, 4 do
      local b = Board.new(def)
      b:spawn(x, y0, 0, 40)
      local prev
      for _ = 1, math.floor(6 * C.TICK_HZ) do
        b:step(cmd(), true)
        local bx, by = b:ball_pos()
        if not bx then break end
        if prev and prev < line and by >= line then
          hist[#hist+1] = bx
          break
        end
        prev = by
      end
    end
    return hist
  end

  local function histogram(label, xs, w)
    local cells = math.floor(w / 16)
    local bins = {}
    for i = 0, cells do bins[i] = 0 end
    for _, x in ipairs(xs) do
      local i = math.max(0, math.min(cells, math.floor(x / 16)))
      bins[i] = bins[i] + 1
    end
    local peak = 1
    for _, v in pairs(bins) do peak = math.max(peak, v) end
    print("  " .. label .. ("  (%d balls, peak %d)"):format(#xs, peak))
    local row = {}
    for i = 0, cells do
      local v = bins[i] / peak
      row[#row+1] = (bins[i] == 0) and " " or (" .:-=+*#%@"):sub(
        math.max(1, math.ceil(v * 9)) + 1, math.max(1, math.ceil(v * 9)) + 1)
    end
    print("   |" .. table.concat(row) .. "|")
    print("    " .. ("0"):rep(1) .. ("%" .. (cells - 1) .. "s"):format(w))
  end

  --- What happens to a ball that comes out of the tube and is never flipped?
  local function arrivals(def)
    local out = { drain = 0, tube = 0, alive = 0 }
    local side = {}
    for i = 1, 40 do
      math.randomseed(31 + i * 613)
      local b = Board.new(def)
      local speed = C.TRANSIT_MIN_SP
                  + (C.TRANSIT_MAX_SP - C.TRANSIT_MIN_SP) * math.random()
      b:arrive(speed)
      local last_x, done = nil, nil
      for _ = 1, math.floor(8 * C.TICK_HZ) do
        for _, ev in ipairs(b:step(cmd(), true)) do
          if ev.kind == "drain" then done = "drain" elseif ev.kind == "tube" then done = "tube" end
        end
        local bx = b:ball_pos()
        if bx then last_x = bx end
        if done then break end
      end
      out[done or "alive"] = out[done or "alive"] + 1
      if done == "drain" and last_x then
        local lo = def.flippers[1].x < def.flippers[2].x and def.flippers[1] or def.flippers[2]
        local hi = def.flippers[1].x < def.flippers[2].x and def.flippers[2] or def.flippers[1]
        local where = (last_x < lo.x - 20) and "left outlane"
                   or (last_x > hi.x + 20) and "right outlane" or "centre"
        side[where] = (side[where] or 0) + 1
      end
    end
    local parts = {}
    for k, v in pairs(side) do parts[#parts+1] = ("%s %d"):format(k, v) end
    table.sort(parts)
    print(("  arrivals, never flipped: %d drain, %d tube, %d alive   [%s]")
      :format(out.drain, out.tube, out.alive, table.concat(parts, ", ")))
  end

  local which = nil
  for _, v in ipairs(arg or {}) do if v == "a" or v == "b" then which = v end end
  for _, id in ipairs(which and { which } or { "a", "b" }) do
    local def = boards[id]
    print("\n" .. def.name)
    for _, line in ipairs({ 210, 340, 480, 620, def.flippers[1].y - 10 }) do
      histogram("crossing y=" .. line, crossings(def, 60, line), def.size.w)
    end
    arrivals(def)
  end
  return true
end
