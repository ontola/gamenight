--- How far above the flippers can the ramp mouth go, and how narrow can the
--- channel be, before the pass stops being makeable?
---
--- boards-v2 phase 0 raised the flipper line by 192px and left the ramp where
--- it was, which is what "the ramp is too close to the flippers" asks for --
--- and the pass promptly became unmakeable (0/8 from Foundry's right flipper).
--- Mouth height and funnel width are the same variable in disguise: a mouth
--- further away needs a wider funnel to catch a shot that has had longer to
--- spread. This sweeps both together so the pair can be chosen rather than
--- argued about.
---
---   PINPALS_SUITE=tests.probe_ramp love . --test [board]

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
  end

  --- The two ramp walls and the roof, rebuilt from the parameters. Indices 4,
  --- 5 and 6 are the ramp on both boards; the flare rise and the channel top
  --- come from the board rather than being reinvented here.
  local function reshape(def, mouth_y, flare, half)
    local d  = copy(def)
    local cx = def.tube.mouth.x
    local top  = def.walls[4][6]                 -- where the channel ends
    local rise = def.walls[4][2] - def.walls[4][4]
    d.walls[4] = { cx - flare, mouth_y, cx - half, mouth_y - rise, cx - half, top }
    d.walls[5] = { cx + flare, mouth_y, cx + half, mouth_y - rise, cx + half, top }
    d.walls[6] = { cx - half, top, cx, top - 22, cx + half, top }
    return d
  end

  --- One swept flip, the shot a player is actually trying to make.
  local function trace(def, side, frac)
    local b = Board.new(def)
    local spec
    for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
    local sign = (side == "left") and 1 or -1
    local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
    local d    = C.FLIPPER_LEN * frac
    b:spawn(spec.x + math.cos(ang) * d * sign,
            spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2, 0, 0)
    for _ = 1, math.floor(0.12 * C.TICK_HZ) do b:step(cmd(), true) end
    local held    = cmd(true, false, side == "left", side == "right")
    local rested  = cmd(true, false)
    local release = math.floor(0.22 * C.TICK_HZ)
    local c, done = held, nil
    local up = false
    local m = def.tube.mouth
    for tick = 1, math.floor(6.0 * C.TICK_HZ) do
      if tick == release then c = rested end
      for _, ev in ipairs(b:step(c, true)) do
        if ev.kind == "tube" then done = "pass" elseif ev.kind == "drain" then done = "drain" end
      end
      local bx, by = b:ball_pos()
      if bx and by < m.y + 352 and (bx < m.x - 46 or bx > m.x + 46) then up = true end
      if done then break end
    end
    return done or "alive", up
  end

  local function sweep(def)
    local base = def.walls[4][2]
    print(("\n%s -- 50 swept shots per row (mouth y, flare half-width, channel half-width)")
      :format(def.name))
    print("  mouth y   flare   half    pass   drain   up the board")
    for _, my in ipairs({ base, base + 60, base + 120 }) do
      for _, flare in ipairs({ 53, 66 }) do
       for _, half in ipairs({ 26, 30, 34, 38 }) do
        local d = reshape(def, my, flare, half)
        local pass, drain, up, n = 0, 0, 0, 0
        for _, side in ipairs({ "left", "right" }) do
          for frac = 0.28, 0.96, 0.028 do
            local r, u = trace(d, side, frac)
            n = n + 1
            if r == "pass" then pass = pass + 1 elseif r == "drain" then drain = drain + 1 end
            if u then up = up + 1 end
          end
        end
        print(("   %5d   %5d   %4d   %4d%%   %4d%%   %10d%%")
          :format(my, flare, half, pass / n * 100, drain / n * 100, up / n * 100))
       end
      end
    end
  end

  local which = nil
  for _, v in ipairs(arg or {}) do if v == "a" or v == "b" then which = v end end
  for _, id in ipairs(which and { which } or { "a", "b" }) do sweep(boards[id]) end
  return true
end
