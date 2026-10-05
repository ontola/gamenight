extends SceneTree
## Requires a desktop display. Does not connect to the running party.
var view: Control
var failed := false
func _initialize() -> void:
	OS.set_environment("GAMENIGHT_ADDR","127.0.0.1:1")
	OS.set_environment("GAMENIGHT_LOBBY_FULLSCREEN","1")
	call_deferred("run")
func check_fit(label: String) -> void:
	var window := view.get_window()
	var screen := window.current_screen
	var expected := DisplayServer.screen_get_size(screen)
	var native := DisplayServer.window_get_size(window.get_window_id())
	var viewport := window.get_visible_rect().size
	print(label," window=",window.size," native=",native," screen=",expected," layout=",view.size," viewport=",viewport)
	if window.size != expected or native != expected or not view.size.is_equal_approx(viewport) or not window.borderless:
		failed = true
		push_error("DISPLAY_TEST: "+label+" did not fit the display")
func settle() -> void:
	for i in 8: await process_frame
func run() -> void:
	view = load("res://lobby/main.tscn").instantiate()
	root.add_child(view)
	view.client.active = true
	await settle()
	check_fit("startup")
	for i in 3:
		view.client.active = false
		view._focus_changed(false)
		await settle()
		view.client.active = true
		view._focus_changed(true)
		await settle()
		check_fit("game return %d" % i)
		if not root.always_on_top and root.has_focus():
			failed = true
			push_error("DISPLAY_TEST: focused lobby did not cover the taskbar")
	view._window_focus_lost()
	if root.always_on_top:
		failed = true
		push_error("DISPLAY_TEST: lobby stayed above another focused app")
	# Windows restore can use the old windowed rectangle. Exercise that path
	# independently from a host focus message.
	root.size = Vector2i(1280,720)
	await settle()
	view._window_restored()
	await settle()
	check_fit("native restore")
	# A queued resize must not raise the lobby again after a game takes focus.
	view._fit_fullscreen()
	view.client.active = false
	view._focus_changed(false)
	await settle()
	if root.mode != Window.MODE_MINIMIZED or root.always_on_top:
		failed = true
		push_error("DISPLAY_TEST: stale resize raised the lobby")
	print("LOBBY_DISPLAY_", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
