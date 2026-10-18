extends SceneTree
## Run with --script tests/update.gd -- --demo (no daemon needed).
## A downloaded host update is offered in the Start menu and applied with A.

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
	var p: Dictionary = main.world.players.p0
	p.x = 7.0; p.y = 0.0; p.grounded = true; p.sleeping = false
	check(main.menu_items("p0").all(func(item): return item.action != "update"), "No update item without a downloaded update")
	var party: Dictionary = main.party.duplicate(true)
	party["update_ready"] = "0.2.300"
	main.set_party(party)
	check(main.toasts.any(func(t): return "version ready" in t.text), "A ready update is announced")
	check(main.menu_items("p0")[0].action == "update", "Update is the first menu item")
	press(main, main.BTN_START)
	press(main, main.World.BTN_A)
	check(recorder.commands == [{"type": "apply_update"}], "Start then A applies the update")
	check(main.menus.is_empty(), "The menu closes while the host restarts")
	party["update_ready"] = null
	main.set_party(party)
	check(main.menu_items("p0").all(func(item): return item.action != "update"), "The item goes once the update is gone")
	print("GAME_ROOM_UPDATE_PASS" if failures == 0 else "GAME_ROOM_UPDATE_FAIL")
	quit(failures)
