--- §9 Scoring. The multiplier lives on passing, not on shots.
---
--- The whole model is here and it is deliberately tiny: heat is a function of
--- one number (crossings since the last drain), and everything else is that
--- heat times a base value. A rally is worth more the longer it runs, and a
--- drain takes all of it away -- which is the risk curve §9 asks for, produced
--- by nothing but the two players choosing to keep passing.
---
--- Pure Lua. No love.*, no physics, no randomness: every number below is
--- reproducible in the bare interpreter.

local C = require("core.constants")

local M = {}

--- The multiplier, earned only by crossing the tube. It IS the crossing
--- count: x7 means "we have passed seven times without dropping it", which is
--- a sentence either player can say out loud mid-rally. Floored at x1 so a
--- fresh ball still scores, capped so a long rally has a ceiling and the
--- readout stays two digits.
---
--- Written first as `1 + relay`, which had the first pass of every life
--- already paying x2 and made the multiplier a number with no meaning of its
--- own. Caught by the scattered-versus-together test below.
---@param relay integer crossings since the last drain
---@return integer
function M.heat(relay)
  return math.max(1, math.min(C.HEAT_MAX, relay or 0))
end

--- §9 "worth more, and moving faster." Separate curve from the score
--- multiplier, and much gentler: the score can escalate wildly without
--- hurting anything, but arrival speed is a difficulty knob and a tunneling
--- risk, so it moves 5% a crossing and stops at +55%.
---@param relay integer
---@return number multiplier on arrival speed
function M.speed_scale(relay)
  return math.min(C.HEAT_SPEED_MAX, 1 + (relay or 0) * C.HEAT_SPEED_STEP)
end

--- What each thing is worth before the multiplier. The spread is the boards'
--- identities in numbers: a bumper is chaos you did not aim, a target is a
--- shot you meant, and a bank is a sequence you and your partner planned.
local BASE = {
  lane = 75, lanes = 500, ramp = 750, combo = 1500, jackpot = 2500,
  pass   = C.SCORE_PASS,
  bumper = C.SCORE_BUMPER,
  sling  = C.SCORE_SLING,
  guard  = C.SCORE_GUARD,
  target = C.SCORE_TARGET,
  bank   = C.SCORE_BANK,
}

--- What one scoring event is worth right now.
---@param kind string
---@param relay integer
---@param boost? number cross-board multiplier on top of relay heat (§7)
---@return integer
function M.value(kind, relay, boost)
  local base = BASE[kind]
  if not base then return 0 end
  return math.floor(base * M.heat(relay) * (boost or 1))
end

--- Award an event, and report what it was worth so app/ can float the number
--- where it happened.
---
--- Two totals, because they answer different questions. `score` is the
--- session and only ever grows, so it is a record but not a measurement.
--- `rally` is what the current rally has been worth and dies with it, which
--- makes `best_rally` the number that actually answers §14: how good was the
--- best thing these two players managed together?
---@param stats table
---@param kind string
---@return integer awarded
---@param boost? number
function M.award(stats, kind, boost)
  local v = M.value(kind, stats.relay, boost)
  stats.score       = (stats.score or 0) + v
  stats.rally_score = (stats.rally_score or 0) + v
  if stats.rally_score > (stats.best_rally_score or 0) then
    stats.best_rally_score = stats.rally_score
  end
  return v
end

--- A drain takes the rally and everything it was worth. The session total
--- keeps it; the rally does not.
---@param stats table
function M.end_rally(stats)
  stats.rally_score = 0
end

return M
