extends SceneTree
## Exercises the actual lobby scene against a real daemon and protocol game.
var view: Control
var failed := false

class FakeAssistant extends "res://lobby/assistant.gd":
	var starts := 0
	var releases := 0
	func start() -> void:
		starts += 1
		_set_state("listening", "Listening…")
	func release() -> void:
		releases += 1
		_set_state("transcribing", "Understanding…")

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failed = true
		push_error("LOBBY_TEST: " + label)

func wait_until(predicate: Callable, label: String) -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(predicate.call(), label)

func key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)

func run() -> void:
	view = load("res://lobby/main.tscn").instantiate()
	root.add_child(view)
	await wait_until(func(): return view.client.connected and view.party.get("players", []).size() == 4, "connected with four test players")
	check(view.party.players[0].name == "Nora", "names arrive from party snapshots")
	check(not view.faces.decode(view.party.players[0].avatar).is_empty(), "custom avatar decodes")
	check(view.faces.decode(view.party.players[0].avatar).center == Vector2(24, 28), "48px face head anchor")
	check(view.faces.decode('{"v":1,"w":256,"h":256,"px":[]}').is_empty(), "malformed avatar falls back")
	check(view.faces.decode('{"v":1,"w":[],"h":48,"px":[]}').is_empty(), "invalid dimensions fall back")
	var old := {"v": 1, "w": 16, "h": 16, "px": []}
	old.px.resize(256)
	check(view.faces.decode(JSON.stringify(old)).center == Vector2(2, 5), "historic face anchor")
	await wait_until(func(): return view.client.active, "lobby ready owns screen")
	# Exercise the actual scene's per-player cursors with deterministic frames.
	var original_seats: Array = view.party.seats.duplicate(true)
	view.party.seats[0]["controller"] = "test:0"
	view.party.seats[1]["controller"] = "test:1"
	await process_frame
	var frames: Array = [{"controller":"test:0", "buttons":0}, {"controller":"test:1", "buttons":0}]
	view._controllers_changed(frames)
	check(view._cursors.size() == 2, "each joined controller gets a selection")
	check(view.hits.all(func(hit): return hit.action not in ["previous","next","play-next","queue"]), "game hints cannot be clicked or focused")
	var real_assistant = view.assistant
	var fake := FakeAssistant.new()
	view.add_child(fake)
	view.assistant = fake
	view._cursors["test:0"].action = "assistant"
	frames[0].buttons = 1 << 7
	view._controllers_changed(frames)
	check(fake.starts == 0 and view._menu_open, "Start opens menu without recording")
	await process_frame
	check(view.hits.any(func(hit): return hit.action == "choose-lobby"), "Start menu exposes the lobby chooser")
	check(view.hits.all(func(hit): return not hit.action.begins_with("select:")), "menu prevents underlying game actions")
	view._activate("choose-lobby")
	check(view._chooser_open and view._menu_open,"chooser stays inside the lobby")
	# The local host API supplies lobby choices. Only saving is mocked here.
	view._chooser.cancel_request()
	view._chooser_received(HTTPRequest.RESULT_SUCCESS,200,PackedStringArray(),JSON.stringify({"selected":"godot-lobby","choices":[{"id":"lobby","title":"Clubhouse"},{"id":"godot-lobby","title":"Living Room"}]}).to_utf8_buffer())
	await process_frame
	await process_frame
	check(view.hits.any(func(hit): return hit.action=="lobby:lobby"),"in-lobby chooser exposes Clubhouse")
	check(view.hits.all(func(hit): return hit.action.begins_with("lobby:") or hit.action=="menu-close"),"chooser blocks game inputs")
	view._activate("menu-close")
	check(view._menu_open and not view._chooser_open,"B returns to Start menu")
	view._activate("menu-close")
	for child in view.get_children():
		if child is Timer: child.stop()
	view._links.cancel_request()
	view._room_panel = true
	view._room = {"pending":[{"id":"profile-a","display_name":"Sam","skin_color":"#bf855b"},{"id":"profile-b","display_name":"Kim","skin_color":"#905c40"},{"id":"profile-c","display_name":"Lee"}]}
	view.queue_redraw()
	await process_frame
	await process_frame
	check(view.hits.any(func(hit): return hit.action=="pickup:profile-a"),"pending profile has a pickup action")
	view._activate("pickup:profile-a")
	check(view._pickup_pending.is_empty(),"mouse cannot assign a profile to an arbitrary controller")
	view._activate("pickup-page:1")
	await process_frame
	await process_frame
	check(view.hits.any(func(hit): return hit.action=="pickup:profile-c"),"every pending profile remains reachable")
	view._pickup_pending = "profile-c"
	view._pickup_player = str(view.party.players[1].id)
	view._pickup_received(HTTPRequest.RESULT_SUCCESS,500,PackedStringArray(),PackedByteArray())
	check(view._pickup_pending.is_empty(),"pickup failure permits retry")
	view._room = {}
	view._pickup_page = 0
	view._room_panel = false
	view.party.seats[0]["controller"] = "test:0"
	view.party.seats[1]["controller"] = "test:1"
	frames[0].buttons = 0
	view._controllers_changed(frames)
	view._cursors["test:0"].action = "assistant"
	frames[0].buttons = 1
	view._controllers_changed(frames)
	check(fake.starts == 1 and view._talk_owner == "test:0", "holding A on Talk starts listening")
	view._controllers_changed(frames)
	check(fake.starts == 1, "held A does not restart recording")
	frames[0].buttons = 0
	view._controllers_changed(frames)
	check(fake.releases == 1 and view._talk_owner.is_empty(), "release sends speech once")
	view._cancel_talk()
	view._cursors["test:0"].action = "assistant"
	frames[0].buttons = 1
	view._controllers_changed(frames)
	view._controllers_changed([])
	check(fake.state == "idle" and fake.releases == 1, "controller disconnect cancels without sending")
	view.assistant = real_assistant
	fake.queue_free()
	frames[0].buttons = 0
	view._controllers_changed(frames)
	var second_action: String = view._cursors["test:1"].action
	frames[0]["axes"] = [0,0,0,0,0,32767]
	view._controllers_changed(frames)
	check(view._cursors["test:0"].game == 1, "RT cycles to the next game")
	check(view._cursors["test:1"].action == second_action, "RT preserves the other player selection")
	view._controllers_changed(frames)
	check(view._cursors["test:0"].game == 1, "holding RT does not skip repeatedly")
	frames[0].axes = [0,0,0,0,0,0]
	view._controllers_changed(frames)
	frames[0].axes = [0,0,0,0,32767,0]
	view._controllers_changed(frames)
	check(view._cursors["test:0"].game == 0, "LT cycles to the previous game")
	frames[0].axes = [0,0,0,0,0,0]
	view._controllers_changed(frames)
	frames[0].axes = [0,0,0,0,32767,0]
	view._controllers_changed(frames)
	check(view._cursors["test:0"].game == view.games.size()-1, "LT wraps around the catalog")
	view._cycle_game("test:0",1)
	await process_frame
	frames[0].axes = [0,0,0,0,0,0]
	frames[0].buttons = 1 << 10
	view._controllers_changed(frames)
	check(view._section(view._cursors["test:0"].action) != "games", "D-pad up leaves the carousel")
	var layout: Array = view._carousel_layout(32,400,900,true)
	check(layout.size()==3 and layout[-1].index==view.selected, "selected card is the central foreground card")
	check(layout[-1].rect.size.x > layout[0].rect.size.x and layout[-1].rect.size.y > layout[0].rect.size.y, "center card is larger")
	check(layout[0].rect.get_center().x < layout[-1].rect.get_center().x and layout[1].rect.get_center().x > layout[-1].rect.get_center().x, "neighbors flank the selected game")
	check(view._cursor_hits("test:0").all(func(hit): return hit.action != "leave:" + str(view.party.players[1].id)), "controller cannot select another player's leave button")
	view.party.seats = original_seats
	view._controllers_changed([])
	view.selected = 0
	var first_id: String = view.games[view.selected].id
	key(KEY_RIGHT)
	await process_frame
	check(view.games[view.selected].id != first_id, "keyboard changes selected game")
	var before: Array = view.party.playlist.entries.duplicate(true)
	key(KEY_A)
	await wait_until(func(): return view.party.playlist.entries.size() == before.size()+1, "A appends one game")
	check(view.party.playlist.entries[-1].game == view.games[view.selected].id, "A appends at the end")
	check(view.party.playlist.entries[0] == before[0], "A preserves the first game")
	check(view.party.get("active_session", {}).is_empty(), "A never starts gameplay")
	check(view._current_game().is_empty(), "no current card before a game starts")
	check(view.hits.all(func(hit): return hit.action != "resume"), "no Resume when there is no current game")
	view._activate("settings")
	await wait_until(func(): return not view._settings().is_empty(),"game declares editable settings")
	view._change_setting(0,1)
	await wait_until(func(): return view._settings().values.items == false,"toggle setting reaches runtime")
	view._change_setting(1,99)
	await wait_until(func(): return view._settings().values.rounds == 5,"number setting respects bounds")
	view._change_setting(2,1)
	await wait_until(func(): return view._settings().values.arena == "Warehouse","choice setting reaches runtime")
	view._activate("settings-close")
	key(KEY_X)
	await wait_until(func(): return view.party.playlist.entries.size() == before.size()+2, "X inserts one game")
	check(view.party.playlist.entries[0].game == view.games[view.selected].id, "X puts the selected game first")
	check(view._next_game().id == view.party.playlist.entries[0].game, "Up next follows the head of the queue")
	await wait_until(func(): return view.party.get("warm_session", {}).get("game") == view.games[view.selected].id, "first game is prepared")
	check(view.party.get("active_session", {}).is_empty(), "X never starts gameplay")
	key(KEY_ENTER)
	await wait_until(func(): return view.party.get("active_session", {}).get("phase") == "running", "play starts selected game")
	await wait_until(func(): return not view.client.active, "lobby yields to game")
	view.client.open_lobby()
	await wait_until(func(): return view.client.active and view.party.get("active_session", {}).get("phase") == "paused", "return pauses game")
	await process_frame
	var current_session: Dictionary = view.party.active_session.duplicate(true)
	var queued: Array = view._upcoming().duplicate(true)
	check(not queued.is_empty(), "resume test has an upcoming game")
	check(view._current_game().id == current_session.game, "Current uses the active game rather than queue head")
	check(view.hits.any(func(hit): return hit.action == "resume"), "Resume remains visible with a nonempty queue")
	check(view.hits.any(func(hit): return hit.action == "start"), "Up next keeps its independent Start action")
	view._activate("resume")
	await wait_until(func(): return view.party.get("active_session", {}).get("phase") == "running", "Resume button returns to game")
	check(view.party.active_session.id == current_session.id, "Resume preserves session id")
	check(view._upcoming() == queued, "Resume does not advance the queue")
	view.client.open_lobby()
	await wait_until(func(): return view.client.active, "return again")
	var player_id: String = view.party.players[0].id
	view.client._send({"type": "rename_player", "player_id": player_id, "name": "Nora updated"})
	view.client._send({"type": "set_player_avatar", "player_id": player_id, "avatar": JSON.stringify(old)})
	await wait_until(func(): return view.party.players[0].name == "Nora updated" and view.party.players[0].avatar == JSON.stringify(old), "live name and artwork updates")
	var seats: Array = view.party.seats.duplicate(true)
	view.client._socket.close()
	await wait_until(func(): return not view.client.connected, "disconnect detected")
	await wait_until(func(): return view.client.connected, "authenticated reconnect")
	check(view.party.seats == seats and view.party.players.size() == 4, "reconnect preserves players and controller bindings")
	view.client.leave(player_id)
	await wait_until(func(): return view.party.players.size() == 3, "leave frees seat")
	key(KEY_J)
	await process_frame
	check(view.party.players.size() == 3, "keyboard cannot create a controller-less guest")
	check(view.hits.all(func(hit): return hit.action != "join"), "no manual guest join buttons")
	var art = view.artwork
	check(not art.remote_url("file:///etc/passwd"),"artwork rejects file URLs")
	check(art.remote_url("https://example.test/cover.png"),"artwork accepts HTTPS")
	var picture := Image.create(2,2,false,Image.FORMAT_RGBA8)
	picture.fill(Color.RED)
	check(art.decode(picture.save_png_to_buffer()) != null,"artwork decodes PNG")
	check(art.decode(picture.save_jpg_to_buffer()) != null,"artwork decodes JPEG")
	check(art.decode(PackedByteArray([1,2,3])) == null,"bad artwork has title fallback")
	var actual_party: Dictionary = view.party.duplicate(true)
	var next_game: Dictionary = view._next_game()
	view.party["game_issues"] = [{"game": next_game.id, "kind": "disconnected"}]
	check(view._status(next_game) == "Game disconnected · Retry to load it again", "closed preload has useful status instead of Ready")
	view.queue_redraw()
	await process_frame
	await process_frame
	check(view.hits.any(func(hit): return hit.action == "start"), "retry remains actionable")
	view.party = actual_party
	print("LOBBY_FLOW_", "FAIL" if failed else "PASS")
	key(KEY_Q)
	await process_frame
	check(view._quit_confirm, "quit asks before ending party")
	key(KEY_ENTER)
	# A successful request ends the daemon and this child. Staying alive would
	# mean the user-visible quit path failed or restarted the lobby.
	await create_timer(3).timeout
	print("LOBBY_FLOW_FAIL: quit did not end the runtime")
	quit(1)
