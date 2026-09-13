--- app/record.lua's bookkeeping, in the bare interpreter.
---
--- record only touches love.* inside finish(), so everything that decides
--- whether a morning's playtest produces usable numbers -- duty cycles, rally
--- capture, the summary itself -- is testable with no window and no disk.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local record = require("app.record")
  local boards = require("data.tables.init").load()

  --- A match-shaped stub. record reads state and events and nothing else,
  --- so it needs no physics.
  local function fake_match(active, phase)
    local m = { state = {
      tick = 0, active = active or "a", phase = phase or "play",
      stats = { score = 0, passes = 0, drains = 0, relay = 0,
                best_relay = 0, best_rally_score = 0 },
      boards = {},
    } }
    for id in pairs(boards) do
      m.state.boards[id] = { devices = { gate = { commanded = false },
                                         post = { commanded = false } } }
    end
    return m
  end

  describe("playtest capture", function()
    it("does nothing at all until it is started", function()
      -- --test and --shot must never touch the disk or accumulate state.
      A.truthy(not record.active(), "recording was live before start()")
      record.intent({ tick = 1, player = 1, action = "flip_left", pressed = true })
      A.equal(nil, record.finish(fake_match()), "finish() wrote without a session")
    end)

    it("measures how much of the time each operator was doing something",
       function()
      -- Pillar 1 says nobody waits. An operator sitting near 0% is what
      -- "waiting" looks like in a number, so this is the instrument for the
      -- pillar rather than a nice-to-have.
      record.start(boards)
      local m = fake_match("a")
      for i = 1, 100 do
        m.state.boards.a.devices.gate.commanded = i <= 40
        record.update(m, {})
      end
      local out = record.summary(m)
      A.truthy(out:find("gate  40%%"), "duty cycle is wrong:\n" .. out)
      A.truthy(out:find("post   0%%"), "an untouched device shows as used:\n" .. out)
      record.finish(m)
    end)

    it("records the length of the rally a drain ended", function()
      record.start(boards)
      local m = fake_match("a")
      m.state.stats.relay = 4
      record.update(m, {})                       -- observe the live rally
      m.state.stats.relay = 0                    -- core resets it on the drain
      record.update(m, { { kind = "drain", board = "a" } })
      local out = record.summary(m)
      A.truthy(out:find("max 4"), "the ended rally was not captured:\n" .. out)
      record.finish(m)
    end)

    it("keeps a run's numbers when the player restarts", function()
      -- Pressing R builds a whole new Match with zeroed stats while this
      -- session keeps accumulating. A summary that read the live match
      -- reported the last few seconds against rallies from before the
      -- restart: measured, 24,800 points of play came out as "score 250,
      -- passes 0" beside five completed rallies.
      record.start(boards)
      local m = fake_match("a")
      m.state.stats.score  = 24800
      m.state.stats.passes = 3
      m.state.stats.best_rally_score = 24800
      m.state.stats.best_relay = 3
      record.update(m, {})
      record.restart(m)

      local fresh = fake_match("a")            -- what R produces
      fresh.state.stats.score = 250
      record.update(fresh, {})
      local out = record.summary(fresh)
      A.truthy(out:find("score 25050"), "the retired run's score was lost:\n" .. out)
      A.truthy(out:find("passes 3"),    "the retired run's passes were lost:\n" .. out)
      A.truthy(out:find("24,?800"),     "best rally was lost:\n" .. out)
      A.truthy(out:find("2 runs"),      "the restart is not reported:\n" .. out)
      record.finish(fresh)
    end)

    it("counts rallies that never got a single pass", function()
      -- The one number that would say the prototype has failed: if most
      -- rallies die before a crossing, there is no rally to have a feel.
      record.start(boards)
      local m = fake_match("a")
      for _ = 1, 3 do
        record.update(m, {})
        record.update(m, { { kind = "drain", board = "b" } })
      end
      local out = record.summary(m)
      A.truthy(out:find("3 of 3 rallies %(100%%%) ended without a single pass"),
               "zero-pass rallies not reported:\n" .. out)
      record.finish(m)
    end)
  end)
end
