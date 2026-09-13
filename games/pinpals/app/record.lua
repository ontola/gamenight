--- Playtest capture. §5.1 notes that a tick-stamped intent stream makes whole
--- matches recordable "which is worth the layer on its own for debugging
--- pinball physics" -- this is that, plus the summary that turns an evening
--- of play into numbers somebody can act on.
---
--- The prototype exists to answer one question no headless probe can reach:
--- does the rally feel good? A human answers that with an impression. This
--- makes the same session also produce a measurement, so "it felt bad around
--- the third pass" can be checked against what actually happened.
---
--- app/ layer: love.filesystem lives here. Everything no-ops if recording is
--- off, so --test and --shot never touch the disk.

local C = require("core.constants")

local M = {}

local session = nil

---------------------------------------------------------------------------
-- Capture
---------------------------------------------------------------------------

--- @param boards table<string, table>
--- @param seed number|nil the match's seed. The intent stream alone stopped being
---   enough to reproduce a session the moment serves gained their jitter, so
---   the seed is written down with it.
function M.start(boards, seed)
  session = {
    started  = os.time(),
    seed     = seed,
    lines    = {},
    rallies  = {},          -- length of every completed rally, in crossings
    drains_by_board = { a = 0, b = 0 },
    -- Duty cycle: how much of the time each device was commanded on, over
    -- the time its board was the active one. Pillar 1 says nobody waits --
    -- an operator sitting on 0% is the measurable form of "waiting".
    duty     = {},
    active_ticks = { a = 0, b = 0 },
    ticks    = 0,
    prev_relay = 0,
    prev_phase = nil,
    -- Runs, plural. Pressing R builds a whole new Match with zeroed stats
    -- while this session keeps accumulating, so a summary that read the live
    -- match would report the last few seconds against rallies from before
    -- the restart. Measured: 24,800 points of play reported as "score 250,
    -- passes 0" next to five completed rallies. Each run is banked here as
    -- it ends.
    runs     = {},
  }
  for id in pairs(boards) do
    session.duty[id] = { gate = 0, post = 0 }
  end
  return true
end

function M.active() return session ~= nil end

local function line(fmt, ...)
  if not session then return end
  local s = session.lines
  s[#s+1] = fmt:format(...)
end

--- Every intent, tick-stamped. This is the part that makes a session
--- replayable (§5.1): intents plus the board data reproduce the match.
---@param it Intent
function M.intent(it)
  if not session then return end
  line("I %d %d %s %d", it.tick, it.player, it.action, it.pressed and 1 or 0)
end

--- One frame of match state, plus the events that happened in it.
---@param match table
---@param events table[]
function M.update(match, events)
  if not session then return end
  local s = match.state
  session.ticks = session.ticks + 1

  local active = s.active
  session.active_ticks[active] = (session.active_ticks[active] or 0) + 1
  local ab = s.boards[active]
  if ab then
    for id, d in pairs(ab.devices) do
      if d.commanded then
        session.duty[active][id] = (session.duty[active][id] or 0) + 1
      end
    end
    -- §6.2 The outlane guard is a state like the others, so it earns a duty
    -- line too -- and unlike the gate and the post it is never OFF, so the
    -- two numbers are a split of the same time and read as a preference.
    if ab.guard then
      local k = "guard " .. ab.guard
      session.duty[active][k] = (session.duty[active][k] or 0) + 1
    end
  end

  for _, ev in ipairs(events) do
    if ev.kind == "tube" then
      line("E %d pass %s->%s speed=%.0f relay=%d", s.tick, ev.board,
           ev.board == "a" and "b" or "a", ev.speed, s.stats.relay)
    elseif ev.kind == "drain" then
      -- Capture the rally that just ended and what guarded it, because "we
      -- lost it on the fourth pass with the post down" is the sentence a
      -- playtest note wants to be able to make.
      local guarded = ab and ab.devices.post and ab.devices.post.commanded
      session.rallies[#session.rallies+1] = session.prev_relay
      session.drains_by_board[ev.board] = (session.drains_by_board[ev.board] or 0) + 1
      line("E %d drain %s after=%d post=%s guard=%s score=%d", s.tick, ev.board,
           session.prev_relay, guarded and "up" or "down",
           (ab and ab.guard) or "-", s.stats.score)
    elseif ev.kind == "target" or ev.kind == "bumper" then
      line("E %d %s %s", s.tick, ev.kind, ev.board)
    end
  end

  if s.phase == "play" then session.prev_relay = s.stats.relay end
  session.prev_phase = s.phase
end

--- Bank a finished run. Called when the player restarts, so the numbers that
--- run produced are not lost with the Match that produced them.
---@param match table the match being retired
function M.restart(match)
  if not session then return end
  local st = match.state.stats
  session.runs[#session.runs+1] = {
    score = st.score, passes = st.passes, drains = st.drains,
    rescues = st.rescues, best_rally_score = st.best_rally_score,
    best_relay = st.best_relay,
  }
  line("E %d restart  (run %d ended on %d points)",
       match.state.tick, #session.runs, st.score)
end

---------------------------------------------------------------------------
-- Summary
---------------------------------------------------------------------------

--- Session totals: every banked run plus the one still going.
---@param runs table[] runs already retired by a restart
---@param live table the current match's stats
local function totals(runs, live)
  local t = { score = 0, passes = 0, drains = 0, rescues = 0,
              best_rally_score = 0, best_relay = 0 }
  local all = {}
  for _, r in ipairs(runs) do all[#all+1] = r end
  all[#all+1] = live
  for _, r in ipairs(all) do
    t.score   = t.score   + (r.score   or 0)
    t.passes  = t.passes  + (r.passes  or 0)
    t.drains  = t.drains  + (r.drains  or 0)
    t.rescues = t.rescues + (r.rescues or 0)
    t.best_rally_score = math.max(t.best_rally_score, r.best_rally_score or 0)
    t.best_relay       = math.max(t.best_relay,       r.best_relay or 0)
  end
  return t
end

local function percentile(sorted, p)
  if #sorted == 0 then return 0 end
  return sorted[math.max(1, math.ceil(#sorted * p))]
end

--- The numbers worth reading in the morning, as text.
---@param match table
---@return string
function M.summary(match)
  if not session then return "" end
  local st = totals(session.runs, match.state.stats)
  local mins = session.ticks * C.FIXED_DT / 60
  local out = {}
  local function put(fmt, ...) out[#out+1] = fmt:format(...) end

  put("pinpals session -- %s", os.date("%Y-%m-%d %H:%M", session.started))
  put("%.1f minutes of play, %d ticks%s", mins, session.ticks,
      (#session.runs > 0) and (", %d runs (restarted %d times)")
        :format(#session.runs + 1, #session.runs) or "")
  put("")
  put("score %d    best single rally was worth %d", st.score, st.best_rally_score)
  put("passes %d (%.1f/min)   drains %d (%.1f/min)   longest rally %d crossings",
      st.passes, st.passes / math.max(0.01, mins),
      st.drains, st.drains / math.max(0.01, mins), st.best_relay)

  local r = {}
  for _, v in ipairs(session.rallies) do r[#r+1] = v end
  table.sort(r)
  if #r > 0 then
    local sum = 0
    for _, v in ipairs(r) do sum = sum + v end
    put("")
    put("rally length, %d completed rallies:", #r)
    put("  mean %.1f   median %d   p90 %d   max %d",
        sum / #r, percentile(r, 0.5), percentile(r, 0.9), r[#r])
    -- The distribution is the answer to "does the rally feel good?" in
    -- numbers: a pile of zeroes means the ball dies before the game starts.
    local zero = 0
    for _, v in ipairs(r) do if v == 0 then zero = zero + 1 end end
    put("  %d of %d rallies (%.0f%%) ended without a single pass",
        zero, #r, 100 * zero / #r)
  end

  put("")
  put("drains by board: Foundry %d, Glasshouse %d",
      session.drains_by_board.a or 0, session.drains_by_board.b or 0)

  put("")
  put("operator duty cycle (share of that board's active time):")
  for id, d in pairs(session.duty) do
    local at = math.max(1, session.active_ticks[id] or 1)
    put("  board %s: gate %3.0f%%   post %3.0f%%",
        id, 100 * (d.gate or 0) / at, 100 * (d.post or 0) / at)
  end
  put("  (pillar 1: an operator near 0%% is a player who was waiting)")

  return table.concat(out, "\n")
end

--- Write the log and return the path, or nil if there was nothing to write
--- or nowhere to write it.
---
--- Ends the session either way. The disk is the only part of this module that
--- needs LÖVE, so without it this still closes the session cleanly rather
--- than erroring -- which is what lets the whole thing be tested in the bare
--- interpreter, and what keeps the module's "no-ops if recording is off"
--- promise honest rather than aspirational.
---@param match table
---@return string|nil
function M.finish(match)
  if not session then return nil end
  local body = M.summary(match)
    .. ("\n\n--- events and intents (seed %s) ---\n"):format(session.seed or "?")
    .. table.concat(session.lines, "\n") .. "\n"
  local name = os.date("session-%Y%m%d-%H%M%S.log", session.started)
  session = nil
  if not (love and love.filesystem) then return nil end
  if not love.filesystem.write(name, body) then return nil end
  return love.filesystem.getSaveDirectory() .. "/" .. name
end

return M
