--- §5.3 Board data validator.
--- Board layouts are declarative data. Both the game and the tests load the
--- same definitions, so a bad table must fail loudly and early rather than as
--- a nil index somewhere inside sim/.
--- Pure Lua. No love.* here.

local C = require("core.constants")

local M = {}

local function isnum(v) return type(v) == "number" and v == v end

local function vec(errs, where, v)
  if type(v) ~= "table" or not isnum(v.x) or not isnum(v.y) then
    errs[#errs + 1] = where .. ": expected {x=number, y=number}"
    return false
  end
  return true
end

---@param b table board definition
---@return boolean ok, string[] errors
function M.board(b)
  local e = {}
  if type(b) ~= "table" then return false, { "board: not a table" } end

  if b.id ~= "a" and b.id ~= "b" then e[#e+1] = "id: must be 'a' or 'b'" end
  if type(b.name) ~= "string" then e[#e+1] = "name: must be a string" end

  if type(b.size) ~= "table" or not isnum(b.size.w) or not isnum(b.size.h) then
    e[#e+1] = "size: expected {w=number, h=number}"
  end

  -- Walls are polylines: flat lists of x,y pairs, at least two points.
  if type(b.walls) ~= "table" or #b.walls == 0 then
    e[#e+1] = "walls: expected a non-empty list of polylines"
  else
    for i, poly in ipairs(b.walls) do
      if type(poly) ~= "table" or #poly < 4 or #poly % 2 ~= 0 then
        e[#e+1] = ("walls[%d]: expected an even list of >=4 coordinates"):format(i)
      end
    end
  end

  for i, bump in ipairs(b.bumpers or {}) do
    if not (isnum(bump.x) and isnum(bump.y) and isnum(bump.r)) then
      e[#e+1] = ("bumpers[%d]: expected x, y, r"):format(i)
    end
  end

  for i, lane in ipairs(b.rollovers or {}) do
    local valid = isnum(lane.x) and isnum(lane.y) and isnum(lane.w) and isnum(lane.h)
    if not valid or lane.w <= 0 or lane.h <= 0 or type(lane.label) ~= "string" then
      e[#e+1] = ("rollovers[%d]: expected x, y, positive w/h and label"):format(i)
    elseif type(b.size) == "table" and isnum(b.size.w) and isnum(b.size.h) then
      if lane.x - lane.w / 2 < 0 or lane.x + lane.w / 2 > b.size.w
         or lane.y - lane.h / 2 < 0 or lane.y + lane.h / 2 > b.size.h then
        e[#e+1] = ("rollovers[%d]: outside playfield"):format(i)
      end
    end
  end

  -- Slingshots: three points, and a kick that actually kicks. A slingshot
  -- with restitution <= 1 is a wall shaped like a slingshot, which is the
  -- kind of thing that reads fine on screen and silently does nothing.
  for i, sl in ipairs(b.slingshots or {}) do
    local at = ("slingshots[%d]"):format(i)
    if type(sl.p) ~= "table" or #sl.p ~= 6 then
      e[#e+1] = at .. ".p: expected six numbers, three points of a triangle"
    else
      for k = 1, 6 do
        if not isnum(sl.p[k]) then e[#e+1] = at .. ".p: contains a non-number" break end
      end
      -- Collinear points make a zero-area polygon, which Box2D rejects at
      -- fixture construction with a message nobody can trace back to here.
      local ax, ay, bx, by, cx, cy = sl.p[1], sl.p[2], sl.p[3], sl.p[4], sl.p[5], sl.p[6]
      if isnum(ax) and isnum(cy) then
        local area = math.abs((bx-ax)*(cy-ay) - (by-ay)*(cx-ax)) / 2
        if area < 100 then
          e[#e+1] = at .. (": the three points are nearly collinear (area %.0f)"):format(area)
        end
      end
    end
    if sl.kick ~= nil and not isnum(sl.kick) then
      e[#e+1] = at .. ".kick: expected a number"
    elseif (sl.kick or 1.35) <= 1.0 then
      e[#e+1] = at .. ".kick: must exceed 1.0 or it is a wall, not a slingshot"
    end
  end

  for i, t in ipairs(b.targets or {}) do
    if not (isnum(t.x) and isnum(t.y) and isnum(t.w) and isnum(t.h)) then
      e[#e+1] = ("targets[%d]: expected x, y, w, h"):format(i)
    end
    if t.angle ~= nil and not isnum(t.angle) then
      e[#e+1] = ("targets[%d].angle: expected a number"):format(i)
    end
    -- Every target belongs to a bank; a lone target has a bank of one. That
    -- keeps the completion rule in core/ from needing a special case, and it
    -- means a typo'd bank name shows up here as a bank that never completes
    -- rather than as a mechanic that silently does nothing.
    if type(t.bank) ~= "string" or t.bank == "" then
      e[#e+1] = ("targets[%d].bank: expected a non-empty string"):format(i)
    end
  end

  -- §7 cross-board wiring. Validated here because a typo'd board id or meter
  -- name would otherwise be a mechanic that silently never fires -- the worst
  -- possible failure for something the player is supposed to be building
  -- toward across two boards.
  for i, l in ipairs(b.links or {}) do
    if type(l.when) ~= "string" then
      e[#e+1] = ("links[%d].when: expected a string"):format(i)
    end
    local effect = l.charges or l.lights
    if not effect then
      e[#e+1] = ("links[%d]: expected `charges` or `lights`"):format(i)
    elseif type(effect.board) ~= "string" then
      e[#e+1] = ("links[%d]: effect needs a target board id"):format(i)
    end
  end

  -- Exactly one left and one right flipper.
  local sides = {}
  if type(b.flippers) ~= "table" or #b.flippers ~= 2 then
    e[#e+1] = "flippers: expected exactly 2"
  else
    for i, f in ipairs(b.flippers) do
      if f.side ~= "left" and f.side ~= "right" then
        e[#e+1] = ("flippers[%d].side: expected 'left' or 'right'"):format(i)
      elseif sides[f.side] then
        e[#e+1] = ("flippers[%d]: duplicate %s flipper"):format(i, f.side)
      else
        sides[f.side] = true
      end
      if not (isnum(f.x) and isnum(f.y)) then
        e[#e+1] = ("flippers[%d]: expected x, y"):format(i)
      end
    end
  end

  -- §6.1: every device must be a persistent state with a real travel time.
  -- A device that snaps is a design bug, so it is a validation error.
  local seen, kinds = {}, {}
  if type(b.devices) ~= "table" or #b.devices < 1 then
    e[#e+1] = "devices: expects at least one device"
  end
  for i, d in ipairs(b.devices or {}) do
    local at = ("devices[%d]"):format(i)
    if type(d.id) ~= "string" then
      e[#e+1] = at .. ".id: must be a string"
    elseif seen[d.id] then
      e[#e+1] = at .. ": duplicate id " .. d.id
    else
      seen[d.id] = true
    end
    kinds[d.kind or "?"] = true
    if not isnum(d.travel) or d.travel < 0.15 then
      e[#e+1] = at .. ".travel: must be >= 0.15s (design.md §6.1: states, not impulses)"
    end
    if type(d.tradeoff) ~= "string" or #d.tradeoff == 0 then
      e[#e+1] = at .. ".tradeoff: must state what this device gives up (§6.2)"
    end
    if d.kind == "gate" then
      vec(e, at .. ".pivot", d.pivot)
      if not isnum(d.length) then e[#e+1] = at .. ".length: expected number" end
      if not (isnum(d.closed) and isnum(d.open)) then
        e[#e+1] = at .. ": expected closed/open angles in radians"
      elseif math.abs(d.open - d.closed) < 0.2 then
        e[#e+1] = at .. ": open and closed angles are too close to tell apart"
      end
    elseif d.kind == "paddle" then
      vec(e, at .. ".down", d.down)
      vec(e, at .. ".up", d.up)
      if not (isnum(d.w) and isnum(d.h)) then e[#e+1] = at .. ": expected w, h" end
    else
      e[#e+1] = at .. ".kind: expected 'gate' or 'paddle'"
    end
  end
  if b.devices and not kinds.paddle then
    e[#e+1] = "devices: expects a paddle"
  end

  -- §6.2 The outlane guards. Exactly two, one per side, and a kick that
  -- actually kicks -- the same rule slingshots get, for the same reason: a
  -- barrier with restitution <= 1 is a wall shaped like a bumper, which reads
  -- fine on screen and silently hands the ball back to the drain it just
  -- saved it from.
  if b.guards ~= nil then
    local g = b.guards
    if type(g) ~= "table" then
      e[#e+1] = "guards: expected a table"
    else
      if g.start ~= "left" and g.start ~= "right" then
        e[#e+1] = "guards.start: expected 'left' or 'right'"
      end
      if g.kick ~= nil and not isnum(g.kick) then
        e[#e+1] = "guards.kick: expected a number"
      elseif (g.kick or 1.30) <= 1.0 then
        e[#e+1] = "guards.kick: must exceed 1.0 or it is a wall, not a bumper"
      end
      if #g ~= 2 then
        e[#e+1] = "guards: expected exactly 2, one per side"
      end
      local gsides = {}
      for i, gd in ipairs(g) do
        local at = ("guards[%d]"):format(i)
        if gd.side ~= "left" and gd.side ~= "right" then
          e[#e+1] = at .. ".side: expected 'left' or 'right'"
        elseif gsides[gd.side] then
          e[#e+1] = at .. ": duplicate " .. gd.side .. " guard"
        else
          gsides[gd.side] = true
        end
        vec(e, at .. ".up", gd.up)
        vec(e, at .. ".down", gd.down)
        if not (isnum(gd.w) and isnum(gd.h)) then e[#e+1] = at .. ": expected w, h" end
        if gd.angle ~= nil and not isnum(gd.angle) then
          e[#e+1] = at .. ".angle: expected a number"
        end
      end
    end
  end

  -- Elevated ramps (core/ramp.lua). Every field here is load-bearing in a way
  -- that is invisible on screen until a ball is on one, which is why they are
  -- checked rather than trusted.
  local ramp_ids = {}
  for i, r in ipairs(b.ramps or {}) do
    local at = ("ramps[%d]"):format(i)
    if type(r) ~= "table" then
      e[#e+1] = at .. ": expected a table"
    else
      if type(r.id) ~= "string" or r.id == "" then
        e[#e+1] = at .. ".id: expected a non-empty string"
      elseif ramp_ids[r.id] then
        e[#e+1] = at .. ": duplicate id " .. r.id
      else
        ramp_ids[r.id] = true
      end

      -- The path arrives here already expanded by core/curve.lua, so it is a
      -- flat list whatever it looked like in the file.
      local len = 0
      if type(r.path) ~= "table" or #r.path < 4 or #r.path % 2 ~= 0 then
        e[#e+1] = at .. ".path: expected an even list of >=4 coordinates"
      else
        for k = 3, #r.path, 2 do
          len = len + math.sqrt((r.path[k] - r.path[k-2])^2 + (r.path[k+1] - r.path[k-1])^2)
        end
        if len < C.RAMP_MOUTH * 3 then
          e[#e+1] = (at .. ".path: %.0fpx long, which is barely more than its own two mouths")
            :format(len)
        end
      end

      -- A lane the ball cannot travel without scraping both rails is not a
      -- ramp, it is a wedge that happens to be elevated.
      local ball_d = C.BALL_RADIUS * 2
      if not isnum(r.width) then
        e[#e+1] = at .. ".width: expected a number"
      elseif r.width < ball_d * 1.5 then
        e[#e+1] = (at .. ".width: %.1fpx leaves no room beside a %.1fpx ball")
          :format(r.width, ball_d)
      end
      if not isnum(r.height) or r.height <= 0 then
        e[#e+1] = at .. ".height: expected a height above the playfield"
      end

      -- The slopes are the ramp's difficulty, stated as the steepest gradient
      -- at each end rather than as a length, because that is the number that
      -- decides whether a given shot makes it.
      for _, which in ipairs({ "entry_slope", "exit_slope" }) do
        local v = r[which]
        if not isnum(v) or v <= 0 then
          e[#e+1] = ("%s.%s: expected a positive gradient"):format(at, which)
        elseif v > C.RAMP_MAX_SLOPE then
          e[#e+1] = ("%s.%s: %.2f is steeper than %.2f; no shot on either board pays for that")
            :format(at, which, v, C.RAMP_MAX_SLOPE)
        end
      end

      -- Climb and descent have to fit, with a crown between them. Without
      -- this the ramp never reaches the height it claims, and everything
      -- drawn from that height quietly disagrees with everything simulated.
      if isnum(r.height) and isnum(r.entry_slope) and isnum(r.exit_slope)
         and r.entry_slope > 0 and r.exit_slope > 0 and len > 0 then
        local rise = 1.5 * r.height / r.entry_slope
        local fall = 1.5 * r.height / r.exit_slope
        if rise + fall > len then
          e[#e+1] = (at .. ": climbing %.0fpx and descending %.0fpx needs %.0fpx of ramp, but it is %.0fpx long")
            :format(rise, fall, rise + fall, len)
        end
      end

      if r.enter ~= nil and r.enter ~= "both" and r.enter ~= "start" and r.enter ~= "end" then
        e[#e+1] = at .. ".enter: expected 'both', 'start' or 'end'"
      end
    end
  end

  -- The link (§5). One tube out, one arrival point in.
  if type(b.tube) ~= "table" then
    e[#e+1] = "tube: missing"
  else
    vec(e, "tube.mouth", b.tube.mouth)
    if not isnum(b.tube.mouth and b.tube.mouth.r) then
      e[#e+1] = "tube.mouth.r: expected number"
    end
    if b.tube.to ~= "a" and b.tube.to ~= "b" then
      e[#e+1] = "tube.to: expected 'a' or 'b'"
    elseif b.tube.to == b.id then
      e[#e+1] = "tube.to: a board may not pass to itself"
    end
  end

  if vec(e, "entry", b.entry) then
    -- vec() appends its own error for a bad shape, so the only thing left
    -- to check here is that a well-formed direction is not the zero vector.
    if vec(e, "entry.dir", b.entry.dir)
       and b.entry.dir.x == 0 and b.entry.dir.y == 0 then
      e[#e+1] = "entry.dir: must be a non-zero direction"
    end
  end
  if vec(e, "serve", b.serve) then vec(e, "serve.dir", b.serve.dir) end

  if not isnum(b.drain_y) then e[#e+1] = "drain_y: expected number" end

  -- Everything must sit inside the playfield -- except a ramp, which is
  -- allowed to hang off the edge and is deliberately absent below. A ramp is
  -- above the playfield rather than on it, so the board's rectangle is not
  -- its boundary; app/render.lua widens its scissor to whatever they cover.
  if type(b.size) == "table" and isnum(b.size.w) and isnum(b.size.h) then
    local function inside(where, x, y)
      if isnum(x) and isnum(y) and (x < 0 or y < 0 or x > b.size.w or y > b.size.h) then
        e[#e+1] = ("%s: (%g, %g) is outside the playfield"):format(where, x, y)
      end
    end
    for _, f in ipairs(b.flippers or {}) do inside("flipper", f.x, f.y) end
    for _, bump in ipairs(b.bumpers or {}) do inside("bumper", bump.x, bump.y) end
    for i, sl in ipairs(b.slingshots or {}) do
      if type(sl.p) == "table" and #sl.p == 6 then
        for k = 1, 5, 2 do inside("slingshot " .. i, sl.p[k], sl.p[k+1]) end
      end
    end
    for i, t in ipairs(b.targets or {}) do inside("target " .. i, t.x, t.y) end
    if b.tube and b.tube.mouth then inside("tube.mouth", b.tube.mouth.x, b.tube.mouth.y) end
    if b.entry then inside("entry", b.entry.x, b.entry.y) end
    if b.serve then inside("serve", b.serve.x, b.serve.y) end
  end

  return #e == 0, e
end

--- Link targets, which need the whole board set: a link naming a board that
--- does not exist, a meter no bank will ever cash, or a `lights` target the
--- destination board has none of, is a dead mechanic.
---@param boards table<string, table>
---@param errs string[]
local function check_links(boards, errs)
  for id, b in pairs(boards) do
    for i, l in ipairs(b.links or {}) do
      local effect = l.charges or l.lights
      if effect and type(effect.board) == "string" then
        local dest = boards[effect.board]
        if not dest then
          errs[#errs+1] = ("board %s links[%d]: no such board '%s'")
            :format(id, i, effect.board)
        elseif l.charges then
          -- A meter is cashed by a bank of the same name on the destination.
          local found = false
          for _, t in ipairs(dest.targets or {}) do
            if t.bank == effect.meter then found = true end
          end
          if not found then
            errs[#errs+1] = ("board %s links[%d]: board %s has no '%s' bank to cash the charge")
              :format(id, i, effect.board, tostring(effect.meter))
          end
        elseif l.lights and effect.what == "bumpers" and #(dest.bumpers or {}) == 0 then
          errs[#errs+1] = ("board %s links[%d]: board %s has no bumpers to light")
            :format(id, i, effect.board)
        end
      end
    end
  end
end

--- Validate a full board set and the wiring between them.
---@param boards table<string, table>
---@return boolean ok, string[] errors
function M.set(boards)
  local e = {}
  for _, id in ipairs({ "a", "b" }) do
    local b = boards[id]
    if not b then
      e[#e+1] = "board " .. id .. ": missing"
    else
      local ok, errs = M.board(b)
      if not ok then
        for _, msg in ipairs(errs) do e[#e+1] = "board " .. id .. ": " .. msg end
      end
      if b.id ~= id then e[#e+1] = "board " .. id .. ": id field disagrees with key" end
    end
  end
  -- Each tube must land somewhere real (§5).
  for _, id in ipairs({ "a", "b" }) do
    local b = boards[id]
    if b and b.tube and b.tube.to then
      local dest = boards[b.tube.to]
      if not dest then
        e[#e+1] = ("board %s: tube leads to unknown board %s"):format(id, b.tube.to)
      elseif not dest.entry then
        e[#e+1] = ("board %s: destination board %s has no entry point"):format(id, b.tube.to)
      end
    end
  end
  check_links(boards, e)
  return #e == 0, e
end

return M
