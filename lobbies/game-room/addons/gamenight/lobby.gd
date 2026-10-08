extends Node
## Public client for a runtime-selected lobby. No game autoload is needed.
## The daemon supplies controller frames and owns players, sessions and input.
signal party_changed(party: Dictionary)
signal focus_changed(active: bool)
signal controllers_changed(controllers: Array)
signal connection_changed(connected: bool)
signal rejected(message: String)

var party: Dictionary = {}
var active := false
var connected := false
var lobby_id := "godot-lobby"
var _socket: WebSocketPeer
var _hello := false
var _retry_at := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.get_environment("GAMENIGHT_GAME_ID").is_empty():
		lobby_id = OS.get_environment("GAMENIGHT_GAME_ID")
	_open()

func _open() -> void:
	_socket = WebSocketPeer.new()
	# Party snapshots may contain several embedded PNG covers plus player art.
	_socket.inbound_buffer_size = 16 * 1024 * 1024
	_socket.max_queued_packets = 256
	_hello = false
	var address := OS.get_environment("GAMENIGHT_ADDR")
	if address.is_empty(): address = "127.0.0.1:7912"
	if not address.begins_with("ws://") and not address.begins_with("wss://"):
		address = "ws://" + address
	_socket.connect_to_url(address)

func _process(_delta: float) -> void:
	if _socket == null:
		if Time.get_ticks_msec() >= _retry_at: _open()
		return
	_socket.poll()
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _hello:
			_hello = true
			_send({"type": "hello", "role": "lobby", "game": lobby_id,
				"token": OS.get_environment("GAMENIGHT_TOKEN")})
		while _socket.get_available_packet_count() > 0:
			var message: Variant = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
			if message is Dictionary: _handle(message)
	elif _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_socket = null
		_retry_at = Time.get_ticks_msec() + 1500
		connected = false
		connection_changed.emit(false)

func _handle(message: Dictionary) -> void:
	match message.get("type", ""):
		"welcome":
			connected = true
			connection_changed.emit(true)
			party = message.get("party", {})
			party_changed.emit(party)
			# Let the view build its first frame before accepting screen ownership.
			await get_tree().process_frame
			_send({"type": "lobby_ready"})
		"party_state":
			party = message.get("party", {})
			party_changed.emit(party)
		"lobby_focus":
			active = message.get("active", false)
			focus_changed.emit(active)
		"controller_frame": controllers_changed.emit(message.get("controllers", []))
		"error": rejected.emit(message.get("message", "The request could not be completed."))

func _send(message: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(message))

func _command(message: Dictionary) -> void:
	if not connected:
		rejected.emit("Reconnecting to GameNight. Please try again when connected.")
		return
	_send(message)

func join_guest(name: String) -> void:
	_command({"type": "join_party", "name": name})

func leave(player_id: String) -> void:
	_command({"type": "leave_party", "player_id": player_id})

func play(game_id: String) -> void:
	_command({"type": "play_next", "game": game_id})

func queue_game(game_id: String, first: bool = false) -> void:
	_command({"type": "queue_game", "game": game_id, "first":first})

func start_next() -> void:
	_command({"type":"next"})

func resume_game() -> void:
	# Close only the pause caused by opening the lobby.
	_command({"type": "close_overlay"})

func open_lobby() -> void:
	_command({"type": "open_overlay"})

func quit_party() -> void:
	_command({"type": "quit_party"})

func set_setting(game_id: String, key: String, value: Variant) -> void:
	_command({"type": "set_setting", "game": game_id, "key": key, "value": value})

func media_control(action: String) -> void:
	if action in ["play_pause", "previous_track", "next_track"]:
		_command({"type":"media_control", "action":action})

func remove_from_queue(index: int) -> void:
	_command({"type":"remove_playlist_entry", "expected":party.get("playlist", {}), "index":index})

func move_in_queue(from: int, to: int) -> void:
	_command({"type":"move_playlist_entry", "expected":party.get("playlist", {}), "from":from, "to":to})
