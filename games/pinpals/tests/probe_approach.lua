--- WHERE does a received ball meet the flipper?
---
--- This is the answer to item 14 -- why Foundry receives at a 20ms timing
--- window and Glasshouse at 50ms -- after bumpers, drain gap, arrival speed
--- and a truncated sweep were all eliminated.
---
---   board         n    p10    p50    p90   |vx| p50
---   Foundry     119   0.12   0.59   1.00        218
---   Glasshouse  120   0.12   1.01   1.02        399
---
--- Glasshouse funnels received balls onto the flipper TIP: half of them land
--- past 1.01 of the flipper's length and 90% past 1.02. Foundry scatters them
--- along it, median 0.59, mid-flipper. The tip is where the flipper is moving
--- fastest and imparts the most energy, which is also why Glasshouse's peak
--- pass rate is 85% against Foundry's 63%.
---
--- The mechanism is horizontal carry. Glasshouse's ball arrives with nearly
--- twice the horizontal speed, crosses the board during its descent and
--- arrives at the far flipper's tip consistently; Foundry's dribbles down
--- onto the near flipper wherever it happens to land. A shot whose contact
--- point varies that much cannot have one right flip time, which is the
--- narrow window.
---
--- The entry angle is NOT the lever, tested and rejected: steepening
--- Foundry's entry from dir.x 0.32 to 0.60 and 0.90 makes the ball meet the
--- left wall sooner and arrive with LESS horizontal carry (|vx| 218 -> 187 ->
--- 114), moving contact toward the pivot and, at 0.90, dropping the peak to
--- 48%. What would work is a descent that carries the ball across -- a
--- shallower left orbit, or a deflector -- and that is a layout change worth
--- doing awake.
---
---   PINPALS_SUITE=tests.probe_approach love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()
  local function cmd() return { flippers={left=false,right=false},
    devices={gate={commanded=true},post={commanded=false}} } end

  local function pct(t,p) return #t>0 and t[math.max(1,math.ceil(#t*p))] or 0 end

  print("")
  print("where a RECEIVED ball first touches a flipper (fraction along it from pivot)")
  print(("%-12s %6s %7s %7s %7s %9s %9s")
    :format("board","n","p10","p50","p90","spread","|vx| p50"))
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    local fracs, vxs, sides = {}, {}, { left = 0, right = 0 }
    for i = 1, 120 do
      math.randomseed(700 + i * 7717)
      local b = Board.new(def)
      local e = def.entry
      local speed = C.TRANSIT_MIN_SP + (C.TRANSIT_MAX_SP - C.TRANSIT_MIN_SP) * math.random()
      local ang = math.atan2(e.dir.y, e.dir.x) + (math.random()*2-1) * 0.10
      for _ = 1, math.floor(0.45*C.TICK_HZ) do b:step(cmd(), true) end
      b:spawn(e.x + (math.random()*2-1)*6, e.y, math.cos(ang)*speed, math.sin(ang)*speed)
      local done = false
      for _ = 1, math.floor(8*C.TICK_HZ) do
        local vx = select(1, b:ball_velocity())
        for _, ev in ipairs(b:step(cmd(), true)) do
          if ev.kind == "impact" and ev.what == "flipper" and not done then
            -- Nearest flipper pivot, and how far along that flipper the hit is.
            local best, bd
            for _, f in ipairs(def.flippers) do
              local d = math.sqrt((ev.x-f.x)^2 + (ev.y-f.y)^2)
              if not bd or d < bd then best, bd = f, d end
            end
            fracs[#fracs+1] = bd / C.FLIPPER_LEN
            vxs[#vxs+1] = math.abs(vx)
            sides[best.side] = sides[best.side] + 1
            done = true
          end
          if ev.kind == "drain" or ev.kind == "tube" then done = true end
        end
        if done then break end
        if not b:ball_pos() then break end
      end
    end
    table.sort(fracs); table.sort(vxs)
    print(("%-12s %6d %7.2f %7.2f %7.2f %9.2f %9.0f   (L %d / R %d)")
      :format(def.name, #fracs, pct(fracs,0.10), pct(fracs,0.50), pct(fracs,0.90),
              pct(fracs,0.90)-pct(fracs,0.10), pct(vxs,0.50),
              sides.left, sides.right))
  end
  print("")
  return true
end
