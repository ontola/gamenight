--- Produces a real session log from simulated play, so the artifact a human
--- gets in the morning can be read before a human is asked to generate one.
--- A capture that is never looked at is a capture nobody knows is broken.
---
---   PINPALS_SUITE=tests.probe_session love . --test

return function()
  local C      = require("core.constants")
  local Match  = require("sim.match")
  local record = require("app.record")
  local boards = require("data.tables.init").load()

  math.randomseed(20260906)
  local m = Match.new(boards)
  record.start(boards)

  local ACTIONS = { "flip_left", "flip_right", "operator_gate", "operator_paddle" }
  for i = 1, math.floor(180 * C.TICK_HZ) do
    if i % 24 == 0 then
      local s = m.state
      -- Synthetic intents, recorded the way real ones are.
      local it = {
        player  = math.random(2),
        action  = ACTIONS[math.random(#ACTIONS)],
        pressed = math.random() < 0.5,
        tick    = s.tick,
      }
      record.intent(it)
      m:push(it)
    end
    m:run(1)
    record.update(m, m:drain_events())
  end

  print("")
  print(record.summary(m))
  local path = record.finish(m)
  print("")
  print("written to: " .. tostring(path))
  print("")
  return true
end
