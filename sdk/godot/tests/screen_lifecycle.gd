extends SceneTree
## Exercise managed window ordering without creating a native window or taking
## focus. The probe replaces only the platform operations, not the lifecycle.
var failures := 0

func check(condition: bool, label: String) -> void:
	if condition: print("PASS: ", label)
	else:
		push_error("FAIL: " + label)
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var ScreenProbe = load("res://tests/screen_probe.gd")
	var sdk = root.get_node("GameNight")
	var master := AudioServer.get_bus_index(&"Master")
	Engine.max_fps = 144
	sdk.launched_by_daemon = false
	var standalone = ScreenProbe.new()
	standalone._headless = false
	root.add_child(standalone)
	check(standalone.calls.is_empty() and not AudioServer.is_bus_mute(master), "standalone launch leaves its window and sound alone")
	standalone.free()

	sdk.launched_by_daemon = true
	var managed = ScreenProbe.new()
	managed._headless = false
	root.add_child(managed)
	var expected: Array = ["park", "minimize"] if OS.get_name() == "Windows" else ["minimize"]
	check(managed.calls == expected, "managed Windows warmup parks before minimizing")
	check(AudioServer.is_bus_mute(master) and Engine.max_fps == 144, "warmup mutes without throttling loading")
	sdk.ready_sent.emit("test")
	check(Engine.max_fps == managed.warm_max_fps, "ready throttles the hidden game")
	sdk.started.emit("test")
	check(managed.calls.back() == "show" and not AudioServer.is_bus_mute(master) and Engine.max_fps == 144, "start shows, unmutes and restores the frame budget")
	sdk.paused.emit("test")
	check(managed.calls.back() == "minimize" and AudioServer.is_bus_mute(master), "pause gets out of the lobby's way")
	sdk.resumed.emit("test")
	check(managed.calls.back() == "show" and not AudioServer.is_bus_mute(master), "resume restores the game")
	managed.free()

	var headless = ScreenProbe.new()
	headless._headless = true
	root.add_child(headless)
	check(headless.calls.is_empty(), "headless warmup never performs native window operations")
	headless.free()
	print("SCREEN_LIFECYCLE_RESULT ", failures, " failures")
	quit(1 if failures else 0)
