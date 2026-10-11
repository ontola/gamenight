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
	root.disable_3d = true
	room = load("res://tests/display_probe.gd").new()
	root.add_child(room)
	room.client.set_process(false) # This display test has no host/reconnect lifecycle.
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
	# Deterministic focus adapter: Xvfb/Godot can cache a stale focus flag.
	# Window geometry is native; foreground-lock behavior needs Windows testing.
	room.reported_focus = true
	room._display_active = false
	var before: int = room.focus_requests
	room._focus_changed(true)
	if room.focus_requests != before + 1:
		failed = true
		push_error("DISPLAY_TEST: stale focused flag skipped explicit host handoff")
	room._focus_changed(true)
	if room.focus_requests != before + 1:
		failed = true
		push_error("DISPLAY_TEST: duplicate host grant requested focus again")
	room.reported_focus = false
	# Deny the initial handoff as Windows does before the game grants rights.
	room._display_active = false
	room.allow_focus = false
	before = room.focus_requests
	room._focus_changed(true)
	await create_timer(0.25).timeout
	if room.focus_requests < before + 2 or room._window_has_focus():
		failed = true
		push_error("DISPLAY_TEST: denied host handoff was not retried")
	room.allow_focus = true
	await create_timer(0.25).timeout
	if not room._window_has_focus():
		failed = true
		push_error("DISPLAY_TEST: delayed host handoff never acquired focus")
	room.reported_focus = false
	root.focus_exited.emit()
	await settle()
	before = room.focus_requests
	await create_timer(0.25).timeout
	if room._window_has_focus() or room.focus_requests != before:
		failed = true
		push_error("DISPLAY_TEST: completed handoff fought subsequent Alt-Tab")
	# A denied handoff has a deadline even when no native focus event arrives.
	room._display_active = false
	room.allow_focus = false
	room._focus_changed(true)
	await create_timer(1.2).timeout
	before = room.focus_requests
	await create_timer(0.2).timeout
	if room.focus_requests != before or room._window_has_focus():
		failed = true
		push_error("DISPLAY_TEST: denied handoff exceeded its deadline")
	room._display_active = false
	room._focus_changed(true)
	room.client.active = false
	room._focus_changed(false)
	before = room.focus_requests
	await create_timer(0.25).timeout
	if room.focus_requests != before or root.mode != Window.MODE_MINIMIZED:
		failed = true
		push_error("DISPLAY_TEST: deactivation did not cancel handoff")
	room.allow_focus = true
	room.client.active = true
	room._focus_changed(true)
	await settle()
	room.reported_focus = null
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
	room._links.free()
	room._pickup.free()
	room.free()
	quit(1 if failed else 0)
