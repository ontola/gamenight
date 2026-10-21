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
	print("GAME_ROOM_PICKUP_", "PASS" if failures == 0 else "FAIL")
	main.free()
	quit(0 if failures == 0 else 1)
