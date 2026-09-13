--- What does a frame cost now?
---
--- A night of additions all landed on the per-frame path -- impact events,
--- particles and a trail, a synthesized audio kit, a session recorder, an
--- objective readout evaluated every draw -- and none of them were costed.
--- §4.1 fixes the simulation at 240 Hz, so the sim must fit in 4.17ms per
--- STEP and the frame work in 16.7ms at 60fps; a 30fps frame legitimately
--- asks for eight steps at once (prototype.md §3).
---
--- Measures what can be measured without a window. Rendering is not here.
---
---   PINPALS_SUITE=tests.probe_perf love . --test

return function()
  local C         = require("core.constants")
  local Match     = require("sim.match")
  local fx        = require("app.fx")
  local record    = require("app.record")
  local objective = require("core.objective")
  local boards    = require("data.tables.init").load()

  local names = {}
  for id, d in pairs(boards) do names[id] = d.name end

  local function bench(label, iterations, fn)
    fn()                                      -- warm
    local t0 = os.clock()
    for i = 1, iterations do fn(i) end
    local per = (os.clock() - t0) / iterations
    return { label = label, us = per * 1e6 }
  end

  math.randomseed(4242)
  local m = Match.new(boards)
  m:run(400)                                  -- get a ball into real play
  record.start(boards)

  local rows = {}
  rows[#rows+1] = bench("sim step (240 Hz)", 20000, function()
    m:run(1)
  end)
  rows[#rows+1] = bench("fx.update", 20000, function()
    fx.update(m, m:drain_events(), 1 / 60)
  end)
  rows[#rows+1] = bench("record.update", 20000, function()
    record.update(m, {})
  end)
  rows[#rows+1] = bench("objective.current", 20000, function()
    objective.current(m.state, names)
  end)
  record.finish(m)

  print("")
  print(("%-22s %10s %14s"):format("per call", "microsec", "share of budget"))
  local step_budget = C.FIXED_DT * 1e6        -- 4166us per sim step
  local frame_budget = 16666                  -- 60fps
  for _, r in ipairs(rows) do
    local budget = (r.label:find("sim step")) and step_budget or frame_budget
    print(("%-22s %10.1f %13.2f%%"):format(r.label, r.us, 100 * r.us / budget))
  end

  -- The number that actually matters: a 60fps frame runs four sim steps plus
  -- one pass of everything else.
  local sim = rows[1].us
  local rest = rows[2].us + rows[3].us + rows[4].us
  local frame = sim * 4 + rest
  print("")
  print(("a 60fps frame = 4 sim steps + one pass of the rest = %.0fus (%.1f%% of 16.7ms)")
    :format(frame, 100 * frame / frame_budget))
  local worst = sim * C.MAX_CATCHUP + rest
  print(("worst case  = MAX_CATCHUP (%d) steps + the rest = %.0fus (%.1f%% of 16.7ms)")
    :format(C.MAX_CATCHUP, worst, 100 * worst / frame_budget))
  print("")
  return true
end
