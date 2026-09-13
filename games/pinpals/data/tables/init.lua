--- Loads and validates the board set. Both the game and the tests come through
--- here, so a malformed board fails identically in both (§5.3).
---
--- Loading is re-entrant: `try_load` drops the `require` cache for every board
--- file before reading it, so calling it again picks up an edit on disk. That
--- is what makes app/hotreload.lua possible, and it is the only reason this
--- module knows the module names rather than just requiring them inline.

local validate = require("core.validate")
local curve    = require("core.curve")
local ramp     = require("core.ramp")

local M = {}

--- Board id -> module name. The one place that mapping exists.
M.MODULES = { a = "data.tables.board_a", b = "data.tables.board_b" }

--- The files behind the board set, for anything that wants to watch them.
---@return string[] paths relative to the game source directory
function M.sources()
  local out = {}
  for _, mod in pairs(M.MODULES) do
    out[#out+1] = (mod:gsub("%.", "/")) .. ".lua"
  end
  table.sort(out)
  return out
end

--- Load the board set without raising. A syntax error in a board file and a
--- board that validates badly come back the same way: as text, with the old
--- board set still standing in the caller.
---
--- The cache is dropped *before* each read rather than after, so a file that
--- fails to compile leaves nothing half-loaded behind for the next call to
--- find and trust.
---@return table<string, table>|nil boards, string[] errors
function M.try_load()
  local boards, errs = {}, {}
  for id, mod in pairs(M.MODULES) do
    package.loaded[mod] = nil
    local ok, res = pcall(require, mod)
    if ok and type(res) == "table" then
      -- Curve nodes are expanded into plain polylines here, before anything
      -- else sees the board: validation, the geometry gate, sim/ and app/ all
      -- read the flat lists they always did, and none of them has to know
      -- what an arc is. The authored form stays on `walls[i].spec` for the
      -- coordinate overlay.
      local cok, cerrs = curve.expand_board(res)
      if cok then
        boards[id] = res
      else
        package.loaded[mod] = nil
        for _, msg in ipairs(cerrs) do errs[#errs+1] = ("board %s: %s"):format(id, msg) end
      end
    else
      package.loaded[mod] = nil
      errs[#errs+1] = ("board %s: %s"):format(id, tostring(res))
    end
  end
  if #errs > 0 then return nil, errs end

  local ok, verrs = validate.set(boards)
  if not ok then return nil, verrs end

  -- Rails, arclengths and height profiles, derived once now that the authored
  -- fields are known to be sane. Everything downstream reads `ramp.geom` and
  -- none of it recomputes -- three layers deriving the same rail is three
  -- chances for the picture to disagree with the physics.
  for _, b in pairs(boards) do ramp.prepare(b) end
  return boards, {}
end

--- @return table<string, table> boards keyed by id
function M.load()
  local boards, errs = M.try_load()
  if not boards then
    error("invalid board data:\n  " .. table.concat(errs, "\n  "), 2)
  end
  return boards
end

return M
