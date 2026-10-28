extends SceneTree
## Saves player sprite sheets and portraits for the Warp port to compare
## against pixel for pixel (lobbies/game-room/tests/character.rs in
## warp-game-engine). Run:
## godot --headless --path . -s tests/warp_sprites.gd -- OUT_DIR

const Character = preload("res://src/character.gd")

## A made-up face with soft edges, so the half-transparent paths are covered.
static func test_face() -> Dictionary:
	var img := Image.create(22, 20, false, Image.FORMAT_RGBA8)
	for y in 20:
		for x in 22:
			var a := clampf(1.2 - Vector2(x - 11, y - 10).length() / 9.0, 0.0, 1.0)
			img.set_pixel(x, y, Color(float(x) / 21.0, float(y) / 19.0, 0.4, a))
	return {"image": img, "center": Vector2(11.4, 9.7)}

func _init() -> void:
	var out: String = OS.get_cmdline_user_args()[0]
	var looks := [
		["plain", {}, {}, "none", false],
		["colours", {"color": "#3ddc97", "skin_color": "#8d5524"}, {}, "cap", true],
		["face", {"color": "#ff4f8b"}, test_face(), "crown", false],
	]
	var i := 0
	for hat in Character.HATS:
		looks.append(["hat_" + hat, {"color": ["#ffb454", "#38d6ff", "#7c5cff"][i % 3]}, {}, hat, i % 2 == 0])
		i += 1
	for look in looks:
		Character.build(look[1], look[2], look[3], look[4]).get_image().save_png(out.path_join(look[0] + ".png"))
	Character.portrait({}, {}).get_image().save_png(out.path_join("portrait_plain.png"))
	Character.portrait({"skin_color": "#8d5524"}, test_face()).get_image().save_png(out.path_join("portrait_face.png"))
	quit()
