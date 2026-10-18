extends SceneTree
## Run with --script tests/lobby_switch.gd -- --demo (no daemon needed).
## The Start menu lists the host's lobbies; picking another one asks the host
## to switch, without a browser.

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

func labels(main) -> Array:
	return main.menu_items("p0").map(func(item): return item.label)

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
	check(main.menu_items("p0").all(func(item): return item.action != "lobbies"), "No lobby page when the host cannot switch")
	var party: Dictionary = main.party.duplicate(true)
	party["lobbies"] = [{"id": "game-room", "title": "Game Room", "current": true}, {"id": "lobby", "title": "Clubhouse"}]
	main.set_party(party)
	press(main, main.BTN_START)
	var items: Array = main.menu_items("p0")
	var at: int = items.map(func(item): return item.action).find("lobbies")
	check(at >= 0, "Switch lobby is in the Start menu")
	for i in at: press(main, main.World.BTN_DOWN)
	press(main, main.World.BTN_A)
	check(labels(main) == ["Game Room  (here now)", "Clubhouse", "Back"], "The lobby page lists every lobby: %s" % [labels(main)])
	check(main.menus.p0.index == 0, "The running lobby is highlighted first")
	press(main, main.World.BTN_A)
	check(recorder.commands.is_empty(), "Picking the running lobby sends nothing")
	press(main, main.World.BTN_B)
	check(main.menus.has("p0") and main.menu_items("p0")[0].action == "close", "B goes back to the main menu")
	for i in at: press(main, main.World.BTN_DOWN)
	press(main, main.World.BTN_A)
	press(main, main.World.BTN_DOWN)
	press(main, main.World.BTN_A)
	check(recorder.commands == [{"type": "switch_lobby", "lobby": "lobby"}], "A on the Clubhouse asks the host to switch: %s" % [recorder.commands])
	check(main.menus.is_empty(), "The menu closes while the host restarts")
	check(main.toasts.any(func(t): return "Clubhouse" in t.text), "The switch is announced")
	print("GAME_ROOM_LOBBY_SWITCH_PASS" if failures == 0 else "GAME_ROOM_LOBBY_SWITCH_FAIL")
	quit(failures)
