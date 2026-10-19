extends SceneTree
## Run with --script tests/music_controls.gd -- --demo (no daemon or host music needed).

class RecordingClient extends "res://addons/gamenight/lobby.gd":
	var commands: Array = []
	func _ready() -> void:
		pass # Exercise messages and disconnects without opening a host socket.
	func _command(message: Dictionary) -> void:
		commands.append(message)

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func press(main, button: int) -> void:
	main.input("p0", 0, Vector2.ZERO)
	main.input("p0", button, Vector2.ZERO)

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
	var p: Dictionary = main.world.players.p0
	p.x = main.Layout.stand_x(main.Layout.JUKEBOX); p.y = 0.0; p.grounded = true; p.sleeping = false
	var station: Dictionary = main.station_for("p0")
	check(station.extra == "LB previous RB next", "Music hint contains both bumper controls")
	check(station.action == "play_pause", "Y keeps play/pause at the jukebox")
	press(main, main.BTN_LB)
	check(recorder.commands == [{"type": "media_control", "action": "previous_track"}], "LB sends previous track")
	main.input("p0", main.BTN_LB, Vector2.ZERO)
	check(recorder.commands.size() == 1, "Holding LB does not keep skipping tracks")
	press(main, main.BTN_RB)
	check(recorder.commands[-1].action == "next_track", "RB sends next track")
	press(main, main.World.BTN_Y)
	check(recorder.commands[-1].action == "play_pause", "Y sends play/pause")
	recorder.commands.clear()
	main._station_cooldown.clear()
	p.x += 1.0
	press(main, main.BTN_LB)
	check(recorder.commands.is_empty(), "Bumpers outside the jukebox do not control music")
	p.x = main.Layout.stand_x(main.Layout.JUKEBOX); p.grounded = false
	press(main, main.BTN_RB)
	check(recorder.commands.is_empty(), "Airborne players do not control the station")
	p.grounded = true
	main.menus.p0 = {"index": 0, "confirm": false}
	press(main, main.BTN_RB)
	check(recorder.commands.is_empty(), "Open menu prevents music commands")
	main.menus.clear()
	main.party.now_playing = null
	check(main.station_for("p0").action == "resume", "Without a media session Y starts the last player")
	press(main, main.BTN_RB)
	check(recorder.commands.is_empty(), "No skipping without a media session")
	press(main, main.World.BTN_Y)
	check(recorder.commands == [{"type": "media_control", "action": "resume"}], "Y sends resume")
	recorder.commands.clear()
	main._station_cooldown.clear()
	main.party.now_playing = {"title": "Demo track", "artist": "Test artist", "playing": false}
	check(main.station_for("p0").label == "Play music", "Paused session offers play")
	p.x = main.Layout.stand_x(main.Layout.GAME_SHELF.x + 0.2)
	var offset: int = main.shelf_offset
	press(main, main.BTN_RB)
	check(main.shelf_offset == (offset + 1) % main.shelf_games().size(), "RB still browses games at the shelf")
	check(recorder.commands.is_empty(), "Browsing the shelf does not change music")
	for player in main.world.players.values(): player.sleeping = true
	main._update_prompts()
	for prompt in main.room._prompts.values(): check(not prompt.node.visible, "Inactive station stays invisible")
	p.sleeping = false
	for entry in [["shelf", -9.6], ["tv", 0.0], ["music", main.Layout.JUKEBOX], ["exit", main.Layout.EXIT_DOOR], ["door0", main.Layout.PROFILE_DOORS[0]]]:
		p.x = main.Layout.stand_x(entry[1])
		main._update_prompts()
		check(main.room._prompts[entry[0]].node.visible, "Station appears within range: " + entry[0])
		var anchor: Vector3 = main.room._prompts[entry[0]].node.position
		p.x += 0.1
		main._update_prompts()
		check(main.room._prompts[entry[0]].node.position == anchor, "Station button stays at its object: " + entry[0])
		main.menus.p0 = {"index": 0, "confirm": false}
		main._update_prompts()
		check(not main.room._prompts[entry[0]].node.visible, "Menu hides station buttons: " + entry[0])
		main.menus.clear()
		p.x = 7.0
		main._update_prompts()
		check(not main.room._prompts[entry[0]].node.visible, "Station disappears out of range: " + entry[0])
	check(not main.room.featured_box.visible, "Selected cover hides when nobody browses the cupboard")
	check(not main.room.get_node("shelf_lb").visible and not main.room.get_node("shelf_rb").visible, "Shelf bumpers disappear out of range")
	p.x = main.Layout.stand_x(-9.6)
	main._update_prompts()
	check(main.room.featured_box.visible, "Selected cover appears for a nearby player")
	check(main.room.get_node("shelf_lb").visible and main.room.get_node("shelf_rb").visible, "Shelf bumpers appear within range")
	var other: Dictionary = main.world.players.p1
	other.x = main.Layout.stand_x(main.Layout.JUKEBOX); other.y = 0.0; other.grounded = true; other.sleeping = false
	p.x = main.Layout.stand_x(main.Layout.JUKEBOX)
	main._update_prompts()
	p.x = 7.0
	main._update_prompts()
	check(main.room._prompts.music.node.visible, "Station remains visible while another player is nearby")
	other.sleeping = true
	# Real runtime mode: background controller frames must never drive the lobby.
	var demo_node: Node = main.demo
	main.demo = null
	main._capture_path = "-" # Keep the isolated test's native window untouched.
	recorder.connected = true
	recorder.active = false
	main.menus.p0 = {"index": 0, "confirm": false}
	p.held = main.World.BTN_A; p.pressed = main.World.BTN_B; p.stick = Vector2.RIGHT; p.vx = 5.0
	main._focus_changed(false)
	check(main.menus.is_empty() and p.held == 0 and p.pressed == 0 and p.stick == Vector2.ZERO, "Focus loss clears menus and pending simulation input")
	recorder.commands.clear()
	var all_buttons: int = main.World.BTN_Y | main.BTN_LB | main.BTN_RB | main.BTN_START | main.World.BTN_X | main.World.BTN_B | main.World.BTN_A
	var shelf_before: int = main.shelf_offset
	for x in [main.Layout.JUKEBOX, -9.6, 0.0, main.Layout.EXIT_DOOR, main.Layout.PROFILE_DOORS[0]]:
		p.x = main.Layout.stand_x(x)
		main._controllers_changed([{"controller": "demo:0", "buttons": all_buttons, "axes": [32767, 0]}])
		var position := Vector2(p.x, p.y)
		main._physics_process(0.1)
		check(Vector2(p.x, p.y) == position and p.held == 0 and p.pressed == 0, "Inactive controller input cannot move or act")
	check(recorder.commands.is_empty() and main.menus.is_empty() and main.shelf_offset == shelf_before, "Inactive Y/LB/RB/Start/X cannot command, open a menu or browse")
	p.x = main.Layout.stand_x(main.Layout.JUKEBOX)
	recorder.active = true
	main._focus_changed(true)
	main._station_cooldown.clear()
	main.input("p0", all_buttons, Vector2.RIGHT)
	check(recorder.commands.is_empty() and main.menus.is_empty() and p.held == 0, "Held buttons on resume do not retrigger")
	main.input("p0", 0, Vector2.RIGHT)
	check(p.stick == Vector2.ZERO, "Held stick on resume waits for neutral")
	main.input("p0", 0, Vector2.ZERO)
	main.input("p0", main.BTN_RB, Vector2.ZERO)
	check(recorder.commands.size() == 1 and recorder.commands[0].action == "next_track", "Fresh press after neutral resumes control")
	recorder.commands.clear()
	recorder.connected = false
	press(main, main.World.BTN_Y)
	check(recorder.commands.is_empty(), "Disconnected lobby ignores commands even with stale active state")
	# Exercise the real SDK disconnect branch and welcome ordering. A welcome
	# must not reuse the old focus grant, even before the next controller frame.
	root.add_child(recorder)
	recorder.set_process(false)
	recorder.connection_changed.connect(main._connection_changed)
	recorder.focus_changed.connect(main._focus_changed)
	recorder.controllers_changed.connect(main._controllers_changed)
	recorder.party_changed.connect(main.set_party)
	recorder.connected = true
	recorder.active = true
	main.menus.p0 = {"index": 1, "confirm": true}
	p.held = main.World.BTN_A; p.pressed = main.World.BTN_B; p.stick = Vector2.RIGHT; p.vx = 5.0
	recorder._socket = WebSocketPeer.new() # Closed peer triggers the actual lost-connection path.
	recorder._process(0.0)
	check(not recorder.connected and not recorder.active, "Disconnect revokes the SDK's stale screen ownership")
	check(main.menus.is_empty() and p.held == 0 and p.pressed == 0 and p.stick == Vector2.ZERO and p.vx == 0.0, "Disconnect clears menus and input without waiting for a focus event")
	recorder._handle({"type": "welcome", "party": main.party.duplicate(true)})
	await process_frame
	check(recorder.connected and not recorder.active, "Welcome does not grant screen ownership")
	var before_reconnect := Vector2(p.x, p.y)
	main._physics_process(0.1)
	check(Vector2(p.x, p.y) == before_reconnect, "Welcome cannot replay held movement before a fresh controller frame")
	recorder._handle({"type": "controller_frame", "controllers": [{"controller": "demo:0", "buttons": all_buttons, "axes": [32767, 0]}]})
	check(recorder.commands.is_empty() and main.menus.is_empty() and p.held == 0, "Frames after welcome stay blocked until a fresh focus grant")
	recorder._handle({"type": "lobby_focus", "active": true})
	recorder._handle({"type": "controller_frame", "controllers": [{"controller": "demo:0", "buttons": main.BTN_RB, "axes": [0, 0]}]})
	check(recorder.commands.is_empty(), "Fresh focus still requires releasing buttons held during reconnect")
	main._station_cooldown.clear()
	recorder._handle({"type": "controller_frame", "controllers": [{"controller": "demo:0", "buttons": 0, "axes": [0, 0]}]})
	recorder._handle({"type": "controller_frame", "controllers": [{"controller": "demo:0", "buttons": main.BTN_RB, "axes": [0, 0]}]})
	check(recorder.commands.size() == 1 and recorder.commands[0].action == "next_track", "Neutral input then a fresh press restores controls after reconnect")
	main.demo = demo_node
	main._input_blocked.clear()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="):
			var directory := arg.trim_prefix("--capture-dir=")
			DirAccess.make_dir_recursive_absolute(directory)
			p.x = main.Layout.stand_x(main.Layout.JUKEBOX)
			main._update_prompts()
			main.profiles.p0.name = "Alex"
			main.world.items.clear()
			main.view.update(main.world, 0.1)
			main.room.redraw("jukebox")
			main.hud.queue_redraw()
			for frame in 12: await process_frame
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(directory.path_join("jukebox-controls.png")) == OK, "Save jukebox preview")
			p.x = 7.0
			main._update_prompts()
			main.view.update(main.world, 0.1)
			main.hud.queue_redraw()
			for frame in 3: await process_frame
			await RenderingServer.frame_post_draw
			check(root.get_texture().get_image().save_png(directory.path_join("station-hints-away.png")) == OK, "Save hidden-station preview")
	print("GAME_ROOM_MUSIC_CONTROLS_PASS" if failures == 0 else "GAME_ROOM_MUSIC_CONTROLS_FAIL: %d" % failures)
	main.free()
	recorder.free()
	quit(0 if failures == 0 else 1)
