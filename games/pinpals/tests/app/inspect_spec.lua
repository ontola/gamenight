--- app/inspect.lua: the pick, which is the only part of the overlay that is
--- an answer rather than a drawing.
---
--- The def here is synthetic on purpose. The real boards are the files this
--- mode exists to edit, so a test that pinned a coordinate out of
--- data/tables/ would fail every time someone moved a bumper -- which is the
--- exact moment the overlay is in use.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local inspect = require("app.inspect")

  local DEF = {
    name = "probe", size = { w = 400, h = 800 },
    walls = { { 100, 200, 100, 300 } },
    bumpers = { { x = 300, y = 600, r = 22 } },
  }
  -- Half scale, offset: a view that catches an unapplied translate or a
  -- forgotten divide, which an identity view would not.
  local VIEW = { x = 50, y = 20, s = 0.5 }

  --- Pick at a board coordinate, optionally nudged by a few screen pixels.
  local function at(bx, by, dx, dy)
    return inspect.pick(DEF, VIEW,
                        VIEW.x + bx * VIEW.s + (dx or 0),
                        VIEW.y + by * VIEW.s + (dy or 0))
  end

  --- pick returns table|nil by design -- off the board is not an error -- so
  --- a test that expects a pick has to say so before reading a field.
  ---@return table
  local function must(p, why)
    A.truthy(p, why or "expected a pick, got none")
    return p or {}
  end

  describe("inspect.pick", function()
    it("names the board pixel under the cursor", function()
      local p = must(at(200, 320), "cursor was over the board and picked nothing")
      A.equal(200, p.x)
      A.equal(320, p.y)
      A.equal("200, 320", p.text, "clipboard text is not the pair as typed")
      A.equal("x = 200, y = 320", p.keyed, "keyed form is not as a bumper is typed")
      A.equal(nil, p.tag, "empty board pixel came back tagged")
    end)

    it("snaps to a labelled point, and copies the point not the pixel", function()
      -- 3px off a wall vertex on screen: inside SNAP, so the readout is
      -- naming the vertex and the clipboard has to agree with the readout.
      local p = must(at(100, 200, 3, -2))
      A.equal("walls[1][1]", p.tag)
      A.equal("100, 200", p.text)
      A.equal("x = 100, y = 200", p.keyed, "the two forms named different points")
      A.equal("bumpers[1]  r22", must(at(300, 600, 2, 2)).tag)
    end)

    it("stays off the numbers when the cursor is between them", function()
      -- Far enough from either wall vertex that snapping to one would be a
      -- lie about where the click was.
      A.equal(nil, must(at(160, 250)).tag)
    end)

    it("picks nothing off the board, or without a cursor", function()
      A.equal(nil, at(-60, 400), "picked left of the board")
      A.equal(nil, at(200, 900), "picked below the board")
      A.equal(nil, inspect.pick(DEF, VIEW, nil, nil), "picked with no cursor")
    end)
  end)
end
