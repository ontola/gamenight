--- The board loader, tested for the one property hot reload rests on: calling
--- it twice re-runs the board chunks instead of handing back what `require`
--- cached the first time. Everything else here is the failure path, because a
--- watcher that can kill a playtest with a half-typed number is worse than no
--- watcher at all.
---
--- `package.preload` stands in for the board files. A fixture file that fails
--- to compile cannot live in tests/ -- `make lint` and `make types` both read
--- everything in there, and a deliberately broken file would fail the gates it
--- is meant to be tested by.

return function(H)
  local describe, it, A = H.describe, H.it, H.assert

  local init = require("data.tables.init")
  local REAL = { a = init.MODULES.a, b = init.MODULES.b }

  --- Point the loader at fixtures, run fn, and put it back whatever happens.
  local function with_modules(mods, fn)
    init.MODULES = mods
    local ok, err = pcall(fn)
    init.MODULES = { a = REAL.a, b = REAL.b }
    if not ok then error(err, 0) end
  end

  --- A stand-in board that validates. Built as a shallow copy of the real one
  --- rather than by hand: a board that passes validation is a hundred lines of
  --- flippers, devices, a tube and an entry, and hand-rolling one here would
  --- be a second copy of the board format to keep in step with core/validate.
  --- Fresh table every call, which is what the cache test compares.
  local function fixture(id)
    local out = {}
    for k, v in pairs(require(REAL[id])) do out[k] = v end
    return out
  end

  describe("board loader", function()
    it("names the files behind the board set", function()
      local paths = init.sources()
      A.equal(2, #paths)
      for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        A.truthy(f, p .. " is watched but does not exist")
        if f then f:close() end
      end
    end)

    it("re-runs the board chunks rather than returning the require cache",
       function()
      local runs = 0
      with_modules({ a = "spec.reload.a", b = "spec.reload.b" }, function()
        package.preload["spec.reload.a"] = function()
          runs = runs + 1
          return fixture("a")
        end
        package.preload["spec.reload.b"] = function() return fixture("b") end

        local first  = init.try_load()
        local second = init.try_load()
        A.truthy(first, "first load")
        A.truthy(second, "second load")
        A.equal(2, runs, "the second load re-read the file")
        -- Different tables, or the game would keep drawing the old numbers.
        if first and second then A.truthy(first.a ~= second.a) end
      end)
      package.preload["spec.reload.a"] = nil
      package.preload["spec.reload.b"] = nil
    end)

    it("reports a board that will not compile instead of raising", function()
      with_modules({ a = "spec.reload.bad", b = "spec.reload.b" }, function()
        package.preload["spec.reload.bad"] = function() error("kaboom", 0) end
        package.preload["spec.reload.b"] = function() return fixture("b") end

        local boards, errs = init.try_load()
        A.falsy(boards)
        A.equal(1, #errs)
        ---@cast errs string[]
        A.truthy(errs[1]:find("board a"), errs[1])
        A.truthy(errs[1]:find("kaboom"), errs[1])
      end)
      package.preload["spec.reload.bad"] = nil
      package.preload["spec.reload.b"] = nil
    end)

    it("reports a board that compiles but does not validate", function()
      with_modules({ a = "spec.reload.thin", b = "spec.reload.b" }, function()
        package.preload["spec.reload.thin"] = function()
          local b = fixture("a")
          b.walls = nil                      -- a board with no geometry at all
          return b
        end
        package.preload["spec.reload.b"] = function() return fixture("b") end

        local boards, errs = init.try_load()
        A.falsy(boards)
        A.truthy(#errs > 0)
        A.truthy(table.concat(errs, " "):find("board a"), table.concat(errs, " "))
      end)
      package.preload["spec.reload.thin"] = nil
      package.preload["spec.reload.b"] = nil
    end)

    it("leaves nothing poisoned behind a failed load", function()
      with_modules({ a = "spec.reload.bad2", b = "spec.reload.b" }, function()
        package.preload["spec.reload.bad2"] = function() error("kaboom", 0) end
        package.preload["spec.reload.b"] = function() return fixture("b") end
        init.try_load()
      end)
      package.preload["spec.reload.bad2"] = nil
      package.preload["spec.reload.b"] = nil

      -- The real boards still load, and load clean: a failed reload must not
      -- be able to leave a half-required module for the next one to trust.
      local boards, errs = init.try_load()
      A.truthy(boards, errs and table.concat(errs, "; "))
      ---@cast boards table
      A.equal("a", boards.a.id)
      A.equal("b", boards.b.id)
    end)
  end)
end
