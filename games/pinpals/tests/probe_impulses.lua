--- One-off measurement, not a gate: what do ball-contact impulses actually
--- look like in play? The impact threshold in core/constants.lua has to sit
--- between "a ball leaning on something" and "a ball hitting it", and that
--- boundary is a property of the physics, not something to pick by taste.
---
---   PINPALS_SUITE=tests.probe_impulses love . --test

return function()
  local C      = require("core.constants")
  local Match  = require("sim.match")
  local boards = require("data.tables.init").load()

  local function percentile(sorted, p)
    if #sorted == 0 then return 0 end
    local i = math.max(1, math.ceil(#sorted * p))
    return sorted[i]
  end

  --- Random operator play, which is what produces both resting contacts
  --- (post up, ball sitting on it) and hard ones (bumpers, flipper slams).
  local function sample(seconds, seed)
    math.randomseed(seed)
    local match = Match.new(boards)
    local by_kind = {}
    local steps = math.floor(seconds * C.TICK_HZ)
    for i = 1, steps do
      if i % 40 == 0 then
        local s = match.state
        for _, b in pairs(s.boards) do
          if math.random() < 0.25 then
            if b.devices.gate then b.devices.gate.commanded = math.random() < 0.5 end
          end
          if math.random() < 0.25 then
            b.devices.post.commanded = math.random() < 0.5
          end
        end
        local act = s.boards[s.active]
        act.flippers.left  = math.random() < 0.35
        act.flippers.right = math.random() < 0.35
      end
      match:run(1)
      for _, ev in ipairs(match:drain_events()) do
        if ev.kind == "impact" then
          by_kind[ev.what] = by_kind[ev.what] or {}
          local t = by_kind[ev.what]
          t[#t+1] = ev.impulse
        end
      end
    end
    return by_kind
  end

  local by_kind = sample(240, 20260906)

  print("")
  print("impulse distribution, 240s of random play")
  print(("%-10s %7s %8s %8s %8s %8s %8s"):format(
        "surface", "n", "min", "p50", "p90", "p99", "max"))
  local kinds = {}
  for k in pairs(by_kind) do kinds[#kinds+1] = k end
  table.sort(kinds)
  for _, k in ipairs(kinds) do
    local v = by_kind[k]
    table.sort(v)
    print(("%-10s %7d %8.3f %8.3f %8.3f %8.3f %8.3f"):format(
          k, #v, v[1], percentile(v, 0.50), percentile(v, 0.90),
          percentile(v, 0.99), v[#v]))
  end

  -- The number that matters: how many events per second survive a given
  -- floor. Above ~25/s the audio is a buzz rather than a set of hits.
  print("")
  print(("%-10s %10s %10s"):format("floor", "events/s", "kept%"))
  local all = {}
  for _, v in pairs(by_kind) do for _, x in ipairs(v) do all[#all+1] = x end end
  for _, floor in ipairs({ 0, 0.02, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 1.0 }) do
    local n = 0
    for _, x in ipairs(all) do if x >= floor then n = n + 1 end end
    print(("%-10.2f %10.1f %9.1f%%"):format(floor, n / 240, 100 * n / math.max(1, #all)))
  end
  print("")
  return true
end
