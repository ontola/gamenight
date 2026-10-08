extends RefCounted
## Builds a pixel-art sprite sheet for one player: a chibi body in the
## player's clothing colour with their own drawn face on a big round head.
## The head is radius 12 at 1:1, the canonical face scale, so profile art
## keeps every pixel. Frames are laid out in one row (see FRAMES).

const W := 32
const H := 46
const HEAD := Vector2(16, 13)
const RADIUS := 12
const INK := Color("0b0b12")
const FRAMES := ["idle0", "idle1", "walk0", "walk1", "walk2", "walk3", "jump", "fall", "sleep", "carry", "throw", "cheer"]
const HATS := ["none", "cap", "crown", "party", "tophat", "beanie", "headphones"]

static func frame_index(name: String) -> int:
	return maxi(0, FRAMES.find(name))

## Returns an ImageTexture atlas with FRAMES.size() columns.
static func build(player: Dictionary, face: Dictionary, hat: String = "none") -> ImageTexture:
	var sheet := Image.create(W * FRAMES.size(), H, false, Image.FORMAT_RGBA8)
	sheet.fill(Color.TRANSPARENT)
	var cloth := Color.from_string(str(player.get("color", "")), Color("7c5cff"))
	var skin := Color.from_string(str(player.get("skin_color", "")), Color("f5e9be"))
	for i in FRAMES.size():
		var frame := Image.create(W, H, false, Image.FORMAT_RGBA8)
		frame.fill(Color.TRANSPARENT)
		_draw_frame(frame, FRAMES[i], cloth, skin, face, hat)
		_outline(frame)
		sheet.blit_rect(frame, Rect2i(0, 0, W, H), Vector2i(i * W, 0))
	return ImageTexture.create_from_image(sheet)

static func _draw_frame(img: Image, frame: String, cloth: Color, skin: Color, face: Dictionary, hat: String) -> void:
	var bob := 0
	var legs := [0, 0]   # forward offset of left/right foot
	var lift := [0, 0]   # how far each foot is raised
	var arms := ["down", "down"]
	var sleeping := frame == "sleep"
	match frame:
		"idle1": bob = 1
		"walk0": legs = [2, -2]
		"walk1": legs = [0, 0]; lift = [0, 1]; bob = -1
		"walk2": legs = [-2, 2]
		"walk3": legs = [0, 0]; lift = [1, 0]; bob = -1
		"jump": legs = [1, -1]; lift = [2, 0]; arms = ["up", "up"]; bob = -1
		"fall": legs = [-1, 1]; lift = [0, 1]; arms = ["out", "out"]
		"sleep": bob = 5; arms = ["down", "down"]
		"carry": arms = ["forward", "forward"]
		"throw": arms = ["up", "forward"]; legs = [2, -1]
		"cheer": arms = ["up", "up"]; bob = -1
	var dark := cloth.darkened(0.35)
	var light := cloth.lightened(0.25)
	var pants := Color("2a2840")
	var shoe := Color("15141f")
	# Legs and shoes. Sleeping players sit, so their legs fold forward.
	if sleeping:
		_rect(img, Rect2i(9, 40, 15, 4), pants)
		_rect(img, Rect2i(22, 40, 4, 4), shoe)
	else:
		for side in 2:
			var x: int = (11 if side == 0 else 17) + legs[side]
			var top := 36 + bob
			var bottom: int = 44 - lift[side]
			_rect(img, Rect2i(x, top, 4, bottom - top), pants)
			_rect(img, Rect2i(x - (1 if side == 0 else 0), bottom - 1, 5, 2), shoe)
	# Torso: a rounded jacket with a darker side and a highlight.
	var torso := Rect2i(9, 25 + bob, 14, 12 if not sleeping else 9)
	_rect(img, torso, cloth)
	_rect(img, Rect2i(torso.position.x, torso.position.y, 2, torso.size.y), dark)
	_rect(img, Rect2i(torso.end.x - 3, torso.position.y + 1, 2, torso.size.y - 2), light)
	img.set_pixel(torso.position.x, torso.end.y - 1, Color.TRANSPARENT)
	img.set_pixel(torso.end.x - 1, torso.end.y - 1, Color.TRANSPARENT)
	# Arms.
	for side in 2:
		var x := 6 if side == 0 else 23
		var y := torso.position.y + 1
		match arms[side]:
			"down":
				_rect(img, Rect2i(x, y, 3, 9), dark if side == 0 else cloth)
				_rect(img, Rect2i(x, y + 9, 3, 2), skin)
			"up":
				_rect(img, Rect2i(x, y - 8, 3, 9), dark if side == 0 else cloth)
				_rect(img, Rect2i(x, y - 10, 3, 2), skin)
			"out":
				_rect(img, Rect2i(x - (3 if side == 0 else 0), y, 6, 3), dark if side == 0 else cloth)
				_rect(img, Rect2i((x - 5) if side == 0 else (x + 6), y, 2, 3), skin)
			"forward":
				_rect(img, Rect2i(x, y, 3, 5), dark if side == 0 else cloth)
				_rect(img, Rect2i(23, y + 4, 7, 3), cloth if side == 1 else dark)
				_rect(img, Rect2i(29, y + 4, 2, 3), skin)
	# Head: skin disc, the player's face art at 1:1, then the hat.
	var head := HEAD + Vector2(0, bob)
	for y in H:
		for x in W:
			if Vector2(x + 0.5, y + 0.5).distance_to(head) <= RADIUS:
				img.set_pixel(x, y, skin)
	if face.has("image"):
		var art: Image = face.image
		var origin := Vector2i(head - face.center)
		for v in art.get_height():
			for u in art.get_width():
				var c := art.get_pixel(u, v)
				if c.a < 0.5: continue
				var p := origin + Vector2i(u, v)
				if p.x >= 0 and p.y >= 0 and p.x < W and p.y < H:
					img.set_pixel(p.x, p.y, c)
	else:
		# Same default face as the shared helpers.
		var eye_y := int(head.y) - 2
		if sleeping:
			_rect(img, Rect2i(int(head.x) - 1, eye_y, 3, 1), INK)
			_rect(img, Rect2i(int(head.x) + 5, eye_y, 3, 1), INK)
		else:
			_rect(img, Rect2i(int(head.x) - 1, eye_y - 1, 2, 2), INK)
			_rect(img, Rect2i(int(head.x) + 5, eye_y - 1, 2, 2), INK)
		_rect(img, Rect2i(int(head.x) + 2, int(head.y) + 5, 4, 1), INK)
	if sleeping:
		# Hands over the eyes, like the platformer lobby: drawn faces cannot close their eyes.
		var hand := skin.darkened(0.08)
		for side in [-1, 1]:
			var hx: int = int(head.x) + (side * 5) - 3 + (2 if side > 0 else 0)
			_rect(img, Rect2i(hx, int(head.y) - 5, 7, 6), hand)
			_rect(img, Rect2i(hx, int(head.y) - 5, 7, 1), skin.lightened(0.15))
			_rect(img, Rect2i(hx + 1, int(head.y) + 1, 5, 4), cloth.darkened(0.2))
	_hat(img, hat, head, cloth)

static func _hat(img: Image, hat: String, head: Vector2, cloth: Color) -> void:
	var x := int(head.x)
	var top := int(head.y) - RADIUS
	match hat:
		"cap":
			_rect(img, Rect2i(x - 9, top + 1, 18, 4), cloth.darkened(0.2))
			_rect(img, Rect2i(x - 7, top - 1, 14, 2), cloth.darkened(0.2))
			_rect(img, Rect2i(x + 6, top + 4, 9, 2), cloth.darkened(0.45))
		"crown":
			var gold := Color("ffcf5a")
			_rect(img, Rect2i(x - 8, top - 1, 16, 4), gold)
			for i in 4:
				_rect(img, Rect2i(x - 8 + i * 5, top - 4, 2, 3), gold)
			img.set_pixel(x - 1, top, Color("ff4f8b")); img.set_pixel(x, top, Color("ff4f8b"))
		"party":
			var pink := Color("ff4f8b")
			for i in 10:
				_rect(img, Rect2i(x - 5 + i / 2, top + 2 - i, 10 - i, 1), pink if i % 3 else Color("ffb454"))
			_rect(img, Rect2i(x - 1, top - 10, 2, 2), Color("3ddc97"))
		"tophat":
			var black := Color("1d1b2c")
			_rect(img, Rect2i(x - 10, top + 1, 20, 2), black)
			_rect(img, Rect2i(x - 6, top - 9, 12, 10), black)
			_rect(img, Rect2i(x - 6, top - 2, 12, 2), Color("7c5cff"))
		"beanie":
			var wool := Color("3ddc97")
			_rect(img, Rect2i(x - 10, top + 1, 20, 5), wool)
			_rect(img, Rect2i(x - 8, top - 2, 16, 3), wool)
			_rect(img, Rect2i(x - 10, top + 4, 20, 2), wool.darkened(0.3))
			_rect(img, Rect2i(x - 2, top - 5, 4, 3), Color("f2f1f8"))
		"headphones":
			var band := Color("2b2b3d")
			_rect(img, Rect2i(x - 10, top - 1, 20, 2), band)
			_rect(img, Rect2i(x - 13, int(head.y) - 4, 4, 8), Color("ffb454"))
			_rect(img, Rect2i(x + 9, int(head.y) - 4, 4, 8), Color("ffb454"))

static func _rect(img: Image, rect: Rect2i, color: Color) -> void:
	var clipped := rect.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if clipped.size.x > 0 and clipped.size.y > 0:
		img.fill_rect(clipped, color)

## One-pixel dark outline around every opaque shape: classic sprite look,
## and it keeps light faces readable against bright neon.
static func _outline(img: Image) -> void:
	var source := img.duplicate()
	for y in H:
		for x in W:
			if source.get_pixel(x, y).a > 0.5: continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var p: Vector2i = Vector2i(x, y) + d
				if p.x >= 0 and p.y >= 0 and p.x < W and p.y < H and source.get_pixelv(p).a > 0.5:
					img.set_pixel(x, y, INK)
					break

## Decodes profile art through the shared face helper into a plain Image.
static func decode_face(faces, player: Dictionary) -> Dictionary:
	var decoded: Dictionary = faces.decode(str(player.get("avatar", "")))
	if decoded.is_empty(): return {}
	var tex: Texture2D = decoded.texture
	return {"image": tex.get_image(), "center": decoded.center}
