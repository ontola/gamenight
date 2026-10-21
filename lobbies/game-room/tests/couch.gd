extends SceneTree
## Run with --script tests/couch.gd -- --demo (no daemon needed).
## Couch position in the Start menu: left and right move your filled block
## and ask the host to move you, the rest of the couch shifts over.

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

func press(main, id: String, button: int, stick := Vector2.ZERO) -> void:
	main.input(id, 0, Vector2.ZERO)
	main.input(id, button, stick)

func places(main) -> Array:
	return ["p0", "p1", "p2", "p3"].map(func(id): return main.couch_place(id))

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
	press(main, "p1", main.BTN_START)
	var items: Array = main.menu_items("p1")
	check(items[1].action == "couch" and items[1].label == "Couch position", "Couch position is right under Close menu: %s" % [items])
	press(main, "p1", main.World.BTN_DOWN)
	press(main, "p1", main.World.BTN_LEFT)
	check(places(main) == [1, 0, 2, 3], "Left swaps places with the player on your left: %s" % [places(main)])
	check(recorder.commands == [{"type": "set_couch_position", "player_id": "p1", "position": 0}], "The host hears it: %s" % [recorder.commands])
	press(main, "p1", main.World.BTN_LEFT)
	check(recorder.commands.size() == 1, "Nothing further left than the end")
	main.input("p1", 0, Vector2.ZERO)
	main.input("p1", 0, Vector2(1, 0))
	main.input("p1", 0, Vector2(1, 0))
	check(places(main) == [0, 1, 2, 3], "The stick moves one place per push: %s" % [places(main)])
	main.input("p1", 0, Vector2.ZERO)
	main.input("p1", 0, Vector2(1, 0))
	check(places(main) == [0, 2, 1, 3], "Right moves you on: %s" % [places(main)])
	check(main.menus.p1.index == 1, "Moving keeps the couch line selected")
	press(main, "p0", main.BTN_START)
	press(main, "p0", main.World.BTN_RIGHT)
	check(places(main)[0] == 0, "Left and right do nothing on other lines")
	# Older hosts send no couch: no line for it.
	var party: Dictionary = main.party.duplicate(true)
	for player in party.players: player.erase("couch")
	main.set_party(party)
	check(main.menu_items("p1").all(func(item): return item.action != "couch"), "No couch line without host support")
	print("GAME_ROOM_COUCH_PASS" if failures == 0 else "GAME_ROOM_COUCH_FAIL")
	quit(failures)
