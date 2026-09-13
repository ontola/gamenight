--- Elevated ramps: the geometry of a lane that runs ABOVE the playfield.
---
--- Everything else on the board lives on one plane, and CLAUDE.md's fifth
--- hard-won lesson -- "the ball falls straight down, so nothing may sit under
--- anything else" -- is a consequence of that. A ramp is the exception the
--- rule was waiting for: it climbs off the playfield, crosses over whatever
--- is there, and comes back down, so the space underneath it stays live.
---
--- The physics is real, not scripted. sim/ puts the ball and the ramp rails
--- on separate Box2D collision categories and swaps which one the ball sees;
--- this module owns the arithmetic both layers have to agree on -- how high
--- the ramp is at a given point, how steeply it is climbing there, and where
--- along it the ball currently is. Three copies of that would be three
--- chances for the picture, the physics and the checks to disagree, which is
--- the same reason M.rect_corners lives in core/geometry.lua.
---
--- The height profile is a smoothstep rather than a straight incline, and
--- that is what `entry_slope` means: the STEEPEST gradient on the way in, at
--- the middle of the climb. The ramp therefore leaves the playfield and meets
--- its own crown tangentially, with no lip at either end for the ball to trip
--- over and no step change in the force fighting it.
---
--- Pure Lua. No love.* here.

local C = require("core.constants")

local M = {}

local function smoothstep(u)
  if u <= 0 then return 0 end
  if u >= 1 then return 1 end
  return u * u * (3 - 2 * u)
end

--- d/du of the above. Peaks at 1.5 in the middle, which is where
--- `entry_slope` is defined and why `rise` below carries that 1.5.
local function dsmoothstep(u)
  if u <= 0 or u >= 1 then return 0 end
  return 6 * u * (1 - u)
end

---------------------------------------------------------------------------
-- Derived geometry
---------------------------------------------------------------------------

--- Offset one side of a polyline by `d`, mitring at the vertices.
---
--- The miter is clamped, because a path that turns hard enough sends an
--- unclamped one off to infinity. A ramp that turns that hard is a defect
--- rather than a shape to be drawn faithfully, and core/geometry.lua reports
--- it -- this only stops the drawing from exploding first.
local function offset(path, d)
  local n = #path / 2
  local out = {}
  local function pt(i) return path[i*2-1], path[i*2] end

  -- Segment i runs from vertex i to vertex i+1, so the first vertex has no
  -- segment before it and the last none after: both ends take the one normal
  -- they have.
  local function seg_normal(i)
    if i < 1 or i >= n then return nil end
    local x1, y1 = pt(i)
    local x2, y2 = pt(i + 1)
    local dx, dy = x2 - x1, y2 - y1
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1e-9 then return nil end
    return -dy / l, dx / l
  end

  for i = 1, n do
    local px, py = pt(i)
    local n1x, n1y = seg_normal(i - 1)
    local n2x, n2y = seg_normal(i)
    local nx, ny
    if n1x and n2x then
      -- (n1+n2)/(1+n1.n2) is the miter vector: it lies on the bisector and is
      -- exactly 1/cos(half the turn) long, which is what keeps the offset
      -- rail parallel to the centreline through a corner instead of pinching
      -- in on the outside of it.
      local denom = 1 + (n1x * n2x + n1y * n2y)
      if denom < 1e-6 then
        nx, ny = n2x, n2y                      -- doubled back; take one side
      else
        nx, ny = (n1x + n2x) / denom, (n1y + n2y) / denom
        local m = math.sqrt(nx * nx + ny * ny)
        if m > C.RAMP_MITER_MAX then
          nx, ny = nx / m * C.RAMP_MITER_MAX, ny / m * C.RAMP_MITER_MAX
        end
      end
    else
      nx, ny = n1x or n2x, n1y or n2y
    end
    out[#out+1] = px + nx * d
    out[#out+1] = py + ny * d
  end
  return out
end

--- How fast the ball has to enter one end to crest the ramp.
---
--- This is the whole difference between a ramp and a trap, and it was
--- measured into being. A gate that counted only the climb -- the height
--- against C.RAMP_CLIMB_G -- let shots onto Foundry's skyway at 609px/s that
--- needed 944, so they climbed a little, rolled back out of the mouth they
--- came in through, and went down the board. The mouths sit in the orbits, so
--- that turned both orbits into dead ends: the east bumper went from 40 hits
--- in eight minutes of play to exactly zero, and the sim gate said so.
---
--- So the budget counts BOTH costs at every point on the ramp and takes the
--- worst: the height climbed against C.RAMP_CLIMB_G, and the distance
--- travelled up-board against ordinary gravity. A shot that clears this bar
--- mostly completes the ramp; one that does not is never let on, and carries
--- on up the lane exactly as it did before the ramp existed.
---
--- The budget is frictionless where the ball is not, so it under-states what
--- a shot really needs -- and a headroom multiplier for that was written and
--- then measured away. See the note at C.RAMP_ENTER_SPEED: on the only ramp
--- either board has, every shot that reaches the mouth arrives at half again
--- the gate, so the gate's exact value is invisible and only its existence
--- matters.
---@param g table partially built geometry: path, cum, length, height, rise, fall
---@param which "start"|"end"
---@return number px/s
local function entry_speed(g, which)
  local from = (which == "start") and 0 or g.length
  local _, y0 = M.point_at(g, from)
  local need, steps = 0, math.max(2, math.ceil(g.length / 8))
  for i = 0, steps do
    local s = g.length * (i / steps)
    local _, y = M.point_at(g, s)
    need = math.max(need, C.RAMP_CLIMB_G * M.height_at(g, s) + C.GRAVITY_PX * (y0 - y))
  end
  return math.max(C.RAMP_ENTER_SPEED, math.sqrt(2 * need))
end

--- The stretch of ramp a playfield ball can pass underneath.
---
--- Everything outside it is solid: near the feet the lane is inches off the
--- floor, and a ball has to go around rather than under. Solved by walking
--- the profile rather than inverting the smoothstep, because the profile is
--- the min of two of them and the two feet need not be the same shape.
---@return number s0 where the ramp first lifts clear
---@return number s1 where it comes back down; s0 == s1 means nothing is open
local function clear_span(g)
  local step = math.max(1, g.length / 400)
  local s0, s1 = -1, -1
  for s = 0, g.length, step do
    if M.height_at(g, s) >= C.RAMP_CLEARANCE then
      if s0 < 0 then s0 = s end
      s1 = s
    end
  end
  -- A ramp that never lifts a ball's height clear is solid end to end: there
  -- is no span to pass under, and the whole thing is skirt.
  if s0 < 0 then return g.length / 2, g.length / 2 end
  return s0, s1
end

--- The part of a ramp that is solid to a ball on the playfield: one chain
--- around each foot, from the mouth up the outer rail, across the lane, and
--- back down the inner rail to the mouth.
---
--- One chain rather than three pieces, and that is the whole of it. Built as
--- separate rails plus a wall laid across them, the wall's ends land wherever
--- the slant puts them: past the top of one rail, leaving a gap the ball goes
--- through, and short of the other, leaving a notch beside it to sit in. As a
--- single chain the rails end exactly where the wall begins, so the foot is
--- closed on three sides and open only at the mouth, by construction.
---
--- The crossing is slanted, and that is not decoration either. A shot that
--- enters the mouth and does not commit to the climb is inside a channel one
--- ball wider than itself; square, the far end of that channel is somewhere
--- to come to rest, and nothing on a board may quietly hold the ball. Slanted,
--- the ball glances off and is sent back out of the mouth it came in through.
---
--- Which way it slants is chosen too: the OUTER rail is the short one, so the
--- glance carries the ball toward the middle of the playfield rather than
--- into the shell it is standing against.
---@return table polylines each a flat list of playfield x,y pairs
local function skirt_of(g, board_w)
  local out = {}
  local half = g.width / 2

  --- A point on one rail. `side` is +1 for the rail `left` was offset toward.
  --- Interior path vertices come straight out of `left`/`right` so the solid
  --- skirt lies exactly on the rail the ball rides and the renderer draws,
  --- mitred corners included; only a cut between vertices is recomputed.
  local function rail_at(s, side)
    for k = 1, #g.cum do
      if math.abs(g.cum[k] - s) < 1e-6 then
        local rail = (side > 0) and g.left or g.right
        return rail[k*2-1], rail[k*2]
      end
    end
    local x, y, tx, ty = M.point_at(g, s)
    return x + ty * half * side, y - tx * half * side
  end

  local function emit(poly, s, side)
    local x, y = rail_at(s, side)
    poly[#poly+1] = x
    poly[#poly+1] = y
  end

  --- Walk one rail from `from` to `to`, emitting both ends and every path
  --- vertex between them, so a foot on a bend follows the bend. Walks either
  --- direction: the chain goes up one rail and back down the other.
  local function walk(poly, from, to, side)
    emit(poly, from, side)
    local lo, hi = math.min(from, to), math.max(from, to)
    local ks = {}
    for k = 1, #g.cum do
      local c = g.cum[k]
      if (c - lo) > 1e-6 and (hi - c) > 1e-6 then ks[#ks+1] = c end
    end
    if to < from then
      for i = 1, math.floor(#ks / 2) do
        ks[i], ks[#ks+1-i] = ks[#ks+1-i], ks[i]
      end
    end
    for _, c in ipairs(ks) do emit(poly, c, side) end
    emit(poly, to, side)
  end

  --- One foot. `dir` is +1 at the start of the ramp, where the solid part
  --- lies at lower s, and -1 at the end, where it lies at higher s.
  local function foot(at, clear, dir)
    if math.abs(clear - at) < 1e-6 then return end
    -- Whichever rail sits further from the middle of the board is the outer
    -- one, measured at the mouth.
    local mx, _, _, mty = M.point_at(g, at)
    local mid = board_w / 2
    local outer = (math.abs(mx + mty * half - mid) > math.abs(mx - mty * half - mid))
                  and 1 or -1

    -- Up the outer rail, across the lane, back down the inner one. The two
    -- walks meet at the crossing, so it is a corner of the chain rather than
    -- a separate wall that has to be made to line up with anything.
    local poly = {}
    walk(poly, at, clear - C.RAMP_BACKSTOP * dir, outer)
    walk(poly, clear + C.RAMP_BACKSTOP * dir, at, -outer)
    out[#out+1] = poly
  end

  foot(0, g.clear[1], 1)
  foot(g.length, g.clear[2], -1)
  return out
end

--- Everything derived from one ramp's authored fields, computed once.
---
--- Stored on the ramp as `.geom` rather than memoised behind a lookup,
--- because board definitions are immutable once loaded and replaced whole on
--- a reload -- so "once" is unambiguous, and a stale cache is impossible.
---@param r table one `ramps` entry, path already expanded by core/curve
---@return table geom
local function build(r, board_w)
  local path = r.path
  local cum, total = { 0 }, 0
  for i = 3, #path, 2 do
    total = total + math.sqrt((path[i] - path[i-2])^2 + (path[i+1] - path[i-1])^2)
    cum[#cum+1] = total
  end

  local half = r.width / 2
  local g = {
    path   = path,
    cum    = cum,
    length = total,
    height = r.height,
    -- 1.5 because the smoothstep's gradient peaks at 1.5x its average, and
    -- `entry_slope` is defined as that peak.
    rise   = 1.5 * r.height / r.entry_slope,
    fall   = 1.5 * r.height / r.exit_slope,
    width  = r.width,
    left   = offset(path, -half),
    right  = offset(path,  half),
    enter  = r.enter or "both",
  }
  g.enter_speed = { start = entry_speed(g, "start"), ["end"] = entry_speed(g, "end") }
  g.clear = { clear_span(g) }
  g.skirt = skirt_of(g, board_w)
  return g
end

--- Build the derived geometry for every ramp on a board. Called once at load
--- time, after core/validate has said the authored fields are sane.
---@param def table board definition
function M.prepare(def)
  local w = (def.size and def.size.w) or C.BOARD_W
  for _, r in ipairs(def.ramps or {}) do r.geom = build(r, w) end
end

---------------------------------------------------------------------------
-- The profile
---------------------------------------------------------------------------

--- How high the ramp is, `s` pixels along it. Zero at both feet.
---@return number px above the playfield
function M.height_at(g, s)
  if s <= 0 or s >= g.length then return 0 end
  return g.height * math.min(smoothstep(s / g.rise),
                             smoothstep((g.length - s) / g.fall))
end

--- The gradient there: dz/ds, positive while climbing in the +s direction.
---
--- The two branches never overlap, because core/validate.lua rejects a ramp
--- whose climb and descent are together longer than the ramp.
---@return number
function M.slope_at(g, s)
  if s <= 0 or s >= g.length then return 0 end
  if s < g.rise then
    return g.height / g.rise * dsmoothstep(s / g.rise)
  elseif s > g.length - g.fall then
    return -g.height / g.fall * dsmoothstep((g.length - s) / g.fall)
  end
  return 0
end

---------------------------------------------------------------------------
-- Where the ball is
---------------------------------------------------------------------------

--- Project a point onto the ramp's centreline.
---
--- This is how sim/ answers every question it has about a ball on a ramp:
--- how high it is, which way "up the ramp" points from here, and whether it
--- has run off the end -- which is the safety net that keeps a layer switch
--- from ever stranding the ball on a ramp it is no longer standing on.
---@param g table ramp geometry
---@param x number
---@param y number
---@return number s arclength along the centreline
---@return number lateral signed offset, positive toward `geom.right`
---@return number tx unit tangent, pointing along +s
---@return number ty
function M.project(g, x, y)
  local path, cum = g.path, g.cum
  local best, bs, blat, btx, bty = math.huge, 0, 0, 1, 0
  for i = 1, #path - 3, 2 do
    local ax, ay, bx, by = path[i], path[i+1], path[i+2], path[i+3]
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    if l2 > 1e-12 then
      local t = ((x - ax) * dx + (y - ay) * dy) / l2
      -- Not clamped for the end segments: a ball past the mouth has to read
      -- as s < 0 or s > length, which is exactly how sim/ knows it has left.
      local k = (i == 1 or i == #path - 3) and t or math.max(0, math.min(1, t))
      local qx, qy = ax + dx * k, ay + dy * k
      local d = math.sqrt((x - qx)^2 + (y - qy)^2)
      if d < best then
        local l = math.sqrt(l2)
        best = d
        bs   = cum[(i + 1) / 2] + k * l
        btx, bty = dx / l, dy / l
        -- Signed along the right-hand normal (-ty, tx), so a positive lateral
        -- is on the side `geom.right` was offset toward.
        blat = (x - qx) * -bty + (y - qy) * btx
      end
    end
  end
  return bs, blat, btx, bty
end

--- The rectangle a ramp occupies on screen, rails included. Ramps are allowed
--- to hang off the playfield, so app/render.lua has to widen its scissor by
--- this or the overhang is quietly clipped away.
---@return number x0, number y0, number x1, number y1
function M.bounds(g)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, rail in ipairs({ g.left, g.right }) do
    for i = 1, #rail - 1, 2 do
      x0, x1 = math.min(x0, rail[i]),   math.max(x1, rail[i])
      y0, y1 = math.min(y0, rail[i+1]), math.max(y1, rail[i+1])
    end
  end
  return x0, y0, x1, y1
end

--- Board-wide bounds over every ramp, or nil when the board has none.
function M.board_bounds(def)
  local x0, y0, x1, y1
  for _, r in ipairs(def.ramps or {}) do
    local a, b, c, d = M.bounds(r.geom)
    x0 = math.min(x0 or a, a); y0 = math.min(y0 or b, b)
    x1 = math.max(x1 or c, c); y1 = math.max(y1 or d, d)
  end
  if not x0 then return nil end
  return x0, y0, x1, y1
end

--- The stretch of ramp that counts as one of its mouths -- the run a ball
--- has to be within to get on or off there. sim/ tests against it every step
--- and core/geometry.lua checks that no playfield wall is inside it.
---@param g table
---@param which "start"|"end"
---@return number s0, number s1 the stretch of ramp the mouth covers
function M.mouth(g, which)
  if which == "start" then return 0, math.min(C.RAMP_MOUTH, g.length) end
  return math.max(0, g.length - C.RAMP_MOUTH), g.length
end

--- Is this end of the ramp open to a ball arriving from the playfield?
function M.admits(g, which)
  return g.enter == "both" or g.enter == which
end

--- The centreline point and tangent at arclength `s`. The renderer walks the
--- ramp with this, and it is also how the mouth zones are drawn.
---@return number x, number y, number tx, number ty
function M.point_at(g, s)
  local path, cum = g.path, g.cum
  s = math.max(0, math.min(g.length, s))
  local n = #cum
  local i = 1
  while i < n - 1 and cum[i + 1] < s do i = i + 1 end
  local seg = cum[i + 1] - cum[i]
  local t   = (seg > 1e-9) and (s - cum[i]) / seg or 0
  local ax, ay = path[i*2-1], path[i*2]
  local bx, by = path[i*2+1], path[i*2+2]
  local dx, dy = bx - ax, by - ay
  local l = math.sqrt(dx * dx + dy * dy)
  if l < 1e-9 then return ax, ay, 1, 0 end
  return ax + dx * t, ay + dy * t, dx / l, dy / l
end

return M
