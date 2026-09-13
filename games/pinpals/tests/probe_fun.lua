--- Whole-match shot participation, across reproducible seeds. A probe, not a gate.
--- PINPALS_SUITE=tests.probe_fun love . --test
return function()
  local C = require("core.constants")
  local Match = require("sim.match")
  local defs = require("data.tables.init").load()
  local totals = {}
  for _, id in ipairs({ "a", "b" }) do
    totals[id] = { targets = {}, lanes = {}, rides = 0, jackpots = 0, banks = 0, passes = 0 }
  end
  local stalls = 0
  for seed = 1, 8 do
    local rng = love.math.newRandomGenerator(7300 + seed * 977)
    local m = Match.new(defs, 7300 + seed * 977)
    local still, reported = 0, false
    for tick = 1, 180 * C.TICK_HZ do
      if tick % 30 == 0 then
        local owner = m.state.active == "a" and 1 or 2
        for _, action in ipairs({ "flip_left", "flip_right" }) do
          m:push({ player = owner, action = action, pressed = rng:random() < 0.4 })
        end
        m:push({ player = 3 - owner, action = "operator_gate", pressed = rng:random() < 0.65 })
        m:push({ player = 3 - owner, action = "operator_paddle", pressed = rng:random() < 0.15 })
      end
      m:run(1)
      local ball = m.boards[m.state.active]
      if m.state.phase == "play" and ball.ball and ball:ball_speed() < 30 then
        still = still + 1
      else still = 0 end
      if still > 5 * C.TICK_HZ and not reported then
        local x, y = ball:ball_pos()
        print(("STALL seed %d board %s at %.0f,%.0f"):format(7300 + seed * 977, ball.id, x, y))
        stalls, reported = stalls + 1, true
      end
      for _, ev in ipairs(m:drain_events()) do
        local t = totals[ev.board]
        if t then
          if ev.kind == "target" then t.targets[ev.index] = (t.targets[ev.index] or 0) + 1 end
          if ev.kind == "rollover" then t.lanes[ev.index] = (t.lanes[ev.index] or 0) + 1 end
          if ev.kind == "tube" then t.passes = t.passes + 1 end
        end
      end
    end
    for id, b in pairs(m.state.boards) do
      local t = totals[id]
      t.rides = t.rides + b.mission.rides
      t.jackpots = t.jackpots + b.mission.jackpots
      for _, bank in pairs(b.banks) do t.banks = t.banks + bank.cleared end
    end
    print(("seed %d: score %d, passes %d, drains %d"):format(
      7300 + seed * 977, m.state.stats.score, m.state.stats.passes, m.state.stats.drains))
  end
  for _, id in ipairs({ "a", "b" }) do
    local t = totals[id]
    print(("%s: passes %d, rides %d, jackpots %d, banks %d"):format(
      id, t.passes, t.rides, t.jackpots, t.banks))
    for i in ipairs(defs[id].targets) do print("  target", i, t.targets[i] or 0) end
    for i in ipairs(defs[id].rollovers) do print("  lane", i, t.lanes[i] or 0) end
  end
  print("stalled seeds", stalls)
  return stalls == 0
end
