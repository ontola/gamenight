extends SceneTree
## Run with --script tests/carry.gd (pure simulation, no scene).
## B lifts a nearby player; any input frees them; thrown into the exit, an
## away player leaves the party.

const World = preload("res://src/world.gd")
const Layout = preload("res://src/layout.gd")
var failures := 0

func _initialize() -> void:
	_run()
	print("GAME_ROOM_CARRY_PASS" if failures == 0 else "GAME_ROOM_CARRY_FAIL")
	quit(failures)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func pair(x: float, gap: float) -> Array:
	var w := World.new()
	w._drop_at = 1e9
	var a := w.ensure_player("a", 0)
	var b := w.ensure_player("b", 1)
	for p in [a, b]:
		p.y = 0.0; p.vy = 0.0; p.grounded = true; p.spawn = 0.0
	a.x = x; b.x = x + gap; a.facing = signf(gap)
	return [w, a, b]

func press(w, id: String, button: int) -> void:
	w.set_input(id, button, Vector2.ZERO)
	w.step()
	w.set_input(id, 0, Vector2.ZERO)

func run_for(w, seconds: float) -> void:
	for i in int(seconds * 60): w.step()

func _run() -> void:
	var r := pair(0.0, 0.8)
	var w = r[0]; var a: Dictionary = r[1]; var b: Dictionary = r[2]
	press(w, "a", World.BTN_B)
	check(a.carrying == "b" and b.carried_by == "a", "B lifts a player next to you")
	run_for(w, 0.5)
	check(absf(b.x - a.x) < 0.01 and b.y > a.y + 1.0, "The carried player rides above the carrier")
	w.set_input("b", 0, Vector2(0.9, 0))
	w.step()
	check(a.carrying == "" and b.carried_by == "", "Moving the stick wriggles free")
	run_for(w, 1.0)

	r = pair(0.0, 0.8)
	w = r[0]; a = r[1]; b = r[2]
	var item: Dictionary = w.spawn_item("blaster", 0.0, 0.0)
	press(w, "a", World.BTN_B)
	check(a.item == item.id and a.carrying == "", "An item in reach wins over a player")

	r = pair(Layout.EXIT_DOOR + 2.0, -0.8)
	w = r[0]; a = r[1]; b = r[2]
	press(w, "a", World.BTN_B)
	check(a.carrying == "b", "Lifted beside the exit")
	press(w, "a", World.BTN_B)
	check(a.carrying == "" and b.flung > 0, "B again throws the player")
	run_for(w, 1.0)
	check(w.ejected == ["b"], "Thrown into the exit door, the player is ejected: %s" % [w.ejected])

	r = pair(4.0, 0.8)
	w = r[0]; a = r[1]; b = r[2]
	press(w, "a", World.BTN_B)
	press(w, "a", World.BTN_B)
	run_for(w, 2.0)
	check(w.ejected.is_empty() and b.flung == 0.0, "Thrown elsewhere, nobody leaves")
	w.remove_player("a")
	check(b.carried_by == "", "Removing the carrier frees the carried")
