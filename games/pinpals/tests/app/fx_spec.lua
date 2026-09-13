--- app/fx.lua's state machine, in the bare interpreter.
---
--- fx only touches love.* inside its draw functions, so everything that can
--- actually go wrong over a long session -- unbounded growth, a trail that
--- never lets go, shake that never settles -- is testable with no window, no
--- physics and no graphics at all.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local C      = require("core.constants")
  local FX     = require("app.fx")
  local boards = require("data.tables.init").load()

  --- The two fields fx reads off a match: board definitions, and where the
  --- ball is right now. Building this by hand rather than running physics
  --- keeps the whole suite in the fast gate.
  --- Carries per-board cross-board state as well, because fx watches it for
  --- the §7 panel flash and a stub without it exercises less than it looks.
  local function fake_match(phase, ball_a)
    return {
      defs  = boards,
      state = {
        phase = phase or "play", stats = { relay = 0 },
        boards = { a = { meters = { vault = 0 }, lit = { bumpers = 0 } },
                   b = { meters = { vault = 0 }, lit = { bumpers = 0 } } },
      },
      cur   = { a = { ball = ball_a }, b = { ball = nil } },
    }
  end

  local function impact(board, what, x, y, impulse)
    return { kind = "impact", board = board, what = what,
             x = x, y = y, impulse = impulse }
  end

  describe("fx bounds", function()
    it("never grows its effect lists without bound", function()
      -- A long session emits hundreds of thousands of impacts. Nothing culls
      -- these except the caps, so this is a memory-leak test, not a look test.
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      for _ = 1, 400 do
        local burst = {}
        for _ = 1, 20 do
          burst[#burst+1] = impact("a", "wall", 200, 400, 60)
        end
        FX.update(m, burst, 1 / 60)
      end
      local st = FX.stats()
      A.truthy(st.rings  <= 48,  "rings unbounded: "  .. st.rings)
      A.truthy(st.sparks <= 160, "sparks unbounded: " .. st.sparks)
    end)

    it("caps the trail and lets it run out when the ball goes", function()
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      for _ = 1, 200 do FX.update(m, {}, 1 / 60) end
      A.truthy(FX.stats().trail_a <= 22, "trail unbounded")
      A.truthy(FX.stats().trail_a > 0,   "no trail while the ball is in play")

      -- Ball gone (transit or drain): the tail must retract, not blink out
      -- and not persist forever on a board nobody is looking at.
      local gone = fake_match("transit", nil)
      for _ = 1, 60 do FX.update(gone, {}, 1 / 60) end
      A.equal(0, FX.stats().trail_a, "the trail outlived the ball")
    end)
  end)

  describe("shake", function()
    it("settles to nothing on its own", function()
      -- Shake that never reaches zero is a permanently blurred screen.
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      FX.update(m, { { kind = "drain", board = "a" } }, 1 / 60)
      A.truthy(FX.stats().shake > 1, "a drain produced no shake")
      for _ = 1, 120 do FX.update(m, {}, 1 / 60) end
      A.equal(0, FX.stats().shake, "shake never settled")
    end)

    it("stays clamped when impacts pile up", function()
      -- Otherwise a multi-contact frame accumulates into an unwatchable jolt.
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      local burst = {}
      for _ = 1, 40 do burst[#burst+1] = impact("a", "wall", 200, 400, 220) end
      FX.update(m, burst, 1 / 60)
      A.truthy(FX.stats().shake <= 11, "shake accumulated past its clamp")
    end)
  end)

  describe("bumper pulse", function()
    it("lights the bumper that was actually hit", function()
      FX.reset()
      local m = fake_match("play", { x = 95, y = 250 })
      local b = boards.a.bumpers[2]
      FX.update(m, { impact("a", "bumper", b.x + b.r, b.y, 90) }, 1 / 60)
      A.truthy(FX.hit_pulse("a", "bumper", 2) > 0, "the struck bumper did not light")
      A.equal(0, FX.hit_pulse("a", "bumper", 1), "an untouched bumper lit up")
      A.equal(0, FX.hit_pulse("b", "bumper", 2), "the pulse crossed to the other board")
    end)

    it("fades out", function()
      FX.reset()
      local m = fake_match("play", { x = 95, y = 250 })
      local b = boards.a.bumpers[1]
      FX.update(m, { impact("a", "bumper", b.x, b.y - b.r, 90) }, 1 / 60)
      for _ = 1, 40 do FX.update(m, {}, 1 / 60) end
      A.equal(0, FX.hit_pulse("a", "bumper", 1), "a bumper stayed lit")
    end)
  end)

  describe("impact strength", function()
    it("scales an effect with the hit, not linearly with the impulse", function()
      -- Impulses span 0.3 to 227. A linear map makes one bumper hit dwarf
      -- every other effect on the board.
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      FX.update(m, { impact("a", "wall", 200, 400, C.IMPACT_MIN_IMPULSE) }, 1 / 60)
      local soft = FX.stats().sparks
      FX.reset()
      FX.update(m, { impact("a", "wall", 200, 400, 200) }, 1 / 60)
      local hard = FX.stats().sparks
      A.truthy(hard > soft, "a hard hit made no more sparks than a soft one")
      A.equal(0, soft, "the quietest possible contact still threw sparks")
    end)
  end)
  describe("cross-board panel flash (§7)", function()
    it("flags the board whose state changed, and only that one", function()
      -- "The dormant board is shown as a small panel that lights up when
      -- cross-board state changes, so you always know what you've built up
      -- over there." Without this the loop is two numbers moving somewhere
      -- nobody is looking.
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      FX.update(m, {}, 1 / 60)                       -- establish a baseline
      A.equal(0, FX.panel_flash("b"), "flashed before anything changed")
      m.state.boards.b.meters.vault = 3
      FX.update(m, {}, 1 / 60)
      A.truthy(FX.panel_flash("b") > 0, "a charged vault did not flag its panel")
      A.equal(0, FX.panel_flash("a"), "the flash crossed to the other board")
    end)

    it("fades, so an old change does not look like a new one", function()
      FX.reset()
      local m = fake_match("play", { x = 200, y = 400 })
      FX.update(m, {}, 1 / 60)
      m.state.boards.a.lit.bumpers = 12
      FX.update(m, {}, 1 / 60)
      A.truthy(FX.panel_flash("a") > 0)
      for _ = 1, 90 do FX.update(m, {}, 1 / 60) end
      A.equal(0, FX.panel_flash("a"), "the panel stayed lit")
    end)
  end)

end
