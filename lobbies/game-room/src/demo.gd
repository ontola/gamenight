extends Node
## Offline demo: a synthetic party with drawn faces and simple bots, for
## screenshots and for trying the room without a GameNight runtime.
##   godot --path . -- --demo [--scene=action|stations|sleep|empty] [--links=file.json]

var main
var scene := "action"
var bots: Dictionary = {}
var t := 0.0
var rng := RandomNumberGenerator.new()

const NAMES := ["Joep", "Mango", "Disco", "Waffle", "Pickle", "Rocket"]
const COLORS := ["#ff5c5c", "#2dd4bf", "#ffb454", "#a78bfa", "#7be08a", "#ff8fd6"]
const SKINS := ["#f5e9be", "#d7a477", "#edc59a", "#895735", "#b77b50", "#f5e9be"]

func _ready() -> void:
	rng.seed = 42
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--scene="): scene = argument.trim_prefix("--scene=")
	var count := 0 if scene == "empty" else (6 if scene == "action" else 4)
	var players: Array = []
	var seats: Array = []
	for i in count:
		players.append({"id": "p%d" % i, "name": NAMES[i], "color": COLORS[i], "skin_color": SKINS[i], "avatar": _face(i)})
		seats.append({"index": i, "occupant": {"kind": "local", "player_id": "p%d" % i}, "controller": "demo:%d" % i})
	var library := [
		{"id": "spaceracer", "title": "Space Racer", "color": "#38d6ff", "players": "1-8", "max_players": 8},
		{"id": "ballkickers", "title": "Ball Kickers", "color": "#3ddc97", "players": "2-8", "max_players": 8},
		{"id": "downhill-rush", "title": "Downhill Rush", "color": "#ffb454", "players": "1-4", "max_players": 4},
		{"id": "god-game", "title": "God Game", "color": "#ff4f8b", "players": "2-6", "max_players": 6},
		{"id": "pinpals", "title": "Pinpals", "color": "#a78bfa", "players": "1-4", "max_players": 4},
	]
	_cover_art(library)
	var entries := [{"game": "spaceracer", "title": "Space Racer"}, {"game": "ballkickers", "title": "Ball Kickers"},
		{"game": "god-game", "title": "God Game"}, {"game": "pinpals", "title": "Pinpals"}]
	var party := {"players": players, "seats": seats, "library": library,
		"playlist": {"entries": entries if scene != "empty" else []}, "presence": [],
		"warm_session": {"game": "spaceracer", "phase": "preparing", "progress": 64, "progress_label": "Loading"},
		"now_playing": {"title": "Midnight City", "artist": "M83", "playing": true, "source": "Spotify"}}
	if scene == "sleep": party.presence = [{"player_id": "p1", "state": "sleeping"}, {"player_id": "p3", "state": "sleeping"}]
	main.set_party(party)
	var links := {"room": {"room_code": "KJX4", "pending": [
		{"id": "pend1", "profile": {"display_name": "Sanne", "skin_color": "#edc59a", "avatar": _face(4)}},
		{"id": "pend2", "profile": {"display_name": "Thijs", "skin_color": "#b77b50", "avatar": _face(5)}}]}, "linked": {}}
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--links="):
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(argument.trim_prefix("--links=")))
			if data is Dictionary:
				links.room.qr_svg = data.get("room", {}).get("qr_svg", "")
				if str(data.get("room", {}).get("room_code", "")) != "": links.room.room_code = data.room.room_code
	main.set_links(links)
	_stage()

## Places bots for a screenshot. Bots keep moving afterwards.
func _stage() -> void:
	var w = main.world
	match scene:
		"action":
			var places := [[-6.0, 0.0], [-1.2, 0.0], [1.5, 6.55], [5.8, 0.85], [-9.6, 2.7], [8.8, 0.0]]
			for i in places.size():
				var p: Dictionary = w.players.get("p%d" % i, {})
				if p.is_empty(): continue
				p.x = places[i][0]; p.y = places[i][1]; p.spawn = 0
			w.players.p1.hat = "crown"
			w.players.p3.hat = "party"
			w.players.p4.hat = "headphones"
			var bomb: Dictionary = w.spawn_item("bomb", -3.6, 0.0)
			bomb.vx = 0.0; bomb.vy = 0.0; bomb.fuse = main._capture_at - 0.08
			w.spawn_item("ball", 2.8, 0.2)
			w.spawn_item("hatbox", 9.6, 3.15)
			var blaster: Dictionary = w.spawn_item("blaster", -6.0, 0.6)
			blaster.holder = "p0"; w.players.p0.item = blaster.id
			w.spawn_item("bomb", -5.4, 5.9)
		"stations":
			var places := [[-8.325, 0.0], [0.0, 0.0], [9.35, 0.0], [6.0, 0.85]]
			for i in places.size():
				var p: Dictionary = w.players["p%d" % i]
				p.x = places[i][0]; p.y = places[i][1]; p.spawn = 0
				p.facing = -1.0 if p.x > 0 else 1.0
			w.players.p2.hat = "beanie"
		"sleep":
			for i in 4:
				var p: Dictionary = w.players["p%d" % i]
				p.x = [5.4, 6.4, 7.4, -2.0][i]; p.y = [0.85, 0.85, 0.85, 0.0][i]; p.spawn = 0
	for id in w.players: bots[id] = {"target": w.players[id].x, "next": rng.randf_range(0.5, 2.0), "jump": 0.0}

func tick(delta: float) -> void:
	t += delta
	var w = main.world
	for id in w.players:
		var p: Dictionary = w.players[id]
		var bot: Dictionary = bots.get(id, {})
		if bot.is_empty(): continue
		var buttons := 0
		var stick := Vector2.ZERO
		var still: bool = scene == "stations" or (scene == "sleep") or (scene == "action" and t < main._capture_at - 0.6)
		if scene == "action" and t < 1.0: still = true
		if not still:
			bot.next -= delta
			if bot.next <= 0:
				bot.next = rng.randf_range(1.0, 3.0)
				bot.target = rng.randf_range(-10.5, 10.5)
			if absf(bot.target - p.x) > 0.4: stick.x = signf(bot.target - p.x)
			bot.jump -= delta
			if bot.jump <= 0 and rng.randf() < 0.03:
				buttons |= 1
				bot.jump = 0.5
			elif bot.jump > 0.2: buttons |= 1
			if rng.randf() < 0.01: buttons |= 2
			if rng.randf() < 0.02: buttons |= 4
		main.input(id, buttons, stick)
	if scene == "action":
		# A mid-air pose for the screenshot: one player leaping, one punched.
		if absf(t - (main._capture_at - 0.25)) < delta:
			w.players.p1.vy = 9.0; w.players.p1.grounded = false
			w.players.p5.stun = 0.4

func _face(style: int) -> String:
	var px: Array = []
	px.resize(48 * 48)
	px.fill(null)
	var ink := "#1d1b2c"
	var set_px := func(x: int, y: int, c: String):
		if x >= 0 and y >= 0 and x < 48 and y < 48: px[y * 48 + x] = c
	var rect := func(x0: int, y0: int, w: int, h: int, c: String):
		for y in range(y0, y0 + h):
			for x in range(x0, x0 + w): set_px.call(x, y, c)
	var hair: String = ["#3b2416", "#f2c14e", "#1d1b2c", "#c0392b", "#7b4a2a", "#e8e0d0"][style]
	# Hair across the top of the head (the head circle is centred at 24,28).
	match style % 3:
		0:
			rect.call(14, 16, 20, 4, hair); rect.call(13, 19, 4, 5, hair); rect.call(31, 19, 4, 5, hair)
		1:
			rect.call(15, 15, 18, 3, hair); rect.call(13, 17, 22, 3, hair); rect.call(20, 13, 4, 3, hair)
		2:
			for x in range(13, 36, 3): rect.call(x, 15, 2, 4, hair)
			rect.call(14, 18, 20, 2, hair)
	# Eyes, with variations.
	if style == 2:
		rect.call(17, 24, 6, 5, ink); rect.call(26, 24, 6, 5, ink); rect.call(23, 25, 3, 1, ink)
		rect.call(18, 25, 4, 3, "#38d6ff"); rect.call(27, 25, 4, 3, "#38d6ff")
	else:
		rect.call(19, 25, 2, 3, ink); rect.call(27, 25, 2, 3, ink)
		set_px.call(19, 25, "#ffffff"); set_px.call(27, 25, "#ffffff")
	# Mouth.
	match style:
		0, 3: rect.call(21, 33, 6, 1, ink); set_px.call(20, 32, ink); set_px.call(27, 32, ink)
		1: rect.call(22, 32, 4, 3, "#9e5546"); rect.call(22, 32, 4, 1, ink)
		4: rect.call(20, 32, 8, 2, "#ffffff"); rect.call(20, 34, 8, 1, ink)
		_: rect.call(22, 33, 4, 1, ink)
	if style == 5: rect.call(17, 32, 14, 5, "#7b4a2a")
	# Cheeks.
	set_px.call(16, 30, "#f28b82"); set_px.call(17, 30, "#f28b82"); set_px.call(31, 30, "#f28b82"); set_px.call(32, 30, "#f28b82")
	return JSON.stringify({"v": 1, "w": 48, "h": 48, "px": px})

## Simple generated cover art so the demo screens are not just title cards.
func _cover_art(library: Array) -> void:
	for i in library.size():
		var img := Image.create(320, 200, false, Image.FORMAT_RGBA8)
		var base := Color(library[i].color)
		var r := RandomNumberGenerator.new()
		r.seed = i * 31 + 3
		for y in 200:
			var c := base.darkened(0.75).lerp(base.darkened(0.2), y / 200.0)
			img.fill_rect(Rect2i(0, y, 320, 1), c)
		match i:
			0:
				for s in 60: img.set_pixel(r.randi_range(0, 319), r.randi_range(0, 120), Color.WHITE)
				for x in 320:
					var h := int(130 + sin(x * 0.03) * 12 + sin(x * 0.11) * 5)
					img.fill_rect(Rect2i(x, h, 1, 200 - h), base.darkened(0.6))
				img.fill_rect(Rect2i(140, 120, 40, 10), Color("ffb454"))
				img.fill_rect(Rect2i(150, 112, 20, 8), Color("f2f1f8"))
			1:
				img.fill_rect(Rect2i(0, 120, 320, 80), Color("2f8f5a"))
				for x in range(0, 320, 40): img.fill_rect(Rect2i(x, 120, 20, 80), Color("37a466"))
				img.fill_rect(Rect2i(158, 120, 4, 80), Color("f2f1f8"))
				for y in 12:
					for x in 12:
						if Vector2(x - 5.5, y - 5.5).length() < 6: img.set_pixel(200 + x, 100 + y, Color("f2f1f8"))
			2:
				for x in 320:
					var h := int(40 + x * 0.45 + sin(x * 0.05) * 10)
					img.fill_rect(Rect2i(x, h, 1, 200 - h), Color("eef4ff"))
				for x in range(30, 300, 60): img.fill_rect(Rect2i(x, int(40 + x * 0.45) - 30, 10, 30), Color("1f5c3a"))
			3:
				for y in 200:
					for x in 320:
						if Vector2(x - 160, (y - 140) * 1.6).length() < 110: img.set_pixel(x, y, Color("3a7d44"))
				img.fill_rect(Rect2i(150, 70, 20, 40), Color("fff3c8"))
			4:
				for k in 8:
					var cx := r.randi_range(30, 290)
					var cy := r.randi_range(30, 170)
					for y in 20:
						for x in 20:
							if Vector2(x - 10, y - 10).length() < 9: img.set_pixel(cx + x - 10, cy + y - 10, Color.from_hsv(r.randf(), 0.6, 1.0))
		var png := img.save_png_to_buffer()
		library[i]["cover"] = "data:image/png;base64," + Marshalls.raw_to_base64(png)
