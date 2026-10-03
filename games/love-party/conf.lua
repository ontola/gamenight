function love.conf(t)
	t.identity = "gamenight-love-party"
	t.version = "11.5"
	t.window.title = "GameNight | Party Pack"
	t.window.width, t.window.height = 1280, 800
	t.window.resizable, t.window.vsync = true, 1
	t.modules.physics, t.modules.video, t.modules.touch = false, false, false
	if os.getenv("GAMENIGHT") == "1" then
		t.window.borderless = true
		t.window.x, t.window.y = -10000, -10000
	end
	if os.getenv("GNLOVE_HEADLESS") == "1" then
		t.window = false
		t.modules.graphics, t.modules.audio, t.modules.sound, t.modules.joystick = false, false, false, false
	end
end
