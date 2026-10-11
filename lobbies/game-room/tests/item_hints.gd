extends SceneTree
## Isolated pickup/hint regression test. Run with --script tests/item_hints.gd -- --demo.
## Add --capture-dir=/absolute/path under Xvfb for screenshots without touching the live lobby.

const World = preload("res://src/world.gd")
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
	# Demo mode does not attach the runtime HTTP helpers to the scene tree.
	main._links.free()
	main._pickup.free()
	var w := World.new()
	main.world = w
	var p := w.ensure_player("p0", 0)
	var other := w.ensure_player("p1", 1)
	p.x = 0.0; p.y = 0.0
	other.x = 0.0; other.y = 0.0
	var bomb := w.spawn_item("bomb", 0.5, 0.0)
	var box := w.spawn_item("hatbox", 0.6, 0.0)
	check(w.pickup_target(p) == bomb, "Hint follows the first item B will actually use")
	check(main.pickup_hint_items().size() == 1, "Two players sharing a target show one badge")
	p.x = -0.31; other.x = -0.31
	check(main.pickup_hint_items().is_empty(), "No hint outside horizontal pickup range")
	p.x = 0.0; other.x = 10.0
	p.y = 0.6
	check(w.pickup_target(p).is_empty(), "No hint when the item is below the player's reach")
	p.y = -World.HEIGHT
	check(w.pickup_target(p).is_empty(), "No hint when the item is above the player's reach")
	p.y = 0.0
	p.sleeping = true
	check(main.pickup_hint_items().is_empty(), "Sleeping players cannot reveal hints")
	p.sleeping = false; p.stun = 0.2
	check(main.pickup_hint_items().is_empty(), "Stunned players cannot reveal hints")
	p.stun = 0.0
	main.menus.p0 = {"index": 0, "confirm": ""}
	check(main.pickup_hint_items().is_empty(), "Menu input cannot reveal pickup hints")
	main.menus.clear()
	main.input("p0", World.BTN_B, Vector2.ZERO)
	w.step()
	check(p.item == bomb.id and bomb.holder == "p0", "B grabs the hinted bomb through the controller input path")
	check(main.pickup_hint_items().is_empty(), "Carrying an item suppresses pickup hints")
	other.x = 0.0
	check(w.pickup_target(other) == box, "Another player can target the remaining free item")
	w.set_input("p1", World.BTN_B, Vector2.ZERO)
	w.step()
	check(box.dead and other.hat == box.hat, "B opens the hinted hat box")
	check(w.pickup_target(other).is_empty(), "Consumed or held items cannot be targeted")
	# An already-consumed box must not be opened twice within one simulation step.
	w.items.clear(); p.item = -1
	box = w.spawn_item("hatbox", 0.0, 0.0)
	box.dead = true
	check(w.pickup_target(p).is_empty(), "Dead items are excluded before cleanup")
	w.items.clear()
	var ball := w.spawn_item("ball", 0.5, 0.0)
	w.set_input("p0", 0, Vector2.ZERO)
	w.set_input("p0", World.BTN_B, Vector2.ZERO)
	w.step()
	check(p.item == -1 and ball.vy > 0, "B kicks the hinted ball without carrying it")
	var capture_dir := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): capture_dir = arg.trim_prefix("--capture-dir=")
	if not capture_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(capture_dir)
		await _capture(main, capture_dir)
	print("GAME_ROOM_ITEM_HINTS_PASS" if failures == 0 else "GAME_ROOM_ITEM_HINTS_FAIL: %d" % failures)
	var runtime_client: Node = main.client # Demo leaves the client unparented.
	main.free()
	runtime_client.free()
	quit(0 if failures == 0 else 1)

func _capture(main, directory: String) -> void:
	main.world = World.new()
	var snapshot: Dictionary = main.party.duplicate(true)
	snapshot.players.resize(4)
	for i in snapshot.players.size(): snapshot.players[i].name = ["Alex", "Sam", "Robin", "Kim"][i]
	main.set_party(snapshot)
	var w = main.world
	for i in 4:
		var p: Dictionary = w.players["p%d" % i]
		p.x = [-5.0, -1.7, 2.0, 8.3][i]; p.y = 0.0; p.spawn = 0.0
		var item: Dictionary = w.spawn_item(["bomb", "hatbox", "blaster", "ball"][i], p.x + 0.6, 0.0)
		item.vx = 0.0
	main.view.update(w, 0.1)
	main.hud.queue_redraw()
	for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(directory.path_join("item-hints-near.png")) == OK, "Save nearby-item preview")
	for p in w.players.values(): p.x -= 1.5
	main.view.update(w, 0.1)
	main.hud.queue_redraw()
	for frame in 3: await process_frame
	await RenderingServer.frame_post_draw
	check(root.get_texture().get_image().save_png(directory.path_join("item-hints-away.png")) == OK, "Save out-of-range preview")
