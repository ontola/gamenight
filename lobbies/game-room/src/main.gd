extends Node3D
## GameNight Game Room: a 2.5D platformer lobby. The runtime owns players,
## seats, controllers and sessions; this scene turns them into a room where
## everyone runs, jumps and fights over bombs while choosing the next game.
##
## Controls: stick/D-pad move, A jump (down + A drops through), B grab/throw,
## X punch/use, Y use the station you stand at, LB/RB browse the game shelf,
## Start opens your menu.

const LobbyClient = preload("res://addons/gamenight/lobby.gd")
const Artwork = preload("res://addons/gamenight/artwork.gd")
const World = preload("res://src/world.gd")
const Layout = preload("res://src/layout.gd")
const Room = preload("res://src/room.gd")
const View = preload("res://src/view.gd")
const Canvas = preload("res://src/canvas.gd")
const Character = preload("res://src/character.gd")
const Demo = preload("res://src/demo.gd")

const AMBER := Color("ffb454")
const VIOLET := Color("7c5cff")
const GREEN := Color("3ddc97")
const PINK := Color("ff4f8b")
const BG := Color("0b0b12")
const TEXT := Color("f2f1f8")
const DIM := Color("9a98ad")
const BTN_LB := 16
const BTN_START := 128
const BTN_RB := 32

var client = LobbyClient.new()
var artwork = Artwork.new()
var world = World.new()
var room
var view
var hud: Control
var font: FontFile
var bold: FontFile
var party: Dictionary = {}
var profiles: Dictionary = {}       # player id -> player
var controllers: Dictionary = {}    # controller token -> player id
var held: Dictionary = {}           # player id -> button bitmask
var menus: Dictionary = {}          # player id -> {index, confirm}
var shelf_offset := 0
var toasts: Array = []
var links: Dictionary = {}          # /api/player-links response
var qr: Texture2D
var _qr_source := ""
var _links_base := ""
var _links := HTTPRequest.new()
var _pickup := HTTPRequest.new()
var _pickup_cooldown := 0.0
var _accumulator := 0.0
var _station_cooldown: Dictionary = {}
var _pressed_flash: Dictionary = {}  # station id -> time of last press
var _door_nodes: Array = []
var _door_key := ""
var _screen_key := ""
var _shelf_key := ""
var _time := 0.0
var demo                            # demo.gd when running with --demo
var _capture_path := ""
var _capture_at := 4.0
var _captured := false
var _fullscreen := false
var _last_input: Dictionary = {}

func _ready() -> void:
	room = Room.new()
	font = Room.load_font()
	bold = Room.load_font(800)
	add_child(room)
	view = View.new()
	view.room = room
	add_child(view)
	add_child(artwork)
	artwork.changed.connect(_redraw_screens)
	_hook_screens()
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Canvas.new()
	hud.painter = _draw_hud
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)
	var args := OS.get_cmdline_user_args()
	for argument in args:
		if argument.begins_with("--capture="): _capture_path = argument.trim_prefix("--capture=")
		if argument.begins_with("--capture-at="): _capture_at = float(argument.trim_prefix("--capture-at="))
	_fullscreen = OS.get_environment("GAMENIGHT_LOBBY_FULLSCREEN") == "1"
	if args.has("--demo"):
		demo = Demo.new()
		demo.main = self
		add_child(demo)
		return
	_links_base = OS.get_environment("GAMENIGHT_LINKS_URL")
	if _links_base.is_empty(): _links_base = "http://127.0.0.1:7913"
	if not _links_base.begins_with("http://127.0.0.1:"): _links_base = ""
	_links.timeout = 3
	_pickup.timeout = 3
	add_child(_links)
	add_child(_pickup)
	_links.request_completed.connect(_links_received)
	_pickup.request_completed.connect(func(_r, code, _h, body: PackedByteArray):
		if code >= 300:
			print("pickup refused: ", code, " ", body.get_string_from_utf8().left(200))
			toast("That profile could not be picked up. Try again.", PINK))
	if not _links_base.is_empty():
		var timer := Timer.new()
		timer.wait_time = 1.0
		timer.timeout.connect(func():
			if _links.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
				_links.request(_links_base + "/api/player-links"))
		add_child(timer)
		timer.start()
	if args.has("--test-flow"):
		var flow: Node = load("res://tests/flow.gd").new()
		flow.main = self
		add_child(flow)
		_capture_path = _capture_path if not _capture_path.is_empty() else "-"
	client.party_changed.connect(set_party)
	client.focus_changed.connect(_focus_changed)
	client.controllers_changed.connect(_controllers_changed)
	client.connection_changed.connect(func(ok: bool):
		if not ok: toast("Reconnecting… your party is still here.", AMBER)
		hud.queue_redraw())
	client.rejected.connect(func(message: String): toast(message, PINK))
	add_child(client)
	get_tree().auto_accept_quit = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if client.connected and demo == null: client.quit_party()
		else: get_tree().quit()

func _focus_changed(active: bool) -> void:
	Engine.max_fps = 60 if active else 10
	AudioServer.set_bus_mute(0, not active)
	if DisplayServer.get_name() != "headless" and _capture_path.is_empty():
		if active:
			get_window().mode = Window.MODE_FULLSCREEN if _fullscreen else Window.MODE_WINDOWED
			get_window().grab_focus()
		else:
			get_window().mode = Window.MODE_MINIMIZED

# ---------------------------------------------------------------- party state

func set_party(snapshot: Dictionary) -> void:
	party = snapshot
	profiles.clear()
	for player in party.get("players", []): profiles[str(player.id)] = player
	controllers.clear()
	var slots: Dictionary = {}
	for seat in party.get("seats", []):
		var occupant: Dictionary = seat.get("occupant", {})
		if not occupant.has("player_id"): continue
		var id := str(occupant.player_id)
		slots[id] = int(seat.get("index", 0))
		if seat.get("controller") != null: controllers[str(seat.controller)] = id
	for id in world.players.keys():
		if not profiles.has(id):
			world.remove_player(id)
			menus.erase(id)
	var i := 0
	for id in profiles:
		world.ensure_player(id, slots.get(id, i))
		i += 1
	view.sync_profiles(profiles, world.players)
	_update_sleep()
	var shelf := shelf_games()
	if shelf.size() > 0: shelf_offset = posmod(shelf_offset, shelf.size())
	_redraw_screens()

func shelf_games() -> Array:
	return party.get("library", []).filter(func(g): return str(g.get("id")) != client.lobby_id)

func game_meta(id: String) -> Dictionary:
	for game in party.get("library", []):
		if str(game.get("id")) == id: return game
	return {}

func upcoming() -> Array:
	var playlist: Dictionary = party.get("playlist", {})
	var entries: Array = playlist.get("entries", [])
	var start := 0 if playlist.get("current") == null else int(playlist.current) + 1
	var result: Array = []
	for index in range(start, entries.size()):
		if str(entries[index].game) == client.lobby_id: continue
		result.append({"index": index, "game": str(entries[index].game), "title": str(entries[index].get("title", "Game"))})
	return result

func current_game() -> Dictionary:
	var session: Variant = party.get("active_session")
	if not session is Dictionary or session.is_empty() or str(session.get("game")) == client.lobby_id: return {}
	var meta := game_meta(str(session.game))
	if meta.is_empty(): meta = {"id": session.game, "title": str(session.game)}
	meta = meta.duplicate()
	meta["phase"] = session.get("phase", "")
	return meta

func _update_sleep() -> void:
	var sleeping := {}
	for presence in party.get("presence", []):
		if presence.get("state") == "sleeping": sleeping[str(presence.player_id)] = true
	for id in world.players:
		var p: Dictionary = world.players[id]
		var quiet: bool = world.time - float(p.last_input) > 1.0
		p.sleeping = sleeping.has(id) and quiet

# ---------------------------------------------------------------- input

func _controllers_changed(frames: Array) -> void:
	for frame in frames:
		var token := str(frame.get("controller", ""))
		var id: String = controllers.get(token, "")
		if id.is_empty(): continue
		var buttons := int(frame.get("buttons", 0))
		var axes: Array = frame.get("axes", [0, 0, 0, 0, 0, 0])
		var stick := Vector2(float(axes[0]) / 32767.0, float(axes[1]) / 32767.0) if axes.size() >= 2 else Vector2.ZERO
		input(id, buttons, stick)

## Routes one player's controller state; demo bots use the same path.
func input(id: String, buttons: int, stick: Vector2) -> void:
	if not world.players.has(id): return
	var before: int = held.get(id, 0)
	var pressed := buttons & ~before
	held[id] = buttons
	if buttons != 0 or stick.length() > 0.3:
		world.players[id].last_input = world.time
		world.players[id].sleeping = false
	if pressed & BTN_START:
		if menus.has(id): menus.erase(id)
		else: menus[id] = {"index": 0, "confirm": false}
		hud.queue_redraw()
	if menus.has(id):
		_menu_input(id, pressed, stick)
		world.set_input(id, 0, Vector2.ZERO)
		return
	world.set_input(id, buttons, stick)
	if pressed & World.BTN_Y: _use_station(id)
	if pressed & (BTN_LB | BTN_RB) and station_for(id).get("kind") == "shelf":
		_browse(-1 if pressed & BTN_LB else 1)

func _browse(step: int) -> void:
	var shelf := shelf_games()
	if shelf.is_empty(): return
	shelf_offset = posmod(shelf_offset + step, shelf.size())
	room.pop_box(step)
	_redraw_screens()

# ---------------------------------------------------------------- stations

## What the player can use where they stand, or {} when nothing.
func station_for(id: String) -> Dictionary:
	var p: Dictionary = world.players.get(id, {})
	if p.is_empty() or not p.grounded or p.y > 0.1 or p.sleeping: return {}
	var shelf := shelf_games()
	if p.x >= Layout.GAME_SHELF.x and p.x <= Layout.GAME_SHELF.y and not shelf.is_empty():
		var game: Dictionary = shelf[shelf_offset % shelf.size()]
		var reason := _unavailable(game)
		return {"id": "shelf", "kind": "shelf", "game": game.id, "title": str(game.get("title", "Game")),
			"label": reason if not reason.is_empty() else "Queue %s" % str(game.get("title", "game")),
			"enabled": reason.is_empty(), "extra": "LB RB browse" if shelf.size() > 1 else ""}
	for i in Layout.TV_PADS.size():
		if absf(p.x - Layout.TV_PADS[i]) <= Layout.PAD_HALF:
			var pad := tv_pad(i)
			pad["id"] = "pad%d" % i
			pad["kind"] = "pad"
			return pad
	if not party.get("now_playing", {}).is_empty():
		var labels := ["Previous track", "Play / pause music", "Next track"]
		var actions := ["previous_track", "play_pause", "next_track"]
		for i in 3:
			if absf(p.x - Layout.MUSIC_PADS[i]) <= 0.3:
				return {"id": "music%d" % i, "kind": "music", "label": labels[i], "action": actions[i], "enabled": true}
	if absf(p.x - Layout.EXIT_DOOR) <= 0.6:
		return {"id": "exit", "kind": "exit", "label": "Leave", "enabled": true}
	var pending := pending_profiles()
	for i in mini(pending.size(), Layout.PROFILE_DOORS.size()):
		if absf(p.x - Layout.PROFILE_DOORS[i]) <= Layout.DOOR_HALF:
			var linked: bool = links.get("linked", {}).has(id)
			var name := str(pending[i].get("profile", {}).get("display_name", "Player"))
			return {"id": "door%d" % i, "kind": "door", "pending": str(pending[i].get("id", "")),
				"label": "Unlink first to pick up %s" % name if linked else "Pick up %s" % name, "enabled": not linked}
	return {}

func tv_pad(index: int) -> Dictionary:
	var live := not current_game().is_empty()
	var queue := upcoming()
	match index:
		0:
			if live: return {"label": "Resume %s" % current_game().get("title", "game"), "action": "resume", "enabled": true}
			return {"label": "Play %s" % queue[0].title if not queue.is_empty() else "Queue a game first", "action": "next", "enabled": not queue.is_empty()}
		1:
			return {"label": "Start %s" % queue[0].title if not queue.is_empty() else "Nothing queued", "action": "next", "enabled": not queue.is_empty()}
		_:
			return {"label": "Skip to %s" % queue[1].title if queue.size() > 1 else "Nothing to skip to", "action": "skip", "enabled": queue.size() > 1}

func _unavailable(game: Dictionary) -> String:
	if not client.connected and demo == null: return "Waiting for GameNight"
	var count: int = profiles.size()
	if game.get("max_players") != null and count > int(game.max_players): return "Too many players"
	if game.get("min_players") != null and count < int(game.min_players): return "Needs %d players" % int(game.min_players)
	return ""

func _use_station(id: String) -> void:
	var station := station_for(id)
	if station.is_empty() or not station.enabled: return
	var now := Time.get_ticks_msec() / 1000.0
	if now < float(_station_cooldown.get(station.id, 0.0)): return
	_station_cooldown[station.id] = now + 0.4
	match station.kind:
		"shelf":
			client.queue_game(str(station.game), false)
			toast("%s added to the queue." % station.title, GREEN)
		"pad":
			match station.action:
				"resume": client.resume_game()
				"next": client.start_next()
				"skip":
					var queue := upcoming()
					if queue.size() > 1: client._command({"type": "queue_next", "game": queue[1].game})
		"music": client.media_control(str(station.action))
		"exit":
			client.leave(id)
			toast("%s left. Press a button to join again." % _name(id), DIM)
		"door":
			if _links_base.is_empty() or now < _pickup_cooldown: return
			_pickup_cooldown = now + 5.0
			var sent := _pickup.request(_links_base + "/api/room-pickup/" + str(station.pending) + "/" + id,
				["X-GameNight-Local-Pickup: 1"], HTTPClient.METHOD_POST)
			if sent != OK: toast("That profile could not be picked up. Try again.", PINK)
			toast("Welcome in!", GREEN)
	_celebrate(id, str(station.id))

func _celebrate(id: String, station_id: String) -> void:
	_pressed_flash[station_id] = _time
	if world.players.has(id): world.players[id].cheer = 0.45
	var p: Dictionary = world.players.get(id, {})
	if not p.is_empty():
		view.burst(Vector3(p.x, p.y + 1.6, 0.3), 28, [AMBER, VIOLET, GREEN, PINK], 4.5, 0.9, 0.07, true)
		room.flash(Vector3(p.x, 1.2, 1.0), AMBER, 4.0, 4.0)

# ---------------------------------------------------------------- menu

func menu_items(id: String) -> Array:
	var items := [{"label": "Close menu", "action": "close"}, {"label": "Leave the party", "action": "leave"}]
	if links.get("linked", {}).has(id): items.insert(1, {"label": "Unlink my phone profile", "action": "unlink"})
	items.append({"label": "Select other lobby", "action": "chooser"})
	items.append({"label": "Quit GameNight", "action": "quit"})
	return items

func _menu_input(id: String, pressed: int, stick: Vector2) -> void:
	var menu: Dictionary = menus[id]
	var items := menu_items(id)
	var up: bool = pressed & World.BTN_UP or (stick.y < -0.6 and not menu.get("stick", false))
	var down: bool = pressed & World.BTN_DOWN or (stick.y > 0.6 and not menu.get("stick", false))
	menu["stick"] = absf(stick.y) > 0.6
	if up: menu.index = posmod(menu.index - 1, items.size()); menu.confirm = false
	if down: menu.index = posmod(menu.index + 1, items.size()); menu.confirm = false
	if pressed & World.BTN_B:
		menus.erase(id)
	elif pressed & World.BTN_A:
		var action: String = items[menu.index].action
		match action:
			"close": menus.erase(id)
			"leave":
				menus.erase(id)
				client.leave(id)
			"unlink":
				menus.erase(id)
				if not _links_base.is_empty():
					_pickup.request(_links_base + "/api/player-links/" + id + "/unlink", ["X-GameNight-Local-Pickup: 1"], HTTPClient.METHOD_POST)
			"chooser":
				var url := OS.get_environment("GAMENIGHT_LOBBY_CHOOSER_URL")
				if not url.begins_with("http://127.0.0.1:"): url = "http://127.0.0.1:7913/host/lobby"
				OS.shell_open(url)
				menus.erase(id)
			"quit":
				if menu.confirm:
					if client.connected: client.quit_party()
					else: get_tree().quit()
				else: menu.confirm = true
	hud.queue_redraw()

# ---------------------------------------------------------------- phone links

func pending_profiles() -> Array:
	var now := Time.get_unix_time_from_system()
	return links.get("room", {}).get("pending", []).filter(func(p):
		var expires: Variant = p.get("expires")
		return not (expires is float or expires is int) or float(expires) > now or float(expires) < 1e9)

func _links_received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		set_links({})
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if data is Dictionary: set_links(data)

func set_links(data: Dictionary) -> void:
	links = data
	var source: String = links.get("room", {}).get("qr_svg", "")
	if source != _qr_source:
		_qr_source = source
		qr = null
		var image := Image.new()
		if not source.is_empty() and source.length() < 200000 and image.load_svg_from_string(source, 6.0) == OK:
			qr = ImageTexture.create_from_image(image)
	_sync_doors()
	room.redraw("plaque")

func _sync_doors() -> void:
	var pending := pending_profiles()
	var key := JSON.stringify(pending.slice(0, Layout.PROFILE_DOORS.size()))
	if key == _door_key: return
	_door_key = key
	for node in _door_nodes: node.queue_free()
	_door_nodes.clear()
	for i in mini(pending.size(), Layout.PROFILE_DOORS.size()):
		var profile: Dictionary = pending[i].get("profile", {})
		_door_nodes.append(_make_door(Layout.PROFILE_DOORS[i], profile))

func _make_door(x: float, profile: Dictionary) -> Node3D:
	var node := Node3D.new()
	room.add_child(node)
	var z := Layout.BACK + 0.08
	var frame: StandardMaterial3D = room.mat(Color("2a1d3a"), 0.5)
	room.box(Vector3(1.25, 2.35, 0.14), Vector3(x, 1.17, z), frame, node)
	# The doorway glows: someone is waiting on the other side.
	room.box(Vector3(1.0, 2.1, 0.04), Vector3(x, 1.05, z + 0.08), room.mat(Color("6a3a1c"), 0.3, 0, AMBER, 0.55), node, false)
	var color := Color.from_string(str(profile.get("skin_color", "")), AMBER)
	for p in [[Vector3(-0.6, 0, 0.12), Vector3(-0.6, 2.3, 0.12)], [Vector3(0.6, 0, 0.12), Vector3(0.6, 2.3, 0.12)], [Vector3(-0.6, 2.3, 0.12), Vector3(0.6, 2.3, 0.12)]]:
		var tube: MeshInstance3D = room.neon_line(Vector3(x, 0, z) + p[0], Vector3(x, 0, z) + p[1], AMBER, 3.5, 0.05, 3.0)
		tube.reparent(node)
	var waiting := Sprite3D.new()
	waiting.texture = Character.build({"color": "#8c9be6", "skin_color": profile.get("skin_color", "#f5e9be"), "avatar": profile.get("avatar", "")},
		Character.decode_face(view.faces, profile))
	waiting.hframes = Character.FRAMES.size()
	waiting.frame = Character.frame_index("idle0")
	waiting.pixel_size = 0.04
	waiting.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	waiting.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	waiting.shaded = true
	waiting.offset = Vector2(0, Character.H / 2.0 - 2)
	waiting.position = Vector3(x, 0.0, z + 0.14)
	node.add_child(waiting)
	var tag: Label3D = room.label(str(profile.get("display_name", "Player")).left(20), Vector3(x, 2.65, z + 0.2), 36, Color(2.2, 1.6, 0.8), node, 10)
	tag.name = "tag"
	var light := OmniLight3D.new()
	light.light_color = color.lerp(AMBER, 0.5)
	light.light_energy = 2.0
	light.omni_range = 3.0
	light.position = Vector3(x, 1.2, z + 0.9)
	node.add_child(light)
	return node

# ---------------------------------------------------------------- loop

func _physics_process(delta: float) -> void:
	_accumulator = minf(_accumulator + delta, 0.1)
	while _accumulator >= World.DT:
		_accumulator -= World.DT
		world.step()

func _process(delta: float) -> void:
	_time += delta
	if demo != null: demo.tick(delta)
	_update_sleep()
	view.sync_profiles(profiles, world.players)
	view.update(world, delta)
	_update_pads()
	var next := current_game()
	if next.is_empty():
		var queue := upcoming()
		if not queue.is_empty(): next = game_meta(queue[0].game)
	room.set_mood(Color.from_string(str(next.get("color", "")), VIOLET) if not next.is_empty() else VIOLET)
	var key := JSON.stringify([party.get("warm_session"), party.get("warming"), party.get("game_issues"), party.get("now_playing"), shelf_offset])
	if key != _screen_key:
		_screen_key = key
		_redraw_screens()
	toasts = toasts.filter(func(t): return t.until > _time)
	hud.queue_redraw()
	if not _capture_path.is_empty() and _capture_path != "-" and not _captured and _time >= _capture_at:
		_captured = true
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture_path)
		print("LOBBY_CAPTURE ", _capture_path, " ", error)
		if demo != null: get_tree().quit()

func _update_pads() -> void:
	var occupied := {}
	for id in world.players:
		var station := station_for(id)
		if not station.is_empty(): occupied[station.id] = station
	for i in Layout.TV_PADS.size():
		var pad := tv_pad(i)
		var since := _time - float(_pressed_flash.get("pad%d" % i, -10.0))
		var energy := 0.6 if not pad.enabled else (1.6 if occupied.has("pad%d" % i) else 0.9 + sin(_time * 2.0 + i) * 0.25)
		energy += maxf(0, 1.0 - since * 2.5) * 6.0
		room.set_pad_glow(i, [GREEN, AMBER, VIOLET][i] if pad.enabled else Color("3a3550"), energy)

func toast(message: String, color: Color = TEXT) -> void:
	toasts.append({"text": message, "color": color, "until": _time + 3.5})
	if toasts.size() > 3: toasts.pop_front()

func _name(id: String) -> String:
	return str(profiles.get(id, {}).get("name", "Player"))

# ---------------------------------------------------------------- screens

func _hook_screens() -> void:
	room.screens.tv.canvas.painter = _draw_tv
	room.screens.plaque.canvas.painter = _draw_plaque
	room.screens.jukebox.canvas.painter = _draw_jukebox
	room.screens.box_front.canvas.painter = _draw_front_box
	for i in 3: room.screens["queue%d" % i].canvas.painter = _draw_queue_box.bind(i)

func _redraw_screens() -> void:
	for name in ["tv", "plaque", "jukebox", "box_front", "queue0", "queue1", "queue2"]: room.redraw(name)
	var track: Variant = party.get("now_playing")
	room.music_playing = track is Dictionary and bool(track.get("playing", false))
	var shelf := shelf_games()
	var shelf_key := JSON.stringify([shelf.map(func(g): return [g.get("id"), g.get("title"), g.get("color")]), shelf_offset])
	if shelf_key != _shelf_key:
		_shelf_key = shelf_key
		room.set_shelf(shelf, shelf_offset)
	for side in ["shelf_lb", "shelf_rb"]: room.get_node(side).visible = shelf.size() > 1
	var queue := upcoming()
	room.set_queue(mini(queue.size(), 3), maxi(queue.size() - 3, 0))

func _short(value: String, length: int) -> String:
	return value if value.length() <= length else value.left(length - 1) + "…"

func _art(game: Dictionary, keys: Array) -> Texture2D:
	for key in keys:
		var value := str(game.get(key, ""))
		if value.is_empty() or value == "<null>": continue
		var texture: Texture2D = artwork.texture(value)
		if texture != null: return texture
	return null

func _cover(canvas: Control, texture: Texture2D, rect: Rect2) -> void:
	# Aspect-fill without stretching.
	var size := texture.get_size()
	var scale := maxf(rect.size.x / size.x, rect.size.y / size.y)
	var src_size := rect.size / scale
	var src := Rect2((size - src_size) / 2, src_size)
	canvas.draw_texture_rect_region(texture, rect, src)

## Headings (40 px and up) use the heavy weight.
func _text(canvas: Control, value: String, pos: Vector2, size: int, color: Color, width := -1.0, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	canvas.draw_string(bold if size >= 40 else font, pos, value, align, width, size, color)

## Shrinks the size until value fits in width, down to a minimum.
func _fit(value: String, size: int, width: float, minimum := 14) -> int:
	while size > minimum and (bold if size >= 40 else font).get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width: size -= 2
	return size

func _title_card(canvas: Control, game: Dictionary, rect: Rect2, size: int) -> void:
	var color := Color.from_string(str(game.get("color", "")), VIOLET)
	for y in int(rect.size.y):
		canvas.draw_line(rect.position + Vector2(0, y), rect.position + Vector2(rect.size.x, y), color.darkened(0.35 + 0.45 * y / rect.size.y))
	var title := str(game.get("title", "Game"))
	var words := title.split(" ")
	var line_height := size * 1.1
	var top := rect.get_center().y - (words.size() - 1) * line_height / 2.0 + size * 0.35
	for i in words.size():
		_text(canvas, words[i].to_upper(), Vector2(rect.position.x, top + i * line_height), size, TEXT, rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_tv(canvas: Control) -> void:
	var size := canvas.size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("07060d"))
	var game := current_game()
	var kicker := ""
	var kicker_color := Color(0.6, 0.75, 1.0)
	var detail := ""
	if not game.is_empty():
		kicker = "PAUSED" if game.get("phase") == "paused" else "NOW PLAYING"
		kicker_color = GREEN
		detail = "Stand on the left pad and press Y to resume"
	else:
		var queue := upcoming()
		if not queue.is_empty():
			game = game_meta(queue[0].game)
			if game.is_empty(): game = {"id": queue[0].game, "title": queue[0].title}
			kicker = "UP NEXT"
			var warm: Variant = party.get("warm_session")
			var issue := _issue(str(game.id))
			if not issue.is_empty():
				kicker = issue.to_upper()
				kicker_color = PINK
				detail = "Press Y on Play to retry"
			elif warm is Dictionary and str(warm.get("game")) == str(game.id):
				if warm.get("phase") == "ready":
					kicker = "UP NEXT · READY"
					kicker_color = GREEN
				else:
					kicker = "LOADING %d%%" % int(warm.get("progress", 0)) if warm.get("progress") != null else "LOADING…"
					kicker_color = AMBER
			detail = "Press Y on Play to start"
	if game.is_empty():
		_draw_idle_tv(canvas)
		return
	var art := _art(game, ["screenshot", "cover"])
	var rect := Rect2(Vector2.ZERO, size)
	if art != null: _cover(canvas, art, rect)
	else: _title_card(canvas, game, rect, 64)
	# Bottom bar with the title, top-left kicker capsule.
	canvas.draw_rect(Rect2(0, size.y - 120, size.x, 120), Color(0.02, 0.02, 0.05, 0.78))
	_text(canvas, str(game.get("title", "Game")), Vector2(36, size.y - 58), 48, TEXT)
	_text(canvas, detail, Vector2(36, size.y - 22), 22, DIM)
	var kw := font.get_string_size(kicker, HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x + 40
	canvas.draw_rect(Rect2(28, 26, kw, 52), Color(0.02, 0.02, 0.05, 0.85))
	canvas.draw_rect(Rect2(28, 26, 6, 52), kicker_color)
	_text(canvas, kicker, Vector2(48, 63), 32, kicker_color)
	var x := size.x - 40
	for id in profiles:
		var c := Color.from_string(str(profiles[id].get("color", "")), VIOLET)
		canvas.draw_circle(Vector2(x, size.y - 60), 14, c)
		x -= 36
	_scanlines(canvas, size)

func _draw_idle_tv(canvas: Control) -> void:
	var size := canvas.size
	var t := _time
	for i in 14:
		var c := Color.from_hsv(fmod(t * 0.05 + i * 0.05, 1.0), 0.7, 0.35)
		canvas.draw_rect(Rect2(0, i * size.y / 14, size.x, size.y / 14 + 1), c)
	_text(canvas, "NOTHING QUEUED", Vector2(0, size.y / 2 - 10), 64, TEXT, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_text(canvas, "Walk to the game shelf and press Y to add a game", Vector2(0, size.y / 2 + 48), 24, TEXT.darkened(0.15), size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_scanlines(canvas, size)

func _scanlines(canvas: Control, size: Vector2) -> void:
	for y in range(0, int(size.y), 4):
		canvas.draw_line(Vector2(0, y), Vector2(size.x, y), Color(0, 0, 0, 0.12))

func _issue(game_id: String) -> String:
	for issue in party.get("game_issues", []):
		if str(issue.get("game")) == game_id:
			return {"closed": "Game closed", "disconnected": "Game disconnected", "exited_unexpectedly": "Game exited unexpectedly",
				"failed_to_start": "Could not start game", "startup_timeout": "Game did not connect"}.get(str(issue.get("kind")), "Game stopped")
	return ""

## A box cover: art (or a title card), a GameNight band on top and the
## player count at the bottom, like an old DVD case.
func _draw_box(canvas: Control, game: Dictionary, badge := "") -> void:
	var size := canvas.size
	var color := Color.from_string(str(game.get("color", "")), VIOLET)
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("0c0a16"))
	var band := roundf(size.y * 0.09)
	var rect := Rect2(0, band, size.x, size.y - band * 2)
	var art := _art(game, ["cover", "screenshot", "icon"])
	if art != null: _cover(canvas, art, rect)
	else: _title_card(canvas, game, rect, 32 if size.x > 220 else 16)
	canvas.draw_rect(Rect2(0, 0, size.x, band), color)
	_text(canvas, "GAMENIGHT", Vector2(0, band * 0.72), 16, BG, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	canvas.draw_rect(Rect2(0, size.y - band, size.x, band), Color("12141f"))
	var players := str(game.get("players", "")) if game.get("players") != null else ""
	if players.is_empty() and game.get("max_players") != null: players = "1-%d" % int(game.max_players)
	if not players.is_empty():
		_text(canvas, "%s PLAYERS" % players, Vector2(0, size.y - band * 0.28), 16, color.lightened(0.3), size.x, HORIZONTAL_ALIGNMENT_CENTER)
	if art != null and size.x > 220:
		# Title over the art so the stand reads from the couch.
		canvas.draw_rect(Rect2(0, size.y - band - 64, size.x, 64), Color(0.02, 0.02, 0.05, 0.72))
		_text(canvas, _short(str(game.get("title", "Game")), 14), Vector2(0, size.y - band - 20), 32, TEXT, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	if not badge.is_empty():
		var r := Rect2(8, band + 8, 44, 44)
		canvas.draw_rect(r, AMBER if badge == "1" else TEXT)
		_text(canvas, badge, Vector2(8, band + 44), 32, BG, 44, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_front_box(canvas: Control) -> void:
	var shelf := shelf_games()
	if shelf.is_empty():
		canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("0c0a16"))
		_text(canvas, "NO GAMES", Vector2(0, canvas.size.y / 2), 32, DIM, canvas.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		return
	_draw_box(canvas, shelf[shelf_offset % shelf.size()])

func _draw_queue_box(canvas: Control, index: int) -> void:
	var queue := upcoming()
	if index >= queue.size(): return
	var game := game_meta(queue[index].game)
	if game.is_empty(): game = {"id": queue[index].game, "title": queue[index].title}
	_draw_box(canvas, game, str(index + 1))

func _draw_jukebox(canvas: Control) -> void:
	# Transparent strip on the glowing dome: dark lettering only, no panel.
	# Long titles shrink to fit, so nothing leaves the circle.
	var size := canvas.size
	var ink := Color("4a1428")
	var track: Variant = party.get("now_playing")
	if not track is Dictionary or track.is_empty():
		_text(canvas, "JUKEBOX", Vector2(0, 96), _fit("JUKEBOX", 48, size.x - 40), ink, size.x, HORIZONTAL_ALIGNMENT_CENTER)
		return
	var playing: bool = track.get("playing", false)
	var title := _short(str(track.get("title", "")), 28)
	var artist := str(track.get("artist", ""))
	if artist.is_empty(): artist = str(track.get("source", ""))
	artist = _short(artist, 32)
	var width := size.x - 40
	_text(canvas, "NOW PLAYING" if playing else "PAUSED", Vector2(0, 44), 18, Color(ink, 0.7), size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_text(canvas, title, Vector2(0, 94), _fit(title, 44, width, 22), ink, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_text(canvas, artist, Vector2(0, 128), _fit(artist, 24, width - 40, 16), Color("8a2e3c"), size.x, HORIZONTAL_ALIGNMENT_CENTER)

func _draw_plaque(canvas: Control) -> void:
	var size := canvas.size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("0c0a16"))
	_text(canvas, "SCAN TO JOIN", Vector2(0, 42), 32, AMBER, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var room_info: Dictionary = links.get("room", {})
	var side := 216.0
	var qr_rect := Rect2((size.x - side) / 2, 70, side, side)
	if qr != null:
		canvas.draw_rect(qr_rect.grow(14), Color.WHITE)
		canvas.draw_texture_rect(qr, qr_rect, false)
	else:
		canvas.draw_rect(qr_rect, Color("1a1730"))
		_text(canvas, "Phone joining", Vector2(qr_rect.position.x, qr_rect.get_center().y - 6), 16, DIM, qr_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		_text(canvas, "starts with GameNight", Vector2(qr_rect.position.x, qr_rect.get_center().y + 18), 16, DIM, qr_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var code := str(room_info.get("room_code", room_info.get("code", "")))
	if code == "<null>": code = ""
	_text(canvas, code if not code.is_empty() else "· · · ·", Vector2(0, size.y - 18), 48, TEXT, size.x, HORIZONTAL_ALIGNMENT_CENTER)
	_text(canvas, "ROOM CODE", Vector2(0, size.y - 66), 16, DIM, size.x, HORIZONTAL_ALIGNMENT_CENTER)

# ---------------------------------------------------------------- HUD

func _draw_hud(canvas: Control) -> void:
	var camera: Camera3D = room.camera
	var scale := canvas.size.y / 1080.0
	# Name tags and station hints follow the players.
	for id in world.players:
		var p: Dictionary = world.players[id]
		var head := Vector3(p.x, p.y + 2.25, 0)
		if camera.is_position_behind(head): continue
		var at := camera.unproject_position(head) / canvas.get_global_transform().get_scale()
		var color := Color.from_string(str(profiles.get(id, {}).get("color", "")), VIOLET)
		var name := _short(_name(id), 14)
		var size := int(20 * scale)
		var width := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		canvas.draw_string_outline(font, at + Vector2(-width / 2, 0), name, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(4, int(5 * scale)), Color(BG, 0.85))
		_text(canvas, name, at + Vector2(-width / 2, 0), size, color.lightened(0.35))
		var station := station_for(id)
		if not station.is_empty() and not menus.has(id):
			_hint(canvas, at + Vector2(0, -size - 10 * scale), station, int(19 * scale))
		if menus.has(id): _draw_menu(canvas, id, at + Vector2(0, -size - 10 * scale), int(22 * scale))
	# Toasts, bottom centre.
	var y := canvas.size.y - 40 * scale
	for i in range(toasts.size() - 1, -1, -1):
		var t: Dictionary = toasts[i]
		var size := int(22 * scale)
		var w := font.get_string_size(t.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 44
		var rect := Rect2(canvas.size.x / 2 - w / 2, y - size - 20, w, size + 24)
		canvas.draw_rect(rect, Color(0.03, 0.03, 0.06, 0.88))
		canvas.draw_rect(Rect2(rect.position, Vector2(4, rect.size.y)), t.color)
		_text(canvas, t.text, rect.position + Vector2(24, size + 4), size, TEXT)
		y -= rect.size.y + 10
	if demo == null and not client.connected:
		var size := int(24 * scale)
		var msg := "Connecting to GameNight…"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 48
		canvas.draw_rect(Rect2(canvas.size.x / 2 - w / 2, 24, w, size + 28), Color(0.03, 0.03, 0.06, 0.9))
		_text(canvas, msg, Vector2(canvas.size.x / 2 - w / 2 + 24, 24 + size + 6), size, AMBER)
	if profiles.is_empty() and (demo != null or client.connected):
		var size := int(28 * scale)
		var msg := "Press any button on a controller to jump in"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 48
		canvas.draw_rect(Rect2(canvas.size.x / 2 - w / 2, canvas.size.y * 0.42, w, size + 28), Color(0.03, 0.03, 0.06, 0.85))
		_text(canvas, msg, Vector2(canvas.size.x / 2 - w / 2 + 24, canvas.size.y * 0.42 + size + 6), size, TEXT)

## A black capsule with a yellow Y badge, like the platformer lobby.
func _hint(canvas: Control, at: Vector2, station: Dictionary, size: int) -> void:
	var text := str(station.label)
	var extra := str(station.get("extra", ""))
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var small := int(size * 0.72)
	var ew := _extra_width(extra, small) if not extra.is_empty() else 0.0
	var h := size + 14.0
	var badge := h - 8
	var w := tw + badge + 22 + (ew + 16 if extra else 0.0)
	var rect := Rect2(at.x - w / 2, at.y - h, w, h)
	# Keep the capsule and its round ends on screen near the walls.
	rect.position.x = clampf(rect.position.x, h / 2 + 12, canvas.size.x - w - h / 2 - 12)
	var bg := Color(0.03, 0.03, 0.06, 0.9)
	# One rounded box, so the translucent ends don't overlap and darken.
	var pill := StyleBoxFlat.new()
	pill.bg_color = bg
	pill.set_corner_radius_all(int(h / 2))
	pill.anti_aliasing = true
	canvas.draw_style_box(pill, rect.grow_individual(h / 2, 0, h / 2, 0))
	var badge_color := Color("f8cd34") if station.enabled else Color("55516a")
	canvas.draw_circle(rect.position + Vector2(badge / 2 - 2, h / 2), badge / 2, badge_color)
	canvas.draw_string(bold, rect.position + Vector2(-2, h / 2 + size * 0.36), "Y", HORIZONTAL_ALIGNMENT_CENTER, badge, size, BG)
	_text(canvas, text, rect.position + Vector2(badge + 10, h / 2 + size * 0.36), size, TEXT if station.enabled else DIM)
	if extra:
		_draw_extra(canvas, extra, rect.position + Vector2(badge + 26 + tw, h / 2), small)

## Hint extras like "LB RB browse": button names become bumper badges.
const BUMPERS := ["LB", "RB", "LT", "RT"]

func _extra_width(extra: String, size: int) -> float:
	var w := 0.0
	for token in extra.split(" ", false):
		if token == "/": continue
		w += (size * 2.0 if token in BUMPERS else font.get_string_size(token, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x) + size * 0.3
	return w

func _draw_extra(canvas: Control, extra: String, at: Vector2, size: int) -> void:
	var x := at.x
	for token in extra.split(" ", false):
		if token == "/": continue
		if token in BUMPERS:
			Room.draw_bumper(canvas, Rect2(x, at.y - size * 0.55, size * 2.0, size * 1.1), token, bold)
			x += size * 2.3
		else:
			_text(canvas, token, Vector2(x, at.y + size * 0.36), size, AMBER)
			x += font.get_string_size(token, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + size * 0.3

func _draw_menu(canvas: Control, id: String, at: Vector2, size: int) -> void:
	var items := menu_items(id)
	var menu: Dictionary = menus[id]
	var line := size + 16.0
	var w := 0.0
	for item in items: w = maxf(w, font.get_string_size(item.label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	w += 80
	var h := line * items.size() + 70
	var rect := Rect2(at.x - w / 2, at.y - h, w, h)
	rect.position.x = clampf(rect.position.x, 16, canvas.size.x - w - 16)
	rect.position.y = maxf(rect.position.y, 16)
	canvas.draw_rect(rect, Color(0.04, 0.035, 0.08, 0.95))
	canvas.draw_rect(rect, Color(VIOLET, 0.9), false, 3)
	_text(canvas, _name(id).to_upper(), rect.position + Vector2(24, size + 14), int(size * 0.7), AMBER)
	for i in items.size():
		var y := rect.position.y + 50 + i * line
		var selected: bool = i == menu.index
		var label: String = items[i].label
		if items[i].action == "quit" and menu.confirm and selected: label = "Press A again to quit"
		if selected: canvas.draw_rect(Rect2(rect.position.x + 12, y, w - 24, line - 4), Color(VIOLET, 0.35))
		_text(canvas, label, Vector2(rect.position.x + 32, y + size), size, TEXT if selected else DIM)
