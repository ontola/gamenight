extends Node3D
## GameNight Game Room: a 2.5D platformer lobby. The runtime owns players,
## seats, controllers and sessions; this scene turns them into a room where
## everyone runs, jumps and fights over bombs while choosing the next game.
##
## Controls: stick/D-pad move, A jump (down + A drops through), B grab/throw,
## X punch/use (queue at the game shelf), Y use the station you stand at,
## LB/RB browse the game shelf, Start opens your menu.

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
var _input_blocked: Dictionary = {} # after a focus transition, wait for neutral input
var menus: Dictionary = {}          # player id -> {index, confirm}
## Seated players who never had a controller here (phone players, a stale
## web join). They cannot walk, so they get a line on the HUD instead.
var bench: Array = []
## Player id -> _time their controller went (or, on the bench, since they
## have neither a controller nor a phone). Gone for LOST_SECONDS, they leave.
var lost_since: Dictionary = {}
const LOST_SECONDS := 30.0
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
var _item_prompt_presses: Dictionary = {}
var _pressed_flash: Dictionary = {}  # station id -> time of last press
var _door_nodes: Array = []
var _door_key := ""
## Loading percentage shown per game. Games report progress in phases that
## jump (3% to 53%), or not at all; the bar estimates in between so it
## always moves: it creeps toward the next phase and eases into each report.
var _load_shown := {}
var _load_report := {}
var _screen_key := ""
var _shelf_key := ""
var _time := 0.0
var demo                            # demo.gd when running with --demo
var _capture_path := ""
var _capture_at := 4.0
var _captured := false
var _fullscreen := false
var _display_active: Variant = null
var _focus_handoff := 0
var _last_input: Dictionary = {}
var _last_queue: Array = []          # up next game ids at the last redraw

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
	# Fullscreen like the other lobbies; GAMENIGHT_LOBBY_FULLSCREEN=0 keeps a window.
	_fullscreen = OS.get_environment("GAMENIGHT_LOBBY_FULLSCREEN") != "0"
	if _fullscreen and DisplayServer.get_name() != "headless" and _capture_path.is_empty() and not args.has("--demo"):
		get_window().min_size = Vector2i.ZERO
		_fit_fullscreen()
	if DisplayServer.get_name() != "headless" and _capture_path.is_empty() and not args.has("--demo"):
		# Native focus only cancels a host handoff; it never initiates one.
		get_window().focus_entered.connect(_cancel_focus_handoff)
		get_window().focus_exited.connect(_cancel_focus_handoff)
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
	client.connection_changed.connect(_connection_changed)
	client.rejected.connect(func(message: String): toast(message, PINK))
	add_child(client)
	get_tree().auto_accept_quit = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if client.connected and demo == null: client.quit_party()
		else: get_tree().quit()

func _connection_changed(connected: bool) -> void:
	if not connected:
		_display_active = null
		_cancel_focus_handoff()
		_suspend_input()
		toast("Reconnecting… your party is still here.", AMBER)
	hud.queue_redraw()

func _focus_changed(active: bool) -> void:
	# Only a host ownership transition may claim the screen. Repeated grants
	# and native Alt-Tab focus events must leave the user's chosen app alone.
	if _display_active == active: return
	_display_active = active
	_cancel_focus_handoff()
	_suspend_input()
	Engine.max_fps = 60 if active else 10
	AudioServer.set_bus_mute(0, not active)
	if DisplayServer.get_name() != "headless" and _capture_path.is_empty():
		if active:
			if _fullscreen: _fit_fullscreen()
			else: get_window().mode = Window.MODE_WINDOWED
			_claim_lobby_focus(_focus_handoff)
		else:
			# Back is handled by the host, bypassing the lobby's Y command.
			# Grant foreground rights while we still own focus, before hiding.
			_release_game_focus()
			get_window().mode = Window.MODE_MINIMIZED

func _release_game_focus() -> void:
	client._allow_game_foreground()

func _cancel_focus_handoff() -> void:
	_focus_handoff += 1

func _request_window_focus() -> void:
	get_window().grab_focus()

func _window_has_focus() -> bool:
	return get_window().has_focus()

func _claim_lobby_focus(revision: int) -> void:
	# Pause and lobby_focus travel to separate processes. The game may still
	# be granting Windows foreground rights when the first attempt arrives.
	# Retry only this explicit handoff, at most one second; any focus event
	# cancels it, so a successful handoff can never fight subsequent Alt-Tab.
	var deadline := Time.get_ticks_msec() + 1000
	# Native focus flags may lag behind a switch. Every new host grant gets
	# one real attempt, even if the cached flag still says we have focus.
	_request_window_focus()
	var requested_at := Time.get_ticks_msec()
	while revision == _focus_handoff and _display_active == true and not _window_has_focus():
		var now := Time.get_ticks_msec()
		if now >= deadline: return
		if now - requested_at >= 100:
			_request_window_focus()
			requested_at = now
		await get_tree().process_frame

func _fit_fullscreen() -> void:
	# Windows may restore MODE_FULLSCREEN to the old windowed rectangle while
	# retaining a larger render surface. Fit a borderless desktop window instead,
	# using full monitor bounds (not the work area that excludes the taskbar).
	var window := get_window()
	var screen := window.current_screen
	var origin := DisplayServer.screen_get_position(screen)
	var size := DisplayServer.screen_get_size(screen)
	if window.mode != Window.MODE_WINDOWED: window.mode = Window.MODE_WINDOWED
	if not window.borderless: window.borderless = true
	if window.position != origin: window.position = origin
	if window.size != size: window.size = size

# ---------------------------------------------------------------- party state

func set_party(snapshot: Dictionary) -> void:
	var was_ready := update_ready()
	party = snapshot
	if was_ready.is_empty() and not update_ready().is_empty():
		toast("New GameNight version ready. It installs when the room is quiet, or press Start.", GREEN)
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
	var walkers: Array = controllers.values()
	var phones: Array = party.get("phones", [])
	# A character whose controller went keeps standing, asleep and marked,
	# until it comes back or the player is taken out. A phone player sits.
	bench = profiles.keys().filter(func(id): return not walkers.has(id) and (phones.has(id) or not world.players.has(id)))
	for id in world.players.keys():
		if not profiles.has(id) or bench.has(id):
			world.remove_player(id)
			menus.erase(id)
	for id in profiles:
		if walkers.has(id) or phones.has(id): lost_since.erase(id)
		elif not lost_since.has(id): lost_since[id] = _time
	for id in lost_since.keys():
		if not profiles.has(id): lost_since.erase(id)
	var i := 0
	for id in profiles:
		if walkers.has(id): world.ensure_player(id, slots.get(id, i))
		i += 1
	view.phones = party.get("phones", [])
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
	var next_index := int(party.get("next_game_index", -1)) if party.get("next_game_index") != null else -1
	var authoritative := next_index >= 0 and next_index < entries.size() and _fits_party(game_meta(str(entries[next_index].game)))
	if authoritative: start = next_index
	# The host may skip an incompatible entry or honor an explicit next pick.
	# Follow that prepared target instead of advertising the raw playlist head.
	var target: Variant = party.get("warm_session")
	if not target is Dictionary: target = party.get("warming", {})
	if not authoritative and target is Dictionary:
		var game := str(target.get("game", ""))
		var active := current_game()
		if not game.is_empty() and (active.is_empty() or str(active.id) != game):
			for offset in entries.size():
				var index := (start + offset) % entries.size()
				if str(entries[index].game) == game and _fits_party(game_meta(game)):
					start = index
					break
	if start >= entries.size(): start = 0 # Host playlists rotate after the last entry.
	var result: Array = []
	for index in range(start, entries.size()):
		if str(entries[index].game) == client.lobby_id: continue
		if not _fits_party(game_meta(str(entries[index].game))): continue
		result.append({"index": index, "game": str(entries[index].game), "title": str(entries[index].get("title", "Game"))})
	return result

func _human_count() -> int:
	var count := 0
	for seat in party.get("seats", []):
		if seat.get("occupant", {}).get("player_id") != null: count += 1
	return count

## Seated players who hold what `game` is played with, mirroring the host's
## `GameMeta::party_fit`: {humans, able, phones}. A player with neither a
## controller nor a linked phone counts as holding a controller.
func party_fit(game: Dictionary) -> Dictionary:
	var phones: Array = party.get("phones", [])
	var play_with := str(game.get("play_with", "controller"))
	var fit := {"humans": 0, "able": 0, "phones": 0}
	for seat in party.get("seats", []):
		var id: Variant = seat.get("occupant", {}).get("player_id")
		if id == null: continue
		var phone := phones.has(id)
		var pad: bool = seat.get("controller") != null or not phone
		var able: bool = {"phone": phone, "controller_and_phone": pad and phone, "controller_or_phone": pad or phone}.get(play_with, pad)
		fit.humans += 1
		if able:
			fit.able += 1
			if phone: fit.phones += 1
	return fit

## Why this party can't play `game` ("" when it can). An empty party fits all.
func _shortfall(game: Dictionary) -> String:
	var fit := party_fit(game)
	if fit.humans == 0: return ""
	if game.get("max_players") != null and fit.able > int(game.max_players): return "Too many players"
	var low := 1 if game.get("min_players") == null else maxi(1, int(game.min_players))
	var play_with := str(game.get("play_with", "controller"))
	if fit.able < low:
		if fit.humans < low: return "Needs %d players" % low
		if play_with in ["phone", "controller_and_phone"]: return "Needs %d phones" % low
		return "Needs %d controllers" % low
	if game.get("min_phones") != null and fit.phones < int(game.min_phones):
		return "Needs a phone" if int(game.min_phones) == 1 else "Needs %d phones" % int(game.min_phones)
	return ""

func _fits_party(game: Dictionary) -> bool:
	# Match host prewarming before anyone joins. Re-evaluate on every snapshot.
	return _shortfall(game).is_empty()

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
		p.sleeping = (sleeping.has(id) and quiet) or lost_since.has(id)

## Takes out players whose controller (and phone) stayed gone. Only counts
## while the room is on screen, so a game in progress never removes anyone.
func _remove_lost(delta: float) -> void:
	for id in lost_since.keys():
		if not _accepts_input():
			lost_since[id] += delta
			continue
		if _time - float(lost_since[id]) < LOST_SECONDS: continue
		lost_since.erase(id)
		toast("%s left the party: no controller." % _name(id), DIM)
		client.leave(id)

## Seconds left before a player without a controller leaves.
func lost_left(id: String) -> int:
	if not lost_since.has(id): return -1
	return maxi(0, ceili(LOST_SECONDS - (_time - float(lost_since[id]))))

# ---------------------------------------------------------------- input

func _accepts_input() -> bool:
	# Host screen ownership is authoritative; native focus can briefly lag behind it.
	return demo != null or (client.connected and client.active)

func _clear_player_input(id: String) -> void:
	var p: Dictionary = world.players[id]
	p.held = 0
	p.pressed = 0
	p.stick = Vector2.ZERO
	p.buffer = 0.0
	p.vx = 0.0

func _suspend_input() -> void:
	menus.clear()
	_accumulator = 0.0
	for id in world.players:
		_input_blocked[id] = true
		_clear_player_input(id)
	if hud != null: hud.queue_redraw()

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
	if not _accepts_input():
		held[id] = buttons
		_input_blocked[id] = true
		_clear_player_input(id)
		return
	if _input_blocked.has(id):
		held[id] = buttons
		_clear_player_input(id)
		if buttons == 0 and stick.length() <= 0.25: _input_blocked.erase(id)
		return
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
	if pressed & World.BTN_B:
		var item: Dictionary = world.pickup_target(world.players[id])
		if not item.is_empty():
			var node: Node3D = view.item_nodes.get(item.id)
			if node != null: _item_prompt_presses[item.id] = {"item": item.duplicate(), "position": node.global_position, "time": _time}
	var station_kind: String = station_for(id).get("kind", "")
	var at_shelf := station_kind == "shelf"
	var station_x := station_kind in ["shelf", "queue"]
	# X belongs to the station here, so it must not punch another player.
	world.set_input(id, buttons & ~World.BTN_X if station_x else buttons, stick)
	if pressed & World.BTN_Y: _use_station(id)
	if station_x and pressed & World.BTN_X: _use_station(id, true)
	if at_shelf and pressed & (BTN_LB | BTN_RB):
		room.press_prompt("shelf", "LB" if pressed & BTN_LB else "RB")
		_browse(-1 if pressed & BTN_LB else 1)
	elif pressed & (BTN_LB | BTN_RB):
		_skip_music(id, -1 if pressed & BTN_LB else 1)

func _skip_music(id: String, direction: int) -> void:
	if station_for(id).get("kind") != "music": return
	var action := "previous_track" if direction < 0 else "next_track"
	var station_id := "music0" if direction < 0 else "music2"
	var key := "%s:%s" % [station_id, action]
	var now := Time.get_ticks_msec() / 1000.0
	if now < float(_station_cooldown.get(key, 0.0)): return
	_station_cooldown[key] = now + 0.4
	room.press_prompt("music", "LB" if direction < 0 else "RB")
	client.media_control(action)
	_celebrate(id, station_id)

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
	if p.is_empty() or not p.grounded or p.sleeping: return {}
	var on_floor: bool = absf(p.y) <= 0.1
	# Stations follow what the camera shows: where the player appears against
	# the furniture, not where they stand on the play plane.
	var x := Layout.apparent_x(p.x)
	var at_tv_floor: bool = on_floor and x >= Layout.TV_STATION.x and x <= Layout.TV_STATION.y
	var on_tv_console: bool = absf(p.y - Layout.TV_CONSOLE[2]) <= 0.1 and p.x >= Layout.TV_CONSOLE[0] and p.x <= Layout.TV_CONSOLE[1]
	if at_tv_floor or on_tv_console:
		var tv := tv_station()
		tv["id"] = "tv"
		tv["kind"] = "tv"
		return tv
	if not on_floor: return {}
	var shelf := shelf_games()
	if x >= Layout.GAME_SHELF.x and x <= Layout.GAME_SHELF.y and not shelf.is_empty():
		var game: Dictionary = shelf[shelf_offset % shelf.size()]
		var reason := _unavailable(game)
		return {"id": "shelf", "kind": "shelf", "game": game.id, "title": str(game.get("title", "Game")),
			"label": reason if not reason.is_empty() else "Set %s up next" % str(game.get("title", "game")),
			"enabled": reason.is_empty(), "extra": "X queue LB RB browse" if shelf.size() > 1 else "X queue"}
	if x >= Layout.UP_NEXT.x and x <= Layout.UP_NEXT.y:
		return queue_station()
	var track: Variant = party.get("now_playing")
	if track is Dictionary and not track.is_empty() and absf(x - Layout.JUKEBOX) <= 0.85:
		return {"id": "music1", "kind": "music", "label": "Pause music" if track.get("playing", false) else "Play music",
			"action": "play_pause", "enabled": true, "extra": "LB previous RB next"}
	if absf(x - Layout.EXIT_DOOR) <= 0.6:
		return {"id": "exit", "kind": "exit", "label": "Leave", "enabled": true}
	var pending := pending_profiles()
	for i in mini(pending.size(), Layout.PROFILE_DOORS.size()):
		if absf(x - Layout.PROFILE_DOORS[i]) <= Layout.DOOR_HALF:
			var linked: bool = links.get("linked", {}).has(id)
			var name := str(pending[i].get("profile", {}).get("display_name", "Player"))
			return {"id": "door%d" % i, "kind": "door", "pending": str(pending[i].get("id", "")),
				"label": "Unlink first to pick up %s" % name if linked else "Pick up %s" % name, "enabled": not linked}
	return {}

## The TV: Y resumes the paused game, or starts the next one.
func tv_station() -> Dictionary:
	var active := current_game()
	if not active.is_empty() and _fits_party(active):
		return {"label": "Resume %s" % active.get("title", "game"), "short": "Resume", "action": "resume", "enabled": true}
	var queue := upcoming()
	if queue.is_empty(): return {"label": "No queued games for this party", "short": "Start", "action": "next", "enabled": false}
	return {"label": "Start %s" % queue[0].title, "short": "Start", "action": "next", "enabled": true}

## The queue cabinet always starts the next game, even while another is paused.
func queue_station() -> Dictionary:
	var entries := upcoming()
	return {"id": "queue", "kind": "queue", "action": "next", "short": "Play next",
		"label": "Play %s" % entries[0].title if not entries.is_empty() else "Queue is empty",
		"enabled": not entries.is_empty() and (client.connected or demo != null)}

func _unavailable(game: Dictionary) -> String:
	if not client.connected and demo == null: return "Waiting for GameNight"
	return _shortfall(game)

## Y uses the station; at the shelf, queue (X) adds the box at the end.
func _use_station(id: String, queue := false) -> void:
	var station := station_for(id)
	if station.is_empty() or not station.enabled: return
	var now := Time.get_ticks_msec() / 1000.0
	var key := "%s:%s:%s" % [station.id, station.get("action", ""), "X" if queue else "Y"]
	if now < float(_station_cooldown.get(key, 0.0)): return
	_station_cooldown[key] = now + 0.4
	room.press_prompt("music" if station.kind == "music" else str(station.id), "X" if queue else "Y")
	match station.kind:
		"shelf":
			if queue:
				client.queue_game(str(station.game), false)
				toast("%s added to the queue." % station.title, GREEN)
			else:
				# queue_next makes it next without starting it, unlike play_next.
				client._command({"type": "queue_next", "game": str(station.game)})
				toast("%s is up next." % station.title, GREEN)
		"queue":
			if queue:
				var entries := upcoming()
				if entries.is_empty(): return
				client._command({"type": "remove_playlist_entry", "expected": party.get("playlist", {}).duplicate(true), "index": int(entries[0].index)})
				toast("Skipped %s." % entries[0].title, GREEN)
			else: client.start_next()
		"tv":
			match station.action:
				"resume": client.resume_game()
				"next": client.start_next()
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

func update_ready() -> String:
	var version = party.get("update_ready")
	return "" if version == null else str(version)

func menu_items(id: String) -> Array:
	if menus.get(id, {}).get("page", "") == "lobbies": return lobby_items()
	if menus.get(id, {}).get("page", "") == "remove": return remove_items(id)
	var items := [{"label": "Close menu", "action": "close"}, {"label": "Leave the party", "action": "leave"}]
	# The host restarts into the new version and brings the party back.
	if not update_ready().is_empty(): items.push_front({"label": "Update GameNight now", "action": "update"})
	if links.get("linked", {}).has(id): items.insert(1, {"label": "Unlink my phone profile", "action": "unlink"})
	if profiles.size() > 1: items.append({"label": "Remove a player", "action": "remove_page"})
	if party.get("lobbies", []).size() > 1: items.append({"label": "Switch lobby", "action": "lobbies"})
	items.append({"label": "Quit GameNight", "action": "quit"})
	return items

## Everyone else in the party, as a page of the Start menu, so a player who
## left without leaving (a phone, a web join, someone gone home) can be
## taken out. Players without a controller come first.
func remove_items(id: String) -> Array:
	var items := []
	for other in bench + world.players.keys():
		if other == id or not profiles.has(other): continue
		var label := _short(_name(other), 18)
		if bench.has(other): label += "  (phone)" if party.get("phones", []).has(other) else "  (no controller)"
		elif lost_since.has(other): label += "  (no controller)"
		elif world.players[other].sleeping: label += "  (away)"
		items.append({"label": label, "action": "remove", "player": other, "name": _name(other)})
	items.append({"label": "Back", "action": "back"})
	return items

## The host's lobbies, as a page of the Start menu. Picking one restarts
## the host into it with everyone still seated.
func lobby_items() -> Array:
	var items := []
	for lobby in party.get("lobbies", []):
		var current: bool = lobby.get("current", false)
		var title := str(lobby.get("title", lobby.get("id", "")))
		items.append({"label": title + ("  (here now)" if current else ""), "action": "lobby",
			"lobby": str(lobby.get("id", "")), "title": title, "current": current})
	items.append({"label": "Back", "action": "back"})
	return items

func _menu_input(id: String, pressed: int, stick: Vector2) -> void:
	var menu: Dictionary = menus[id]
	var items := menu_items(id)
	menu.index = clampi(menu.index, 0, items.size() - 1)
	var up: bool = pressed & World.BTN_UP or (stick.y < -0.6 and not menu.get("stick", false))
	var down: bool = pressed & World.BTN_DOWN or (stick.y > 0.6 and not menu.get("stick", false))
	menu["stick"] = absf(stick.y) > 0.6
	if up: menu.index = posmod(menu.index - 1, items.size()); menu.confirm = false
	if down: menu.index = posmod(menu.index + 1, items.size()); menu.confirm = false
	if pressed & World.BTN_B:
		if menu.get("page", "") != "": _menu_page(menu, "")
		else: menus.erase(id)
	elif pressed & World.BTN_A:
		var item: Dictionary = items[menu.index]
		var action: String = item.action
		match action:
			"close": menus.erase(id)
			"lobbies": _menu_page(menu, "lobbies")
			"remove_page": _menu_page(menu, "remove")
			"remove":
				if menu.confirm:
					_menu_page(menu, "")
					toast("%s left the party." % item.name, DIM)
					client.leave(item.player)
				else: menu.confirm = true
			"back": _menu_page(menu, "")
			"lobby":
				if item.current:
					toast("You're already in the %s." % item.title, DIM)
				else:
					menus.clear()
					toast("Opening the %s… everyone stays in the party." % item.title, GREEN)
					client._command({"type": "switch_lobby", "lobby": item.lobby})
			"update":
				menus.erase(id)
				toast("Updating GameNight… everyone stays in the party.", GREEN)
				client._command({"type": "apply_update"})
			"leave":
				menus.erase(id)
				client.leave(id)
			"unlink":
				menus.erase(id)
				if not _links_base.is_empty():
					_pickup.request(_links_base + "/api/player-links/" + id + "/unlink", ["X-GameNight-Local-Pickup: 1"], HTTPClient.METHOD_POST)
			"quit":
				if menu.confirm:
					if client.connected: client.quit_party()
					else: get_tree().quit()
				else: menu.confirm = true
	hud.queue_redraw()

func _menu_page(menu: Dictionary, page: String) -> void:
	menu.page = page
	menu.confirm = false
	menu.index = 0
	if page == "lobbies":
		var lobbies: Array = party.get("lobbies", [])
		for i in lobbies.size():
			if lobbies[i].get("current", false): menu.index = i

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
			qr = ImageTexture.create_from_image(_inverted_qr(image))
	_sync_doors()
	room.redraw("plaque")

## The daemon renders black modules on white; the plaque shows white modules
## on its own dark background, so light only comes from the modules.
static func _inverted_qr(image: Image) -> Image:
	image.convert(Image.FORMAT_RGBA8)
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			image.set_pixel(x, y, Color.WHITE if c.a > 0.5 and c.get_luminance() < 0.5 else Color.TRANSPARENT)
	return image

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
	if not _accepts_input():
		_accumulator = 0.0
		return
	_accumulator = minf(_accumulator + delta, 0.1)
	while _accumulator >= World.DT:
		_accumulator -= World.DT
		world.step()
	# Carried to the exit and thrown out: an away player leaves the party.
	for id in world.ejected:
		toast("%s was thrown out of the party." % _name(id), DIM)
		client.leave(id)
	world.ejected.clear()

func _process(delta: float) -> void:
	_time += delta
	if demo != null: demo.tick(delta)
	_remove_lost(delta)
	_update_sleep()
	view.sync_profiles(profiles, world.players)
	view.update(world, delta)
	_update_prompts()
	var next := current_game()
	if next.is_empty():
		var queue := upcoming()
		if not queue.is_empty(): next = game_meta(queue[0].game)
	room.set_mood(Color.from_string(str(next.get("color", "")), VIOLET) if not next.is_empty() else VIOLET)
	_update_loading(delta)
	var shown := _load_shown.keys().map(func(game): return [game, loading_percent(game)])
	var key := JSON.stringify([party.get("active_session"), party.get("warm_session"), party.get("warming"), party.get("game_issues"), party.get("now_playing"), shelf_offset, shown])
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

## The floating buttons light up while someone stands where they work.
func _update_prompts() -> void:
	var occupied := {}
	for id in world.players:
		if menus.has(id): continue
		var station := station_for(id)
		if not station.is_empty() and (not occupied.has(station.id) or station.enabled): occupied[station.id] = station
	var tv := tv_station()
	room.set_prompt("tv", [["Y", tv.short]], tv.enabled, occupied.has("tv"))
	var queued := queue_station()
	room.set_prompt("queue", [["Y", "Play next"], ["X", "Skip next"]], queued.enabled, occupied.has("queue"))
	var shelf_live := not shelf_games().is_empty()
	room.featured_box.visible = shelf_live and occupied.has("shelf")
	room.set_prompt("shelf", [["Y", "Set up next"], ["X", "Queue"]], occupied.get("shelf", {}).get("enabled", shelf_live), occupied.has("shelf"))
	for side in ["shelf_lb", "shelf_rb"]: room.get_node(side).visible = occupied.has("shelf") and shelf_games().size() > 1
	var playing: bool = party.get("now_playing", {}).get("playing", false) if party.get("now_playing") is Dictionary else false
	room.set_prompt("music", [["LB", "Previous"], ["Y", "Pause" if playing else "Play"], ["RB", "Next"]], true, occupied.has("music1"))
	room.set_prompt("exit", [["Y", "Leave"]], true, occupied.has("exit"))
	for i in Layout.PROFILE_DOORS.size():
		var key := "door%d" % i
		var enabled: bool = occupied.get(key, {}).get("enabled", false)
		room.set_prompt(key, [["Y", "Pick up" if enabled else "Unlink first"]], enabled, occupied.has(key))

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
	room.screens.queue0.canvas.painter = _draw_queue_preview
	room.screens.queue_titles.canvas.painter = _draw_queue_titles

func _redraw_screens() -> void:
	for name in ["tv", "plaque", "jukebox", "box_front", "queue0", "queue_titles"]: room.redraw(name)
	var track: Variant = party.get("now_playing")
	room.music_playing = track is Dictionary and bool(track.get("playing", false))
	var shelf := shelf_games()
	var shelf_key := JSON.stringify([shelf.map(func(g): return [g.get("id"), g.get("title"), g.get("color")]), shelf_offset])
	if shelf_key != _shelf_key:
		_shelf_key = shelf_key
		room.set_shelf(shelf, shelf_offset)
	_update_prompts()
	var queue := upcoming()
	_animate_queue(queue.map(func(e): return e.game))

## Promote the next preview and slide the title list when the queue advances.
func _animate_queue(ids: Array) -> void:
	var old := _last_queue
	if ids == old: return
	_last_queue = ids.duplicate()
	var next_changed: bool = ids.is_empty() or old.is_empty() or ids[0] != old[0]
	room.animate_queue(next_changed, not old.is_empty() and ids == old.slice(1))

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
		detail = "Press Y at the TV to resume"
		var loading := _loading_session(str(game.id))
		if not loading.is_empty():
			kicker = "LOADING %d%%" % loading_percent(str(game.id))
			kicker_color = AMBER
			detail = str(loading.get("progress_label", "Preparing game"))
		elif not _fits_party(game):
			var action := tv_station()
			detail = "Y at TV: %s" % action.label if action.enabled else "This game needs a different player count"
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
				detail = "Press Y at the TV to retry"
			elif warm is Dictionary and str(warm.get("game")) == str(game.id):
				if warm.get("phase") == "ready":
					kicker = "UP NEXT · READY"
					kicker_color = GREEN
				else:
					kicker = "LOADING %d%%" % loading_percent(str(game.id))
					kicker_color = AMBER
			if issue.is_empty(): detail = "Press Y at the TV to start"
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
	_draw_loading_bar(canvas, Rect2(28, 88, size.x - 56, 12), str(game.id))
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

## The selected game is a plain cover. Games without artwork get a title card.
func _draw_box(canvas: Control, game: Dictionary) -> void:
	var rect := Rect2(Vector2.ZERO, canvas.size)
	var art := _art(game, ["cover"])
	if art != null: _cover(canvas, art, rect)
	else: _title_card(canvas, game, rect, 32 if canvas.size.x > 220 else 16)

func _draw_front_box(canvas: Control) -> void:
	var shelf := shelf_games()
	if shelf.is_empty():
		canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("0c0a16"))
		_text(canvas, "NO GAMES", Vector2(0, canvas.size.y / 2), 32, DIM, canvas.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		return
	_draw_box(canvas, shelf[shelf_offset % shelf.size()])

func _draw_queue_preview(canvas: Control) -> void:
	var size := canvas.size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), BG)
	var queue := upcoming()
	_text(canvas, "UP NEXT", Vector2(24, 46), 34, GREEN)
	if queue.is_empty():
		var matching := shelf_games().any(func(g): return _fits_party(g))
		_text(canvas, "Choose a game" if matching else "No matching games", Vector2(24, 206), 44, TEXT)
		_text(canvas, "at the game shelf" if matching else "%d players in this party" % _human_count(), Vector2(24, 256), 32, DIM)
		return
	var game := game_meta(queue[0].game)
	if game.is_empty(): game = {"id": queue[0].game, "title": queue[0].title}
	var rect := Rect2(0, 66, size.x, 272)
	var art := _art(game, ["screenshot", "cover"])
	if art != null: _cover(canvas, art, rect)
	else: _title_card(canvas, game, rect, 48)
	_draw_loading_bar(canvas, Rect2(0, 326, size.x, 12), str(game.id))
	var title := _short(str(game.get("title", queue[0].title)), 32)
	var status := _queue_status(str(game.id))
	_text(canvas, title, Vector2(24, 375 if not status.is_empty() else 390), _fit(title, 46, size.x - 48, 30), TEXT)
	if not status.is_empty(): _text(canvas, status, Vector2(24, 408), _fit(status, 24, size.x - 48, 17), PINK if not _issue(str(game.id)).is_empty() else AMBER)

func _update_loading(delta: float) -> void:
	var seen := {}
	for key in ["active_session", "warm_session", "warming"]:
		var session: Variant = party.get(key)
		if not (session is Dictionary and str(session.get("phase")) in ["created", "preparing"]): continue
		var game := str(session.get("game"))
		if seen.has(game): continue
		seen[game] = true
		var reported := clampf(float(session.progress), 0.0, 100.0) if session.get("progress") != null else 0.0
		var report: Array = _load_report.get(game, [-1.0, _time])
		if reported != report[0]:
			report = [reported, _time]
			_load_report[game] = report
		# Creep halfway toward 95% over this phase, never reaching it.
		var ceiling := reported + (95.0 - reported) * 0.5 if reported < 95.0 else reported
		var estimate := reported + (ceiling - reported) * (1.0 - exp(-(_time - float(report[1])) / 6.0))
		var now: float = _load_shown.get(game, 0.0)
		_load_shown[game] = minf(99.0, maxf(now, now + (estimate - now) * minf(1.0, delta * 2.5)))
	for game in _load_shown.keys():
		if not seen.has(game):
			_load_shown.erase(game)
			_load_report.erase(game)

func loading_percent(game_id: String) -> int:
	return int(_load_shown.get(game_id, 0.0))

## Loading can move from the warm slot to the active slot after Play next.
func _loading_session(game_id: String) -> Dictionary:
	for key in ["active_session", "warm_session", "warming"]:
		var session: Variant = party.get(key)
		if session is Dictionary and str(session.get("game")) == game_id and str(session.get("phase")) in ["created", "preparing"]:
			return session
	return {}

func _draw_loading_bar(canvas: Control, rect: Rect2, game_id: String) -> void:
	var loading := _loading_session(game_id)
	if loading.is_empty(): return
	canvas.draw_rect(rect, Color(0.03, 0.03, 0.06, 0.92))
	canvas.draw_rect(Rect2(rect.position, Vector2(rect.size.x * _load_shown.get(game_id, 0.0) / 100.0, rect.size.y)), AMBER)

func _queue_status(game_id: String) -> String:
	var issue := _issue(game_id)
	if not issue.is_empty(): return issue + " · Press Y here to retry"
	var loading := _loading_session(game_id)
	if not loading.is_empty():
		var label := str(loading.get("progress_label", "Preparing game"))
		return "%d%% · %s" % [loading_percent(game_id), label]
	var warm: Variant = party.get("warm_session")
	if warm is Dictionary and str(warm.get("game")) == game_id and warm.get("phase") == "ready": return "Ready to play"
	return ""

## Pure title data keeps the rest of the playlist independent from artwork.
func queue_title_rows() -> Array:
	var result: Array = []
	var queue := upcoming()
	for i in range(1, mini(queue.size(), Room.QUEUE_TITLE_ROWS + 1)):
		var meta := game_meta(queue[i].game)
		result.append({"number": i + 1, "title": str(meta.get("title", queue[i].title))})
	return result

func _draw_queue_titles(canvas: Control) -> void:
	var size := canvas.size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("100f1b"))
	var rows := queue_title_rows()
	if rows.is_empty(): return
	for i in rows.size():
		var y := 53.0 + i * 55.0
		_text(canvas, str(rows[i].number).pad_zeros(2), Vector2(22, y), 32, DIM)
		var title := _short(str(rows[i].title), 32)
		_text(canvas, title, Vector2(88, y), _fit(title, 40, size.x - 108, 28), TEXT)
		canvas.draw_line(Vector2(88, y + 14), Vector2(size.x - 24, y + 14), Color(1, 1, 1, 0.08))
	var more := maxi(0, upcoming().size() - 1 - rows.size())
	if more > 0: _text(canvas, "+%d more in queue" % more, Vector2(88, 284), 30, GREEN)

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
	# Only the code itself: white modules on black (the dark wall around it is
	# the quiet zone, so inverted readers still scan it), the room code below.
	var size := canvas.size
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("0c0a16"))
	var room_info: Dictionary = links.get("room", {})
	var side := 264.0
	var qr_rect := Rect2((size.x - side) / 2, 20, side, side)
	if qr != null:
		canvas.draw_texture_rect(qr, qr_rect, false)
	else:
		_text(canvas, "Phone joining", Vector2(qr_rect.position.x, qr_rect.get_center().y - 6), 16, DIM, qr_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
		_text(canvas, "starts with GameNight", Vector2(qr_rect.position.x, qr_rect.get_center().y + 18), 16, DIM, qr_rect.size.x, HORIZONTAL_ALIGNMENT_CENTER)
	var code := str(room_info.get("room_code", room_info.get("code", "")))
	if code == "<null>": code = ""
	if code.is_empty(): code = "· · · ·"
	canvas.draw_string(room.wordmark, Vector2(0, size.y - 34), code, HORIZONTAL_ALIGNMENT_CENTER, size.x, 52, TEXT)

# ---------------------------------------------------------------- HUD

func _draw_hud(canvas: Control) -> void:
	var camera: Camera3D = room.camera
	var scale := canvas.size.y / 1080.0
	var onboarding_error := str(party.get("onboarding_error", ""))
	if not onboarding_error.is_empty():
		var width := minf(canvas.size.x * 0.9, 1080 * scale)
		var rect := Rect2((canvas.size.x - width) / 2, 24 * scale, width, 112 * scale)
		canvas.draw_rect(rect, Color(0.03, 0.03, 0.06, 0.94))
		canvas.draw_rect(Rect2(rect.position, Vector2(5 * scale, rect.size.y)), AMBER)
		_text(canvas, "Could not prepare your game", rect.position + Vector2(22, 30) * scale, int(23 * scale), AMBER)
		canvas.draw_multiline_string(font, rect.position + Vector2(22, 62) * scale, onboarding_error, HORIZONTAL_ALIGNMENT_LEFT, width - 44 * scale, int(21 * scale), 2, TEXT)
	_draw_item_hints(canvas, camera)
	# Only names and open menus follow players; action buttons stay at their objects.
	for id in world.players:
		var p: Dictionary = world.players[id]
		var head := Vector3(p.x, p.y + (1.3 if p.sleeping else 2.25), view.depth(id))
		if camera.is_position_behind(head): continue
		var at := camera.unproject_position(head) / canvas.get_global_transform().get_scale()
		var color := Color.from_string(str(profiles.get(id, {}).get("color", "")), VIOLET)
		var name := _short(_name(id), 14)
		var size := int(20 * scale)
		var width := font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		canvas.draw_string_outline(font, at + Vector2(-width / 2, 0), name, HORIZONTAL_ALIGNMENT_LEFT, -1, size, maxi(4, int(5 * scale)), Color(BG, 0.85))
		_text(canvas, name, at + Vector2(-width / 2, 0), size, color.lightened(0.35))
		if lost_since.has(id):
			var lost := "Controller lost · leaves in %ds" % lost_left(id)
			var small := int(16 * scale)
			var lw := font.get_string_size(lost, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x
			canvas.draw_string_outline(font, at + Vector2(-lw / 2, -size - 4 * scale), lost, HORIZONTAL_ALIGNMENT_LEFT, -1, small, maxi(4, int(5 * scale)), Color(BG, 0.85))
			_text(canvas, lost, at + Vector2(-lw / 2, -size - 4 * scale), small, AMBER)
		if menus.has(id): _draw_menu(canvas, id, at + Vector2(0, -size - 10 * scale), int(22 * scale))
	_draw_bench(canvas, scale)
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
	if not update_ready().is_empty():
		var size := int(18 * scale)
		var msg := "Update ready  ·  Start to install"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 40
		var rect := Rect2(canvas.size.x - w - 24 * scale, 24 * scale, w, size + 22)
		canvas.draw_rect(rect, Color(0.03, 0.03, 0.06, 0.85))
		canvas.draw_rect(Rect2(rect.position, Vector2(4, rect.size.y)), GREEN)
		_text(canvas, msg, rect.position + Vector2(20, size + 4), size, TEXT)
	if demo == null and not client.connected:
		var size := int(24 * scale)
		var msg := "Connecting to GameNight…"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 48
		canvas.draw_rect(Rect2(canvas.size.x / 2 - w / 2, 24, w, size + 28), Color(0.03, 0.03, 0.06, 0.9))
		_text(canvas, msg, Vector2(canvas.size.x / 2 - w / 2 + 24, 24 + size + 6), size, AMBER)
	if profiles.is_empty() and (demo != null or client.connected):
		var size := int(28 * scale)
		var msg := "Press A on a controller to jump in"
		var w := font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 48
		canvas.draw_rect(Rect2(canvas.size.x / 2 - w / 2, canvas.size.y * 0.42, w, size + 28), Color(0.03, 0.03, 0.06, 0.85))
		_text(canvas, msg, Vector2(canvas.size.x / 2 - w / 2 + 24, canvas.size.y * 0.42 + size + 6), size, TEXT)

## Players without a controller, bottom left: a coloured dot, the name, and
## a small phone for those who play on one.
func _draw_bench(canvas: Control, scale: float) -> void:
	if bench.is_empty(): return
	var size := int(19 * scale)
	var line := size + 14 * scale
	var phones: Array = party.get("phones", [])
	var w := font.get_string_size("ON PHONES", HORIZONTAL_ALIGNMENT_LEFT, -1, int(size * 0.75)).x
	for id in bench: w = maxf(w, font.get_string_size(_short(_name(id), 16) + "  no controller", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 44 * scale)
	w += 36 * scale
	var h := line * bench.size() + 44 * scale
	var rect := Rect2(24 * scale, canvas.size.y - h - 24 * scale, w, h)
	canvas.draw_rect(rect, Color(0.03, 0.03, 0.06, 0.82))
	canvas.draw_rect(Rect2(rect.position, Vector2(4 * scale, rect.size.y)), VIOLET)
	var heading := "ON PHONES" if bench.all(func(id): return phones.has(id)) else "NO CONTROLLER"
	_text(canvas, heading, rect.position + Vector2(18, 26) * scale, int(size * 0.75), AMBER)
	for i in bench.size():
		var id: String = bench[i]
		var y := rect.position.y + 40 * scale + i * line
		var color := Color.from_string(str(profiles.get(id, {}).get("color", "")), VIOLET)
		var phone := phones.has(id)
		var icon := Rect2(rect.position.x + 20 * scale, y + 2 * scale, 12 * scale, 20 * scale)
		if phone:
			canvas.draw_rect(icon, color.lightened(0.2))
			canvas.draw_rect(icon.grow(-2.5 * scale), Color(BG, 0.9))
		else:
			canvas.draw_circle(icon.get_center(), 6 * scale, Color(color, 0.45))
		var label := _short(_name(id), 16)
		_text(canvas, label, Vector2(rect.position.x + 44 * scale, y + size), size, color.lightened(0.35) if phone else DIM)
		if not phone:
			var x := rect.position.x + 44 * scale + font.get_string_size(label + "  ", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			_text(canvas, "leaves in %ds" % lost_left(id), Vector2(x, y + size), int(size * 0.8), AMBER)

## One badge per reachable item, even when several players stand beside it.
func pickup_hint_items() -> Dictionary:
	var targets := {}
	for id in world.players:
		if menus.has(id): continue
		var item: Dictionary = world.pickup_target(world.players[id])
		if not item.is_empty(): targets[item.id] = item
	return targets

func _draw_item_hints(canvas: Control, camera: Camera3D) -> void:
	var targets := pickup_hint_items()
	for key in _item_prompt_presses.keys():
		if _time - _item_prompt_presses[key].time >= .2:
			_item_prompt_presses.erase(key)
		else: targets[key] = _item_prompt_presses[key].item
	for item in targets.values():
		var press: Dictionary = _item_prompt_presses.get(item.id, {})
		var node: Node3D = view.item_nodes.get(item.id)
		var top: Vector3
		if not press.is_empty(): top = press.position
		elif node != null and node.visible: top = node.global_position
		else: continue
		top += Vector3(0, 0.95, 0)
		if camera.is_position_behind(top): continue
		var ui_scale := canvas.get_global_transform().get_scale()
		var at := camera.unproject_position(top) / ui_scale
		var above := camera.unproject_position(top + Vector3(0, .4032, 0)) / ui_scale
		var factor := at.distance_to(above) / 96.0
		var label := "Kick" if item.kind == "ball" else "Pick up"
		var items := [["B", label]]
		var size := Vector2(room._prompt_size(items)) * factor
		at -= size * .5
		at.x = clampf(at.x, 4, canvas.size.x - size.x - 4)
		at.y = clampf(at.y, 4, canvas.size.y - size.y - 4)
		var pressed := maxf(0.0, 1.0 - (_time - float(press.get("time", -1.0))) / .2) if not press.is_empty() else 0.0
		Room.draw_prompt(canvas, {"items": items, "enabled": true, "pressed": {"B": pressed}}, bold, Transform2D(0, Vector2.ONE * factor, 0, at))
		canvas.draw_set_transform(Vector2.ZERO)

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

## Hint extras like "X queue LB RB browse": button names become badges.
const BUMPERS := ["LB", "RB", "LT", "RT"]
const FACES := {"A": Color("5cb85c"), "B": Color("e2574c"), "X": Color("3b8eea"), "Y": Color("f8cd34")}

func _extra_width(extra: String, size: int) -> float:
	var w := 0.0
	for token in extra.split(" ", false):
		if token == "/": continue
		if token in BUMPERS: w += size * 2.3
		elif FACES.has(token): w += size * 1.45
		else: w += font.get_string_size(token, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + size * 0.6
	return w

func _draw_extra(canvas: Control, extra: String, at: Vector2, size: int) -> void:
	var x := at.x
	for token in extra.split(" ", false):
		if token == "/": continue
		if token in BUMPERS:
			Room.draw_bumper(canvas, Rect2(x, at.y - size * 0.55, size * 2.0, size * 1.1), token, bold)
			x += size * 2.3
		elif FACES.has(token):
			canvas.draw_circle(Vector2(x + size * 0.6, at.y), size * 0.62, FACES[token])
			canvas.draw_string(bold, Vector2(x, at.y + size * 0.36), token, HORIZONTAL_ALIGNMENT_CENTER, size * 1.2, size, BG)
			x += size * 1.45
		else:
			_text(canvas, token, Vector2(x, at.y + size * 0.36), size, AMBER)
			x += font.get_string_size(token, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + size * 0.6

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
	var heading: String = {"lobbies": "CHOOSE A LOBBY", "remove": "REMOVE A PLAYER"}.get(menu.get("page", ""), _name(id).to_upper())
	_text(canvas, heading, rect.position + Vector2(24, size + 14), int(size * 0.7), AMBER)
	for i in items.size():
		var y := rect.position.y + 50 + i * line
		var selected: bool = i == menu.index
		var label: String = items[i].label
		if items[i].action == "quit" and menu.confirm and selected: label = "Press A again to quit"
		if items[i].action == "remove" and menu.confirm and selected: label = "Press A again to remove %s" % _short(items[i].name, 14)
		if selected: canvas.draw_rect(Rect2(rect.position.x + 12, y, w - 24, line - 4), Color(VIOLET, 0.35))
		_text(canvas, label, Vector2(rect.position.x + 32, y + size), size, TEXT if selected else DIM)

