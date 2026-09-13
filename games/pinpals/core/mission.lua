--- Shot progress survives drains; the timed skyway combo does not.
--- No random objectives: every lit insert corresponds to a shot on the board.
local C = require("core.constants")
local score = require("core.score")
local M = { GOAL = 8, COMBO_TIME = 12 }

function M.new()
  return { charge = 0, jackpots = 0, lanes = {}, lane_tick = {}, combo = 0,
           rides = 0, notice = "", notice_time = 0 }
end

function M.update(m, dt, playing)
  m.notice_time = math.max(0, m.notice_time - dt)
  if playing then m.combo = math.max(0, m.combo - dt) end
end

local function announce(m, text)
  m.notice, m.notice_time = text, 3
end

function M.charge(m, amount)
  local before = m.charge
  m.charge = math.min(M.GOAL, m.charge + amount)
  if before < M.GOAL and m.charge == M.GOAL then announce(m, "JACKPOT READY - SHOOT PASS") end
end

--- Returns the bonus earned by a shot; ordinary contact scoring stays in state.
function M.shot(s, ev)
  local b = s.boards[ev.board]
  local m = b.mission
  if ev.kind == "rollover" then
    if not ev.index or ev.index < 1 or ev.index > b.lane_count then return 0 end
    if s.tick - (m.lane_tick[ev.index] or -10000) < C.TICK_HZ / 2 then return 0 end
    m.lane_tick[ev.index] = s.tick
    local value = score.award(s.stats, "lane")
    if not m.lanes[ev.index] then
      m.lanes[ev.index] = true
      M.charge(m, 1)
      local count = 0
      for _ in pairs(m.lanes) do count = count + 1 end
      if count == b.lane_count then
        m.lanes = {}
        value = value + score.award(s.stats, "lanes")
        M.charge(m, 2)
        announce(m, "ALL LANES! +500")
      end
    end
    return value
  elseif ev.kind == "ramp" and ev.at == "exit" and ev.complete then
    m.rides = m.rides + 1
    m.combo = M.COMBO_TIME
    M.charge(m, 3)
    announce(m, "SKYWAY! PASS FOR COMBO")
    return score.award(s.stats, "ramp")
  elseif ev.kind == "tube" then
    local value = 0
    if m.charge >= M.GOAL then
      m.charge = 0
      m.jackpots = m.jackpots + 1
      value = score.award(s.stats, "jackpot", math.min(5, m.jackpots))
      announce(m, "RELAY JACKPOT!")
    end
    if m.combo > 0 then
      value = value + score.award(s.stats, "combo")
      announce(m, "SKYWAY PASS COMBO!")
    end
    if value > 0 then
      s.shot_notice, s.shot_notice_time = m.notice, 3
    end
    m.combo = 0
    return value
  end
  return 0
end

return M
