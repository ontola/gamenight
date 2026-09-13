--- §7: "completing something on A arms something on B. You play A to prepare
--- B, then pass and cash in -- which arms A again."
---
--- That is a loop with four steps, and a loop is exactly the kind of thing
--- that can be fully implemented and still never happen: if the charge never
--- fills, or the vault never clears, or the pass never lands, the mechanic is
--- correct code describing something no player will ever see. This probe runs
--- real matches and asks whether the loop closes.
---
---   PINPALS_SUITE=tests.probe_crossboard love . --test

return function()
  local C      = require("core.constants")
  local Match  = require("sim.match")
  local boards = require("data.tables.init").load()

  local function play(seconds, seed)
    math.randomseed(seed)
    local m = Match.new(boards)
    local r = {
      max_charge = 0, banks = 0, boosted_banks = 0, best_boost = 0,
      lit_hits = 0, passes = 0, drains = 0, score = 0,
    }
    local steps = math.floor(seconds * C.TICK_HZ)
    for i = 1, steps do
      if i % 26 == 0 then
        local s = m.state
        for _, b in pairs(s.boards) do
          if b.devices.gate and math.random() < 0.30 then b.devices.gate.commanded = math.random() < 0.65 end
          if math.random() < 0.20 then b.devices.post.commanded = math.random() < 0.30 end
        end
        local act = s.boards[s.active]
        act.flippers.left  = math.random() < 0.40
        act.flippers.right = math.random() < 0.40
      end
      m:run(1)
      local s = m.state
      for _, ev in ipairs(m:drain_events()) do
        if ev.kind == "award" and ev.what == "bumper" then r.lit_hits = r.lit_hits end
      end
      -- Charge is visible directly on the dormant board's state, which is the
      -- whole point of §7: it persists while nobody is looking at it.
      for _, b in pairs(s.boards) do
        for _, v in pairs(b.meters) do
          if v > r.max_charge then r.max_charge = v end
        end
      end
      local cleared = 0
      for _, b in pairs(s.boards) do
        for _, bank in pairs(b.banks) do cleared = cleared + bank.cleared end
      end
      if cleared > r.banks then r.banks = cleared end
      if (s.boards.a.lit.bumpers or 0) > 0 then r.lit_hits = math.max(r.lit_hits, 1) end
    end
    r.passes = m.state.stats.passes
    r.drains = m.state.stats.drains
    r.score  = m.state.stats.score
    return r
  end

  print("")
  print(("%-6s %8s %11s %7s %8s %9s %12s")
    :format("seed", "passes", "max charge", "banks", "drains", "lit fired", "score"))
  local any_lit, any_charge, any_bank = false, false, false
  for k = 1, 5 do
    local r = play(120, 5150 + k * 31)
    print(("%-6d %8d %11d %7d %8d %9s %12d")
      :format(k, r.passes, r.max_charge, r.banks, r.drains,
              r.lit_hits > 0 and "yes" or "NO", r.score))
    any_lit    = any_lit    or r.lit_hits > 0
    any_charge = any_charge or r.max_charge > 0
    any_bank   = any_bank   or r.banks > 0
  end
  print("")
  print(("  loop closes: charge %s -> bank cleared %s -> bumpers lit %s")
    :format(any_charge and "YES" or "no", any_bank and "YES" or "no",
            any_lit and "YES" or "no"))
  print("")
  return true
end
