extends SceneTree
## Offline queue hierarchy test; run with -- --demo --scene=stations.
class RecordingClient extends "res://addons/gamenight/lobby.gd":
	var commands: Array = []
	func _ready() -> void: pass
	func _command(message: Dictionary) -> void: commands.append(message)

var failures := 0

func tick(main) -> void:
	main._time += 1.0 / 60.0
	main._update_loading(1.0 / 60.0)

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func _run() -> void:
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	main._links.free()
	main._pickup.free()
	main.client.free()
	var recorder := RecordingClient.new()
	main.client = recorder
	var party: Dictionary = main.party.duplicate(true)
	party.playlist.current = 0
	party.active_session = {"game": "spaceracer", "phase": "paused"}
	main.set_party(party)
	check(main.current_game().id == "spaceracer", "Current game stays on the large TV")
	check(main.upcoming()[0].game == "ballkickers", "Next preview follows the playlist cursor")
	check(main.queue_title_rows() == [{"number": 2, "title": "God Game"}, {"number": 3, "title": "Blast Party"}], "Later entries are ordered title rows, excluding the preview")
	check(main.room.screens.has("queue0") and main.room.screens.has("queue_titles"), "Next preview and title surfaces exist")
	check(not main.room.screens.has("queue1") and not main.room.screens.has("queue2"), "Later games have no cover surfaces")
	check(main.Room.NEXT_SIZE.x > 2.5 and main.Room.NEXT_SIZE.x < main.Layout.TV_SIZE.x, "Next preview is substantial but smaller than current TV")
	var p: Dictionary = main.world.players.p0
	p.x = main.Layout.stand_x(-4.95); p.y = 0.0; p.grounded = true; p.sleeping = false
	check(main.station_for("p0").kind == "queue", "Queue has its own station, separate from browsing")
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands == [{"type": "next"}], "Y at the queue starts next while the current game is paused")
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands.size() == 1, "Holding Y cannot advance twice")
	main.input("p0", 0, Vector2.ZERO)
	main.input("p0", main.World.BTN_X, Vector2.ZERO)
	check(recorder.commands[-1] == {"type": "remove_playlist_entry", "expected": party.playlist, "index": 1}, "X skips the actual upcoming entry without starting anything")
	check(main.current_game().id == "spaceracer", "Skipping preserves the current paused game")
	check(not bool(p.held & main.World.BTN_X), "Skip action does not also punch")
	check(main.room._prompts.queue.state.pressed.get("X") == 1.0, "Skip animates the floating queue X button")
	main.room._process(.18)
	check(is_equal_approx(main.room._prompts.queue.state.pressed.get("X", 0.0), .5), "Button press visibly releases over time")
	main.input("p0", 0, Vector2.ZERO)
	p.x = 0.0
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands[-1] == {"type": "close_overlay"}, "Y at TV still resumes the current game")
	main.input("p0", 0, Vector2.ZERO)
	main._station_cooldown.clear()
	main.input("p0", main.World.BTN_X, Vector2.ZERO)
	check(recorder.commands[-1] == {"type": "next"}, "X at the TV quits the current game and starts the next")
	check(not bool(p.held & main.World.BTN_X), "Quitting does not also punch")
	main.input("p0", 0, Vector2.ZERO)
	for x in [-3.1, 0.0, 3.1]:
		p.x = x; p.y = main.Layout.TV_CONSOLE[2]
		check(main.station_for("p0").get("action") == "resume", "Low console shelf offers Resume across its width")
	main._station_cooldown.clear()
	var before_resume := recorder.commands.size()
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands.size() == before_resume + 1 and recorder.commands[-1].type == "close_overlay", "Y on the low shelf resumes the current game")
	p.grounded = false
	check(main.station_for("p0").is_empty(), "Jumping past the TV does not trigger the station")
	p.grounded = true; p.y = 6.55
	check(main.station_for("p0").is_empty(), "High shelf is outside TV interaction range")
	p.y = 0.0
	main.input("p0", 0, Vector2.ZERO)
	p.x = main.Layout.stand_x(-9.6)
	var shelf: Array = main.shelf_games()
	main.shelf_offset = shelf.map(func(g): return str(g.id)).find("spaceracer")
	main._station_cooldown.clear()
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands[-1].type == "close_overlay", "Play now on the paused game resumes it")
	main.input("p0", 0, Vector2.ZERO)
	main.shelf_offset = (main.shelf_offset + 1) % shelf.size()
	main._station_cooldown.clear()
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands.slice(-2).map(func(c): return c.type) == ["queue_next", "next"], "Play now puts it on top and switches to it")
	check(main.station_for("p0").label.ends_with(" now"), "Selector label says it plays now")
	main.world.players.p1.x = 0.0
	main.world.players.p1.y = main.Layout.TV_CONSOLE[2]
	main.world.players.p2.x = main.Layout.stand_x(-4.95)
	main.world.players.p2.y = 0.0
	main.world.players.p1.grounded = true
	main.world.players.p2.grounded = true
	main._update_prompts()
	check(main.room._prompts.queue.node.visible, "Queue shows its floating Y action in range")
	check(main.room._prompts.queue.state.items == [["Y", "Play next"], ["X", "Skip next"]], "Queue shows separate Play next and Skip next actions")
	check(main.room._prompts.shelf.state.items == [["Y", "Play now"], ["X", "Queue"]], "Selector offers Play now or Queue")
	await capture(main, "queue-hierarchy")
	party.onboarding_error = "Hexstead is not available on this computer. Add or update the game, then restart GameNight. Your choice is saved."
	party.warm_session = {"game": "ballkickers", "phase": "preparing", "progress_label": "World ready. Loading 2 player views"}
	main.set_party(party)
	check(main._queue_status("ballkickers") == "0% · World ready. Loading 2 player views", "Queue shows real game loading progress")
	for i in 120: tick(main)
	var unreported: int = main.loading_percent("ballkickers")
	check(unreported > 0 and unreported < 50, "Loading without a percentage still moves: %d" % unreported)
	party.warm_session.progress = 53
	main.set_party(party)
	tick(main)
	check(main.loading_percent("ballkickers") < 53, "A reported jump eases in instead of jumping")
	for i in 180: tick(main)
	var eased: int = main.loading_percent("ballkickers")
	check(eased >= 53 and eased < 95, "The bar reaches the report and keeps creeping: %d" % eased)
	check(main._queue_status("ballkickers").begins_with("%d%%" % eased), "Queue shows the shown loading percentage")
	party.erase("onboarding_error")
	main.set_party(party)
	main.toasts.clear()
	await capture(main, "queue-loading")
	var previous_active: Dictionary = party.active_session.duplicate(true)
	party.active_session = party.warm_session.duplicate(true)
	party.erase("warm_session")
	main.set_party(party)
	check(main._loading_session("ballkickers").get("progress") == 53, "Loading stays visible after Play next moves it to the active slot")
	party.active_session.phase = "running"
	main.set_party(party)
	check(main._loading_session("ballkickers").is_empty(), "Completed games do not keep stale loading progress")
	party.active_session = previous_active
	party.game_issues = [{"game": "ballkickers", "kind": "startup_timeout"}]
	main.set_party(party)
	check(main._queue_status("ballkickers").contains("retry"), "Startup failure overrides old loading progress even with another game paused")
	await capture(main, "requested-game-unavailable")
	party.erase("onboarding_error")
	party.erase("game_issues")
	party.erase("warm_session")
	main.set_party(party)
	main.room.set_process(false)
	main.room.press_prompt("queue", "X")
	await capture(main, "queue-skip-pressed")
	main.room._process(.4)
	check(main.room._prompts.queue.state.pressed.is_empty(), "Floating badge returns to rest without changing its label")
	main.room.set_process(true)
	for i in 6: party.playlist.entries.append({"game": "extra-%d" % i, "title": "Later game %d" % i})
	main.set_party(party)
	check(main.queue_title_rows().size() == main.Room.QUEUE_TITLE_ROWS, "Long queues retain bounded, legible title rows")
	check(main.upcoming().size() - 1 - main.queue_title_rows().size() == 4, "Overflow count excludes next and visible titles")
	await capture(main, "queue-overflow")
	party.playlist.current = 1
	main.set_party(party)
	check(main.upcoming()[0].game == "god-game" and main.queue_title_rows()[0].title == "Blast Party", "Advancing promotes the next title in order")
	party.erase("active_session")
	main.set_party(party)
	var queue: Array = main.upcoming()
	check(main.cabinet_queue()[0] == queue[1], "With nothing running the TV shows the first game and the cabinet the one after it")
	check(main.queue_title_rows()[0].number == 3, "Title rows number on from the cabinet's game")
	party.active_session = {"game": "spaceracer", "phase": "paused"}
	main.set_party(party)
	party.playlist.entries = []
	party.playlist.erase("current")
	party.erase("active_session")
	main.set_party(party)
	check(main.upcoming().is_empty() and main.queue_title_rows().is_empty(), "Empty queue clears both surfaces")
	main._station_cooldown.clear()
	main.input("p0", 0, Vector2.ZERO)
	p.x = main.Layout.stand_x(-4.95)
	var command_count := recorder.commands.size()
	main.input("p0", main.World.BTN_Y, Vector2.ZERO)
	check(recorder.commands.size() == command_count, "Empty queue cannot launch a game")
	print("GAME_ROOM_QUEUE_", "PASS" if failures == 0 else "FAIL")
	var client: Node = main.client
	main.free()
	client.free()
	quit(0 if failures == 0 else 1)

func capture(main, name: String) -> void:
	var directory := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): directory = arg.trim_prefix("--capture-dir=")
	if directory.is_empty() or DisplayServer.get_name() == "headless": return
	main.view.sync_profiles(main.profiles, main.world.players)
	main.view.update(main.world, 0.0)
	main.hud.queue_redraw()
	await create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(name + ".png"))
