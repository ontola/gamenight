--- app/input.lua: raw devices -> intents (§5.1, §9).
---
--- Testable in the bare interpreter because input touches love.keyboard and
--- love.joystick only through values handed to it -- a "joystick" here is
--- whatever object LÖVE passed in, and any table stands in for one.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local input = require("app.input")

  local function fresh()
    input.joysticks = {}
    return { id = "pad1" }, { id = "pad2" }
  end

  --- Assert an intent was produced, and hand it back. from_key/from_pad
  --- return Intent|nil by design -- an unbound key is not an error -- so
  --- every test that expects one has to say so.
  local function must(intent, why)
    A.truthy(intent, why or "expected an intent, got none")
    return intent
  end

  describe("keyboard bindings", function()
    it("gives the two players disjoint keys", function()
      -- They share one keyboard (§9), so an overlap would hand one keypress
      -- to both players at once.
      local seen = {}
      for player, map in pairs(input.KEYS) do
        for key in pairs(map) do
          A.equal(nil, seen[key],
                  ("key %q is bound for both players"):format(key))
          seen[key] = player
        end
      end
    end)

    it("maps a key to the right player's intent", function()
      local it1 = must(input.from_key("a", true, 7))
      A.equal(1, it1.player)
      A.equal("flip_left", it1.action)
      A.equal(7, it1.tick)
      A.equal(2, must(input.from_key("right", true, 1)).player)
      A.equal(nil, input.from_key("q", true, 1), "an unbound key made an intent")
    end)
  end)

  describe("gamepads", function()
    it("assigns pads to players in connection order", function()
      local p1, p2 = fresh()
      input.attach(p1); input.attach(p2)
      A.equal(1, must(input.from_pad(p1, "leftshoulder", true, 1)).player)
      A.equal(2, must(input.from_pad(p2, "leftshoulder", true, 1)).player)
    end)

    it("does not renumber the other player when one pad disconnects", function()
      -- The bug this test was written for: detach used table.remove, which
      -- shifts player 2's pad into slot 1. Player 2 would silently start
      -- driving player 1's board -- their flippers, their devices, the wrong
      -- half of a two-player game -- because a battery died.
      local p1, p2 = fresh()
      input.attach(p1); input.attach(p2)
      input.detach(p1)
      A.equal(2, must(input.from_pad(p2, "leftshoulder", true, 1),
                      "player 2's pad stopped working entirely").player,
              "player 2's pad was renumbered when player 1 unplugged")
    end)

    it("gives a reconnecting pad the empty slot", function()
      local p1, p2 = fresh()
      input.attach(p1); input.attach(p2)
      input.detach(p1)
      local p3 = { id = "pad3" }
      input.attach(p3)
      A.equal(1, must(input.from_pad(p3, "leftshoulder", true, 1),
                      "a reconnecting pad produced nothing").player,
              "a reconnecting pad did not take the free slot")
      A.equal(2, must(input.from_pad(p2, "leftshoulder", true, 1)).player,
              "the surviving player moved")
    end)

    it("ignores a third pad and unbound buttons", function()
      local p1, p2 = fresh()
      input.attach(p1); input.attach(p2)
      input.attach({ id = "pad3" })
      A.equal(nil, input.from_pad({ id = "pad3" }, "leftshoulder", true, 1))
      A.equal(nil, input.from_pad(p1, "start", true, 1), "an unbound button fired")
    end)
  end)
end
