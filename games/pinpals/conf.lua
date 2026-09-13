--- §7: agents must be able to prove their work without a human looking at a
--- screen. `love . --test` disables the window entirely; love.physics needs
--- none, so the whole simulation is testable headless.

local function has_flag(name)
  for _, v in ipairs(arg or {}) do if v == name then return true end end
  return os.getenv("PINPALS_HEADLESS") == "1"
end

function love.conf(t)
  t.identity           = "pinpals"
  t.version            = "11.5"          -- §2.4: pinned, verified at setup
  t.window.title       = "Pinpals - prototype"
  t.window.width       = 1000
  t.window.height      = 780
  t.window.resizable   = false
  t.window.vsync       = 1
  t.window.msaa        = 4
  if os.getenv("GAMENIGHT") == "1" and not has_flag("--test") then
    -- Warm off-screen; the adapter minimizes immediately, then centers on start.
    t.window.x = -10000
    t.window.y = -10000
  end

  t.modules.joystick   = true
  t.modules.physics    = true
  -- app/audio.lua synthesizes its whole kit at load, so these buy us sound
  -- without adding a single asset file. Switched off again under --test
  -- below: the headless runner has no output device.
  t.modules.audio      = true
  t.modules.sound      = true
  t.modules.video      = false
  t.modules.touch      = false

  if has_flag("--test") then
    t.modules.window   = false
    t.modules.graphics = false
    t.modules.joystick = false
    t.modules.audio    = false
    t.modules.sound    = false
  end
end
