-- Managed play uses the common GameNight runner. Standalone authoring stays local.
if os.getenv("GAMENIGHT") == "1" then
  assert(love.filesystem.mount(love.filesystem.getSourceBaseDirectory() .. "/love-party", "", false))
  assert(love.filesystem.load("main.lua"))()
  return
end

--- Entry point. Three modes:
---   love .            play
---   love . --test     headless physics tests, results to stdout (§7)
---   love . --shot N   run N fixed steps, screenshot, quit (§7 visual check)
---
--- Play mode watches data/tables/*.lua and reloads the boards when one
--- changes (--no-hot turns that off; key 3 forces one). Board layouts are data,
--- and every board bug so far has been a coordinate -- a coordinate you can
--- only judge by looking at it, which means the loop that matters is edit,
--- save, look. Restarting the game for each nudge put a build in the middle
--- of that loop.

-- Redirected to a file or a pipe, stdout is fully buffered and nothing this
-- game prints appears until it exits -- which is no use to a hot reload, whose
-- whole job is to tell you something in the second after you saved.
io.stdout:setvbuf("line")

local C = require("core.constants")

local mode, shot_ticks, shot_open, shot_pass = "play", 240, false, false
local hot_on, shot_coords = true, nil

for i, v in ipairs(arg or {}) do
  if v == "--test" then mode = "test" end
  if v == "--shot" then mode = "shot"; shot_ticks = tonumber(arg[i + 1]) or 240 end
  if v == "--open" then shot_open = true end
  if v == "--pass" then shot_open = true; shot_pass = true end
  if v == "--no-hot" then hot_on = false end
  -- `--shot 1 --coords b` prints a board's coordinates to a PNG: the same
  -- overlay F2 draws, but capturable, diffable and pinnable next to the file.
  if v == "--coords" then shot_coords = (arg[i + 1] == "b") and "b" or "a" end
end

local match, render, input, audio, fx, record, boards
local hot = require("app.hotreload")
local debug_on = false
local paused = false
local shot_done = false

--- The window in conf.lua is a floor, not a choice: 1000x780 was sized around
--- a 768px board, and a taller board simply gets drawn smaller inside it. Take
--- whatever the display can spare instead, so the playfield grows with the
--- screen. app/render.lua reads the result rather than assuming it.
---
--- Done here and not in love.conf because love.window does not exist yet at
--- conf time, so the desktop size cannot be asked for there.
local function fit_window()
  if not (love.window and love.window.getDesktopDimensions) then return end
  local dw, dh = love.window.getDesktopDimensions()
  if not dw or dw == 0 then return end
  local w = math.min(1360, math.max(1000, math.floor(dw * 0.86)))
  local h = math.min(1040, math.max(780,  math.floor(dh * 0.86)))
  local cw, ch = love.window.getMode()
  if w == cw and h == ch then return end
  -- setMode replaces the whole flag set, so every flag conf.lua chose has to
  -- be restated or vsync and MSAA quietly turn themselves off.
  local flags = { resizable = false, vsync = 1, msaa = 4 }
  if os.getenv("GAMENIGHT") == "1" then flags.x, flags.y = -10000, -10000 end
  love.window.setMode(w, h, flags)
end

function love.load()
  love.physics.setMeter(C.METER)      -- §4.2: set once, before any world
  boards = require("data.tables.init").load()
  if mode ~= "test" then fit_window() end

  if mode == "test" then
    local ok = require(os.getenv("PINPALS_SUITE") or "tests.run_sim")()
    love.event.quit(ok and 0 or 1)
    return
  end

  local Match = require("sim.match")
  -- A played session gets its own seed so no two games serve alike; --shot
  -- keeps the fixed one, because a screenshot has to be the same picture
  -- every time it is taken.
  match  = Match.new(boards, mode ~= "shot" and os.time() or nil)
  render = require("app.render")
  input  = require("app.input")
  audio  = require("app.audio")
  fx     = require("app.fx")
  record = require("app.record")
  render.load(boards)
  render.attach_fx(fx)
  audio.load()          -- no-ops if the audio modules are off (--shot, --test)

  -- §7's visual check is only worth anything if what it captures is what the
  -- player sees. fx state exists only because something advanced it, so the
  -- shot path drives it exactly as love.update does -- otherwise every
  -- screenshot shows a game with no trail, no sparks and no lit bumpers.
  local function run_with_fx(n)
    for _ = 1, n do
      match:run(1)
      fx.update(match, match:drain_events(), C.FIXED_DT)
    end
  end

  if mode == "shot" then
    -- Stand in for an operator holding the gate open, so a screenshot can
    -- catch the pass rather than only the safe return loop.
    if shot_open then
      for _, b in pairs(match.state.boards) do if b.devices.gate then b.devices.gate.commanded = true end end
    end
    -- --pass puts the ball up the ramp on cue, so the transit and the
    -- handed-over camera can both be captured deterministically.
    if shot_pass then
      run_with_fx(200)
      match.boards[match.state.active]:spawn(
        boards[match.state.active].tube.mouth.x, 520, 0, -C.SERVE_SPEED)
      run_with_fx(math.max(0, shot_ticks - 200))
    else
      run_with_fx(shot_ticks)
    end
    return
  end

  for _, js in ipairs(love.joystick.getJoysticks()) do input.attach(js) end
  -- §5.1: the intent stream makes a session recordable for free. Only in
  -- play mode -- --test and --shot never touch the disk.
  record.start(boards, match.seed)

  if hot_on then
    local paths = require("data.tables.init").sources()
    hot.watch(paths)
    print("hot reload: watching " .. table.concat(paths, ", ") .. "  (--no-hot to disable)")
  end
end

---------------------------------------------------------------------------
-- Board reload (§ boards are data, and data you can only judge by looking)
---------------------------------------------------------------------------

--- Retire the running match and start a fresh one on `boards`. The bank comes
--- first: those numbers leave with the Match that produced them, and the
--- session log would otherwise report the wrong game.
local function restart_match()
  record.restart(match)
  -- A fresh seed, drawn from the retiring match's own generator: `os.time()`
  -- would hand two restarts inside one second the same serves.
  match = require("sim.match").new(boards, match.rng:random(1, 2 ^ 31 - 1))
  fx.reset()
end

--- Report a reload's outcome to the screen and the terminal at once. The
--- screen is where the person is; the terminal is where the whole list fits.
local function announce(head, lines, kind)
  render.set_notice(head, lines, kind)
  print(head)
  for _, l in ipairs(lines or {}) do print("  " .. l) end
end

--- Re-read the board files. A board that will not compile or will not
--- validate leaves the running game exactly as it was and puts the error on
--- screen -- a typo mid-edit must not be able to end a playtest, or the
--- watcher is a liability rather than a tool.
---@param why string what triggered it, for the notice
---@return boolean reloaded
local function reload_boards(why)
  local fresh, errs = require("data.tables.init").try_load()
  if not fresh then
    announce("board reload failed - still playing the last good boards", errs, "error")
    return false
  end

  boards = fresh
  restart_match()
  render.load(boards)          -- board size drives every scale on screen
  render.attach_fx(fx)

  -- The geometry gate, on the spot. It is pure Lua and takes microseconds, and
  -- it is the check most likely to have something to say about an edit that
  -- just moved a wall: bowls, walls inside a flipper's arc, throats narrower
  -- than the ball. Finding that out on save beats finding it out in `make
  -- check` after a session of wondering why the ball sticks.
  local clean, lines = require("core.geometry").report(boards)
  if clean then
    announce(("boards reloaded (%s)"):format(why), {}, "ok")
  else
    announce(("boards reloaded (%s) - %d geometry defect(s)"):format(why, #lines),
             lines, "warn")
  end
  return true
end

--- Every intent goes through here, so the recording cannot miss one by
--- someone adding a fifth input path and forgetting about it.
local function push_intent(it)
  if not it then return end
  match:push(it)
  record.intent(it)
end

function love.update(dt)
  if mode ~= "play" then return end

  -- Before the step, so a reload's brand-new match is what this frame
  -- advances rather than one tick of the match that is about to be discarded.
  local changed = hot.poll(dt)
  if changed then reload_boards(changed) end

  -- P freezes the simulation and everything downstream of it -- sound,
  -- effects and the session log all follow the tick, and a recording that
  -- counted the minutes spent staring at a still board would report the
  -- operator asleep at a device they were in fact reading.
  --
  -- Two things deliberately keep running. The camera, because TAB swaps the
  -- inspected board while paused and the view has to be able to travel. And
  -- the file watcher, because a held ball next to the geometry that dropped
  -- it is exactly when you want to edit the board.
  --
  -- Intents keep queueing rather than being dropped: a flipper pressed before
  -- the pause and released during it must see both halves, or it comes back
  -- stuck up. Held into the resume, it flips on the first tick, which is what
  -- the player asked for.
  if not paused then
    match:advance(dt)
    -- Drained once and shared: audio and fx must see the same events, and
    -- whichever called drain_events() second would otherwise see none.
    local events = match:drain_events()
    audio.update(match, events)
    fx.update(match, events, dt)
    record.update(match, events)
  end
  render.update_camera(match.state, boards, dt)
end

function love.draw()
  if mode == "test" then return end

  if mode == "shot" then
    render.inspect = shot_coords
    render.update_camera(match.state, boards, 1)   -- snap the camera, no easing
    render.draw(match, { input.legend(1), input.legend(2) }, { debug = true })
    if not shot_done then
      shot_done = true
      local name = ("shot-%d.png"):format(shot_ticks)
      love.graphics.captureScreenshot(function(img)
        img:encode("png", name)
        print("screenshot: " .. love.filesystem.getSaveDirectory() .. "/" .. name)
        love.event.quit(0)
      end)
    end
    return
  end

  render.draw(match, { input.legend(1), input.legend(2) },
             { debug = debug_on, paused = paused })
end

---------------------------------------------------------------------------
-- Input -> intents. Nothing else in the codebase reads a device (§5.1).
---------------------------------------------------------------------------

function love.keypressed(key)
  if mode ~= "play" then return end
  if key == "escape" then love.event.quit() return end
  -- Number row rather than function keys: on a Mac laptop every F-key is a
  -- chord with fn, and a tool you reach for between one nudge and the next has
  -- to cost one finger.
  if key == "1" then debug_on = not debug_on return end
  if key == "2" then render.toggle_inspect(match.state.active) return end
  if key == "p" then paused = not paused return end
  if key == "tab" then render.swap_inspect() return end
  if key == "3" then
    -- A manual reload re-stamps the watcher too, or the same edit comes back
    -- a quarter of a second later as an automatic one and restarts the match
    -- a second time.
    reload_boards("key 3")
    hot.resync()
    return
  end
  if key == "r" then restart_match() return end
  push_intent(input.from_key(key, true, match.state.tick))
end

--- Click-to-copy for the coordinate overlay. The mouse does nothing in this
--- game otherwise, so it costs no binding and no mode: point at where the
--- thing should go, click, paste the pair into data/tables/*.lua.
---
--- Left copies `230, 85`, the form a polyline vertex is written in; right
--- copies `x = 230, y = 85`, the form a bumper or a device home is written in.
--- Which button is which follows the file: polylines are far and away the
--- commoner paste, so they get the button the hand is already on.
function love.mousepressed(x, y, button)
  if mode ~= "play" or (button ~= 1 and button ~= 2) then return end
  local at = render.pick_inspect(match, x, y)
  if not at then return end
  love.system.setClipboardText(button == 1 and at.text or at.keyed)
  -- Naming the point as well as the numbers: a click that snapped to a vertex
  -- 17px away copied that vertex, not the pixel under the cursor, and the
  -- notice is where that becomes visible.
  render.set_notice(("copied  %s%s"):format(button == 1 and at.text or at.keyed,
                    at.tag and ("   (" .. at.tag .. ")") or ""), nil, "ok")
end

function love.keyreleased(key)
  if mode ~= "play" then return end
  push_intent(input.from_key(key, false, match.state.tick))
end

function love.gamepadpressed(js, button)
  if mode ~= "play" then return end
  push_intent(input.from_pad(js, button, true, match.state.tick))
end

function love.gamepadreleased(js, button)
  if mode ~= "play" then return end
  push_intent(input.from_pad(js, button, false, match.state.tick))
end

function love.joystickadded(js)
  if input then input.attach(js) end
end
function love.joystickremoved(js)
  if input then input.detach(js) end
end

function love.focus() end

--- Write the playtest capture on the way out, and say where it went, so a
--- session that felt like something also produced something to read.
function love.quit()
  if mode ~= "play" or not record then return false end
  print(("\n%s\n"):format(record.summary(match)))
  local path = record.finish(match)
  if path then print("session log: " .. path .. "\n") end
  return false
end
