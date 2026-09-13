--- Report board geometry defects with coordinates. Pure Lua, no LÖVE.
---   luajit scripts/geometry.lua      (or: make geometry)
package.path = "./?.lua;./?/init.lua;" .. package.path

local boards = require("data.tables.init").load()
local clean, lines = require("core.geometry").report(boards)

if clean then
  print("geometry: both boards clean")
  os.exit(0)
end
print(("geometry: %d defect(s)"):format(#lines))
for _, l in ipairs(lines) do print("  " .. l) end
os.exit(1)
