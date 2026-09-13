--- core/curve.lua and core/ramp.lua: the arithmetic every other layer trusts
--- without repeating.
---
--- The expansion is the load-bearing part. sim/ builds edge fixtures from the
--- flat list, core/geometry.lua measures it, app/ draws it and app/inspect.lua
--- labels the authored form behind it -- so a curve that expands wrongly is
--- wrong in four places at once, and in three of them silently.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert
  local C     = require("core.constants")
  local curve = require("core.curve")
  local ramp  = require("core.ramp")

  --- flatten returns nil plus a message for a bad path, so a test that means
  --- to index the result has to say so first.
  ---@return number[]
  local function flat(items)
    local f, err = curve.flatten(items, "t")
    A.truthy(f, tostring(err))
    return f or {}
  end

  local function chords(flat_pts)
    local mn, mx = math.huge, 0
    for i = 3, #flat_pts, 2 do
      local d = math.sqrt((flat_pts[i] - flat_pts[i-2])^2
                        + (flat_pts[i+1] - flat_pts[i-1])^2)
      mn, mx = math.min(mn, d), math.max(mx, d)
    end
    return mn, mx
  end

  describe("curve.flatten", function()
    it("leaves a plain polyline exactly as it was", function()
      local f = flat({ 10, 20, 30, 40 })
      A.equal(4, #f)
      A.equal(30, f[3])
    end)

    it("rounds a corner without moving the points either side of it", function()
      local f = flat({ 0, 100, 0, 0, { round = 20 }, 100, 0 })
      A.near(0, f[1], 1e-9)
      A.near(100, f[2], 1e-9, "the leg the fillet came from moved")
      A.near(100, f[#f-1], 1e-9, "the leg the fillet went to moved")
      A.near(0, f[#f], 1e-9)
      -- A right angle rounded at r=20 leaves the first leg at (0,20) and
      -- rejoins the second at (20,0): a radius back along each, because
      -- r/tan(45deg) is r.
      A.near(20, f[4], 0.01, "the arc did not start a radius back along the leg")
      A.near(20, f[#f-3], 0.01, "the arc did not end a radius along the far leg")
    end)

    it("sees past one round node to find the next corner's leg", function()
      -- Two corners on one run. The second `round` looks back for its leg and
      -- must not stop at the first `round` node standing in the way.
      local f = flat({ 0, 400, 0, 0, { round = 60 }, 400, 0, { round = 60 }, 400, 400 })
      A.near(400, f[#f-1], 1e-9)
      A.near(400, f[#f], 1e-9)
    end)

    it("refuses two rounds that would eat more of a leg than it has", function()
      local f, err = curve.flatten(
        { 0, 400, 0, 0, { round = 90 }, 100, 0, { round = 90 }, 100, 400 }, "t")
      A.falsy(f, "a leg 100px long swallowed two 90px fillets")
      A.truthy(tostring(err):find("between them", 1, true), tostring(err))
    end)

    it("refuses a radius the leg cannot hold", function()
      local f = curve.flatten({ 0, 40, 0, 0, { round = 500 }, 40, 0 }, "t")
      A.falsy(f, "a 40px leg accepted a 500px radius")
    end)

    it("keeps every chord above the floor the throat check needs", function()
      -- Chords shorter than this and core/geometry.lua reads a smooth curve as
      -- a gap the ball cannot fit through: two segments one apart on a curve
      -- sit exactly one chord from each other.
      for _, items in ipairs({
        { 0, 0, { to = { 300, 0 }, c1 = { 30, -120 }, c2 = { 270, 120 } } },
        { 0, 0, { to = { 100, 0 }, via = { 50, -60 } } },
        { { arc = { x = 200, y = 200, r = 40, from = math.pi, to = 0 } } },
      }) do
        local mn = chords(flat(items))
        A.truthy(mn >= C.CURVE_MIN_CHORD - 1e-6,
          ("shortest chord was %.2f, floor is %g"):format(mn, C.CURVE_MIN_CHORD))
      end
    end)

    it("ends a curve exactly where it was told to", function()
      local f = flat({ 0, 0, { to = { 137, -41 }, via = { 50, -60 } } })
      A.near(137, f[#f-1], 1e-9)
      A.near(-41, f[#f], 1e-9)
    end)

    it("rejects an odd coordinate count and a leading curve", function()
      A.falsy(curve.flatten({ 1, 2, 3 }, "t"))
      A.falsy(curve.flatten({ { to = { 10, 10 }, via = { 5, 5 } } }, "t"))
    end)
  end)

  describe("curve.expand_board", function()
    it("keeps the authored form on the expanded list", function()
      local spec = { 0, 100, 0, 0, { round = 20 }, 100, 0 }
      local def  = { walls = { spec } }
      A.truthy(curve.expand_board(def))
      A.equal(spec, def.walls[1].spec, "the authored path was not kept")
      A.truthy(#def.walls[1] > #spec, "the wall was not expanded")
    end)

    it("leaves a wall with no curve nodes untouched, spec and all", function()
      local plain = { 0, 0, 10, 10 }
      local def = { walls = { plain } }
      A.truthy(curve.expand_board(def))
      A.equal(plain, def.walls[1])
      A.equal(nil, def.walls[1].spec)
    end)

    it("reports the path that failed, by name", function()
      local def = { walls = { { 0, 0, 10, 10 }, { 0, 40, 0, 0, { round = 900 }, 40, 0 } } }
      local ok, errs = curve.expand_board(def)
      A.falsy(ok)
      A.truthy(tostring(errs[1]):find("walls[2]", 1, true), tostring(errs[1]))
    end)
  end)

  describe("ramp.height_at and slope_at", function()
    local function build(over)
      local r = { id = "t", width = 40, height = 30,
                  entry_slope = 0.3, exit_slope = 0.3,
                  path = { 0, 0, 0, -600 } }
      for k, v in pairs(over or {}) do r[k] = v end
      local def = { ramps = { r } }
      ramp.prepare(def)
      return def.ramps[1].geom
    end

    it("is flat on the playfield at both feet", function()
      local g = build()
      A.near(0, ramp.height_at(g, 0), 1e-9)
      A.near(0, ramp.height_at(g, g.length), 1e-9)
      A.near(0, ramp.slope_at(g, 0), 1e-9, "the ramp starts with a lip")
      A.near(0, ramp.slope_at(g, g.length), 1e-9, "the ramp ends with a lip")
    end)

    it("reaches its full crown and holds it", function()
      local g = build()
      A.near(30, ramp.height_at(g, g.rise), 1e-6)
      A.near(30, ramp.height_at(g, g.length / 2), 1e-6)
      A.near(0, ramp.slope_at(g, g.length / 2), 1e-9, "the crown is not flat")
    end)

    it("peaks at exactly the slope it was authored with", function()
      -- entry_slope is defined as the STEEPEST gradient on the climb, which is
      -- what `rise = 1.5 * height / slope` in core/ramp.lua buys.
      local g = build({ entry_slope = 0.24 })
      local peak = 0
      for i = 0, 400 do peak = math.max(peak, ramp.slope_at(g, g.rise * i / 400)) end
      A.near(0.24, peak, 1e-3)
    end)

    it("climbs where +s climbs and descends where it descends", function()
      local g = build()
      A.truthy(ramp.slope_at(g, g.rise / 2) > 0)
      A.truthy(ramp.slope_at(g, g.length - g.fall / 2) < 0)
    end)
  end)

  describe("ramp.project", function()
    local def = { ramps = { { id = "t", width = 40, height = 20,
                              entry_slope = 0.3, exit_slope = 0.3,
                              path = { 100, 500, 100, 100 } } } }
    ramp.prepare(def)
    local g = def.ramps[1].geom

    it("reads off distance along and offset across", function()
      local s, lat = ramp.project(g, 100, 380)
      A.near(120, s, 1e-6)
      A.near(0, lat, 1e-6)
    end)

    it("signs the offset toward the right-hand rail", function()
      -- The path runs up the screen and y is down, so the right hand of
      -- travel points at increasing x. `geom.right` is offset the same way,
      -- and the two have to agree or sim/ measures the ball against the
      -- wrong rail when it decides whether to let it on.
      A.near(120, g.right[1], 1e-6, "`right` is not the right-hand rail")
      A.truthy(select(2, ramp.project(g, 112, 380)) > 0,
               "lateral sign disagrees with which rail is `right`")
      A.truthy(select(2, ramp.project(g, 88, 380)) < 0)
    end)

    it("runs negative before the mouth and past the length after it", function()
      -- This is the safety net: sim/ takes the ball off the ramp the moment
      -- its projection leaves [0, length], so it can never be stranded on a
      -- layer whose geometry it has walked off the end of.
      A.truthy(select(1, ramp.project(g, 100, 540)) < 0)
      A.truthy(select(1, ramp.project(g, 100, 60)) > g.length)
    end)
  end)
end
