extends SceneTree
## Run with --script tests/bench.gd -- --demo --scene=phones (no daemon needed).
## Players without a controller get no walking character but a line on the
## HUD, and anyone can take a player out of the party from the Start menu.

class RecordingClient extends "res://addons/gamenight/lobby.gd":
	var commands: Array = []
	func _ready() -> void:
		pass # Record commands without opening a host socket.
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
	check(main.profiles.has("p4") and main.profiles.has("p5"), "The demo seats two players without a controller")
	check(not main.world.players.has("p4") and not main.world.players.has("p5"), "They get no walking character")
	check(main.bench == ["p4", "p5"], "They are on the bench: %s" % [main.bench])
	check(main.world.players.has("p0"), "Controller players still walk")
	var p: Dictionary = main.world.players.p0
	p.x = 7.0; p.y = 0.0; p.grounded = true; p.sleeping = false
	press(main, main.BTN_START)
	var at: int = main.menu_items("p0").map(func(item): return item.action).find("remove_page")
	check(at >= 0, "Remove a player is in the Start menu")
	for i in at: press(main, main.World.BTN_DOWN)
	press(main, main.World.BTN_A)
	var items: Array = main.menu_items("p0")
	check(items[0].player == "p4" and items[0].label.ends_with("(phone)"), "Phone players come first: %s" % [items[0]])
	check(items[1].player == "p5" and items[1].label.ends_with("(no controller)"), "Then players without anything: %s" % [items[1]])
	check(not items.any(func(item): return item.get("player") == "p0"), "You cannot remove yourself here")
	press(main, main.World.BTN_DOWN)
	press(main, main.World.BTN_A)
	check(recorder.commands.is_empty(), "The first A only asks to confirm")
	press(main, main.World.BTN_A)
	check(recorder.commands == [{"type": "leave_party", "player_id": "p5"}], "The second A removes them: %s" % [recorder.commands])
	check(main.menus.p0.get("page", "") == "", "The menu goes back to its first page")
	# A controller coming back gives the player a character again.
	var party: Dictionary = main.party.duplicate(true)
	party.seats[5].controller = "demo:5"
	main.set_party(party)
	check(main.world.players.has("p5") and main.bench == ["p4"], "A player with a controller walks again")
	# A walking player whose controller goes keeps standing, asleep and
	# marked, and leaves after LOST_SECONDS in the room.
	party = main.party.duplicate(true)
	party.seats[1].controller = null
	main.set_party(party)
	main._update_sleep()
	check(main.world.players.has("p1") and not main.bench.has("p1"), "A lost controller keeps the character")
	check(main.world.players.p1.sleeping and main.lost_left("p1") == 30, "It sleeps with a countdown: %d" % main.lost_left("p1"))
	recorder.commands.clear()
	main._time += 29.0
	main._remove_lost(0.0)
	check(recorder.commands.is_empty(), "Not before the countdown ends")
	party.seats[1].controller = "demo:1"
	main.set_party(party)
	main._update_sleep()
	check(main.lost_left("p1") == -1 and not main.world.players.p1.sleeping, "The controller coming back wakes them")
	party.seats[1].controller = null
	main.set_party(party)
	main._time += 31.0
	main._remove_lost(0.0)
	check(recorder.commands == [{"type": "leave_party", "player_id": "p1"}], "After the countdown they leave: %s" % [recorder.commands])
	check(main.lost_left("p4") == -1, "A phone player never counts down")
	print("GAME_ROOM_BENCH_PASS" if failures == 0 else "GAME_ROOM_BENCH_FAIL")
	quit(failures)
