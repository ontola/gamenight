# technical-choices.md §7: a single `make check` must run every gate and exit
# non-zero on failure. Agents run this before claiming a task is done.

LOVE  ?= love
LUA   ?= luajit

.PHONY: check geometry test-core test-sim layers lint types run shot coords clean tools

check: layers lint types geometry test-core test-sim
	@echo "" && echo "all gates passed"

# Board geometry: bowls, walls inside a flipper's arc, throats narrower than
# the ball, devices that do not do what they claim. Static -- no physics.
geometry:
	@$(LUA) scripts/geometry.lua

# Fast gate: pure Lua, bare interpreter, no LÖVE, milliseconds.
test-core:
	@$(LUA) tests/run_core.lua

# Physics gate: headless LÖVE, window module disabled.
test-sim:
	@$(LOVE) . --test

# §11 "layer boundaries erode" — see scripts/check_layers.sh.
layers:
	@./scripts/check_layers.sh

# §7 lint gate. Config in .luacheckrc, which also encodes the §11 layer rules:
# `love` is declared for sim/, app/ and tests/ but never for core/, so a stray
# love.* in core/ trips this gate as an undefined global as well as `layers`.
#
# The tool check and the tool run are deliberately separate lines. Written as
# one `command -v luacheck && luacheck ... || echo skipped`, a real lint
# *failure* also falls into the `||` branch, prints "skipped" and exits 0 --
# the gate could never fail. §7 wants a missing tool loud, not silent.
lint:
	@command -v luacheck >/dev/null 2>&1 || { echo "lint: luacheck missing -- brew install luacheck"; exit 1; }
	@luacheck core sim app tests scripts main.lua conf.lua

# §7 static analysis. Config in .luarc.json (LuaJIT runtime, `love` global).
# --check exits non-zero on anything at or above --checklevel.
types:
	@command -v lua-language-server >/dev/null 2>&1 || { echo "types: lua-language-server missing -- brew install lua-language-server"; exit 1; }
	@lua-language-server --check . --checklevel=Warning

# One-shot toolchain install (macOS/Homebrew), so a fresh machine can run every
# §7 gate. Note luarocks tracks Homebrew's unversioned `lua`: when that formula
# jumps major version, luarocks' shebang points at a Lua that no longer exists
# and every rock command dies with "bad interpreter". `brew upgrade luarocks`
# is the fix. luacheck and lua-language-server are bottles and need no rocks.
tools:
	brew install luajit love luacheck lua-language-server luarocks

run:
	@$(LOVE) .

# §7 visual check: run N fixed steps, screenshot, quit. TICKS=1200 make shot
TICKS ?= 240
shot:
	@$(LOVE) . --shot $(TICKS)

# The F2 coordinate overlay, captured. BOARD=b make coords
BOARD ?= a
coords:
	@$(LOVE) . --shot 1 --coords $(BOARD)

clean:
	@rm -rf build
