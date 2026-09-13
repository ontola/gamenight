--- Watch the board files and say when one changes. app/ layer, because
--- love.filesystem lives here (app/record.lua says the same).
---
--- It watches CONTENT, not mtime. love.filesystem's modtime is whole seconds,
--- and two saves inside one second is exactly what editing a board looks like
--- -- nudge a coordinate, look, nudge it back. A hash of the bytes cannot miss
--- that, and costs a few tens of KB a second to read.
---
--- There is deliberately no debounce. An editor caught mid-write hands back a
--- half file, which fails to compile, which the caller reports and survives;
--- the complete write is another content change a quarter-second later and
--- reloads cleanly. Waiting for the file to settle would buy nothing that the
--- error path does not already handle.

local M = {}

local INTERVAL = 0.25

local watched = {}      -- { { path = ..., stamp = ... }, ... }
local timer   = 0
local on      = false

--- A cheap identity for a file's current contents. nil when the file is gone,
--- which is itself a change worth reporting.
local function stamp(path)
  local data = love.filesystem.read(path)
  if not data then return nil end
  return #data .. ":" .. love.data.hash("md5", data)
end

---@param paths string[] files to watch, relative to the source directory
function M.watch(paths)
  watched, timer, on = {}, 0, true
  for _, p in ipairs(paths) do
    watched[#watched+1] = { path = p, stamp = stamp(p) }
  end
  return watched
end

function M.enabled() return on end

function M.stop() on, watched = false, {} end

--- Poll at most every INTERVAL seconds.
---@param dt number
---@return string|nil path of a file that changed, nil if nothing did
function M.poll(dt)
  if not on then return nil end
  timer = timer + dt
  if timer < INTERVAL then return nil end
  timer = 0

  -- Every watched file is re-stamped even after a hit, so saving two boards
  -- at once is one reload rather than two, and the second file's change is
  -- not still pending on the next poll.
  local hit
  for _, w in ipairs(watched) do
    local s = stamp(w.path)
    if s ~= w.stamp then
      w.stamp = s
      hit = hit or w.path
    end
  end
  return hit
end

--- Forget what the files looked like, so the next poll reports no change.
--- Called after a reload the watcher did not trigger (F5), so a manual reload
--- is not immediately followed by an automatic one.
function M.resync()
  for _, w in ipairs(watched) do w.stamp = stamp(w.path) end
end

return M
