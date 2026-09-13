--- Coordinate overlay for board editing (key 2). Presentation only: it reads a
--- board definition and draws where its numbers are, and owns nothing.
---
--- The rule it follows is worth stating, because it decides everything else:
--- **it labels exactly the numbers that appear in data/tables/*.lua, and no
--- others.** A wall is a polyline, so every vertex gets its own label; a
--- target is a centre plus a width and a height, so the centre gets the label
--- and the corners get an outline. That way a number read off the screen can
--- be found in the file by searching for it, which is the entire point of the
--- mode -- a derived corner coordinate appears nowhere in the source and would
--- send you looking for something that is not written down.

local geo = require("core.geometry")

local M = {}

local GRID   = 32      -- fine grid, board pixels
local MAJOR  = 128     -- labelled grid
local SNAP   = 18      -- screen px: how close the cursor must be to a point

local INK    = { 1.00, 0.93, 0.55 }
local HOT    = { 0.55, 1.00, 0.75 }

--- Board pixels are integers in the data almost everywhere, and a label
--- reading "168.0" invites an edit that adds a decimal point to the file.
local function num(v)
  if v == math.floor(v) then return ("%d"):format(v) end
  return ("%.1f"):format(v)
end

local function coords(x, y) return num(x) .. "," .. num(y) end

---------------------------------------------------------------------------
-- What is on the board
---------------------------------------------------------------------------

local function point(out, x, y, tag, kind)
  out[#out+1] = { x = x, y = y, tag = tag, kind = kind or "vertex" }
end

--- The x,y pairs a human actually typed for a path.
---
--- Since core/curve.lua, `walls[i]` and `ramps[i].path` may have been expanded
--- from curve nodes into a hundred tessellated points, with the authored form
--- kept on `.spec`. This mode's rule is that it labels exactly the numbers
--- that appear in data/tables/*.lua and no others, so a curve gets its control
--- points labelled and not the arithmetic that came out of it -- a generated
--- vertex appears nowhere in the file and would send you looking for something
--- nobody wrote.
local function authored(path)
  local src = path.spec or path
  local pts, pend = {}, nil
  for _, v in ipairs(src) do
    if type(v) == "number" then
      if pend then
        pts[#pts+1] = { pend, v }
        pend = nil
      else
        pend = v
      end
    end
  end
  return pts
end

local function collect_polylines(def, out)
  for i, poly in ipairs(def.walls or {}) do
    for j, pt in ipairs(authored(poly)) do
      point(out, pt[1], pt[2], ("walls[%d][%d]"):format(i, j))
    end
  end
  for i, sling in ipairs(def.slingshots or {}) do
    for j = 1, #sling.p - 1, 2 do
      point(out, sling.p[j], sling.p[j + 1],
            ("slingshots[%d].p[%d]"):format(i, (j + 1) / 2))
    end
  end
end

local function collect_content(def, out)
  for i, b in ipairs(def.bumpers or {}) do
    point(out, b.x, b.y, ("bumpers[%d]  r%s"):format(i, num(b.r)), "centre")
  end
  for i, t in ipairs(def.targets or {}) do
    point(out, t.x, t.y,
          ("targets[%d]  %sx%s  %s"):format(i, num(t.w), num(t.h), t.bank or ""),
          "centre")
  end
  for i, f in ipairs(def.flippers or {}) do
    point(out, f.x, f.y, ("flippers[%d]  %s pivot"):format(i, f.side), "centre")
  end
end

--- Devices and guards each have two homes, and the parked one is off the
--- playfield on purpose. Both are labelled: "why is the post 40px lower than
--- I typed" is a question about the retracted position, and it is invisible
--- in play precisely because it is parked.
local function collect_devices(def, out)
  for _, d in ipairs(def.devices or {}) do
    if d.kind == "gate" then
      point(out, d.pivot.x, d.pivot.y,
            ("%s.pivot  len%s"):format(d.id, num(d.length)), "centre")
    else
      point(out, d.up.x, d.up.y,
            ("%s.up  %sx%s"):format(d.id, num(d.w), num(d.h)), "centre")
      point(out, d.down.x, d.down.y, d.id .. ".down", "parked")
    end
  end
  for i, g in ipairs(def.guards or {}) do
    point(out, g.up.x, g.up.y,
          ("guards[%d].up  %s %sx%s"):format(i, g.side, num(g.w), num(g.h)), "centre")
    point(out, g.down.x, g.down.y, ("guards[%d].down"):format(i), "parked")
  end
end

--- A ramp is a centreline plus four numbers that decide what it costs to
--- shoot, and the four are as load-bearing as the coordinates: the entry
--- window is the width narrowed by a ball radius, and the gate at the mouth
--- is computed from the crown height. So the first point carries them.
local function collect_ramps(def, out)
  for i, r in ipairs(def.ramps or {}) do
    for j, pt in ipairs(authored(r.path)) do
      local tag = ("ramps[%d].path[%d]"):format(i, j)
      if j == 1 then
        tag = ("%s  %s  w%s  crown %s  slope %s/%s")
          :format(tag, r.id, num(r.width), num(r.height),
                  num(r.entry_slope), num(r.exit_slope))
      end
      point(out, pt[1], pt[2], tag)
    end
  end
end

local function collect_points(def, out)
  local m = def.tube and def.tube.mouth
  if m then point(out, m.x, m.y, ("tube.mouth  r%s -> %s"):format(num(m.r), def.tube.to), "centre") end
  if def.entry then point(out, def.entry.x, def.entry.y, "entry", "centre") end
  if def.serve then point(out, def.serve.x, def.serve.y, "serve", "centre") end
end

--- Every labelled number on the board, in file order: walls first, so that
--- when two labels collide it is the wall vertex that survives and the
--- derived furniture that gives way.
local function collect(def)
  local out = {}
  collect_polylines(def, out)
  collect_ramps(def, out)
  collect_content(def, out)
  collect_devices(def, out)
  collect_points(def, out)
  return out
end

--- Board definitions are immutable once loaded and a reload replaces the whole
--- table, so identity is a sound cache key and the overlay stops allocating
--- fifty tables a frame for a list that cannot have changed.
local cached_def, cached_pts

local function points_for(def)
  if cached_def ~= def then cached_def, cached_pts = def, collect(def) end
  return cached_pts
end

--- The rectangles whose extent is worth outlining, since only their centres
--- are labelled.
local function rects_of(def)
  local out = {}
  for _, t in ipairs(def.targets or {}) do out[#out+1] = t end
  for _, d in ipairs(def.devices or {}) do
    if d.kind ~= "gate" then
      out[#out+1] = { x = d.up.x,   y = d.up.y,   w = d.w, h = d.h, angle = 0 }
      out[#out+1] = { x = d.down.x, y = d.down.y, w = d.w, h = d.h, angle = 0 }
    end
  end
  for _, g in ipairs(def.guards or {}) do
    out[#out+1] = geo.guard_rect(g, "up")
    out[#out+1] = geo.guard_rect(g, "down")
  end
  return out
end

---------------------------------------------------------------------------
-- Label placement
---------------------------------------------------------------------------

--- Coarse occupancy grid in screen space. A board's worth of coordinates is
--- forty-odd labels over a 420x900 column, and drawn unconditionally they
--- overlap into a smear exactly where the geometry is densest -- which is
--- where you are looking. First claim wins; a suppressed label keeps its dot,
--- and the cursor readout can always name it.
local CELL_W, CELL_H = 40, 13

local function claim(taken, x, y, w)
  local row = math.floor(y / CELL_H)
  local c0, c1 = math.floor(x / CELL_W), math.floor((x + w) / CELL_W)
  for c = c0, c1 do
    if taken[row .. ":" .. c] then return false end
  end
  for c = c0, c1 do taken[row .. ":" .. c] = true end
  return true
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function scrim(def, view)
  love.graphics.setColor(0.02, 0.02, 0.03, 0.62)
  love.graphics.rectangle("fill", view.x, view.y,
                          def.size.w * view.s, def.size.h * view.s, 8)
end

--- Grid and rulers. The rulers are the reason the grid is here: an unlabelled
--- mesh says "regular", a labelled one says "that bumper is at 230".
local function grid(def, view, font)
  local x0, y0, s = view.x, view.y, view.s
  love.graphics.setLineWidth(1)
  for gx = 0, def.size.w, GRID do
    local major = gx % MAJOR == 0
    love.graphics.setColor(INK[1], INK[2], INK[3], major and 0.20 or 0.07)
    love.graphics.line(x0 + gx * s, y0, x0 + gx * s, y0 + def.size.h * s)
  end
  for gy = 0, def.size.h, GRID do
    local major = gy % MAJOR == 0
    love.graphics.setColor(INK[1], INK[2], INK[3], major and 0.20 or 0.07)
    love.graphics.line(x0, y0 + gy * s, x0 + def.size.w * s, y0 + gy * s)
  end

  love.graphics.setFont(font)
  love.graphics.setColor(INK[1], INK[2], INK[3], 0.5)
  for gx = 0, def.size.w, MAJOR do
    love.graphics.print(tostring(gx), x0 + gx * s + 2, y0 + 2)
  end
  for gy = MAJOR, def.size.h, MAJOR do
    love.graphics.print(tostring(gy), x0 + 2, y0 + gy * s + 1)
  end
end

local function outlines(def, view)
  love.graphics.setLineWidth(1)
  love.graphics.setColor(INK[1], INK[2], INK[3], 0.30)
  love.graphics.push()
  love.graphics.translate(view.x, view.y)
  love.graphics.scale(view.s)
  for _, r in ipairs(rects_of(def)) do
    love.graphics.polygon("line", geo.rect_corners(r))
  end
  love.graphics.pop()
  love.graphics.setLineWidth(1)
end

local function drain_label(def, view, font)
  if not def.drain_y then return end
  local y = view.y + def.drain_y * view.s
  love.graphics.setFont(font)
  love.graphics.setColor(INK[1], INK[2], INK[3], 0.55)
  love.graphics.printf("drain_y " .. num(def.drain_y),
                       view.x, y - 11, def.size.w * view.s - 3, "right")
end

--- Above-right of the dot by preference, then below it, then the same two on
--- the left -- which is also what keeps a label on screen at the right-hand
--- board's outer wall. Four tries rather than one because the places that lose
--- the race are the dense ones, and those are the places you are looking at:
--- a flipper pivot with a wall end 7px away had no label at all before this.
local OFFSETS = { { 5, -12 }, { 5, 2 }, { -5, -12 }, { -5, 2 } }

local function place_label(taken, px, py, w, wmax)
  for _, o in ipairs(OFFSETS) do
    local lx = (o[1] > 0) and (px + o[1]) or (px + o[1] - w)
    local ly = py + o[2]
    if lx >= 0 and lx + w <= wmax and claim(taken, lx, ly, w) then return lx, ly end
  end
  return nil
end

local DOT = { vertex = 2.0, centre = 2.6, parked = 1.6 }

local function draw_points(pts, view, font, taken, wmax)
  love.graphics.setFont(font)
  for _, p in ipairs(pts) do
    local px, py = view.x + p.x * view.s, view.y + p.y * view.s
    local faded = (p.kind == "parked") and 0.45 or 1
    love.graphics.setColor(INK[1], INK[2], INK[3], 0.85 * faded)
    love.graphics.circle("fill", px, py, DOT[p.kind] or 2)

    local text = coords(p.x, p.y)
    local w = font:getWidth(text)
    local lx, ly = place_label(taken, px, py, w, wmax)
    if lx then
      love.graphics.setColor(0.02, 0.02, 0.03, 0.72)
      love.graphics.rectangle("fill", lx - 2, ly, w + 4, 11, 2)
      love.graphics.setColor(INK[1], INK[2], INK[3], 0.95 * faded)
      love.graphics.print(text, lx, ly - 1)
    end
  end
end

---------------------------------------------------------------------------
-- Cursor
---------------------------------------------------------------------------

local function nearest(pts, view, mx, my)
  local best, bd = nil, SNAP * SNAP
  for _, p in ipairs(pts) do
    local dx = view.x + p.x * view.s - mx
    local dy = view.y + p.y * view.s - my
    local d = dx * dx + dy * dy
    if d < bd then best, bd = p, d end
  end
  return best
end

local function callout(text, x, y, font, wmax)
  local w = font:getWidth(text)
  local lx = math.min(x + 14, wmax - w - 6)
  love.graphics.setFont(font)
  love.graphics.setColor(0.02, 0.03, 0.02, 0.88)
  love.graphics.rectangle("fill", lx - 4, y - 8, w + 8, 15, 3)
  love.graphics.setColor(HOT[1], HOT[2], HOT[3], 1)
  love.graphics.rectangle("line", lx - 4, y - 8, w + 8, 15, 3)
  love.graphics.print(text, lx, y - 7)
end

--- What the cursor is naming: the nearest labelled point when one is within
--- SNAP, otherwise the cursor's own position rounded to whole board pixels.
--- nil once the cursor leaves the board.
---
--- Two copyable forms, because the data files want both: `text` is the bare
--- pair a polyline is written in, `keyed` the `x = , y =` a bumper or a device
--- home is written in. The readout and the click-to-copy handler both go
--- through here, so the clipboard can only ever hold what the screen was
--- showing.
---@return table|nil { x, y, tag = string|nil, text = string, keyed = string }
local function pick_from(def, view, pts, mx, my)
  local bx = (mx - view.x) / view.s
  local by = (my - view.y) / view.s
  if bx < -20 or by < -20 or bx > def.size.w + 20 or by > def.size.h + 20 then return nil end

  local hit = nearest(pts, view, mx, my)
  local x, y, tag
  if hit then
    x, y, tag = hit.x, hit.y, hit.tag
  else
    x, y = math.floor(bx + 0.5), math.floor(by + 0.5)
  end
  return { x = x, y = y, tag = tag,
           text  = ("%s, %s"):format(num(x), num(y)),
           keyed = ("x = %s, y = %s"):format(num(x), num(y)) }
end

--- Public because main.lua copies the coordinate under the click (§9): the
--- overlay is the one place the mouse means anything. Left button takes
--- `text`, right button `keyed`.
---@param mx number|nil cursor position in screen space, shake removed
function M.pick(def, view, mx, my)
  if not mx then return nil end
  return pick_from(def, view, points_for(def), mx, my)
end

--- The cursor readout is the half of this mode that answers "where should I
--- put it", as against "where is it". Hovering a point names it in full,
--- because the dense labels above are coordinates only -- the tag is what
--- tells you which line of the file you are looking at.
local function cursor(def, view, pts, mx, my, font, wmax)
  local at = pick_from(def, view, pts, mx, my)
  if not at then return end

  love.graphics.setColor(HOT[1], HOT[2], HOT[3], 0.25)
  love.graphics.line(view.x, my, view.x + def.size.w * view.s, my)
  love.graphics.line(mx, view.y, mx, view.y + def.size.h * view.s)

  if at.tag then
    local hx, hy = view.x + at.x * view.s, view.y + at.y * view.s
    love.graphics.setColor(HOT[1], HOT[2], HOT[3], 1)
    love.graphics.circle("line", hx, hy, 7)
    callout(("%s   %s"):format(at.tag, coords(at.x, at.y)), hx, hy - 16, font, wmax)
  else
    callout(at.text, mx, my - 10, font, wmax)
  end
end

---------------------------------------------------------------------------

--- @param def   table board definition
--- @param view  table { x, y, s } screen placement, from app/render.lua
--- @param fonts table render's fonts; `tiny` is the label face
--- @param mx    number|nil cursor position in screen space, shake removed
--- @param my    number|nil
--- @param wmax  number window width, for keeping labels on screen
function M.draw(def, view, fonts, mx, my, wmax)
  local pts = points_for(def)
  scrim(def, view)
  grid(def, view, fonts.tiny)
  outlines(def, view)
  drain_label(def, view, fonts.tiny)
  draw_points(pts, view, fonts.tiny, {}, wmax)
  if mx then cursor(def, view, pts, mx, my, fonts.small, wmax) end

  -- Two lines, because one ran off the right edge of the window: what the
  -- board is, then what the mouse does with it. The example is spelled out
  -- rather than described -- "RIGHT as x = , y =" reads as a typo.
  local base = view.y + def.size.h * view.s + 4
  love.graphics.setFont(fonts.small)
  love.graphics.setColor(INK[1], INK[2], INK[3], 0.8)
  love.graphics.print(("%s  %dx%d   TAB other board"):format(
                      def.name:upper(), def.size.w, def.size.h), view.x, base)
  love.graphics.setColor(INK[1], INK[2], INK[3], 0.55)
  love.graphics.print("CLICK copies 230, 85   RIGHT copies x = 230, y = 85",
                      view.x, base + 13)
end

return M
