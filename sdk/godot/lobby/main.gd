extends Control
## Example lobby: all authoritative state comes through the public Lobby client.
const LobbyClient = preload("res://addons/gamenight/lobby.gd")
const Face = preload("res://addons/gamenight/face.gd")
const INK := Color("243b36")
const MUTED := Color("718078")
const PAPER := Color("f6f2e6")
const GREEN := Color("285c46")
const LIME := Color("d9ec9a")

var client = LobbyClient.new()
var faces = Face.new()
var artwork = preload("res://addons/gamenight/artwork.gd").new()
var _settings_game := ""
var _settings_page := 0
var font := SystemFont.new()
var bold := SystemFont.new()
var party: Dictionary = {}
var games: Array = []
var selected := 0
var hits: Array = []
var _buttons: Dictionary = {}
var _textures: Dictionary = {}
var _message := "Connecting to GameNight…"
var _message_until := 0
var _quit_confirm := false
var _capture_path := ""
var _captured := false
var _started_at := 0
var _assistant_url := ""
var _fullscreen := false
var _cursors: Dictionary = {}
var _links := HTTPRequest.new()
var _pickup := HTTPRequest.new()
var _room: Dictionary = {}
var _qr: Texture2D
var _qr_source := ""
var _links_base := ""
var _room_panel := false
var _focus_rects: Dictionary = {}
var _delta := 0.016
var _card_rects: Dictionary = {}
var _cards_moving := false
var _queue_offset := 0

func _ready() -> void:
	add_child(artwork)
	artwork.changed.connect(queue_redraw)
	_links_base = OS.get_environment("GAMENIGHT_LINKS_URL")
	if _links_base.is_empty(): _links_base = "http://127.0.0.1:7913"
	if not _links_base.begins_with("http://127.0.0.1:"): _links_base = ""
	_links.timeout = 3
	add_child(_links); add_child(_pickup)
	_links.request_completed.connect(_links_received)
	if not _links_base.is_empty():
		var timer := Timer.new()
		timer.wait_time = 2
		timer.timeout.connect(func():
			if _links.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
				_links.request(_links_base + "/api/player-links"))
		add_child(timer); timer.start()
	var configured := OS.get_environment("GAMENIGHT_ASSISTANT_URL")
	if configured.begins_with("http://127.0.0.1:") or configured.begins_with("https://"):
		_assistant_url = configured
	_fullscreen = OS.get_environment("GAMENIGHT_LOBBY_FULLSCREEN") == "1"
	font.font_names = PackedStringArray(["Inter", "DejaVu Sans"])
	bold.font_names = font.font_names
	bold.font_weight = 700
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	get_window().min_size = Vector2i(400, 800)
	if not _fullscreen and get_window().size.x < 1050:
		get_window().content_scale_size = Vector2i.ZERO
	client.party_changed.connect(_party_changed)
	client.focus_changed.connect(_focus_changed)
	client.controllers_changed.connect(_controllers_changed)
	client.connection_changed.connect(func(ok: bool):
		_buttons.clear()
		_message = "" if ok else "Reconnecting… Your party is still here."
		queue_redraw())
	client.rejected.connect(func(message: String):
		_message = message
		_message_until = Time.get_ticks_msec() + 7000
		queue_redraw())
	add_child(client)
	get_tree().auto_accept_quit = false
	_started_at = Time.get_ticks_msec()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="): _capture_path = argument.trim_prefix("--capture=")
	resized.connect(queue_redraw)
	queue_redraw()

func _process(_delta: float) -> void:
	self._delta = minf(_delta, 0.05)
	if not _cursors.is_empty() or _cards_moving: queue_redraw()
	if _message_until > 0 and Time.get_ticks_msec() > _message_until:
		_message = ""
		_message_until = 0
		queue_redraw()
	if not _capture_path.is_empty() and not _captured and client.connected and Time.get_ticks_msec() - _started_at > 3500:
		_captured = true
		if OS.get_cmdline_user_args().has("--capture-settings"):
			_activate("settings")
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var error := get_viewport().get_texture().get_image().save_png(_capture_path)
		print("LOBBY_CAPTURE ", _capture_path, " ", error)
		get_tree().quit(error)

func _party_changed(snapshot: Dictionary) -> void:
	var previous_id: String = str(games[selected].get("id", "")) if not games.is_empty() else ""
	party = snapshot
	games = snapshot.get("library", []).filter(func(game: Dictionary): return game.get("id") != client.lobby_id)
	selected = clampi(selected, 0, maxi(0, games.size() - 1))
	for i in games.size():
		if games[i].get("id") == previous_id: selected = i
	queue_redraw()

func _focus_changed(active: bool) -> void:
	Engine.max_fps = 60 if active else 15
	AudioServer.set_bus_mute(0, not active)
	if DisplayServer.get_name() != "headless" and _capture_path.is_empty():
		if active:
			get_window().mode = Window.MODE_FULLSCREEN if _fullscreen else Window.MODE_WINDOWED
			get_window().grab_focus()
		else:
			get_window().mode = Window.MODE_MINIMIZED
	queue_redraw()

func _controllers_changed(controllers: Array) -> void:
	var live: Dictionary = {}
	for controller in controllers:
		var id: String = controller.get("controller", "")
		var held := int(controller.get("buttons", 0))
		var axes: Array = controller.get("axes", [0, 0, 0, 0, 0, 0])
		if int(axes[0]) < -16000: held |= 1 << 12
		if int(axes[0]) > 16000: held |= 1 << 13
		if int(axes[1]) < -16000: held |= 1 << 10
		if int(axes[1]) > 16000: held |= 1 << 11
		if int(axes[4]) > 16000: held |= 1 << 14
		if int(axes[5]) > 16000: held |= 1 << 15
		var pressed: int = held & ~int(_buttons.get(id, held))
		live[id] = held
		if not client.active: continue
		var player := _controller_player(id)
		if player.is_empty(): continue
		if not _cursors.has(id) or _cursors[id].player != str(player.id):
			_cursors[id] = {"player":str(player.id), "action":"select:%d" % selected, "game":selected, "repeat_at":0, "direction":Vector2.ZERO}
		var direction := Vector2.ZERO
		if held & (1 << 12): direction = Vector2.LEFT
		elif held & (1 << 13): direction = Vector2.RIGHT
		elif held & (1 << 10): direction = Vector2.UP
		elif held & (1 << 11): direction = Vector2.DOWN
		var cursor: Dictionary = _cursors[id]
		if pressed & (1 << 14): _cycle_game(id, -1)
		if pressed & (1 << 15): _cycle_game(id, 1)
		var now := Time.get_ticks_msec()
		if direction != Vector2.ZERO and (direction != cursor.direction or now >= int(cursor.repeat_at)):
			_move_cursor(id, direction)
			cursor.repeat_at = now + (350 if direction != cursor.direction else 170)
		cursor.direction = direction
		if pressed & 1:
			var action: String = str(cursor.action)
			if action.begins_with("select:"): action = "queue"
			selected = int(cursor.game)
			_activate(action, id)
		if pressed & 2: _activate("settings-close" if not _settings_game.is_empty() else "cancel" if _quit_confirm else "resume")
		if pressed & 4:
			selected = int(cursor.game)
			_activate("play-next")
		if pressed & (1 << 7): _activate("assistant")
		if pressed & 8:
			for seat in party.get("seats", []):
				if seat.get("controller", "") == id:
					client.leave(str(seat.get("occupant", {}).get("player_id", "")))
	_buttons = live
	for id in _cursors.keys():
		if not live.has(id) or _controller_player(id).is_empty(): _cursors.erase(id)
	queue_redraw()

func _controller_player(controller: String) -> Dictionary:
	for seat in party.get("seats", []):
		if seat.get("controller", "") == controller:
			for player in party.get("players", []):
				if player.get("id") == seat.get("occupant", {}).get("player_id"): return player
	return {}

func _cursor_hits(id: String) -> Array:
	var player := _controller_player(id)
	return hits.filter(func(hit: Dictionary):
		return not hit.action.begins_with("leave:") or hit.action == "leave:" + str(player.get("id", "")))

func _section(action: String) -> String:
	if action.begins_with("select:") or action in ["play-next", "queue", "previous", "next"]: return "games"
	if action.begins_with("media:"): return "music"
	if action.begins_with("pickup:") or action == "room": return "room"
	if action.begins_with("leave:"): return "players"
	if action == "assistant": return "assistant"
	return "up-next"

func _cycle_game(id: String, step: int) -> void:
	if games.is_empty() or _quit_confirm or _room_panel or not _settings_game.is_empty(): return
	var cursor: Dictionary = _cursors[id]
	cursor.game = posmod(int(cursor.game) + step, games.size())
	cursor.action = "select:%d" % int(cursor.game)
	selected = int(cursor.game)
	queue_redraw()

func _move_cursor(id: String, direction: Vector2) -> void:
	var cursor: Dictionary = _cursors[id]
	var choices := _cursor_hits(id)
	if choices.is_empty(): return
	var current: Dictionary = {}
	for hit in choices:
		if hit.action == cursor.action: current = hit
	if current.is_empty():
		cursor.action = choices[0].action
		return
	var best := INF
	for hit in choices:
		if hit.action == current.action: continue
		# The carousel is one control. Triggers browse it; directional input
		# can leave it without walking through every game in the catalog.
		if str(current.action).begins_with("select:") and str(hit.action).begins_with("select:"): continue
		var offset: Vector2 = hit.rect.get_center() - current.rect.get_center()
		var forward := offset.dot(direction)
		if forward <= 8: continue
		var sideways := absf(offset.cross(direction))
		var score := forward + sideways * 3
		if score < best:
			best = score; cursor.action = hit.action
	if str(cursor.action).begins_with("select:"):
		cursor.game = int(str(cursor.action).trim_prefix("select:"))

func _draw_cursors() -> void:
	var ring := 0
	for id in _cursors:
		var player := _controller_player(id)
		if player.is_empty(): continue
		var cursor: Dictionary = _cursors[id]
		var choices := _cursor_hits(id)
		var target: Dictionary = {}
		for hit in choices:
			if hit.action == cursor.action: target = hit
		if target.is_empty() and not choices.is_empty():
			# Keep an offscreen game selection instead of stealing its focus.
			if str(cursor.action).begins_with("select:"): continue
			target = choices[0]; cursor.action = target.action
		if target.is_empty(): continue
		var color := Color.from_string(str(player.get("color", "#285c46")), GREEN)
		var destination: Rect2 = target.rect.grow(2)
		var rect: Rect2 = _focus_rects.get(id, destination)
		rect = Rect2(rect.position.lerp(destination.position, 1.0-exp(-22*self._delta)), rect.size.lerp(destination.size, 1.0-exp(-22*self._delta)))
		_focus_rects[id] = rect
		_round(rect, Color.TRANSPARENT, 14, color, 3)
		var label: String = str(player.get("name", "Player")).left(14)
		var badge := Rect2(rect.position + Vector2(10 + ring * 124, -17), Vector2(118, 23))
		_round(badge, color, 6)
		_center(label, badge, 12, Color.BLACK if color.get_luminance() > 0.45 else Color.WHITE, true)
		ring += 1

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_quit_confirm = true
		queue_redraw()

func _input(event: InputEvent) -> void:
	# Host frames drive controllers. Never enumerate Godot devices for ownership.
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_LEFT: _select(-1)
			KEY_RIGHT: _select(1)
			KEY_ENTER, KEY_SPACE: _activate("confirm" if _quit_confirm else "start")
			KEY_ESCAPE: _activate("settings-close" if not _settings_game.is_empty() else "cancel" if _quit_confirm else "resume")
			KEY_X: _activate("play-next")
			KEY_A: _activate("queue")
			KEY_Q: _activate("quit")
			KEY_C: _activate("assistant")
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN: _select(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP: _select(-1)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			for hit in hits:
				if hit.rect.has_point(event.position):
					_activate(hit.action)
					break

func _select(direction: int) -> void:
	if games.is_empty() or _quit_confirm: return
	selected = posmod(selected + direction, games.size())
	queue_redraw()

func _activate(action: String, controller: String = "") -> void:
	if action == "settings-close":
		_settings_game = ""
		queue_redraw()
		return
	if not _settings_game.is_empty():
		if action.begins_with("setting:"): _change_setting(int(action.get_slice(":",1)),int(action.get_slice(":",2)))
		elif action.begins_with("settings-page:"): _settings_page = maxi(0,_settings_page+int(action.get_slice(":",1)))
		queue_redraw()
		return
	if action == "settings" and not games.is_empty():
		_settings_game = str(games[selected].id)
		_settings_page = 0
		queue_redraw()
		return
	if action == "quit":
		_quit_confirm = true
	elif action == "cancel":
		_quit_confirm = false
	elif action == "confirm" and _quit_confirm:
		if client.connected:
			# Keep polling until the host closes its children. Exiting here can
			# discard the queued request and look like a crash to the watchdog.
			client.quit_party()
		else:
			get_tree().quit()
	elif _quit_confirm:
		return
	elif action == "assistant" and not _assistant_url.is_empty():
		OS.shell_open(_assistant_url)
	elif action == "start": client.start_next()
	elif action == "queue-more": _queue_offset += 1
	elif action == "queue-less": _queue_offset = maxi(0,_queue_offset-1)
	elif action == "room": _room_panel = not _room_panel
	elif action.begins_with("media:"): client.media_control(action.trim_prefix("media:"))
	elif action.begins_with("remove:"): client.remove_from_queue(int(action.trim_prefix("remove:")))
	elif action.begins_with("earlier:"):
		var index := int(action.trim_prefix("earlier:"))
		client.move_in_queue(index, index - 1)
	elif action.begins_with("pickup:"):
		var player := _controller_player(controller)
		if player.is_empty():
			_message = "Select your profile with your controller, then press A."
			_message_until = Time.get_ticks_msec() + 5000
		elif not _links_base.is_empty():
			_pickup.request(_links_base + "/api/room-pickup/" + action.trim_prefix("pickup:") + "/" + str(player.id), ["X-GameNight-Local-Pickup: 1"], HTTPClient.METHOD_POST)
	elif action.begins_with("leave:"):
		client.leave(action.trim_prefix("leave:"))
	elif action.begins_with("select:"):
		selected = int(action.trim_prefix("select:"))
	elif action == "previous": _select(-1)
	elif action == "next": _select(1)
	elif action == "resume":
		if not party.get("active_session", {}).is_empty(): client.resume_game()
	elif action in ["play-next", "queue"] and not games.is_empty():
		var game: Dictionary = games[selected]
		if not _unavailable(game).is_empty(): return
		client.queue_game(str(game.id), action == "play-next")
		_message = ("%s will play next." if action == "play-next" else "%s added to queue.") % game.get("title", "Game")
		_message_until = Time.get_ticks_msec() + 2500
	queue_redraw()

func _unavailable(game: Dictionary) -> String:
	if not client.connected: return "Waiting for connection"
	var count: int = party.get("players", []).size()
	if count == 0: return "Connect a controller to play"
	if count > int(game.get("max_players", 99)): return "Too many players for this game"
	# min_players may be satisfied by host-supplied bots.
	return ""

func _round(rect: Rect2, color: Color, radius: int = 16, border: Color = Color.TRANSPARENT, width: int = 0) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.border_color = border
	style.set_border_width_all(width)
	draw_style_box(style, rect)

func _text(value: String, at: Vector2, font_size: int, color: Color = INK, strong: bool = false, width: float = -1) -> void:
	draw_string(bold if strong else font, at, value, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, color)

func _center(value: String, rect: Rect2, font_size: int, color: Color = INK, strong: bool = false) -> void:
	var face: Font = bold if strong else font
	draw_string(face, Vector2(rect.position.x, rect.get_center().y + font_size * 0.35), value,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, font_size, color)

func _button(label: String, rect: Rect2, action: String, primary: bool = false, disabled: bool = false) -> void:
	_round(rect, Color("e7e8de") if disabled else (GREEN if primary else Color("fffdf6")), 12)
	_center(label, rect, 17, MUTED if disabled else (PAPER if primary else INK), true)
	if not disabled: hits.append({"rect": rect, "action": action})

func _draw() -> void:
	hits.clear()
	var wide := size.x >= 1050
	var margin := 32.0 if wide else 20.0
	var width := size.x - 324 if wide else size.x
	var content := width - margin * 2
	draw_rect(Rect2(Vector2.ZERO, size), PAPER)
	_text("gamenight", Vector2(margin, 40), 23, GREEN, true)
	if not _assistant_url.is_empty():
		_button("Start  Assistant" if wide else "Start", Rect2(width-220 if wide else size.x-168,12,188 if wide else 64,42),"assistant")
	if not wide: _button("Room",Rect2(size.x-96,12,76,42),"room")
	var players: Array = party.get("players", [])
	var seat_count: int = maxi(4, party.get("seats", []).size())
	var spacing := content / seat_count
	_round(Rect2(margin,72,content,92), Color("e5ead8"), 18)
	for index in seat_count:
		var left := margin + index * spacing
		var player: Dictionary = {}
		for seat in party.get("seats", []):
			if int(seat.get("index", -1)) != index: continue
			for candidate in players:
				if candidate.id == seat.get("occupant", {}).get("player_id"): player = candidate
		if player.is_empty():
			_center("Connect pad", Rect2(left+4,104,spacing-8,25),12,MUTED)
		else:
			var center := Vector2(left+spacing/2,103)
			faces.draw_face(self,player,center,19)
			_center(str(player.name),Rect2(left+4,125,spacing-8,24),13,INK,true)
			hits.append({"rect":Rect2(left+6,78,spacing-12,78),"action":"leave:"+str(player.id)})
	var hero_height := clampf(size.y-535,220,330) if wide else 320.0
	_draw_up_next(Rect2(margin,185,content,hero_height))
	var top := 185 + hero_height + 40
	_text("Games",Vector2(margin,top),23,INK,true)
	var browsing := _cursors.values().any(func(cursor): return _section(cursor.action) == "games")
	if browsing:
		_round(Rect2(width-margin-258,top-24,258,30),Color("e5ead8"),9)
		_center("LT   Previous / Next   RT",Rect2(width-margin-258,top-24,258,30),14,GREEN,true)
	_draw_carousel(margin,top,content,wide)
	var y := top+219
	_button("‹",Rect2(margin,y,42,42),"previous",false,games.size()<2)
	_button("›",Rect2(margin+50,y,42,42),"next",false,games.size()<2)
	_button("X  Play next",Rect2(width-margin-268,y,144,42),"play-next",false,games.is_empty() or players.is_empty())
	_button("A  Queue",Rect2(width-margin-116,y,116,42),"queue",true,games.is_empty() or players.is_empty())
	if wide: _button("Settings",Rect2(margin+108,y,108,42),"settings",false,games.is_empty())
	else: _button("Settings",Rect2(size.x-198,12,92,42),"settings",false,games.is_empty())
	if not _message.is_empty(): _text(_message,Vector2(margin,size.y-42),13,GREEN,false,content)
	_text("LT / RT  Games     Stick  Navigate     A  Queue / Select     X  Play next     Y  Leave     Back  Resume" if wide else "LT / RT Games    A Queue    X Play next",Vector2(margin,size.y-17),11,MUTED,false,content)
	if wide: _draw_room_tools(Rect2(width,72,292,size.y-105))
	elif _room_panel:
		hits.clear()
		draw_rect(Rect2(Vector2.ZERO,size),PAPER)
		_button("Back",Rect2(20,12,100,42),"room")
		_draw_room_tools(Rect2(20,72,size.x-40,size.y-110))
	if not _settings_game.is_empty(): _draw_settings()
	if _quit_confirm:
		hits.clear()
		draw_rect(Rect2(Vector2.ZERO,size),Color(0.08,0.15,0.12,0.65))
		var box := Rect2(size.x/2-minf(240,size.x/2-20),size.y/2-100,minf(480,size.x-40),200)
		_round(box,PAPER,22)
		_center("End game night?",Rect2(box.position+Vector2(16,20),Vector2(box.size.x-32,44)),27,INK,true)
		_button("Keep playing",Rect2(box.position+Vector2(20,127),Vector2(box.size.x/2-28,45)),"cancel")
		_button("End night",Rect2(box.position+Vector2(box.size.x/2+8,127),Vector2(box.size.x/2-28,45)),"confirm",true)
	_draw_cursors()

func _carousel_layout(margin: float, top: float, content: float, wide: bool) -> Array:
	if games.is_empty(): return []
	if not wide: return [{"index":selected,"rect":Rect2(margin,top+20,content,190)}]
	var gap := 18.0
	var middle := (content-gap*2)*0.44
	var side := (content-middle-gap*2)/2
	var layout: Array = []
	if games.size() > 1: layout.append({"index":posmod(selected-1,games.size()),"rect":Rect2(margin,top+43,side,144)})
	if games.size() > 2: layout.append({"index":posmod(selected+1,games.size()),"rect":Rect2(margin+side+middle+gap*2,top+43,side,144)})
	# Draw the selected card last, so it remains in front during movement.
	layout.append({"index":selected,"rect":Rect2(margin+side+gap,top+20,middle,190)})
	return layout

func _draw_carousel(margin: float, top: float, content: float, wide: bool) -> void:
	var layout := _carousel_layout(margin,top,content,wide)
	var visible: Dictionary = {}
	_cards_moving = false
	for item in layout:
		var index: int = item.index
		var target: Rect2 = item.rect
		var rect: Rect2 = _card_rects.get(index,target)
		var amount := 1.0-exp(-18*self._delta)
		rect = Rect2(rect.position.lerp(target.position,amount),rect.size.lerp(target.size,amount))
		if rect.position.distance_to(target.position) < 0.5 and rect.size.distance_to(target.size) < 0.5: rect = target
		else: _cards_moving = true
		visible[index] = rect
		_draw_game(games[index],rect,index==selected)
		hits.append({"rect":rect,"action":"select:%d" % index})
	_card_rects = visible

func _upcoming() -> Array:
	var playlist: Dictionary = party.get("playlist", {})
	var entries: Array = playlist.get("entries", [])
	var start := 0 if playlist.get("current") == null else int(playlist.current)+1
	var upcoming: Array = []
	for i in range(start, entries.size()):
		if entries[i].game == client.lobby_id: continue
		upcoming.append({"index":i,"game":entries[i].game,"title":entries[i].get("title","Game")})
	return upcoming

func _next_game() -> Dictionary:
	var upcoming := _upcoming()
	if upcoming.is_empty(): return {}
	for game in games:
		if game.id == upcoming[0].game: return game
	return {}

func _draw_up_next(rect: Rect2) -> void:
	var game := _next_game()
	var upcoming := _upcoming()
	_round(rect,Color("e5ead8"),20)
	var list_width := minf(255,rect.size.x*0.32) if rect.size.x > 600 else 0.0
	var hero := Rect2(rect.position,Vector2(rect.size.x-list_width,rect.size.y if list_width > 0 else rect.size.y-96))
	_round(hero,Color("233d36"),20)
	var image := _artwork(str(game.get("screenshot",game.get("cover",""))))
	if image != null:
		var source_size := hero.size / maxf(hero.size.x/image.get_width(),hero.size.y/image.get_height())
		draw_texture_rect_region(image,hero,Rect2((image.get_size()-source_size)/2,source_size))
	# The head of this queue is the only Up next display, even during preload.
	_round(Rect2(hero.position,Vector2(hero.size.x,42)),Color(0.05,0.12,0.1,0.92),12)
	_text("UP NEXT",hero.position+Vector2(18,28),16,LIME,true)
	var band := Rect2(hero.position+Vector2(0,hero.size.y-116),Vector2(hero.size.x,116))
	_round(band,Color(0.05,0.12,0.1,0.94),12)
	_text(str(game.get("title","Your queue is empty")),band.position+Vector2(18,33),23,PAPER,true,hero.size.x-36)
	_text(_status(game) if not game.is_empty() else "A adds a game. X puts it first.",band.position+Vector2(18,59),14,PAPER,false,hero.size.x-36)
	if not game.is_empty(): _button("Start game",Rect2(band.position+Vector2(18,70),Vector2(150,36)),"start",true)
	elif not party.get("active_session",{}).is_empty(): _button("Resume game",Rect2(band.position+Vector2(18,70),Vector2(150,36)),"resume",true)
	if not upcoming.is_empty(): _button("×",Rect2(hero.end.x-40,hero.position.y+5,32,32),"remove:%d" % upcoming[0].index)
	if list_width > 0:
		var x := hero.end.x+16
		_text("THEN",Vector2(x,rect.position.y+29),13,GREEN,true)
		var capacity := maxi(1,int((rect.size.y-66)/49))
		_queue_offset = clampi(_queue_offset,0,maxi(0,upcoming.size()-1-capacity))
		for n in mini(capacity,maxi(0,upcoming.size()-1)):
			var item: Dictionary = upcoming[n+1+_queue_offset]
			var y := rect.position.y+43+n*49
			_text(str(n+2+_queue_offset),Vector2(x,y+25),12,MUTED)
			_text(str(item.title),Vector2(x+20,y+25),14,INK,true,list_width-112)
			_button("↑",Rect2(x+list_width-91,y+3,30,32),"earlier:%d" % item.index)
			_button("×",Rect2(x+list_width-55,y+3,30,32),"remove:%d" % item.index)
		if upcoming.size() <= 1: _text("Add games with A",Vector2(x,rect.position.y+72),14,MUTED,false,list_width-32)
		if upcoming.size() > capacity+1:
			_button("‹",Rect2(x+list_width-94,rect.end.y-33,32,28),"queue-less",false,_queue_offset==0)
			_button("›",Rect2(x+list_width-56,rect.end.y-33,32,28),"queue-more",false,_queue_offset+capacity>=upcoming.size()-1)
	else:
		_queue_offset = clampi(_queue_offset,0,maxi(0,upcoming.size()-3))
		for n in mini(2,maxi(0,upcoming.size()-1)):
			var item: Dictionary = upcoming[n+1+_queue_offset]
			var y := hero.end.y+8+n*39
			_text("%d  %s" % [n+2+_queue_offset,item.title],Vector2(rect.position.x+16,y+24),14,INK,true,rect.size.x-142)
			_button("↑",Rect2(rect.end.x-122,y,32,32),"earlier:%d" % item.index)
			_button("×",Rect2(rect.end.x-84,y,32,32),"remove:%d" % item.index)
		if upcoming.size()>3:
			_button("‹",Rect2(rect.end.x-44,hero.end.y+8,30,32),"queue-less",false,_queue_offset==0)
			_button("›",Rect2(rect.end.x-44,hero.end.y+47,30,32),"queue-more",false,_queue_offset>=upcoming.size()-3)
		if upcoming.size()<=1: _text("Add games with A",Vector2(rect.position.x+18,hero.end.y+40),14,MUTED)

func _links_received(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_room = {}; _qr = null; _qr_source = ""; queue_redraw(); return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary: return
	_room = data.get("room", {})
	var source: String = _room.get("qr_svg", "")
	if source != _qr_source:
		_qr_source = source; _qr = null
		var image := Image.new()
		if source.length() < 200000 and not source.is_empty() and image.load_svg_from_string(source, 4) == OK:
			_qr = ImageTexture.create_from_image(image)
	queue_redraw()

func _draw_room_tools(rect: Rect2) -> void:
	var x := rect.position.x
	var y := rect.position.y
	var w := rect.size.x
	_round(Rect2(x,y,w,228),Color("e5ead8"),18)
	_text("JOIN THE ROOM",Vector2(x+16,y+27),14,GREEN,true)
	if _qr != null: draw_texture_rect(_qr,Rect2(x+16,y+44,132,132),false)
	_text(str(_room.get("room_code","Connecting…")),Vector2(x+16,y+204),25,INK,true,w-32)
	_text("Scan to join",Vector2(x+160,y+83),14,MUTED)
	var pending: Array = _room.get("pending",[])
	for i in mini(2,pending.size()):
		var profile: Dictionary = pending[i].get("profile",{})
		_button(str(profile.get("display_name","Player")).left(12),Rect2(x+156,y+102+i*40,w-168,34),"pickup:"+str(pending[i].id))
	y += 246
	_round(Rect2(x,y,w,180),Color("e5ead8"),18)
	_text("MUSIC",Vector2(x+16,y+28),14,GREEN,true)
	var track: Dictionary = party.get("now_playing",{})
	_text(str(track.get("title","Play music on this computer")),Vector2(x+16,y+58),15,INK,true,w-32)
	_text(str(track.get("artist",track.get("source",""))),Vector2(x+16,y+82),13,MUTED,false,w-32)
	var bw := (w-48)/3
	_button("Previous",Rect2(x+16,y+112,bw,42),"media:previous_track",false,track.is_empty())
	_button("Pause" if track.get("playing",false) else "Play",Rect2(x+24+bw,y+112,bw,42),"media:play_pause",false,track.is_empty())
	_button("Next",Rect2(x+32+bw*2,y+112,bw,42),"media:next_track",false,track.is_empty())

func _status(game: Dictionary) -> String:
	if not client.connected: return "Connecting to your party…"
	if not _unavailable(game).is_empty(): return _unavailable(game)
	var warm: Dictionary = party.get("warm_session", {})
	if warm.get("game") == game.get("id"):
		if warm.get("phase") == "ready": return "Ready when you are."
		var label: String = str(warm.get("progress_label", "Loading game"))
		return "Preparing · %s%s" % [label, " · %d%%" % int(warm.progress) if warm.has("progress") else ""]
	for install in party.get("installs", []):
		if install.get("game") == game.get("id") and install.get("state") != "installed": return "Download · %s" % install.get("state", "Waiting")
	return "Queued"

func _draw_game(game: Dictionary, rect: Rect2, chosen: bool) -> void:
	var keyboard_focus := chosen and _cursors.is_empty()
	_round(rect, Color("fffdf7"), 16, GREEN if keyboard_focus else Color.TRANSPARENT, 2 if keyboard_focus else 0)
	var color := Color.from_string(str(game.get("color", "#b6c9b6")), Color("b6c9b6"))
	var art := Rect2(rect.position + Vector2(10, 10), Vector2(rect.size.x - 20, rect.size.y - 70))
	_round(art, color, 9)
	var texture := _artwork(str(game.get("screenshot", game.get("cover", ""))))
	if texture != null:
		var target := art.grow(-3)
		var scale := maxf(target.size.x / texture.get_width(), target.size.y / texture.get_height())
		var source_size := target.size / scale
		draw_texture_rect_region(texture, target, Rect2((texture.get_size() - source_size) / 2, source_size))
	else:
		_center(str(game.get("title", "Game")), art, 19, INK, true)
	var loading := ""
	var percent := -1.0
	var warm: Dictionary = party.get("warm_session", {})
	if warm.get("game") == game.get("id") and warm.get("phase") != "ready":
		loading = str(warm.progress_label) if warm.get("progress_label") != null else "Preparing game"
		if warm.get("progress") != null: percent = float(warm.progress)
	for install in party.get("installs", []):
		if install.get("game") == game.get("id") and install.get("state") != "installed":
			loading = str(install.label) if install.get("label") != null else str(install.get("state", "Downloading")).capitalize()
			if install.get("percent") != null: percent = float(install.percent)
	if not loading.is_empty():
		_round(art, Color(0.05, 0.12, 0.1, 0.9), 9)
		_center(loading, Rect2(art.position + Vector2(8, 12), art.size - Vector2(16, 34)), 18, PAPER, true)
		var bar := Rect2(art.position + Vector2(14, art.size.y - 20), Vector2(art.size.x-28, 7))
		_round(bar, Color("54635d"), 3)
		if percent >= 0: _round(Rect2(bar.position, Vector2(bar.size.x * clampf(percent / 100, 0, 1), 7)), LIME, 3)
		else: _round(Rect2(bar.position, Vector2(bar.size.x * 0.25, 7)), LIME, 3)
	_text(str(game.get("title", "Untitled")), rect.position + Vector2(17, rect.size.y - 36), 20 if chosen else 16, INK, true, rect.size.x - 32)
	_text("%s players" % game.get("players", "1–4"), rect.position + Vector2(17, rect.size.y - 15), 12, MUTED)

func _artwork(payload: String) -> Texture2D:
	return artwork.texture(payload)

func _settings() -> Dictionary:
	for settings in party.get("settings",[]):
		if settings.get("game") == _settings_game: return settings
	return {}

func _change_setting(index: int, step: int) -> void:
	var settings := _settings()
	var specs: Array = settings.get("specs",[])
	if index<0 or index>=specs.size(): return
	var spec: Dictionary = specs[index]
	var value: Variant = settings.get("values",{}).get(spec.key,spec.get("default"))
	match spec.get("kind"):
		"toggle": value = not bool(value)
		"number": value = clampi(int(value)+step,int(spec.min),int(spec.max))
		"choice":
			var options: Array = spec.get("options",[])
			if options.is_empty(): return
			value = options[posmod(options.find(value)+step,options.size())]
		_: return
	client.set_setting(_settings_game,str(spec.key),value)

func _draw_settings() -> void:
	hits.clear()
	draw_rect(Rect2(Vector2.ZERO,size),Color(0.08,0.15,0.12,0.82))
	var width := minf(620,size.x-40)
	var settings := _settings()
	var specs: Array = settings.get("specs",[])
	var height := minf(135+maxi(1,specs.size())*66,minf(580,size.y-160))
	var box := Rect2((size.x-width)/2,(size.y-height)/2,width,height)
	_round(box,PAPER,18)
	_text("Game settings",box.position+Vector2(22,38),24,INK,true)
	_button("Close",Rect2(box.end.x-96,box.position.y+14,76,36),"settings-close")
	if specs.is_empty():
		_text("No settings declared yet.",box.position+Vector2(22,105),17,INK)
		_text("Queue this game to load its settings.",box.position+Vector2(22,135),14,MUTED,false,width-44)
		return
	var count := maxi(1,int((box.size.y-135)/66))
	_settings_page = clampi(_settings_page,0,maxi(0,int((specs.size()-1)/count)))
	for n in mini(count,specs.size()-_settings_page*count):
		var index := n+_settings_page*count
		var spec: Dictionary = specs[index]
		var value: Variant = settings.get("values",{}).get(spec.key,spec.get("default"))
		var y := box.position.y+74+n*66
		_text(str(spec.get("label",spec.key)),Vector2(box.position.x+22,y+19),17,INK,true,width-164)
		var label := ("On" if bool(value) else "Off") if spec.kind=="toggle" else str(int(value)) if spec.kind=="number" else str(value)
		_text(label,Vector2(box.position.x+22,y+42),14,MUTED,false,width-164)
		if spec.kind=="toggle":
			_button("Toggle",Rect2(box.end.x-118,y,94,42),"setting:%d:1"%index)
		else:
			_button("−",Rect2(box.end.x-118,y,42,42),"setting:%d:-1"%index)
			_button("+",Rect2(box.end.x-66,y,42,42),"setting:%d:1"%index)
	if specs.size()>count:
		_button("Previous",Rect2(box.position.x+22,box.end.y-52,110,36),"settings-page:-1",false,_settings_page==0)
		_button("Next",Rect2(box.end.x-132,box.end.y-52,110,36),"settings-page:1",false,(_settings_page+1)*count>=specs.size())
