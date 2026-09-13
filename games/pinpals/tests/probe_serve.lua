--- What does a serve actually do, now that no two of them are the same?
---
--- C.SERVE_SPEED_VAR and C.SERVE_ANGLE_VAR exist because a plunger is pulled
--- by a hand. The size of them is a gameplay choice with exactly two failure
--- modes, and this is the tool that says which side of both we are on:
---
---   too small -- the ball flies the same line every ball, and the first
---                seconds of every ball are a recording. That is measurable:
---                the spread of where the serve first comes back down.
---   too large -- the serve stops doing its job. A serve has to climb past
---                the tube mouth (it is what puts the ball in the upper
---                field at all) and it must not be the thing that kills the
---                ball before the flippers ever see it.
---
---   PINPALS_SUITE=tests.probe_serve love . --test
return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  local SERVES = 200

  local function idle()
    return { guard = nil, guard_cooldown = 0,
             flippers = { left = false, right = false },
             devices  = { gate = { commanded = false }, post = { commanded = false } } }
  end

  local function stats(t)
    local sum, min, max = 0, math.huge, -math.huge
    for _, v in ipairs(t) do
      sum = sum + v
      if v < min then min = v end
      if v > max then max = v end
    end
    local mean = sum / #t
    local var = 0
    for _, v in ipairs(t) do var = var + (v - mean) ^ 2 end
    return mean, math.sqrt(var / #t), min, max
  end

  --- One serve, left entirely alone: no flipper ever moves. What the serve
  --- does on its own is the thing being measured, and a flipper policy would
  --- only add a second source of spread on top of it.
  ---@return number apex, number|nil cross, boolean died
  local function trace(def, seed)
    local b = Board.new(def, seed)
    b:serve()
    local apex, cross, died = math.huge, nil, false
    local c = idle()
    -- 6s: long enough for the ball to climb, come back down and reach the
    -- flippers, and short enough that a ball still rattling counts as alive.
    for i = 1, math.floor(6.0 * C.TICK_HZ) do
      for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
        if ev.kind == "drain" then died = died or (i < 3.0 * C.TICK_HZ) end
      end
      local x, y = b:ball_pos()
      if not x then break end
      if y < apex then apex = y end
      -- Where it comes back down past the tube mouth's height: the width of
      -- this band is the whole point of the jitter.
      local _, vy = b:ball_velocity()
      if not cross and vy > 0 and y > def.tube.mouth.y then cross = x end
    end
    return apex, cross, died
  end

  --- Four settings of the same two constants, because the question is not
  --- "does the ball move" but "how much input jitter buys how much outcome".
  local BASE_S, BASE_A = C.SERVE_SPEED_VAR, C.SERVE_ANGLE_VAR
  local CASES = {
    { "fixed",  0,          0          },
    { "half",   BASE_S / 2, BASE_A / 2 },
    { "live",   BASE_S,     BASE_A     },
    { "double", BASE_S * 2, BASE_A * 2 },
  }

  local function report(case, def)
    C.SERVE_SPEED_VAR, C.SERVE_ANGLE_VAR = case[2], case[3]
    local apexes, crossings, deaths, short = {}, {}, 0, 0
    for i = 1, SERVES do
      local apex, cross, died = trace(def, 5000 + i * 37)
      apexes[#apexes+1] = apex
      if cross then crossings[#crossings+1] = cross end
      if died then deaths = deaths + 1 end
      if apex > def.tube.mouth.y then short = short + 1 end
    end
    local am, asd, alo, ahi = stats(apexes)
    local cm, csd, clo, chi = stats(crossings)
    print(("[%-6s] board %s -- %d serves from (%d,%d), %d px/s +/-%.0f%%, +/-%.1f deg")
      :format(case[1], def.id, SERVES, def.serve.x, def.serve.y, C.SERVE_SPEED,
              case[2] * 100, math.deg(case[3])))
    print(("   apex y   mean %.0f  sd %.1f  range %.0f..%.0f   (tube mouth y=%d)")
      :format(am, asd, alo, ahi, def.tube.mouth.y))
    print(("   comes back down past the mouth at x: mean %.0f  sd %.1f  range %.0f..%.0f")
      :format(cm, csd, clo, chi))
    print(("   never reached the mouth: %d/%d    drained within 3s untouched: %d/%d")
      :format(short, SERVES, deaths, SERVES))
  end

  ---------------------------------------------------------------------------
  -- What the serve costs once there are flippers under it
  ---------------------------------------------------------------------------
  --- Everything above leaves the flippers parked, which measures the serve
  --- and not the game. A real served ball has two flippers under it from the
  --- first frame, and a serve that comes back down the outlane may simply be
  --- a serve the player answers. Whether it is costs a measurement, not an
  --- opinion.
  ---
  --- Random flipper play, same policy as tests/probe_reach.lua's play_map and
  --- tests/probe_identity.lua, so these numbers sit beside theirs. One served
  --- ball per trial; the trial ends when the ball drains or passes.
  ---
  --- CLAUDE.md rule 1: pinball is chaotic, so this is many seeds and the
  --- per-seed spread is printed next to the mean. Board.new takes the seed as
  --- well as math.randomseed -- without that every seed would receive the
  --- SAME serve and the average would be over flipper timing alone.
  local PLAY_SEEDS, PLAY_BALLS = 24, 10
  local EARLY   = 3.0    -- "before the player had a chance to do anything"
  local TIMEOUT = 30.0

  local function play_cmd()
    return { guard = nil, guard_cooldown = 0,
             flippers = { left = math.random() < 0.35, right = math.random() < 0.35 },
             devices  = { gate = { commanded = math.random() < 0.5 },
                          post = { commanded = math.random() < 0.2 } } }
  end

  --- One served ball, played to its end.
  ---
  --- Target hits are split at SERVE_WINDOW seconds because a target standing
  --- in the plunger lane is hit by the SERVE, not by play, and the two are
  --- indistinguishable in a total. board_b.lua justifies its gallery target
  --- at (56,470) with "154 hits per 720s of play" against a rival position's
  --- 13, and that ratio decides whether the target is content or a backboard.
  ---@return number life, "drain"|"pass"|"timeout" ending, boolean got_up
  local SERVE_WINDOW = 1.0
  local function play_ball(b, def, early_hits, late_hits)
    local c, t, got_up = idle(), 0, false
    local ending, over = "timeout", false
    while not over and t < TIMEOUT * C.TICK_HZ do
      t = t + 1
      if t % 30 == 0 then c = play_cmd() end
      for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
        if ev.kind == "drain" then ending, over = "drain", true end
        if ev.kind == "tube" then ending, over = "pass", true end
        if ev.kind == "target" then
          local into = (t < SERVE_WINDOW * C.TICK_HZ) and early_hits or late_hits
          into[ev.index] = (into[ev.index] or 0) + 1
        end
      end
      local _, y = b:ball_pos()
      if y and y <= def.tube.mouth.y then got_up = true end
    end
    return t / C.TICK_HZ, ending, got_up
  end

  local function play_report(def)
    local lives, early, up = {}, 0, 0
    local ends = { drain = 0, pass = 0, timeout = 0 }
    local seed_early = {}
    local early_hits, late_hits = {}, {}
    for s = 1, PLAY_SEEDS do
      local seed = 20260907 + s * 7717
      math.randomseed(seed)
      local b, n = Board.new(def, seed), 0
      for _ = 1, PLAY_BALLS do
        b:serve()
        local life, ending, got_up = play_ball(b, def, early_hits, late_hits)
        lives[#lives+1] = life
        ends[ending] = ends[ending] + 1
        if ending == "drain" and life < EARLY then early, n = early + 1, n + 1 end
        if got_up then up = up + 1 end
        b:despawn()
      end
      seed_early[s] = n / PLAY_BALLS
    end
    local n = #lives
    local lm = stats(lives)
    local sorted = {}
    for i, v in ipairs(lives) do sorted[i] = v end
    table.sort(sorted)
    local _, esd, elo, ehi = stats(seed_early)
    print(("board %s (%s) -- %d serves, %d seeds x %d balls, random flipper play")
      :format(def.id, def.name, n, PLAY_SEEDS, PLAY_BALLS))
    print(("   drained within %.0fs of the serve: %.0f%%  (per seed: sd %.0f%%, range %.0f..%.0f%%)")
      :format(EARLY, 100 * early / n, 100 * esd, 100 * elo, 100 * ehi))
    print(("   served ball life: mean %.2fs  median %.2fs   reached the mouth's height %.0f%%")
      :format(lm, sorted[math.ceil(n / 2)], 100 * up / n))
    -- What ENDED the ball. A pass is the co-op loop (design.md 7.1), so the
    -- split matters more than the total: a change that buys ball life by
    -- keeping the ball away from the ramp has made the board worse.
    print(("   ended by: drain %d (%.0f%%)  pass %d (%.0f%%)  alive at %.0fs %d (%.0f%%)")
      :format(ends.drain, 100 * ends.drain / n, ends.pass, 100 * ends.pass / n,
              TIMEOUT, ends.timeout, 100 * ends.timeout / n))
    print(("   pass rate of decided balls: %.0f%%")
      :format(100 * ends.pass / math.max(1, ends.pass + ends.drain)))
    for i, t in ipairs(def.targets or {}) do
      local e, l = early_hits[i] or 0, late_hits[i] or 0
      print(("   target %d (%3d,%3d) %-8s hits: %4d off the serve, %4d in play")
        :format(i, t.x, t.y, t.bank, e, l))
    end
  end

  for _, id in ipairs({ "a", "b" }) do
    for _, case in ipairs(CASES) do report(case, boards[id]) end
    print("")
  end
  C.SERVE_SPEED_VAR, C.SERVE_ANGLE_VAR = BASE_S, BASE_A

  print("-- IN PLAY (live jitter, flippers moving) --")
  for _, id in ipairs({ "a", "b" }) do play_report(boards[id]) end
  print("")
  return true
end
