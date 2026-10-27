extends SceneTree
## Optimistic door pickup; run with -- --demo.
## The character becomes the profile and the door empties on the press,
## before the host answers; the host's snapshot confirms or a refusal undoes.

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
	var party: Dictionary = main.party.duplicate(true)
	var id := "p1"
	var before := str(main.profiles[id].name)
	var doors: int = main.pending_profiles().size()
	var door: Dictionary = main.pending_profiles()[0]
	var start := Time.get_ticks_usec()
	main.claim(id, {"pending": door.id})
	var spent := (Time.get_ticks_usec() - start) / 1000.0
	print("claim took %.1f ms" % spent)
	check(str(main.profiles[id].name) == str(door.profile.display_name), "The character takes the profile's name at once")
	check(str(main.profiles[id].avatar) == str(door.profile.avatar), "The character takes the profile's face at once")
	check(main.pending_profiles().size() == doors - 1, "The door empties at once")
	# The host renames first and sets the face in a later snapshot: no step back.
	var renamed: Dictionary = party.duplicate(true)
	for p in renamed.players:
		if p.id == id: p.name = door.profile.display_name
	main.set_party(renamed)
	check(str(main.profiles[id].avatar) == str(door.profile.avatar), "A partial host update keeps the claimed face")
	check(main.pending_profiles().size() == doors - 1, "The door stays empty while the door list catches up")
	for p in renamed.players:
		if p.id == id: p.avatar = door.profile.avatar
	main.set_party(renamed)
	check(main._claims.is_empty(), "A matching snapshot confirms the claim")
	check(main.pending_profiles().size() == doors - 1, "The door stays empty after confirmation until the list drops it")
	# A refusal puts everything back.
	main.set_party(party)
	main.claim(id, {"pending": main.pending_profiles()[0].id})
	main._drop_claims()
	check(str(main.profiles[id].name) == before, "A refused pickup restores the character")
	check(main.pending_profiles().size() == doors, "A refused pickup restores the door")
	# Someone who already is a profile swaps with a hold, not a tap.
	main.set_party(party)
	main.links.linked = {id: "someone"}
	var p: Dictionary = main.world.players[id]
	p.x = main.Layout.PROFILE_DOORS[0]; p.y = 0.0; p.grounded = true; p.sleeping = false
	var station: Dictionary = main.station_for(id)
	check(station.kind == "door" and station.enabled and station.get("hold", false), "A linked player may swap at a door, by holding")
	main._station_cooldown.clear()
	main.input(id, main.World.BTN_Y, Vector2.ZERO)
	check(main._station_cooldown.is_empty(), "Tapping Y does not swap")
	main._time += main.HOLD_SECONDS * 0.5
	main._update_holds()
	check(main._station_cooldown.is_empty() and main._hold_charge(id) > 0.4, "Half a hold charges without swapping")
	main._update_prompts()
	await capture(main, "door-hold")
	main._time = main._holds[id].since + main.HOLD_SECONDS * 0.5
	main.input(id, 0, Vector2.ZERO)
	main._update_holds()
	check(main._holds.is_empty(), "Letting go cancels the hold")
	main.input(id, main.World.BTN_Y, Vector2.ZERO)
	main._time += main.HOLD_SECONDS + 0.01
	main._update_holds()
	check(main._station_cooldown.has("%s::Y" % station.id), "A full hold swaps")
	main.input(id, 0, Vector2.ZERO)
	main.links.linked = {}
	check(not main.station_for(id).get("hold", false), "An unlinked player picks up with a tap")
	# An unjoined controller makes the table pads hop once per new input.
	var rest := {"controller": "stranger", "buttons": 0, "axes": [0, 0, 0, 0, 0, 0]}
	var push := {"controller": "stranger", "buttons": 0, "axes": [20000, 0, 0, 0, 0, 0]}
	var press_b := {"controller": "stranger", "buttons": main.World.BTN_B, "axes": [0, 0, 0, 0, 0, 0]}
	var press_a := {"controller": "stranger", "buttons": main.World.BTN_A, "axes": [0, 0, 0, 0, 0, 0]}
	main._controllers_changed([rest])
	main.room._pad_hop = 99.0
	main._controllers_changed([push])
	check(main.room._pad_hop == 0.0, "Pushing the stick makes the pads hop")
	main.room._process(0.2)
	main._controllers_changed([push])
	check(main.room._pad_hop > 0.1, "Holding the stick does not restart the hop")
	main.room._process(0.5)
	var pad: Dictionary = main.room._pads[0]
	check(pad.node.position.is_equal_approx(pad.pos), "After one hop the pads are still again")
	main._controllers_changed([rest, press_b])
	check(main.room._pad_hop == 0.0, "Each new button press hops again")
	main.room._process(0.5)
	main._controllers_changed([rest, press_a])
	check(main.room._pad_hop > 0.4, "A joins instead of hopping")
	# The A Join hint sits above the table controllers, not as a notice.
	main.room._pad_activity = 0.0
	main._process(1.0 / 60.0)
	main.room._process(1.0 / 60.0)
	check(not main.room._prompts.join.node.visible, "No join hint while people are in the room")
	var empty: Dictionary = party.duplicate(true)
	empty.players = []
	empty.seats = []
	main.set_party(empty)
	main._process(1.0 / 60.0)
	main.room._process(1.0 / 60.0)
	check(main.room._prompts.join.node.visible, "An empty room shows A Join above the controllers")
	check(main.room._prompts.join.state.items == [["A", "Join"]], "The hint is the A Join button")
	print("GAME_ROOM_PICKUP_", "PASS" if failures == 0 else "FAIL")
	main.free()
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
