--- Curves for board geometry (§5.3).
---
--- Every wall on both boards used to be a run of straight segments, because
--- the data format was a flat list of x,y pairs and nothing else. That is a
--- constraint on the *format*, not on the physics: Box2D sees a chain of edge
--- shapes either way. So this module lets a polyline carry curve nodes
--- alongside its coordinates and expands them, once, into the flat list every
--- other layer already understands.
---
--- The expansion happens at load time (data/tables/init.lua) rather than at
--- use time, and that is the whole design:
---
---   * sim/, core/geometry.lua, app/render.lua and app/inspect.lua keep
---     reading `walls[i]` as a flat list of numbers. None of them learns what
---     a curve is, so none of them can disagree about where one goes.
---   * the authored form survives on `walls[i].spec`, so the coordinate
---     overlay can still label exactly the numbers that appear in the file
---     (app/inspect.lua's rule) instead of the hundred it generated.
---
--- Pure Lua. No love.* here.

local C = require("core.constants")

local M = {}

--- Append one point. Deliberately a function and not `out[#out+1],
--- out[#out+1] = x, y`: Lua evaluates both index expressions before either
--- assignment, so that idiom computes the same slot twice and silently keeps
--- only y.
local function push(out, x, y)
  out[#out+1] = x
  out[#out+1] = y
end

---------------------------------------------------------------------------
-- Tessellation
---------------------------------------------------------------------------

--- How many segments an arc of this radius and sweep needs.
---
--- Two floors fight here and both matter. CURVE_TOL keeps the chord from
--- sagging visibly away from the true curve; CURVE_MIN_CHORD keeps the
--- segments long enough that core/geometry.lua's throat check is measuring
--- the board rather than the tessellation -- consecutive-but-one segments of
--- a curve are exactly one chord apart, so a curve chopped fine enough is
--- indistinguishable from a gap narrower than the ball.
local function arc_steps(r, sweep)
  sweep = math.abs(sweep)
  if r <= 0 or sweep <= 0 then return 1 end
  -- Sagitta of one chord is r*(1-cos(step/2)); solve it for step.
  local by_tol = (C.CURVE_TOL < 2 * r)
    and 2 * math.acos(1 - C.CURVE_TOL / r) or math.pi
  -- Chord of one step is 2*r*sin(step/2); solve that for step too.
  local by_chord = 2 * math.asin(math.min(1, C.CURVE_MIN_CHORD / (2 * r)))
  local step = math.max(by_tol, by_chord, 1e-3)
  return math.max(1, math.min(C.CURVE_MAX_STEPS, math.ceil(sweep / step)))
end

--- Sample a circular arc, excluding its first point: the pen is already
--- there, and emitting it twice would put a zero-length edge in the chain.
local function emit_arc(out, cx, cy, r, a0, a1)
  local n = arc_steps(r, a1 - a0)
  for i = 1, n do
    local a = a0 + (a1 - a0) * (i / n)
    push(out, cx + math.cos(a) * r, cy + math.sin(a) * r)
  end
end

--- How far a point lies from the line through two others. The flatness test
--- below is the only caller, and it wants an unsigned distance.
local function point_line(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l = math.sqrt(dx * dx + dy * dy)
  if l < 1e-9 then return math.sqrt((px - ax)^2 + (py - ay)^2) end
  return math.abs((px - ax) * dy - (py - ay) * dx) / l
end

--- Sample a cubic Bezier by recursive subdivision, stopping where the curve
--- is already within CURVE_TOL of its own chord.
---
--- Deliberately not uniform sampling with a step count guessed from the
--- control polygon: the polygon is a poor proxy for length, and a fixed step
--- either over-samples the straight half of an S-curve or under-samples its
--- bend. Subdivision spends segments where the curve actually turns, which is
--- also what the arc case above does.
---
--- The deviation of a cubic from its chord is at most three quarters of the
--- larger control-point offset, so that bound is the test.
local function subdivide(out, x0,y0, x1,y1, x2,y2, x3,y3, depth)
  local d = math.max(point_line(x1,y1, x0,y0, x3,y3),
                     point_line(x2,y2, x0,y0, x3,y3))
  if depth >= C.CURVE_MAX_DEPTH or 0.75 * d <= C.CURVE_TOL then
    push(out, x3, y3)
    return
  end
  -- de Casteljau at the midpoint.
  local ax, ay = (x0+x1)/2, (y0+y1)/2
  local bx, by = (x1+x2)/2, (y1+y2)/2
  local cx, cy = (x2+x3)/2, (y2+y3)/2
  local dx, dy = (ax+bx)/2, (ay+by)/2
  local ex, ey = (bx+cx)/2, (by+cy)/2
  local mx, my = (dx+ex)/2, (dy+ey)/2
  subdivide(out, x0,y0, ax,ay, dx,dy, mx,my, depth + 1)
  subdivide(out, mx,my, ex,ey, cx,cy, x3,y3, depth + 1)
end

--- Drop points until every chord clears CURVE_MIN_CHORD, keeping the last one
--- so the curve still ends where it was asked to. Subdivision is free to
--- produce very short segments in a tight bend, and those are what make a
--- smooth curve read as a throat to core/geometry.lua.
local function thin(pts, fromx, fromy)
  local out = {}
  local lx, ly = fromx, fromy
  local ex, ey = pts[#pts-1], pts[#pts]
  for i = 1, #pts - 3, 2 do
    local x, y = pts[i], pts[i+1]
    if math.sqrt((x - lx)^2 + (y - ly)^2) >= C.CURVE_MIN_CHORD then
      push(out, x, y)
      lx, ly = x, y
    end
  end
  -- The endpoint is never negotiable, so it is the last kept point that gives
  -- way when the two would end up on top of each other -- otherwise the chain
  -- ends with a zero-length edge, which Box2D and every angle in
  -- core/geometry.lua would rather not be handed.
  if #out > 0 and math.sqrt((ex - lx)^2 + (ey - ly)^2) < C.CURVE_MIN_CHORD then
    out[#out] = nil
    out[#out] = nil
  end
  push(out, ex, ey)
  return out
end

--- Append a Bezier, excluding its first point. A quadratic is degree-elevated
--- to a cubic rather than given its own subdivision path.
local function emit_bezier(out, p0, c1, c2, p3)
  local raw = {}
  subdivide(raw, p0[1],p0[2], c1[1],c1[2], c2[1],c2[2], p3[1],p3[2], 0)
  for _, v in ipairs(thin(raw, p0[1], p0[2])) do out[#out+1] = v end
end

local function elevate(p0, v, p2)
  return { p0[1] + 2/3 * (v[1] - p0[1]), p0[2] + 2/3 * (v[2] - p0[2]) },
         { p2[1] + 2/3 * (v[1] - p2[1]), p2[2] + 2/3 * (v[2] - p2[2]) }
end

---------------------------------------------------------------------------
-- Fillets
---------------------------------------------------------------------------

--- Unit vector plus the original length, or three nils for a zero vector.
--- Three nils rather than one so every caller narrows all three at once.
local function norm2(x, y)
  local l = math.sqrt(x * x + y * y)
  if l < 1e-9 then return nil, nil, nil end
  return x / l, y / l, l
end

--- Round the corner at B, between the legs BA and BC, with radius r.
---
--- This is the node that earns the module its place. Every existing chain is
--- a run of sharp corners, and a fillet turns one into a curve without
--- moving any of the coordinates the board was designed around -- the corner
--- stays where it is in the file and only the metal is rounded off.
---
---@return number[]|nil points the arc, starting at the first tangent point
---@return number|nil consumed how much of each leg the arc ate
---@return string|nil err
local function fillet(ax, ay, bx, by, cx, cy, r)
  local ux, uy, la = norm2(ax - bx, ay - by)
  local vx, vy, lc = norm2(cx - bx, cy - by)
  if not (ux and uy and vx and vy and la and lc) then
    return nil, nil, "round: zero-length leg at the corner"
  end

  local dot   = math.max(-1, math.min(1, ux * vx + uy * vy))
  local theta = math.acos(dot)                       -- the corner's full angle
  if theta > math.pi - 1e-3 then return {}, 0, nil end  -- straight: nothing to round
  if theta < 1e-3 then
    return nil, nil, "round: the legs double back on each other, so there is no corner"
  end

  local half = theta / 2
  local back = r / math.tan(half)                    -- how far back the arc starts
  if back > la - 1e-6 or back > lc - 1e-6 then
    return nil, nil, ("round: radius %g needs %.1fpx of leg but has %.1fpx")
      :format(r, back, math.min(la, lc))
  end

  -- The centre sits on the corner's bisector, r/sin(half) away from it.
  local mx, my = norm2(ux + vx, uy + vy)
  if not mx then return nil, nil, "round: the legs are collinear" end
  local ox, oy = bx + mx * (r / math.sin(half)), by + my * (r / math.sin(half))

  local t1x, t1y = bx + ux * back, by + uy * back
  local t2x, t2y = bx + vx * back, by + vy * back
  local a0 = math.atan2(t1y - oy, t1x - ox)
  local a1 = math.atan2(t2y - oy, t2x - ox)
  -- Take the short way round: the fillet is always the minor arc, and
  -- atan2 has no idea which side of -pi the two ends landed on.
  local d = a1 - a0
  while d >  math.pi do d = d - 2 * math.pi end
  while d < -math.pi do d = d + 2 * math.pi end

  local out = { t1x, t1y }
  emit_arc(out, ox, oy, r, a0, a0 + d)
  return out, back, nil
end

---------------------------------------------------------------------------
-- The authored form
---------------------------------------------------------------------------

--- Split a mixed list of numbers and curve nodes into an ordered node list.
--- Numbers pair up into points; anything else is a curve node standing where
--- it was written.
local function parse(items, where)
  local nodes, pend = {}, nil
  for i, v in ipairs(items) do
    if type(v) == "number" then
      if v ~= v then return nil, ("%s[%d]: not a number"):format(where, i) end
      if pend then
        nodes[#nodes+1] = { kind = "point", x = pend, y = v }
        pend = nil
      else
        pend = v
      end
    elseif type(v) == "table" then
      if pend then
        return nil, ("%s[%d]: a curve node interrupts an x,y pair"):format(where, i)
      end
      nodes[#nodes+1] = { kind = "curve", spec = v, at = i }
    else
      return nil, ("%s[%d]: expected a number or a curve node, got %s")
        :format(where, i, type(v))
    end
  end
  if pend then return nil, where .. ": odd number of coordinates" end
  return nodes, nil
end

local function isnum(v) return type(v) == "number" and v == v end

local function point_of(v)
  if type(v) == "table" and isnum(v.x) and isnum(v.y) then return v.x, v.y end
  if type(v) == "table" and isnum(v[1]) and isnum(v[2]) then return v[1], v[2] end
  return nil
end

--- One `{ to = ..., ... }` or `{ arc = ... }` node, appended to `out`.
--- `out` already ends at the pen's current position.
local function emit_curve(out, spec, where)
  local px, py = out[#out-1], out[#out]

  if spec.arc then
    local a = spec.arc
    if not (isnum(a.x) and isnum(a.y) and isnum(a.r) and isnum(a.from) and isnum(a.to)) then
      return ("%s: arc needs x, y, r, from, to"):format(where)
    end
    local sx = a.x + math.cos(a.from) * a.r
    local sy = a.y + math.sin(a.from) * a.r
    -- An arc that does not begin where the pen is gets a straight run into
    -- it. That is nearly always what was meant, and the alternative -- an
    -- error -- would make the author compute the arc's own start point by
    -- hand, which is exactly the arithmetic this module exists to remove.
    if not px or math.abs(px - sx) > 1e-6 or math.abs(py - sy) > 1e-6 then
      push(out, sx, sy)
    end
    emit_arc(out, a.x, a.y, a.r, a.from, a.to)
    return nil
  end

  local tx, ty = point_of(spec.to)
  if not tx then return ("%s: expected `to = {x, y}`"):format(where) end
  if not px then return ("%s: a curve cannot be the first thing in a path"):format(where) end

  local c1x, c1y = point_of(spec.c1)
  local c2x, c2y = point_of(spec.c2)
  local vx,  vy  = point_of(spec.via)
  if c1x and c2x then
    emit_bezier(out, { px, py }, { c1x, c1y }, { c2x, c2y }, { tx, ty })
  elseif vx then
    local e1, e2 = elevate({ px, py }, { vx, vy }, { tx, ty })
    emit_bezier(out, { px, py }, e1, e2, { tx, ty })
  elseif c1x or c2x then
    return ("%s: a cubic needs both c1 and c2"):format(where)
  else
    return ("%s: expected `via` (quadratic) or `c1`+`c2` (cubic) with `to`"):format(where)
  end
  return nil
end

--- The nearest point node on one side of `i`, and whether the run between
--- them is clear of anything that would bend the leg.
---
--- `round` nodes are stepped over: rounding a corner does not move it, so the
--- leg into the NEXT corner still runs from the vertex the author wrote, not
--- from the tangent point the fillet happens to start at. Any other curve
--- node does bend the leg, and a fillet against a curve is not something this
--- module offers.
local function neighbour(nodes, i, step)
  local j = i + step
  while nodes[j] do
    if nodes[j].kind == "point" then return nodes[j], j end
    if not nodes[j].spec.round then return nil end
    j = j + step
  end
  return nil
end

--- Resolve every `round` node up front, so two fillets sharing one leg can be
--- checked for both fitting on it. Authored separately, they each look fine.
---@return table|nil by_index
---@return string|nil err
local function plan_fillets(nodes, where)
  local plan = {}
  for i, n in ipairs(nodes) do
    if n.kind == "curve" and n.spec.round then
      local r = n.spec.round
      local corner = nodes[i - 1]
      if not (corner and corner.kind == "point") then
        return nil, ("%s: `round` must follow an x,y pair"):format(where)
      end
      local before = neighbour(nodes, i - 1, -1)
      local after  = neighbour(nodes, i, 1)
      if not (before and after) then
        return nil, ("%s: `round` at (%g, %g) needs a plain point on each side of it")
          :format(where, corner.x, corner.y)
      end
      if not isnum(r) or r <= 0 then
        return nil, ("%s: `round` at (%g, %g) needs a positive radius")
          :format(where, corner.x, corner.y)
      end
      local pts, t, ferr = fillet(before.x, before.y, corner.x, corner.y, after.x, after.y, r)
      if not pts then
        return nil, ("%s at (%g, %g): %s"):format(where, corner.x, corner.y, ferr)
      end
      plan[i] = { corner = corner, before = before, after = after, t = t, pts = pts }
    end
  end

  -- Two corners on one straight run each eat `t` pixels of it from their own
  -- end. Authored one at a time they both look fine, and together they cross:
  -- the second fillet starts before the first has finished and the chain
  -- doubles back on itself.
  local prev
  for i = 1, #nodes do
    local p = plan[i]
    if p then
      if prev and prev.after == p.corner and p.before == prev.corner then
        local leg = math.sqrt((p.corner.x - prev.corner.x)^2
                            + (p.corner.y - prev.corner.y)^2)
        if prev.t + p.t > leg + 1e-6 then
          return nil, ("%s: the rounds at (%g, %g) and (%g, %g) need %.1fpx of the %.1fpx between them")
            :format(where, prev.corner.x, prev.corner.y, p.corner.x, p.corner.y,
                    prev.t + p.t, leg)
        end
      end
      prev = p
    end
  end
  return plan, nil
end

--- Expand one authored path into a flat list of x,y pairs.
---@param items table numbers, optionally interleaved with curve nodes
---@param where string label used in error messages
---@return number[]|nil flat
---@return string|nil err
function M.flatten(items, where)
  where = where or "path"
  if type(items) ~= "table" then return nil, where .. ": expected a list" end
  local nodes, err = parse(items, where)
  if not nodes then return nil, err end
  local plan, perr = plan_fillets(nodes, where)
  if not plan then return nil, perr end

  local out = {}
  for i, n in ipairs(nodes) do
    if n.kind == "point" then
      -- A `round` names the corner it follows, so a point with one after it
      -- is emitted by the fillet rather than here.
      local nxt = nodes[i + 1]
      if not (nxt and nxt.kind == "curve" and nxt.spec.round) then
        push(out, n.x, n.y)
      end
    elseif n.spec.round then
      local p = plan[i]
      if #p.pts == 0 then
        push(out, p.corner.x, p.corner.y)      -- collinear: nothing to round
      else
        for _, v in ipairs(p.pts) do out[#out+1] = v end
      end
    else
      local cerr = emit_curve(out, n.spec, ("%s node %d"):format(where, n.at))
      if cerr then return nil, cerr end
    end
  end

  if #out < 4 then
    return nil, where .. ": expanded to fewer than two points"
  end
  return out, nil
end

--- True when this authored path contains anything a curve has to expand.
--- Used to leave the ninety per cent of chains that are still plain lists
--- exactly as they were, `spec` and all.
function M.has_nodes(items)
  for _, v in ipairs(items) do if type(v) == "table" then return true end end
  return false
end

--- Expand every authored path on a board, in place.
---
--- The expanded list carries `.spec` -- the authored items -- so anything
--- that wants the numbers a human typed rather than the ones this module
--- generated has them. Lua tables hold an array part and named keys at once,
--- so `walls[i]` is still `ipairs`-able as the flat list it always was.
---@param def table a board definition, straight off disk
---@return boolean ok, string[] errors
function M.expand_board(def)
  local errs = {}
  if type(def) ~= "table" then return false, { "board: not a table" } end

  local function expand(items, where)
    if type(items) ~= "table" then
      errs[#errs+1] = where .. ": expected a list"
      return nil
    end
    if not M.has_nodes(items) then return items end
    local flat, err = M.flatten(items, where)
    if not flat then
      errs[#errs+1] = err
      return nil
    end
    ---@cast flat table
    flat.spec = items
    return flat
  end

  for i, poly in ipairs(def.walls or {}) do
    def.walls[i] = expand(poly, ("walls[%d]"):format(i)) or poly
  end
  for i, r in ipairs(def.ramps or {}) do
    if type(r) == "table" and r.path then
      r.path = expand(r.path, ("ramps[%d].path"):format(i)) or r.path
    end
  end

  return #errs == 0, errs
end

return M
