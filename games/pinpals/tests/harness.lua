--- A ~60-line stand-in for busted, deliberately dependency-free.
--- technical-choices.md §7 specifies busted; luarocks is not usable on this
--- machine yet (it points at a missing lua5.4). The API below is the busted
--- subset we use, so swapping in the real thing later is a one-line change in
--- the runners.

local H = { passed = 0, failed = 0, failures = {}, stack = {} }

local function label()
  return table.concat(H.stack, " > ")
end

function H.describe(name, fn)
  H.stack[#H.stack + 1] = name
  fn()
  H.stack[#H.stack] = nil
end

function H.it(name, fn)
  H.stack[#H.stack + 1] = name
  local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
  if ok then
    H.passed = H.passed + 1
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = label() .. "\n    " .. err:gsub("\n", "\n    ")
  end
  H.stack[#H.stack] = nil
end

local A = {}
H.assert = A

function A.truthy(v, msg) if not v then error(msg or "expected truthy, got " .. tostring(v), 2) end end
function A.falsy(v, msg)  if v then error(msg or "expected falsy, got " .. tostring(v), 2) end end

function A.equal(exp, got, msg)
  if exp ~= got then
    error((msg and msg .. ": " or "") .. ("expected %s, got %s"):format(tostring(exp), tostring(got)), 2)
  end
end

function A.near(exp, got, tol, msg)
  tol = tol or 1e-6
  if type(got) ~= "number" or math.abs(exp - got) > tol then
    error((msg and msg .. ": " or "") .. ("expected %s +/- %s, got %s"):format(exp, tol, tostring(got)), 2)
  end
end

function A.between(lo, hi, got, msg)
  if type(got) ~= "number" or got < lo or got > hi then
    error((msg and msg .. ": " or "") .. ("expected %s..%s, got %s"):format(lo, hi, tostring(got)), 2)
  end
end

function A.error_matches(pattern, fn, msg)
  local ok, err = pcall(fn)
  if ok then error((msg and msg .. ": " or "") .. "expected an error, none raised", 2) end
  if not tostring(err):find(pattern, 1, true) then
    error((msg and msg .. ": " or "") .. ("error did not contain %q: %s"):format(pattern, tostring(err)), 2)
  end
end

function H.report(suite)
  local out = io.write
  out(("\n%s: %d passed, %d failed\n"):format(suite, H.passed, H.failed))
  for _, f in ipairs(H.failures) do out("  FAIL  " .. f .. "\n") end
  return H.failed == 0
end

function H.reset()
  H.passed, H.failed, H.failures, H.stack = 0, 0, {}, {}
end

return H
