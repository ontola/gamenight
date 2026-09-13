return function(H)
  local input = require("app.input")
  local A = H.assert
  H.describe("party seat input", function()
    H.it("keeps sparse seats, ignores AI and extra seats, and uses party names", function()
      local a, b = {}, {}
      input.bind_seats({
        { index = 0, occupant = { kind = "ai" } },
        { index = 1, occupant = { kind = "local", player_id = "ada" } },
        { index = 2, occupant = { kind = "local", player_id = "extra" } },
      }, { { id = "ada", name = "Ada" } }, { a, b })
      A.falsy(input.from_key("a", true, 0))
      A.falsy(input.from_pad(a, "a", true, 0))
      A.equal(2, assert(input.from_pad(b, "a", true, 0)).player)
      A.equal(2, assert(input.from_key("left", true, 0)).player)
      A.equal("Ada", input.legend(2).name)
      A.truthy(input.legend(1).empty)
      input.standalone()
    end)
    H.it("does not duplicate pads and keeps reconnects in occupied seats", function()
      local a, b = {}, {}
      input.bind_seats({ { index = 1, occupant = { kind = "remote" } } }, {}, {})
      A.equal(2, input.attach(a))
      A.equal(2, input.attach(a))
      A.falsy(input.attach(b))
      input.detach(a)
      A.equal(2, input.attach(b))
      A.falsy(input.from_pad(a, "a", true, 0))
      input.standalone()
    end)
    H.it("clears devices on replay and leaves empty parties inactive", function()
      input.bind_seats({}, {}, { {}, {} })
      A.falsy(input.from_key("a", true, 0))
      A.falsy(input.from_key("left", true, 0))
      A.falsy(input.attach({}))
      input.standalone()
      A.truthy(input.from_key("a", true, 0))
    end)
  end)
end
