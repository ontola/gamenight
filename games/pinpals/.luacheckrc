-- Lint gate for §7. Run via `make lint`, which `make check` depends on.
--
-- Both entry points are LuaJIT: `make test-core` runs bare `luajit`, and LÖVE
-- embeds it too. So 5.1 semantics plus the JIT extensions, never 5.4/5.5.
std = "luajit"

-- `love` is the only injected global, and §11's layer rules decide who may see
-- it. Declaring it per-directory rather than globally makes luacheck a second
-- guard on those boundaries alongside scripts/check_layers.sh: core/ never
-- declares it, so any `love.` that drifts in there is an undefined-variable
-- error rather than a silent dependency.
files["sim"]      = { read_globals = { "love" } }  -- love.physics only (§11)
files["app"]      = { read_globals = { "love" } }
-- Unmodified MIT dependency: upstream intentionally leaves these arguments unused.
files["app/vendor/json.lua"] = { ignore = { "212", "213" } }
files["tests"]    = { read_globals = { "love" } }

-- main.lua and conf.lua define the love.* callbacks, so they write the table
-- rather than only reading it.
files["main.lua"] = { globals = { "love" } }
files["conf.lua"] = { globals = { "love" } }

-- core/ is deliberately absent: it is pure Lua and gets no `love` at all.
