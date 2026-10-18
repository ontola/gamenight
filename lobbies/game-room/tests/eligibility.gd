extends SceneTree
## Offline roster changes, including stale host metadata; run with -- --demo --scene=stations.
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func ids(main) -> Array:
	return main.upcoming().map(func(e): return e.game)

func _run() -> void:
	var main = load("res://main.tscn").instantiate()
	root.add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	main._links.free()
	main._pickup.free()
	var initial: Dictionary = main.party.duplicate(true)
	var party: Dictionary = initial.duplicate(true)
	party.library = [
		{"id": "duo", "title": "Two Together", "min_players": 2, "max_players": 2, "color": "#ffb454"},
		{"id": "solo-ai", "title": "Solo + Bots", "min_players": 1, "max_players": 4, "color": "#3ddc97"},
		{"id": "four", "title": "Four Friends", "min_players": 4, "max_players": 4, "color": "#a78bfa"}]
	party.playlist = {"entries": party.library.map(func(g): return {"game": g.id, "title": g.title})}
	party.players = initial.players.slice(0, 1)
	party.seats = initial.seats.slice(0, 1)
	party.warm_session = {"game": "duo", "phase": "ready"} # stale snapshot from previous roster
	main.set_party(party)
	check(ids(main) == ["solo-ai"], "One human sees only explicitly solo-capable suggestions")
	check(main.shelf_games().size() == 3, "All manual catalog choices remain visible")
	check(main.tv_station().label == "Start Solo + Bots", "TV cannot advertise an incompatible ready game")
	await capture(main, "eligibility-solo")
	party.players = initial.players.slice(0, 2)
	party.seats = initial.seats.slice(0, 2)
	party.warm_session = {"game": "duo", "phase": "preparing"}
	main.set_party(party)
	check(ids(main) == ["duo", "solo-ai"], "Joining makes duo eligible, preserving order")
	check(main._unavailable(main.game_meta("duo")).is_empty(), "Seated human count controls eligibility")
	await capture(main, "eligibility-duo")
	party.players = initial.players.duplicate(true)
	party.seats = initial.seats.duplicate(true)
	party.warm_session = {"game": "four", "phase": "ready"}
	main.set_party(party)
	check(ids(main) == ["four"], "Explicit host next target leads the preview")
	check(main.shelf_games().size() == 3, "Count changes do not hide manual games")
	party.playlist = {"entries": [{"game": "solo-ai", "title": "Solo + Bots"}, {"game": "four", "title": "Four Friends"}, {"game": "solo-ai", "title": "Solo + Bots"}], "current": 1}
	party.warm_session = {"game": "solo-ai", "phase": "ready"}
	main.set_party(party)
	check(main.upcoming()[0].index == 2, "Duplicate entries select the upcoming occurrence, not history")
	party.next_game_index = 0
	main.set_party(party)
	check(main.upcoming()[0].index == 0, "Authoritative explicit duplicate selection overrides inference")
	party.erase("next_game_index")
	party.playlist = {"entries": party.library.map(func(g): return {"game": g.id, "title": g.title})}
	party.players = initial.players.slice(0, 1)
	party.seats = initial.seats.slice(0, 1)
	party.seats.append({"index": 1, "occupant": {"kind": "ai"}})
	party.players.append({"id": "spectator", "name": "Spectator"})
	main.set_party(party)
	check(ids(main) == ["solo-ai"], "Leaving clears ineligible suggestions; AI and spectators are not humans")
	party.active_session = {"game": "duo", "phase": "paused"}
	main.set_party(party)
	check(main.tv_station().action == "next" and main.tv_station().label == "Start Solo + Bots", "Unsupported paused game must offer an explicit eligible start instead of Resume")
	await capture(main, "eligibility-paused-mismatch")
	party.library = [party.library[0], party.library[2]]
	party.playlist.entries = [{"game": "duo", "title": "Two Together"}, {"game": "four", "title": "Four Friends"}]
	main.set_party(party)
	check(main.upcoming().is_empty(), "No playable title means no false suggestion")
	check(not main.tv_station().enabled, "Empty eligible queue cannot be started")
	# Phone games count linked phones; phone-only players skip pad games.
	party.library = [
		{"id": "cards", "title": "Cards", "min_players": 2, "max_players": 4, "play_with": "phone"},
		{"id": "god", "title": "God", "min_players": 2, "max_players": 4, "play_with": "controller_or_phone", "min_phones": 1},
		{"id": "duo", "title": "Two Together", "min_players": 2, "max_players": 2}]
	party.playlist = {"entries": party.library.map(func(g): return {"game": g.id, "title": g.title})}
	party.players = initial.players.slice(0, 3)
	party.seats = initial.seats.slice(0, 3)
	for i in 3: party.seats[i].controller = "ordinal:%d" % i
	party.phones = []
	party.active_session = null
	main.set_party(party)
	check(main._unavailable(main.game_meta("cards")) == "Needs 2 phones", "Phone game asks for phones, not players")
	check(main._unavailable(main.game_meta("god")) == "Needs a phone", "Asymmetric game asks for its phone")
	check(main._unavailable(main.game_meta("duo")) == "Too many players", "Three pads are too many for a duo")
	var ids3: Array = party.seats.map(func(s): return s.occupant.player_id)
	party.phones = [ids3[0], ids3[1]]
	main.set_party(party)
	check(ids(main) == ["cards", "god"], "Two phones make the phone games playable")
	party.seats[2].controller = null
	party.phones = [ids3[2]]
	main.set_party(party)
	check(main._unavailable(main.game_meta("duo")).is_empty(), "A phone-only player does not take a pad seat")
	check(main._unavailable(main.game_meta("god")).is_empty(), "Two pads and a phone play the god game")
	print("GAME_ROOM_ELIGIBILITY_", "PASS" if failures == 0 else "FAIL")
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
