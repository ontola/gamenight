extends Node
## Public client for a runtime-selected lobby. No game autoload is needed.
## The daemon supplies controller frames and owns players, sessions and input.
const PROTOCOL := preload("protocol.gd")

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
	if not OS.get_environment(PROTOCOL.ENV_GAME_ID).is_empty():
		lobby_id = OS.get_environment(PROTOCOL.ENV_GAME_ID)
	_open()

func _open() -> void:
	_socket = WebSocketPeer.new()
	# Party snapshots may contain several embedded PNG covers plus player art.
	_socket.inbound_buffer_size = 16 * 1024 * 1024
	_socket.max_queued_packets = 256
	_hello = false
	var address := OS.get_environment(PROTOCOL.ENV_ADDR)
	if address.is_empty(): address = PROTOCOL.DEFAULT_ADDR
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
			_send({"type": PROTOCOL.MSG_HELLO, "role": PROTOCOL.ROLE_LOBBY, "game": lobby_id,
				"token": OS.get_environment(PROTOCOL.ENV_TOKEN)})
		while _socket.get_available_packet_count() > 0:
			var message: Variant = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
			if message is Dictionary: _handle(message)
	elif _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_socket = null
		_retry_at = Time.get_ticks_msec() + 1500
		connected = false
		# A welcome reconnects the socket, but only a fresh lobby_focus grants
		# screen ownership. Never carry the previous connection's grant over.
		active = false
		connection_changed.emit(false)

func _handle(message: Dictionary) -> void:
	match message.get("type", ""):
		PROTOCOL.MSG_WELCOME:
			connected = true
			connection_changed.emit(true)
			party = message.get("party", {})
			party_changed.emit(party)
			# Let the view build its first frame before accepting screen ownership.
			await get_tree().process_frame
			_send({"type": PROTOCOL.MSG_LOBBY_READY})
		PROTOCOL.MSG_PARTY_STATE:
			party = message.get("party", {})
			party_changed.emit(party)
		PROTOCOL.MSG_LOBBY_FOCUS:
			active = message.get("active", false)
			focus_changed.emit(active)
		PROTOCOL.MSG_CONTROLLER_FRAME: controllers_changed.emit(message.get("controllers", []))
		PROTOCOL.MSG_ERROR: rejected.emit(message.get("message", "The request could not be completed."))

func _send(message: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(message))

func _command(message: Dictionary) -> void:
	if not connected:
		rejected.emit("Reconnecting to GameNight. Please try again when connected.")
		return
	# Godot parses every JSON number as float. The optimistic queue snapshot
	# must echo the host's integer cursor, otherwise serde rejects e.g. 3.0.
	# Copy only this command payload; never mutate the received party state or
	# coerce unrelated numeric game settings.
	if message.get("type") in [PROTOCOL.MSG_REMOVE_PLAYLIST_ENTRY, PROTOCOL.MSG_MOVE_PLAYLIST_ENTRY]:
		message = message.duplicate(true)
		var expected: Dictionary = message.get("expected", {})
		if expected.get("current") != null:
			expected["current"] = int(expected["current"])
	if message.get("type") in [PROTOCOL.MSG_NEXT, PROTOCOL.MSG_PLAY_NEXT, PROTOCOL.MSG_CLOSE_OVERLAY]: _allow_game_foreground()
	_send(message)

## Windows keeps a background process from taking focus unless the foreground
## app hands it over. A warm game started before this press would stay behind
## the lobby, so grant it first. GDScript cannot call user32; the host ships a
## helper (GAMENIGHT_FOREGROUND_HELPER) that does, as a child of this process.
func _allow_game_foreground() -> void:
	if OS.get_name() != "Windows": return
	var helper := OS.get_environment("GAMENIGHT_FOREGROUND_HELPER")
	if helper.is_empty() or not FileAccess.file_exists(helper): return
	OS.execute(helper, ["--allow-foreground"])

func join_guest(name: String) -> void:
	_command({"type": PROTOCOL.MSG_JOIN_PARTY, "name": name})

func leave(player_id: String) -> void:
	_command({"type": PROTOCOL.MSG_LEAVE_PARTY, "player_id": player_id})

func play(game_id: String) -> void:
	_command({"type": PROTOCOL.MSG_PLAY_NEXT, "game": game_id})

func queue_game(game_id: String, first: bool = false) -> void:
	_command({"type": PROTOCOL.MSG_QUEUE_GAME, "game": game_id, "first":first})

func start_next() -> void:
	_command({"type":PROTOCOL.MSG_NEXT})

func resume_game() -> void:
	# Close only the pause caused by opening the lobby.
	_command({"type": PROTOCOL.MSG_CLOSE_OVERLAY})

func open_lobby() -> void:
	_command({"type": PROTOCOL.MSG_OPEN_OVERLAY})

func quit_party() -> void:
	_command({"type": PROTOCOL.MSG_QUIT_PARTY})

func set_setting(game_id: String, key: String, value: Variant) -> void:
	_command({"type": PROTOCOL.MSG_SET_SETTING, "game": game_id, "key": key, "value": value})

func media_control(action: String) -> void:
	if action in ["play_pause", "previous_track", "next_track", "resume"]:
		_command({"type":PROTOCOL.MSG_MEDIA_CONTROL, "action":action})

func remove_from_queue(index: int) -> void:
	_command({"type":PROTOCOL.MSG_REMOVE_PLAYLIST_ENTRY, "expected":party.get("playlist", {}), "index":index})

func move_in_queue(from: int, to: int) -> void:
	_command({"type":PROTOCOL.MSG_MOVE_PLAYLIST_ENTRY, "expected":party.get("playlist", {}), "from":from, "to":to})
