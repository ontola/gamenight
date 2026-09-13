return function(H)
  local A = H.assert
  local state = require("core.state")
  local mission = require("core.mission")
  local boards = require("data.tables.init").load()
  local function playing()
    local s = state.new(boards)
    s.phase = "play"
    return s
  end
  local function hit(s, kind, index)
    state.consume(s, { { kind = kind, board = "a", index = index, speed = 900 } })
  end
  H.describe("relay missions", function()
    H.it("requires different lanes and debounces a repeated contact", function()
      local s = playing()
      hit(s, "rollover", 1)
      local points = s.stats.score
      hit(s, "rollover", 1)
      A.equal(points, s.stats.score)
      A.equal(1, s.boards.a.mission.charge)
      hit(s, "rollover", 2)
      hit(s, "rollover", 3)
      A.equal(725, s.stats.score)
      A.equal(nil, next(s.boards.a.mission.lanes))
      A.equal(5, s.boards.a.mission.charge)
    end)
    H.it("keeps preparation through a drain and pays a jackpot only once", function()
      local s = playing()
      mission.charge(s.boards.a.mission, 8)
      hit(s, "drain")
      A.equal(8, s.boards.a.mission.charge)
      s.phase = "play"
      hit(s, "tube")
      A.equal(1, s.boards.a.mission.jackpots)
      A.equal(0, s.boards.a.mission.charge)
      local before = s.stats.score
      hit(s, "tube")
      A.equal(before, s.stats.score, "transit paid twice")
    end)
    H.it("does not reward ramp entry or a rollback", function()
      local s = playing()
      state.consume(s, { { kind = "ramp", board = "a", at = "enter" },
        { kind = "ramp", board = "a", at = "exit", complete = false } })
      A.equal(0, s.stats.score)
      A.equal(0, s.boards.a.mission.combo)
    end)
    H.it("rewards a full ride and a timed pass; drains cancel the combo", function()
      local s = playing()
      state.consume(s, { { kind = "ramp", board = "a", at = "exit", complete = true } })
      A.equal(750, s.stats.score)
      A.equal(3, s.boards.a.mission.charge)
      hit(s, "tube")
      A.truthy(s.stats.score >= 2250)
      A.equal(0, s.boards.a.mission.combo)
      s.phase, s.active = "play", "a"
      s.boards.a.mission.combo = 10
      hit(s, "drain")
      A.equal(0, s.boards.a.mission.combo)
    end)
    H.it("counts down only during active play", function()
      local s = playing()
      s.boards.a.mission.combo = 5
      s.phase = "serve"
      state.update(s)
      A.equal(5, s.boards.a.mission.combo)
      s.phase = "play"
      state.update(s)
      A.truthy(s.boards.a.mission.combo < 5)
      mission.update(s.boards.a.mission, 10, true)
      A.equal(0, s.boards.a.mission.combo)
    end)
  end)
end
