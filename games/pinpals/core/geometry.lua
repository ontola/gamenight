--- Static geometry checks for board data.
---
--- Every board bug in the 2026-09-05 playtest was a coordinate typo that only
--- showed up after thousands of simulated ball drops. All of them are visible
--- in the data. This module finds them without running physics, so a bad edit
--- fails in milliseconds with the offending coordinate named, instead of as a
--- ball quietly sitting still somewhere during play.
---
--- Pure Lua. No love.* here.

local C    = require("core.constants")
local ramp = require("core.ramp")

local M = {}

local BALL_D = C.BALL_RADIUS * 2
-- The throat check's bar is the ball's own width and nothing more, which
-- makes it a lower bound rather than a guarantee: a gap a shade wider than
-- the ball still passes here and can still hold the ball if it dead-ends.
-- See the note at C.THROAT_MIN for why no margin is added, and what does
-- catch that case.
local THROAT = BALL_D

---------------------------------------------------------------------------
-- Small geometry helpers
---------------------------------------------------------------------------

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

--- The four corners of a rotated rectangle, as a flat x,y list.
---
--- Exported because three layers need to agree on exactly where a target is:
--- sim/ builds a polygon fixture from it, this module checks its clearances,
--- and app/ draws it. Three copies of this arithmetic would be three chances
--- for the picture to disagree with the physics.
---@param t table x, y, w, h, angle
---@return number[] eight numbers, four corners clockwise
function M.rect_corners(t)
  local a = t.angle or 0
  local c, s = math.cos(a), math.sin(a)
  local hw, hh = t.w / 2, t.h / 2
  local out = {}
  for _, p in ipairs({ { -hw, -hh }, { hw, -hh }, { hw, hh }, { -hw, hh } }) do
    out[#out+1] = t.x + p[1] * c - p[2] * s
    out[#out+1] = t.y + p[1] * s + p[2] * c
  end
  return out
end

--- The guard bar's rectangle at one of its two homes, in the shape
--- rect_corners wants. Exported for the same reason rect_corners is: sim/
--- builds a fixture from it, this module checks its clearances and app/ draws
--- it, and three copies of "where is the bar, exactly" is three chances for
--- the picture to disagree with the physics.
---@param g table one `guards` entry
---@param where "up"|"down"
---@return table rect with x, y, w, h, angle
function M.guard_rect(g, where)
  local at = g[where]
  return { x = at.x, y = at.y, w = g.w, h = g.h, angle = g.angle or 0 }
end

--- The two ends of the guard bar's centreline, outer end first. "Outer" is
--- the end against the shell, which is the low-x end on the left of the board
--- and the high-x end on the right.
---@param g table one `guards` entry
---@param where "up"|"down"
---@return number ox, number oy, number ix, number iy
function M.guard_ends(g, where)
  local at, a = g[where], g.angle or 0
  local hx, hy = math.cos(a) * g.w / 2, math.sin(a) * g.w / 2
  if g.side == "left" then
    return at.x - hx, at.y - hy, at.x + hx, at.y + hy
  end
  return at.x + hx, at.y + hy, at.x - hx, at.y - hy
end

--- Distance from a point to a segment, and the closest point on it.
local function point_seg(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx*dx + dy*dy
  local t = (l2 > 0) and clamp(((px-ax)*dx + (py-ay)*dy) / l2, 0, 1) or 0
  local qx, qy = ax + dx*t, ay + dy*t
  return math.sqrt((px-qx)^2 + (py-qy)^2), qx, qy
end

local function cross(ox, oy, px, py, qx, qy)
  return (px-ox)*(qy-oy) - (py-oy)*(qx-ox)
end

--- Minimum distance between two segments. Zero if they properly cross.
local function seg_seg(a1x,a1y,a2x,a2y, b1x,b1y,b2x,b2y)
  local d1 = cross(a1x,a1y,a2x,a2y,b1x,b1y)
  local d2 = cross(a1x,a1y,a2x,a2y,b2x,b2y)
  local d3 = cross(b1x,b1y,b2x,b2y,a1x,a1y)
  local d4 = cross(b1x,b1y,b2x,b2y,a2x,a2y)
  if ((d1 > 0) ~= (d2 > 0)) and ((d3 > 0) ~= (d4 > 0)) then return 0 end
  local best = math.huge
  best = math.min(best, (point_seg(b1x,b1y, a1x,a1y,a2x,a2y)))
  best = math.min(best, (point_seg(b2x,b2y, a1x,a1y,a2x,a2y)))
  best = math.min(best, (point_seg(a1x,a1y, b1x,b1y,b2x,b2y)))
  best = math.min(best, (point_seg(a2x,a2y, b1x,b1y,b2x,b2y)))
  return best
end

--- Wrap an angle to [-pi, pi].
local function norm(a)
  while a >  math.pi do a = a - 2*math.pi end
  while a < -math.pi do a = a + 2*math.pi end
  return a
end

--- Flatten every polyline into a list of segments.
---
--- `s0` and `len` are how far along its own chain each segment starts and how
--- long it is. The throat check needs them: since curves became polylines,
--- two segments a few chords apart on one smooth arc are legitimately closer
--- together than the ball is wide, and the only thing separating that from a
--- real throat is how much chain runs between them.
local function segments_of(board)
  local segs = {}
  local function chain(poly, pi, label, ramp_id)
    local run = 0
    for i = 1, #poly - 3, 2 do
      local len = math.sqrt((poly[i+2] - poly[i])^2 + (poly[i+3] - poly[i+1])^2)
      segs[#segs+1] = {
        ax = poly[i], ay = poly[i+1], bx = poly[i+2], by = poly[i+3],
        poly = pi, index = (i + 1) / 2, label = label, ramp = ramp_id,
        s0 = run, len = len,
      }
      run = run + len
    end
  end
  for pi, poly in ipairs(board.walls or {}) do
    chain(poly, pi, "wall " .. pi)
  end
  -- A ramp's skirt -- the rails and the slanted closure where the lane is too
  -- low to duck under -- is solid to a playfield ball, so every rule a wall
  -- obeys applies to it: it can wedge against a target, jam a flipper or make
  -- a bowl, and it is generated rather than typed, which is exactly why it
  -- has to be checked rather than trusted.
  --
  -- `poly` is deliberately shared across one ramp's pieces and negative, so
  -- the throat check's along-the-chain exemption cannot mistake two separate
  -- rails for one continuous run.
  for ri, r in ipairs(board.ramps or {}) do
    if r.geom then
      for k, poly in ipairs(r.geom.skirt) do
        chain(poly, -ri, ("ramp %s skirt %d"):format(r.id, k), r.id)
      end
    end
  end
  return segs
end

--- Everything on the board that is a solid closed outline rather than a
--- chain: standup targets and slingshots. They obey exactly the same rules --
--- a ball cannot pass a sub-ball-width throat, and nothing may sit inside a
--- flipper's swept arc -- so they are checked through one list rather than
--- one branch each. Slingshots were added to the board data after targets,
--- and doing it any other way is how the second kind ends up unchecked.
---@return table[] each { label, x, y, corners }
local function solids_of(board)
  local out = {}
  for i, t in ipairs(board.targets or {}) do
    out[#out+1] = { label = "target " .. i, x = t.x, y = t.y, c = M.rect_corners(t) }
  end
  for i, sl in ipairs(board.slingshots or {}) do
    local c = sl.p
    out[#out+1] = {
      label = "slingshot " .. i, c = c,
      x = (c[1] + c[3] + c[5]) / 3, y = (c[2] + c[4] + c[6]) / 3,
    }
  end
  return out
end

--- A solid's outline as segments, so the flipper-arc check can treat it
--- exactly like a wall.
local function solid_segments(solids)
  local segs = {}
  for _, s in ipairs(solids) do
    local n = #s.c / 2
    for e = 0, n - 1 do
      local i = e * 2 + 1
      local j = (e + 1) % n * 2 + 1
      segs[#segs+1] = { ax = s.c[i], ay = s.c[i+1], bx = s.c[j], by = s.c[j+1],
                        label = s.label }
    end
  end
  return segs
end

---------------------------------------------------------------------------
-- 1. Bowls
---------------------------------------------------------------------------

--- A vertex lower than everything it connects to is a bowl: the ball rolls in
--- and stays. A vertex higher than its neighbours is a peak, which sheds the
--- ball and is fine -- so this is not "the chain must be monotone", it is
--- "the chain must never turn back up".
---
--- Vertices are keyed by position, so a bowl formed where two separate
--- polylines meet is caught the same way as one inside a single chain. Board
--- A's (300,702) and board B's (84,702) were both of the first kind.
local function check_bowls(board, segs, out)
  local at = {}
  local function key(x, y) return ("%.1f,%.1f"):format(x, y) end
  local function add(x, y, ox, oy)
    local k = key(x, y)
    at[k] = at[k] or { x = x, y = y, n = {} }
    table.insert(at[k].n, { x = ox, y = oy })
  end
  for _, s in ipairs(segs) do
    add(s.ax, s.ay, s.bx, s.by)
    add(s.bx, s.by, s.ax, s.ay)
  end

  for _, v in pairs(at) do
    -- A free end connects to only one segment and cannot hold anything.
    if #v.n >= 2 and v.y <= board.drain_y then
      local lowest, strict = true, false
      for _, n in ipairs(v.n) do
        if n.y > v.y + 1e-6 then lowest = false break end
        if n.y < v.y - 1e-6 then strict = true end
      end
      if lowest and strict then
        out[#out+1] = {
          kind = "bowl", x = v.x, y = v.y,
          msg = ("wall vertex (%g, %g) is lower than everything it joins: the ball settles here")
                :format(v.x, v.y),
        }
      end
    end
  end
end

---------------------------------------------------------------------------
-- 2. Walls inside a flipper
---------------------------------------------------------------------------

--- A wall inside the arc a flipper sweeps either jams the flipper or creates a
--- notch behind the pivot that the flipper rotates away from, so a slow ball
--- sits there untouchable. Board A's lower-left chain used to end at
--- (133,692), four pixels under its own pivot.
local function check_flipper_arcs(board, segs, out)
  local half = C.FLIPPER_THICK / 2
  local reach = C.FLIPPER_LEN + half

  for _, f in ipairs(board.flippers or {}) do
    local left = f.side == "left"
    local rest = left and  C.FLIPPER_REST or -C.FLIPPER_REST
    local up   = left and  C.FLIPPER_UP   or -C.FLIPPER_UP
    local lo, hi = math.min(rest, up), math.max(rest, up)
    local worst

    for _, s in ipairs(segs) do
      local len = math.sqrt((s.bx-s.ax)^2 + (s.by-s.ay)^2)
      local steps = math.max(1, math.ceil(len / 2))
      for i = 0, steps do
        local t = i / steps
        local px, py = s.ax + (s.bx-s.ax)*t, s.ay + (s.by-s.ay)*t
        local dx, dy = px - f.x, py - f.y
        local r = math.sqrt(dx*dx + dy*dy)
        if r <= reach then
          local inside
          if r <= half then
            inside = true                     -- effectively on the pivot
          else
            -- The body's rectangle runs along +x for a left flipper and -x for
            -- a right one, so a right flipper's world angle is theta + pi.
            local theta = norm(left and math.atan2(dy, dx)
                                    or (math.atan2(dy, dx) - math.pi))
            local slack = math.asin(clamp(half / r, -1, 1))
            inside = theta >= lo - slack and theta <= hi + slack
          end
          if inside and (not worst or r < worst.r) then
            worst = { x = px, y = py, r = r, seg = s }
          end
        end
      end
    end

    if worst then
      out[#out+1] = {
        kind = "flipper-jam", x = worst.x, y = worst.y,
        msg = ("%s passes through the %s flipper's swept arc at (%.0f, %.0f), %.1fpx from the pivot")
              :format(worst.seg.label, f.side, worst.x, worst.y, worst.r),
      }
    end
  end
end

---------------------------------------------------------------------------
-- 3. Wedges
---------------------------------------------------------------------------

--- Two surfaces closer together than the ball is wide form a throat the ball
--- cannot pass but can rest in. Board B's two rails converged to 10.8px and
--- caught the ball 19 times in 182 drops -- they never actually crossed, which
--- is why "do any walls intersect?" would not have found it.
local function check_wedges(board, segs, out)
  -- Two segments are exempt when they meet at a shared vertex -- including
  -- across two chains, which is how board A's ramp walls join its roof -- or
  -- when too little chain runs between them for the gap to be a throat rather
  -- than a curve. See C.THROAT_RUN for why the second rule exists.
  local function adjacent(a, b)
    local pts = { {a.ax,a.ay}, {a.bx,a.by} }
    for _, p in ipairs(pts) do
      if (math.abs(p[1]-b.ax) < 0.5 and math.abs(p[2]-b.ay) < 0.5)
      or (math.abs(p[1]-b.bx) < 0.5 and math.abs(p[2]-b.by) < 0.5) then return true end
    end
    if a.poly == b.poly and a.s0 and b.s0 then
      local first, second = a, b
      if second.s0 < first.s0 then first, second = b, a end
      if second.s0 - (first.s0 + first.len) <= C.THROAT_RUN then return true end
    end
    return false
  end

  for i = 1, #segs do
    for j = i + 1, #segs do
      local a, b = segs[i], segs[j]
      if not adjacent(a, b) then
        local d = seg_seg(a.ax,a.ay,a.bx,a.by, b.ax,b.ay,b.bx,b.by)
        if d < THROAT then
          local _, qx, qy = point_seg(b.ax, b.ay, a.ax, a.ay, a.bx, a.by)
          out[#out+1] = {
            kind = "wedge", x = qx, y = qy,
            msg = ("walls %d and %d come within %.1fpx near (%.0f, %.0f); the ball is %.1fpx wide")
                  :format(a.poly, b.poly, d, qx, qy, BALL_D),
          }
        end
      end
    end
  end

  -- Bumpers make the same throat against a wall, or against each other.
  for bi, bump in ipairs(board.bumpers or {}) do
    for _, s in ipairs(segs) do
      local d = (point_seg(bump.x, bump.y, s.ax, s.ay, s.bx, s.by)) - bump.r
      if d < THROAT then
        out[#out+1] = {
          kind = "wedge", x = bump.x, y = bump.y,
          msg = ("bumper %d sits %.1fpx from wall %d; the ball is %.1fpx wide")
                :format(bi, d, s.poly, BALL_D),
        }
      end
    end
    for bj = bi + 1, #board.bumpers do
      local o = board.bumpers[bj]
      local d = math.sqrt((bump.x-o.x)^2 + (bump.y-o.y)^2) - bump.r - o.r
      if d < THROAT then
        out[#out+1] = {
          kind = "wedge", x = bump.x, y = bump.y,
          msg = ("bumpers %d and %d are %.1fpx apart; the ball is %.1fpx wide")
                :format(bi, bj, d, BALL_D),
        }
      end
    end
  end

  -- Targets and slingshots are solid too: a standup parked a sub-ball-width
  -- from a wall is a pocket in exactly the way a bumper is, and it is easier
  -- to author by accident because it is small and its angle is easy to get
  -- wrong. A slingshot is bigger and sits in the tightest part of the board,
  -- between an inlane and a flipper, so it is easier still.
  local solids = solids_of(board)
  local function outline(sol)
    local n, es = #sol.c / 2, {}
    for e = 0, n - 1 do
      local i = e * 2 + 1
      local j = (e + 1) % n * 2 + 1
      es[#es+1] = { sol.c[i], sol.c[i+1], sol.c[j], sol.c[j+1] }
    end
    return es
  end

  for si, sol in ipairs(solids) do
    for _, ed in ipairs(outline(sol)) do
      for _, w in ipairs(segs) do
        local d = seg_seg(ed[1], ed[2], ed[3], ed[4], w.ax, w.ay, w.bx, w.by)
        if d < THROAT then
          out[#out+1] = {
            kind = "wedge", x = sol.x, y = sol.y,
            msg = ("%s sits %.1fpx from %s; the ball is %.1fpx wide")
                  :format(sol.label, d, w.label, BALL_D),
          }
        end
      end
    end

    -- And against each other. A bank is authored as a row of near-identical
    -- entries, which makes it very easy to space them by less than they are
    -- wide -- at which point they overlap into one bar on screen and form a
    -- throat between them in the physics. Both happened on the first draft of
    -- Glasshouse's bank, and only the picture gave it away.
    for sj = si + 1, #solids do
      local other = solids[sj]
      local best = math.huge
      for _, e1 in ipairs(outline(sol)) do
        for _, e2 in ipairs(outline(other)) do
          best = math.min(best, seg_seg(e1[1], e1[2], e1[3], e1[4],
                                        e2[1], e2[2], e2[3], e2[4]))
        end
      end
      if best < THROAT then
        out[#out+1] = {
          kind = "wedge", x = sol.x, y = sol.y,
          msg = ("%s and %s are %.1fpx apart; the ball is %.1fpx wide")
                :format(sol.label, other.label, best, BALL_D),
        }
      end
    end

    -- A solid against a bumper is the same pocket again.
    for bi, bump in ipairs(board.bumpers or {}) do
      for _, ed in ipairs(outline(sol)) do
        local d = (point_seg(bump.x, bump.y, ed[1], ed[2], ed[3], ed[4])) - bump.r
        if d < THROAT then
          out[#out+1] = {
            kind = "wedge", x = sol.x, y = sol.y,
            msg = ("%s sits %.1fpx from bumper %d; the ball is %.1fpx wide")
                  :format(sol.label, d, bi, BALL_D),
          }
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- 4. Devices that do not do what they claim
---------------------------------------------------------------------------

--- Both halves of a gate are load-bearing and both are easy to get wrong by a
--- few degrees: closed it has to actually seal the ramp, and open it has to
--- leave the ball room to get past. An earlier open angle left 3px of
--- clearance, which is the sort of thing that reads fine on screen and then
--- eats one shot in five.
local function check_devices(board, segs, out)
  for _, d in ipairs(board.devices or {}) do
    if d.kind == "gate" then
      local tx = d.pivot.x + math.cos(d.closed) * d.length
      local ty = d.pivot.y + math.sin(d.closed) * d.length
      local best, nearest = math.huge, nil
      for _, s in ipairs(segs) do
        local dist = (point_seg(tx, ty, s.ax, s.ay, s.bx, s.by))
        if dist < best then best, nearest = dist, s end
      end
      if best >= BALL_D then
        out[#out+1] = {
          kind = "gate-leaks", x = tx, y = ty,
          msg = ("%s: closed, its tip stops %.1fpx short of the nearest wall; the ball slips past")
                :format(d.id, best),
        }
      elseif nearest then
        local ox = d.pivot.x + math.cos(d.open) * d.length
        local oy = d.pivot.y + math.sin(d.open) * d.length
        local gap = seg_seg(d.pivot.x, d.pivot.y, ox, oy,
                            nearest.ax, nearest.ay, nearest.bx, nearest.by)
                    - C.GATE_THICK / 2
        if gap <= BALL_D then
          out[#out+1] = {
            kind = "gate-blocks", x = ox, y = oy,
            msg = ("%s: open, it leaves only %.1fpx of clearance; the ball is %.1fpx wide")
                  :format(d.id, gap, BALL_D),
          }
        end
      end

    elseif d.kind == "paddle" then
      -- The post exists to plug the gap between the flipper tips. If it does
      -- not span that gap it is guarding nothing, and if it does not retract
      -- clear of the playfield it is guarding it permanently.
      local lo, hi
      for _, f in ipairs(board.flippers or {}) do
        local sgn = (f.side == "left") and 1 or -1
        local tip = f.x + sgn * C.FLIPPER_LEN * math.cos(C.FLIPPER_REST)
        if f.side == "left" then lo = tip else hi = tip end
      end
      if lo and hi then
        if d.up.x - d.w/2 > lo or d.up.x + d.w/2 < hi then
          out[#out+1] = {
            kind = "post-misses", x = d.up.x, y = d.up.y,
            msg = ("%s: raised it spans %.0f..%.0f, but the drain gap is %.0f..%.0f")
                  :format(d.id, d.up.x - d.w/2, d.up.x + d.w/2, lo, hi),
          }
        end
      end
      if d.down.y - d.h/2 <= board.drain_y then
        out[#out+1] = {
          kind = "post-stuck-out", x = d.down.x, y = d.down.y,
          msg = ("%s: retracted it still reaches y=%.0f, above the drain line at %.0f")
                :format(d.id, d.down.y - d.h/2, board.drain_y),
        }
      end
    end
  end
end

---------------------------------------------------------------------------
-- 5. Ramps
---------------------------------------------------------------------------

--- Is (px, py) inside the convex quad given as eight numbers?
local function in_quad(q, px, py)
  local sign
  for i = 1, 8, 2 do
    local ax, ay = q[i], q[i+1]
    local bx, by = q[(i + 1) % 8 + 1], q[(i + 2) % 8 + 1]
    local c = cross(ax, ay, bx, by, px, py)
    if math.abs(c) > 1e-9 then
      local s = c > 0
      if sign == nil then sign = s elseif sign ~= s then return false end
    end
  end
  return true
end

--- The rectangle covering one mouth of a ramp: the stretch of lane a ball
--- has to be standing in to get on or off there, as a quad.
local function mouth_quad(g, which)
  local s0, s1 = ramp.mouth(g, which)
  local half = g.width / 2
  local x0, y0, tx0, ty0 = ramp.point_at(g, s0)
  local x1, y1, tx1, ty1 = ramp.point_at(g, s1)
  return {
    x0 - ty0 * half, y0 + tx0 * half,
    x1 - ty1 * half, y1 + tx1 * half,
    x1 + ty1 * half, y1 - tx1 * half,
    x0 + ty0 * half, y0 - tx0 * half,
  }
end

--- Two things about an elevated ramp are invisible until a ball is on one.
---
--- 1. A ramp that turns tighter than it is wide folds its inner rail back
---    through itself. On screen that is a small kink; in the physics it is a
---    pocket the ball cannot leave, on a layer where nothing else can reach
---    it either.
---
--- 2. A mouth has to open onto clear playfield. Coming off a ramp is the one
---    moment the ball changes which geometry it can see, and if a wall runs
---    through the mouth the ball reappears INSIDE it -- the solver then
---    ejects it in whatever direction it likes, which reads as the ball
---    teleporting. Entering has no such hazard, because a ball on the
---    playfield is by definition not inside a wall already.
local function check_ramps(board, segs, out)
  for _, r in ipairs(board.ramps or {}) do
    local g = r.geom
    if g then
      local path = g.path
      for _, side in ipairs({ "left", "right" }) do
        local rail = g[side]
        for i = 1, #rail - 3, 2 do
          local rx, ry = rail[i+2] - rail[i], rail[i+3] - rail[i+1]
          local cx, cy = path[i+2] - path[i], path[i+3] - path[i+1]
          if rx * cx + ry * cy < 0 then
            out[#out+1] = {
              kind = "ramp-pinch", x = path[i], y = path[i+1],
              msg = ("ramp %s turns tighter than its %gpx width near (%.0f, %.0f): the %s rail folds back on itself")
                    :format(r.id, g.width, path[i], path[i+1], side),
            }
            break
          end
        end
      end

      for _, which in ipairs({ "start", "end" }) do
        if ramp.admits(g, which) then
          local q = mouth_quad(g, which)
          local worst, at
          for _, w in ipairs(segs) do
            -- A ramp's own skirt runs along the sides of its own mouth by
            -- construction, so it is the one wall that being there is not a
            -- defect. Every other wall, this ramp's or another's, still is.
           if w.ramp ~= r.id then
            local d = math.huge
            for k = 1, 8, 2 do
              local j = (k + 1) % 8 + 1
              d = math.min(d, seg_seg(q[k], q[k+1], q[j], q[j+1],
                                      w.ax, w.ay, w.bx, w.by))
            end
            if in_quad(q, (w.ax + w.bx) / 2, (w.ay + w.by) / 2) then d = 0 end
            if d < (worst or math.huge) then worst, at = d, w end
           end
          end
          if worst and worst < C.BALL_RADIUS then
            local s0 = select(1, ramp.mouth(g, which))
            local mx, my = ramp.point_at(g, s0)
            out[#out+1] = {
              kind = "ramp-mouth", x = mx, y = my,
              msg = ("ramp %s: its %s mouth is %.1fpx from %s, so a ball coming off there lands inside it")
                    :format(r.id, which, worst, at.label),
            }
          end
        end
      end
    end
  end
end

---------------------------------------------------------------------------
-- 5. Outlane guards
---------------------------------------------------------------------------

--- The guard is a barrier across the mouth of an outlane, and three separate
--- things about it are easy to author wrong in ways that read fine on screen.
---
--- Deliberately NOT run through check_wedges: the guard is supposed to
--- overlap the shell and the lane divider, which is the exact condition that
--- check flags. It gets its own rules instead.
local function check_guards(board, segs, out)
  local function nearest_wall(x, y)
    local best, poly = math.huge, nil
    for _, s in ipairs(segs) do
      local d = (point_seg(x, y, s.ax, s.ay, s.bx, s.by))
      if d < best then best, poly = d, s.poly end
    end
    return best, poly
  end

  for _, g in ipairs(board.guards or {}) do
    local at = ("guard %s"):format(tostring(g.side))

    -- 1. Deployed, both ends have to reach what they are sealing against. An
    --    end that stops a ball's width short is an end the ball goes around,
    --    and the guard then reads as protection while protecting nothing.
    local ox, oy, ix, iy = M.guard_ends(g, "up")
    local anchor = {}
    for _, en in ipairs({ { "outer", ox, oy }, { "inner", ix, iy } }) do
      local d, poly = nearest_wall(en[2], en[3])
      anchor[en[1]] = poly
      if d >= BALL_D then
        out[#out+1] = {
          kind = "guard-leaks", x = en[2], y = en[3],
          msg = ("%s: its %s end stops %.1fpx from the nearest wall; the ball is %.1fpx wide")
                :format(at, en[1], d, BALL_D),
        }
      end
    end
    -- Both ends near the SAME chain is a bar lying along one wall rather than
    -- across a lane: every clearance is tiny and the lane beside it is wide
    -- open. It is the failure mode the distance test above cannot see.
    if anchor.outer and anchor.outer == anchor.inner then
      out[#out+1] = {
        kind = "guard-leaks", x = g.up.x, y = g.up.y,
        msg = ("%s: both ends sit against wall %d, so it spans no lane")
              :format(at, anchor.outer),
      }
    end

    -- 2. The bar has to slope INWARD-AND-DOWN. Both the kick off its face and
    --    the roll of a ball too slow for Box2D to bounce at all follow the
    --    slope, so the wrong sign sends a dying ball outward into a pocket
    --    against the shell instead of inward onto the lane divider.
    if iy <= oy then
      out[#out+1] = {
        kind = "guard-tilt", x = ix, y = iy,
        msg = ("%s: its inner end (y=%.0f) is not below its outer end (y=%.0f); a slow ball pockets outward")
              :format(at, iy, oy),
      }
    end

    -- 3. Retracted, it has to be genuinely gone. A guard still poking above
    --    the drain line is a guard that never stops guarding, which is the
    --    §6.2 failure the post was already caught committing.
    local top = math.huge
    local c = M.rect_corners(M.guard_rect(g, "down"))
    for i = 2, #c, 2 do top = math.min(top, c[i]) end
    if top <= board.drain_y then
      out[#out+1] = {
        kind = "guard-stuck-out", x = g.down.x, y = g.down.y,
        msg = ("%s: retracted it still reaches y=%.0f, above the drain line at %.0f")
              :format(at, top, board.drain_y),
      }
    end
  end
end

---------------------------------------------------------------------------

--- Check one board's geometry.
---@param board table a board definition that has already passed validate.board
---@return table[] defects each { kind, msg, x, y }
function M.check(board)
  local out = {}
  local segs = segments_of(board)
  -- Bowls are a property of the wall chains alone -- a solid has no vertices
  -- the ball can settle in, because it has no inside. The arc check does see
  -- them: a slingshot inside a flipper's sweep jams the flipper.
  local arc_segs = { }
  for _, sg in ipairs(segs) do arc_segs[#arc_segs+1] = sg end
  for _, sg in ipairs(solid_segments(solids_of(board))) do arc_segs[#arc_segs+1] = sg end
  -- A deployed guard is solid too, so a badly placed one has to be caught
  -- jamming a flipper the same way a slingshot is.
  for _, g in ipairs(board.guards or {}) do
    local sol = { label = "guard " .. tostring(g.side), x = g.up.x, y = g.up.y,
                  c = M.rect_corners(M.guard_rect(g, "up")) }
    for _, sg in ipairs(solid_segments({ sol })) do arc_segs[#arc_segs+1] = sg end
  end
  check_bowls(board, segs, out)
  check_flipper_arcs(board, arc_segs, out)
  check_wedges(board, segs, out)
  check_devices(board, segs, out)
  check_guards(board, segs, out)
  check_ramps(board, segs, out)
  table.sort(out, function(a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return (a.x + a.y * 1e-3) < (b.x + b.y * 1e-3)
  end)
  return out
end

--- Human-readable report for a whole board set.
---@return boolean clean, string[] lines
function M.report(boards)
  local lines, clean = {}, true
  for _, id in ipairs({ "a", "b" }) do
    local defects = M.check(boards[id])
    if #defects > 0 then
      clean = false
      for _, d in ipairs(defects) do
        lines[#lines+1] = ("board %s [%s] %s"):format(id, d.kind, d.msg)
      end
    end
  end
  return clean, lines
end

return M
