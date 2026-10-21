extends SceneTree
## Run with --script tests/weapons.gd (pure simulation, no scene).
## Each lobby weapon knocks a player in front of its holder in its own way.

const World = preload("res://src/world.gd")
var failures := 0

func _initialize() -> void:
	_run()
	print("GAME_ROOM_WEAPONS_PASS" if failures == 0 else "GAME_ROOM_WEAPONS_FAIL")
	quit(failures)

func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)

func arena(kind: String, gap: float) -> Array:
	var w := World.new()
	var a := w.ensure_player("a", 0)
	var b := w.ensure_player("b", 1)
	for p in [a, b]:
		p.y = 0.0; p.vy = 0.0; p.grounded = true; p.spawn = 0.0; p.facing = 1.0
	a.x = 0.0; b.x = gap
	var item := w.spawn_item(kind, 0.0, 0.0)
	item.holder = "a"; a.item = item.id
	return [w, a, b, item]

func press(w, id: String, button: int, frames := 1) -> void:
	for i in frames:
		w.set_input(id, button, Vector2.ZERO)
		w.step()
	w.set_input(id, 0, Vector2.ZERO)

func run_for(w, seconds: float) -> void:
	for i in int(seconds * 60): w.step()

func _run() -> void:
	check(not World.ITEM_KINDS.has("hatbox"), "The gift no longer drops")
	for kind in ["popcorn", "minigun", "bazooka", "laser", "saber"]:
		check(World.ITEM_KINDS.has(kind), "%s drops in the lobby" % kind)
	for case in [["blaster", 4.0], ["minigun", 4.0], ["popcorn", 2.0], ["bazooka", 4.0], ["laser", 9.0], ["saber", 1.2]]:
		var setup := arena(case[0], case[1])
		var w = setup[0]; var b: Dictionary = setup[2]
		press(w, "a", World.BTN_RT, 20 if case[0] == "minigun" else 1)
		run_for(w, 1.0)
		# Popcorn only nudges; the rest send people flying.
		var push := 0.15 if case[0] == "popcorn" else 0.5
		check(b.x > case[1] + push, "%s knocks the player in front away (x %.2f)" % [case[0], b.x])
	var setup := arena("laser", 9.0)
	var w = setup[0]
	press(w, "a", World.BTN_RT)
	check(w.events.any(func(e): return e.type == "laser"), "The laser draws a beam")
	setup = arena("saber", 1.2)
	w = setup[0]; var item: Dictionary = setup[3]
	for i in World.WEAPONS.saber.ammo:
		press(w, "a", World.BTN_RT)
		run_for(w, 0.4)
	check(item.dead and setup[1].item == -1, "The saber wears out")
	setup = arena("popcorn", 3.0)
	w = setup[0]
	press(w, "a", World.BTN_RT)
	check(w.shots.size() == World.WEAPONS.popcorn.handful, "Popcorn is thrown by the handful")
	check(w.shots.all(func(s): return s.vy > 0), "Popcorn is lobbed")
	setup = arena("blaster", 1.0)
	w = setup[0]
	press(w, "a", World.BTN_X)
	check(w.shots.is_empty() and setup[1].punch == 0, "X does nothing in the world")
	setup[1].item = -1
	setup[3].holder = ""
	press(w, "a", World.BTN_RT)
	check(setup[1].punch > 0, "RT punches empty-handed")
