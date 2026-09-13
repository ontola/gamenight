--- Seeded inlane drops: measure the feed before the ball reaches a flipper.
--- PINPALS_SUITE=tests.probe_inlane love . --test
return function()
  local Board = require("sim.board")
  local C = require("core.constants")
  local boards = require("data.tables.init").load()
  local command = { flippers = { left = false, right = false },
    devices = { gate = { commanded = false }, post = { commanded = false } } }
  for _, id in ipairs({ "a", "b" }) do
    for _, side in ipairs({ "left", "right" }) do
      local fed, bounced, missed = 0, 0, 0
      local min_x, max_x = math.huge, -math.huge
      for seed = 1, 48 do
        math.randomseed(seed * 7919)
        local board = Board.new(boards[id], seed * 7919)
        local x = 49 + math.random() * 6
        local vx = (math.random() - 0.5) * 30
        if side == "right" then x, vx = 448 - x, -vx end
        board:spawn(x, 730, vx, 80 + math.random() * 120)
        local previous_y, reversed, arrived = 730, false, false
        for _ = 1, 4 * C.TICK_HZ do
          board:step(command, true)
          local bx, by = board:ball_pos()
          if not bx then break end
          if by < previous_y - 0.1 then reversed = true end
          previous_y = by
          if by >= 860 then
            local local_x = side == "left" and bx or 448 - bx
            min_x, max_x = math.min(min_x, local_x), math.max(max_x, local_x)
            if local_x > 65 and local_x < 155 then fed = fed + 1 end
            arrived = true
            break
          end
        end
        if reversed then bounced = bounced + 1 end
        if not arrived then missed = missed + 1 end
      end
      print(("%s %s: feed %d/48, upward bounce %d, timeout %d, crossing x %.1f..%.1f")
        :format(id, side, fed, bounced, missed, min_x, max_x))
    end
  end
  return true
end
