--- What should these two be trying to do right now?
---
--- The cross-board loop (§7.1) works and is invisible. A player sees a score
--- and a multiplier, and nothing that says "charge the vault, pass, cash it,
--- come home to lit bumpers". Pinball has always solved this with a line of
--- text telling you what is lit; §7 asks for the same thing in the specific
--- form of always knowing what you have built up on the board you are not
--- looking at.
---
--- Derived from the `links` in the board data rather than hardcoded, so a new
--- cross-board relationship gets a readout for free and cannot silently
--- become a mechanic nobody is told about.
---
--- Pure Lua. Returns a description; decides nothing.

local mission = require("core.mission")
local C = require("core.constants")

local M = {}

--- The other board. Two boards for now (§3); a ring topology later would
--- make this a lookup rather than a flip.
function M.other(id) return (id == "a") and "b" or "a" end

--- Which board does this one charge, and with what meter?
local function charge_link(board)
  for _, l in ipairs(board.links or {}) do
    if l.charges then return l.charges end
  end
  return nil
end

--- The meter on this board that is holding the most charge.
local function fullest_meter(board)
  local best, level = nil, 0
  for name, v in pairs(board.meters or {}) do
    if v > level then best, level = name, v end
  end
  return best, level
end

--- @class Objective
--- @field text string      what to do, in fewer than about 30 characters
--- @field board string     the board it wants doing on
--- @field urgent boolean   worth shouting about
--- @field here boolean     true when that board is the one being played

--- @param s table match state
--- @param names table<string, string> board id -> display name
--- @return Objective
function M.current(s, names)
  local active = s.active
  local board  = s.boards[active]
  local other  = s.boards[M.other(active)]
  local function named(id) return (names and names[id]) or id end

  local m = board.mission
  if m and (m.combo > 0 or m.charge >= mission.GOAL) then
    return { text = m.combo > 0 and "SHOOT PASS - SKYWAY COMBO" or "SHOOT PASS - RELAY JACKPOT",
      board = active, urgent = true, here = true }
  end

  -- 1. A lit board is a timer running down on free money. It outranks
  --    everything because it expires and nothing else here does.
  for _, id in ipairs({ active, M.other(active) }) do
    local b = s.boards[id]
    if (b.lit.bumpers or 0) > 0 then
      return {
        text  = ("BUMPERS LIT x%d  (%d left)"):format(C.LIT_MULT, b.lit.bumpers),
        board = id, urgent = true, here = (id == active),
      }
    end
  end

  -- 2. A charged vault under your feet is the payoff you already worked for.
  local meter, level = fullest_meter(board)
  if meter and level > 0 then
    return {
      text  = ("CLEAR THE %s  x%d"):format(meter:upper(), 1 + level),
      board = active, urgent = level >= C.CHARGE_MAX, here = true,
    }
  end

  -- 3. A charged vault on the OTHER board is a reason to pass.
  local ometer, olevel = fullest_meter(other)
  if ometer and olevel > 0 then
    local full = olevel >= C.CHARGE_MAX
    return {
      text  = full and ("PASS -- %s IS FULL"):format(ometer:upper())
                    or ("PASS TO CLEAR THE %s  x%d"):format(ometer:upper(), 1 + olevel),
      board = M.other(active), urgent = full, here = false,
    }
  end

  -- 4. Nothing built yet: fill the thing this board fills.
  local link = charge_link(board)
  if link then
    return {
      text  = ("CHARGE THE %s ON %s"):format(
                tostring(link.meter):upper(), named(link.board):upper()),
      board = active, urgent = false, here = true,
    }
  end

  -- 5. A board that charges nothing has its own content to hit.
  local ometer2 = select(1, fullest_meter(board))
  return {
    text  = ometer2 and ("LIGHT THE %s"):format(ometer2:upper()) or "PASS",
    board = active, urgent = false, here = true,
  }
end

return M
