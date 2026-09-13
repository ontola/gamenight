--- design.md §13.1: what is each board FOR?
---
--- prototype.md §4.1 answers it provisionally -- Foundry forgiving and
--- chaotic, Glasshouse clean and deadly -- and that claim has never been
--- checked against the simulation. Board identity is the reason to pass, so
--- an identity that exists only in a comment is a design that does not exist.
---
---   PINPALS_SUITE=tests.probe_identity love . --test

return function()
  local C      = require("core.constants")
  local Board  = require("sim.board")
  local boards = require("data.tables.init").load()

  --- Bank membership, resolved once from the board data the way core/state.lua
  --- does it. This probe used to treat "all targets on the board" as one bank
  --- and to clear the lit set at the start of every ball, which was accurate
  --- while Glasshouse had exactly two targets in exactly one bank and became
  --- silently wrong the moment it had four in two. It reported ONE completion
  --- where the rules produce nineteen, and dragged points/s down with it --
  --- a probe that lies is worse than no probe, because its numbers get
  --- written into design docs.
  ---
  --- core/state.lua keeps a target lit until its own bank completes, for the
  --- life of the match and not the life of the ball, so a bank is something
  --- two players build across several balls. That is modelled here now.
  local function banks_of(def)
    local of, members = {}, {}
    for i, t in ipairs(def.targets or {}) do
      of[i] = t.bank
      members[t.bank] = members[t.bank] or {}
      table.insert(members[t.bank], i)
    end
    return of, members
  end

  local lit = {}

  local function cmd(gate, post, left, right)
    return { flippers = { left = left or false, right = right or false },
             devices  = { gate = { commanded = gate or false },
                          post = { commanded = post or false } } }
  end

  --- How long does a ball live here, under identical random play? The one
  --- number that says whether a board is forgiving.
  local score = require("core.score")

  local function ball_life(def, seeds, balls_per_seed)
    local lives, drains, passes = {}, 0, 0
    local bank_of, bank_members = banks_of(def)
    -- Points earned per second of ball time, which is the number that says
    -- what a board is FOR. Scored at x1 throughout: this measures the board,
    -- not the rally on top of it.
    local points, seconds, hits = 0, 0, { bumper = 0, target = 0, bank = 0 }
    local flat = { relay = 0, score = 0, rally_score = 0, best_rally_score = 0 }
    for s = 1, seeds do
      math.randomseed(31337 + s * 977)
      -- The serve carries jitter now, so the board gets this seed too: built
      -- without one, every seed here would receive the same serve and the
      -- average would be over flipper timing alone.
      local b = Board.new(def, 31337 + s * 977)
      lit = {}                     -- per match, not per ball, as core/ has it
      for _ = 1, balls_per_seed do
        b:serve()
        local t, over = 0, false
        local c = cmd()
        while not over and t < 30 * C.TICK_HZ do
          t = t + 1
          if t % 30 == 0 then
            c = cmd(math.random() < 0.5, math.random() < 0.2,
                    math.random() < 0.35, math.random() < 0.35)
          end
          for _, ev in ipairs(b:step(c, b.ball ~= nil)) do
            if ev.kind == "drain" then drains = drains + 1; over = true end
            -- A pass ends the ball on THIS board, so it counts as survival:
            -- the ball left alive, which is the whole point of the game.
            if ev.kind == "tube" then passes = passes + 1; over = true end
            if ev.kind == "bumper" then
              hits.bumper = hits.bumper + 1
              points = points + score.value("bumper", 0)
            elseif ev.kind == "target" then
              hits.target = hits.target + 1
              points = points + score.value("target", 0)
              -- Bank completion, simulated the way core/ does it.
              if not lit[ev.index] then
                lit[ev.index] = true
                local bank = bank_of[ev.index]
                local all = true
                for _, i in ipairs(bank_members[bank] or {}) do
                  if not lit[i] then all = false break end
                end
                if all then
                  hits.bank = hits.bank + 1
                  points = points + score.value("bank", 0)
                  for _, i in ipairs(bank_members[bank]) do lit[i] = nil end
                end
              end
            end
          end
        end
        lives[#lives+1] = t / C.TICK_HZ
        seconds = seconds + t / C.TICK_HZ
        b:despawn()
      end
    end
    table.sort(lives)
    local sum = 0
    for _, v in ipairs(lives) do sum = sum + v end
    local _ = flat
    return {
      n = #lives, mean = sum / #lives, median = lives[math.ceil(#lives / 2)],
      drains = drains, passes = passes, points = points, seconds = seconds,
      hits = hits,
      survival = passes / math.max(1, passes + drains),
      pps = points / math.max(0.001, seconds),
      -- Drains per second of ball time. Survival conflates "this board is
      -- deadly" with "this board's pass is hard", because a random flipper
      -- escapes an easy board more often. This isolates deadliness.
      dps = drains / math.max(0.001, seconds),
    }
  end

  --- The gap the ball drains through, tip to tip at rest.
  local function drain_gap(def)
    local left, right
    for _, f in ipairs(def.flippers) do
      if f.side == "left" then left = f else right = f end
    end
    local reach = math.cos(C.FLIPPER_REST) * C.FLIPPER_LEN
    return (right.x - reach) - (left.x + reach)
  end

  print("")
  print(("%-12s %7s %7s %8s %8s %8s %8s %7s")
    :format("board", "gap px", "mean s", "drains/s", "survival", "targets",
            "banks", "pts/s"))
  for _, id in ipairs({ "a", "b" }) do
    local def = boards[id]
    local r = ball_life(def, 5, 12)
    print(("%-12s %7.1f %7.2f %8.4f %7.0f%% %8d %8d %7.0f")
      :format(def.name, drain_gap(def), r.mean, r.dps, 100 * r.survival,
              r.hits.target, r.hits.bank, r.pps))
  end
  print("")
  return true
end
