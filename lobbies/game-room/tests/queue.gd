extends SceneTree
## Offline queue hierarchy test; run with -- --demo --scene=stations.
var failures := 0

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
	await capture(main, "queue-hierarchy")
	for i in 6: party.playlist.entries.append({"game": "extra-%d" % i, "title": "Later game %d" % i})
	main.set_party(party)
	check(main.queue_title_rows().size() == main.Room.QUEUE_TITLE_ROWS, "Long queues retain bounded, legible title rows")
	check(main.upcoming().size() - 1 - main.queue_title_rows().size() == 4, "Overflow count excludes next and visible titles")
	await capture(main, "queue-overflow")
	party.playlist.current = 1
	main.set_party(party)
	check(main.upcoming()[0].game == "god-game" and main.queue_title_rows()[0].title == "Blast Party", "Advancing promotes the next title in order")
	party.playlist.entries = []
	party.playlist.erase("current")
	party.erase("active_session")
	main.set_party(party)
	check(main.upcoming().is_empty() and main.queue_title_rows().is_empty(), "Empty queue clears both surfaces")
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
	await create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(directory)
	root.get_texture().get_image().save_png(directory.path_join(name + ".png"))
