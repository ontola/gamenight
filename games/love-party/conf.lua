function love.conf(t)
  -- Opt in before creating the SDL window; Windows otherwise scales a
  -- virtual 1080p window across a 4K display at 200% desktop scaling.
  local ok, ffi = pcall(require, "ffi")
  if ok and ffi.os == "Windows" then
    pcall(function()
      ffi.cdef[[int SetProcessDpiAwarenessContext(void *value);]]
      ffi.load("user32").SetProcessDpiAwarenessContext(ffi.cast("void *", -4))
    end)
  end
	t.identity = "gamenight-love-party"
	t.version = "11.5"
	t.window.title = "GameNight | Party Pack"
	t.window.width, t.window.height = 1280, 800
	t.window.resizable, t.window.vsync = true, 1
    t.window.highdpi = true
    local ok, game = pcall(require, "game")
    local id = os.getenv("GNLOVE_GAME") or (ok and game.id)
    t.window.fullscreen = id == "volley-trouble" and os.getenv("GAMENIGHT") ~= "1"
    t.window.fullscreentype = "desktop"
	t.modules.physics, t.modules.video, t.modules.touch = true, false, false
	if os.getenv("GAMENIGHT") == "1" then
		t.window.borderless = true
		t.window.x, t.window.y = -10000, -10000
	end
	if os.getenv("GNLOVE_HEADLESS") == "1" then
		t.window = false
		t.modules.graphics, t.modules.audio, t.modules.sound, t.modules.joystick = false, false, false, false
	end
end
