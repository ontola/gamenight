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
	if root.size != expected or native != expected or root.position != origin or not root.borderless or root.mode != Window.MODE_WINDOWED or root.always_on_top:
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
	# Another native window must keep focus even if the host repeats its grant.
	root.gui_embed_subwindows = false
	var other := Window.new()
	other.title = "Isolated Alt-Tab target"
	other.size = Vector2i(400, 300)
	root.add_child(other)
	other.show()
	other.grab_focus()
	await settle()
	room._focus_changed(true)
	for i in 3: room._fit_fullscreen()
	await settle()
	if root.always_on_top or not other.has_focus():
		failed = true
		push_error("DISPLAY_TEST: lobby stole focus from another window")
	other.queue_free()
	await settle()
	# Focus notifications themselves do not resize or start an async restore.
	root.size = Vector2i(1280, 720)
	await settle()
	root.focus_entered.emit()
	root.focus_exited.emit()
	await settle()
	if root.size != Vector2i(1280, 720):
		failed = true
		push_error("DISPLAY_TEST: native focus triggered another fullscreen fit")
	room._fit_fullscreen()
	await settle()
	check_fit("explicit fit")
	room._fit_fullscreen()
	room.client.active = false
	room._focus_changed(false)
	await settle()
	if root.mode != Window.MODE_MINIMIZED or root.always_on_top:
		failed = true
		push_error("DISPLAY_TEST: stale resize raised the lobby")
	print("GAME_ROOM_DISPLAY_", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
