--- §6.2: "the wall that guards the outlane blocks a scoring shot". The post
--- is meant to be a trade. prototype.md §5 flags it as possibly too absolute:
--- the pass measured 20/32 with it down and 0/32 with it up, which is a very
--- legible trade and also leaves the flipper player with nothing productive
--- to do for as long as their partner holds it -- brushing pillar 1,
--- "nobody waits".
---
--- This probe measures both halves at once, because the post is only worth
--- narrowing if it still guards: pass rate with the post up, and drain rate
--- with the post up. A post that blocks fewer shots AND stops guarding is
--- not a better trade, it is a worse device.
---
---   PINPALS_SUITE=tests.probe_post love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- Sweep flipper contact points; report what fraction reach the tube.
  --- Reported per flipper as well as overall: the post sits between them and
  --- there is no reason to assume it costs both the same shot.
  local function pass_rate(def, post_up, only_side)
    local made, tried = 0, 0
    for _, side in ipairs(only_side and { only_side } or { "left", "right" }) do
      local spec
      for _, f in ipairs(def.flippers) do if f.side == side then spec = f end end
      local sign = (side == "left") and 1 or -1
      local ang  = (side == "left") and C.FLIPPER_REST or -C.FLIPPER_REST
      for frac = 0.30, 1.00, 0.03 do
        local b = Board.new(def)
        -- Let the devices finish travelling before the ball exists, so this
        -- measures a held post rather than a moving one.
        for _ = 1, math.floor(0.45 * C.TICK_HZ) do b:step(cmd(true, post_up), true) end
        local d = C.FLIPPER_LEN * frac
        b:spawn(spec.x + math.cos(ang) * d * sign,
                spec.y + math.sin(ang) * d * sign - C.BALL_RADIUS - 2, 0, 0)
        for _ = 1, 12 do b:step(cmd(true, post_up), true) end
        local held = cmd(true, post_up, side == "left", side == "right")
        local rest = cmd(true, post_up)
        local c, got = held, false
        for tick = 1, math.floor(4.0 * C.TICK_HZ) do
          if tick == math.floor(0.22 * C.TICK_HZ) then c = rest end
          local over = false
          for _, ev in ipairs(b:step(c, true)) do
            if ev.kind == "tube" then got = true; over = true end
            if ev.kind == "drain" then over = true end
          end
          if over then break end
        end
        tried = tried + 1
        if got then made = made + 1 end
      end
    end
    return made, tried
  end

  --- Does it still guard? Drop balls into the drain mouth from above and
  --- count how many get through.
  local function drain_rate(def, post_up)
    math.randomseed(90210)
    local through, tried = 0, 0
    for _ = 1, 60 do
      local b = Board.new(def)
      for _ = 1, math.floor(0.45 * C.TICK_HZ) do b:step(cmd(false, post_up), true) end
      -- Aimed at the gap between the flipper tips, with a spread wider than
      -- the gap so the shoulders are sampled too.
      local left, right
      for _, f in ipairs(def.flippers) do
        if f.side == "left" then left = f else right = f end
      end
      local mid = (left.x + right.x) / 2
      local x = mid + (math.random() * 2 - 1) * 34
      b:spawn(x, 600, (math.random() * 2 - 1) * 120, 260 + math.random() * 420)
      local drained = false
      for _ = 1, math.floor(2.5 * C.TICK_HZ) do
        for _, ev in ipairs(b:step(cmd(false, post_up), true)) do
          if ev.kind == "drain" then drained = true end
        end
        if drained then break end
      end
      tried = tried + 1
      if drained then through = through + 1 end
    end
    return through, tried
  end

  print("")
  print(("%-12s %-10s %14s %16s")
    :format("board", "post", "pass rate", "per flipper / drained"))
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    for _, up in ipairs({ false, true }) do
      local made, tried = pass_rate(def, up)
      local lm, lt = pass_rate(def, up, "left")
      local rm, rt = pass_rate(def, up, "right")
      local through, dropped = drain_rate(def, up)
      print(("%-12s %-10s %8d/%-3d %3.0f%%   L %3.0f%%  R %3.0f%% %8d/%-3d %3.0f%%")
        :format(def.name, up and "UP" or "down", made, tried,
                100 * made / tried, 100 * lm / lt, 100 * rm / rt,
                through, dropped, 100 * through / dropped))
    end
  end
  print("")
  return true
end
