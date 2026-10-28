extends SceneTree
## Prints a trace of a scripted match for the Warp port to compare against
## (lobbies/game-room/sim/tests/parity.rs in warp-game-engine). Run:
## godot --headless --path . -s tests/warp_parity.gd > trace.txt

const World = preload("res://src/world.gd")

func _init() -> void:
	var w = World.new(7)
	for k in 4: w.ensure_player("p%d" % k, k)
	for spec in [["bomb", -2.0, 1.0], ["blaster", 0.0, 1.0], ["ball", 2.0, 1.0], ["saber", -4.0, 1.0], ["laser", 4.0, 1.0], ["bazooka", 1.0, 5.0], ["popcorn", -1.0, 5.0], ["minigun", 3.0, 0.5]]:
		w.spawn_item(spec[0], spec[1], spec[2])
	var events := 0
	for t in 3600:
		for k in 4:
			var sx: float = (((t / 37 + k * 2) % 5) - 2) * 0.5
			var sy: float = 1.0 if (t / 53 + k) % 7 == 0 else 0.0
			var held := 0
			if (t + k * 13) % 61 < 9: held |= World.BTN_A
			if (t + k * 29) % 97 < 2: held |= World.BTN_B
			if (t + k * 17) % 23 < 3: held |= World.BTN_RT
			w.set_input("p%d" % k, held, Vector2(sx, sy))
		w.step()
		events += w.events.size()
		w.events.clear()
		if t % 30 == 29:
			var line := "%d e%d i%d s%d" % [t, events, w.items.size(), w.shots.size()]
			for k in 4:
				var p: Dictionary = w.players["p%d" % k]
				line += " | %.5f %.5f %.5f %.5f %d %s" % [p.x, p.y, p.vx, p.vy, p.item, p.carrying]
			print(line)
	quit()
