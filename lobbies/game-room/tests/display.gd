extends SceneTree
## Requires a desktop window manager (e.g. Xvfb + Openbox). Never joins a party.
var room: Node3D
var failed := false

func _initialize() -> void:
	OS.set_environment("GAMENIGHT_ADDR", "127.0.0.1:1")
	OS.set_environment("GAMENIGHT_LINKS_URL", "disabled")
	OS.set_environment("GAMENIGHT_LOBBY_FULLSCREEN", "1")
	call_deferred("run")

func check_fit(label: String) -> void:
	var screen := root.current_screen
	var expected := DisplayServer.screen_get_size(screen)
	var origin := DisplayServer.screen_get_position(screen)
	var native := DisplayServer.window_get_size(root.get_window_id())
	print(label, " window=", root.size, " native=", native, " screen=", expected)
	if root.size != expected or native != expected or root.position != origin or not root.borderless or root.mode != Window.MODE_WINDOWED:
		failed = true
		push_error("DISPLAY_TEST: " + label + " did not fit the desktop")

func settle() -> void:
	for i in 8: await process_frame

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("DISPLAY_TEST requires a desktop display")
		quit(1)
		return
	# Exercise real native window state without rendering the room every frame.
	RenderingServer.render_loop_enabled = false
	room = load("res://main.tscn").instantiate()
	root.add_child(room)
	room.client.active = true
	await settle()
	check_fit("startup")
	for i in 3:
		room.client.active = false
		room._focus_changed(false)
		await settle()
		if root.always_on_top:
			failed = true
			push_error("DISPLAY_TEST: hidden lobby stayed on top")
		room.client.active = true
		room._focus_changed(true)
		await settle()
		check_fit("game return %d" % i)
		if root.has_focus() and not root.always_on_top:
			failed = true
			push_error("DISPLAY_TEST: focused lobby did not cover the taskbar")
	room._window_focus_lost()
	if root.always_on_top:
		failed = true
		push_error("DISPLAY_TEST: lobby stayed above another focused app")
	root.size = Vector2i(1280, 720)
	await settle()
	room._window_restored()
	await settle()
	check_fit("native restore")
	room._fit_fullscreen()
	room.client.active = false
	room._focus_changed(false)
	await settle()
	if root.mode != Window.MODE_MINIMIZED or root.always_on_top:
		failed = true
		push_error("DISPLAY_TEST: stale resize raised the lobby")
	print("GAME_ROOM_DISPLAY_", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
