extends Node
## Drives the real lobby against a real daemon through the same input path
## controllers use. Started by scripts/test-game-room.py with --test-flow.
## Prints GAME_ROOM_FLOW_PASS or GAME_ROOM_FLOW_FAIL <step>.

const World = preload("res://src/world.gd")
const Layout = preload("res://src/layout.gd")

var main
var capture_dir := ""

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-dir="): capture_dir = argument.trim_prefix("--capture-dir=")
	_run.call_deferred()

func _run() -> void:
	if not await _until("connected with players", func(): return main.client.connected and main.profiles.size() >= 3 and main.shelf_games().size() >= 3): return
	var ids: Array = main.profiles.keys()
	var a: String = ids[0]
	var b: String = ids[1]
	var shelf: Array = main.shelf_games()
	# Game shelf: Y queues the box on the stand, RB browses to the next one.
	var first := str(shelf[main.shelf_offset % shelf.size()].id)
	_place(a, (Layout.GAME_SHELF.x + Layout.GAME_SHELF.y) / 2)
	_press(a, World.BTN_Y)
	if not await _until("Y at the shelf queues its game", func(): return main.upcoming().any(func(e): return e.game == first)): return
	var start: int = main.shelf_offset
	_press(a, main.BTN_RB)
	if not await _until("RB browses the shelf", func(): return main.shelf_offset == (start + 1) % shelf.size()): return
	_press(a, main.BTN_LB)
	if not await _until("LB browses back", func(): return main.shelf_offset == start): return
	_press(a, main.BTN_RB)
	var second := str(shelf[(start + 1) % shelf.size()].id)
	await get_tree().create_timer(0.5).timeout  # station cooldown
	_press(a, World.BTN_Y)
	if not await _until("Y queues the browsed game", func(): return main.upcoming().back().game == second): return
	_place(a, Layout.TV_PADS[1])
	_press(a, main.BTN_RB)
	if main.shelf_offset != (start + 1) % shelf.size(): return _fail("RB away from the shelf does not browse")
	var head := str(main.upcoming()[0].game)
	await _capture("queue")
	# TV pad: start the head of the queue.
	_press(a, World.BTN_Y)
	if not await _until("Y on Start launches the queue head", func(): return _phase(head) == "running"): return
	main.client.open_lobby()
	if not await _until("opening the lobby pauses the game", func(): return _phase(head) == "paused"): return
	_place(a, Layout.TV_PADS[0])
	if main.station_for(a).get("action") != "resume": return _fail("left pad offers Resume while a game is paused")
	_press(a, World.BTN_Y)
	if not await _until("Y on Resume resumes the game", func(): return _phase(head) == "running"): return
	main.client.open_lobby()
	if not await _until("lobby open again", func(): return _phase(head) == "paused"): return
	# Phone profile waiting at a door: an unlinked player picks it up.
	if not await _until("a phone profile waits at a door", func(): return main.pending_profiles().size() > 0): return
	await _capture("door")
	_place(b, Layout.PROFILE_DOORS[0])
	if not main.station_for(b).get("enabled", false): return _fail("door offers pickup to an unlinked player")
	_press(b, World.BTN_Y)
	if not await _until("Y at the door links the profile", func(): return main.links.get("linked", []).has(b)): return
	if not await _until("picked up profile name reaches the party", func(): return str(main.profiles.get(b, {}).get("name", "")) == "Sanne"): return
	# Exit door: Y leaves the party.
	var c: String = ids[2]
	_place(c, Layout.EXIT_DOOR)
	_press(c, World.BTN_Y)
	if not await _until("Y at the exit door leaves", func(): return not main.profiles.has(c)): return
	if not main.world.players.has(a) or main.world.players.has(c): return _fail("world players follow the party")
	await _capture("live")
	print("GAME_ROOM_FLOW_PASS")
	_finish()

func _phase(game: String) -> String:
	var session: Variant = main.party.get("active_session")
	if session is Dictionary and str(session.get("game")) == game: return str(session.get("phase"))
	return ""

func _place(id: String, x: float) -> void:
	var p: Dictionary = main.world.players[id]
	p.x = x; p.y = 0.0; p.vx = 0.0; p.vy = 0.0; p.grounded = true; p.sleeping = false

func _press(id: String, button: int) -> void:
	main.input(id, button, Vector2.ZERO)
	main.input(id, 0, Vector2.ZERO)

func _until(step: String, check: Callable, seconds := 15.0) -> bool:
	# Software rendering in CI captures is slow; give it room.
	if not capture_dir.is_empty(): seconds *= 6
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		if check.call():
			print("ok: ", step)
			return true
		await get_tree().create_timer(0.05).timeout
	_fail(step)
	return false

func _fail(step: String) -> void:
	print("GAME_ROOM_FLOW_FAIL ", step, " links=", JSON.stringify(main.links).left(400))
	_finish()

func _finish() -> void:
	# Ending the party stops the daemon too, so a failed run is not restarted.
	main.client.quit_party()
	await get_tree().create_timer(3.0).timeout
	get_tree().quit()

func _capture(name: String) -> void:
	if capture_dir.is_empty() or DisplayServer.get_name() == "headless": return
	await get_tree().create_timer(1.2).timeout
	await RenderingServer.frame_post_draw
	var path := capture_dir.path_join("game-room-%s.png" % name)
	print("LOBBY_CAPTURE ", path, " ", get_viewport().get_texture().get_image().save_png(path))
