extends Node
## Native push-to-talk. Only the transcript uses the existing authenticated agent API.
signal changed
var state := "idle"
var message := ""
var transcript := ""
var quote := 0
var entry_url := ""
var _origin := ""
var _cookie := ""
var _csrf := ""
var _request_id := ""
var _http := HTTPRequest.new()
var _mic := AudioStreamPlayer.new()
var _record := AudioEffectRecord.new()
var _bus := -1
var _started := 0
var _generation := 0
var _thread := Thread.new()
var _thread_generation := 0

func _ready() -> void:
	_http.timeout = 15
	_http.max_redirects = 0
	_http.body_size_limit = 1024 * 1024
	add_child(_http)
	add_child(_mic)

func _set_state(value: String, note: String) -> void:
	state = value
	message = note
	changed.emit()

func start() -> void:
	if state in ["listening", "transcribing", "sending", "thinking", "quote"] or _thread.is_started(): return
	_generation += 1
	transcript = ""
	if entry_url.is_empty():
		_set_state("error", "The session assistant is not connected yet.")
		return
	if OS.get_name() != "Windows":
		_set_state("error", "Voice in this lobby currently needs Windows speech recognition.")
		return
	if not ProjectSettings.get_setting("audio/driver/enable_input", false):
		_set_state("error", "Microphone input is disabled in this lobby.")
		return
	if _bus < 0:
		_bus = AudioServer.bus_count
		AudioServer.add_bus()
		AudioServer.set_bus_name(_bus, "Lobby microphone %d" % get_instance_id())
		AudioServer.set_bus_mute(_bus, true)
		AudioServer.add_bus_effect(_bus, _record)
		_mic.bus = AudioServer.get_bus_name(_bus)
		_mic.stream = AudioStreamMicrophone.new()
	_record.format = AudioStreamWAV.FORMAT_16_BITS
	_record.set_recording_active(true)
	_mic.play()
	_started = Time.get_ticks_msec()
	_set_state("listening", "Listening… Release to send")

func release() -> void:
	if state != "listening": return
	_record.set_recording_active(false)
	_mic.stop()
	var recording := _record.get_recording()
	if Time.get_ticks_msec()-_started < 250 or recording == null or recording.data.is_empty():
		_set_state("idle", "Hold Talk to assistant while speaking.")
		return
	var path := ProjectSettings.globalize_path("user://voice-%d-%d.wav" % [OS.get_process_id(), Time.get_ticks_usec()])
	if recording.save_to_wav(path) != OK:
		_set_state("error", "Could not record your microphone. Check microphone access.")
		return
	_thread_generation = _generation
	var script := ProjectSettings.globalize_path("res://lobby/transcribe-windows.ps1")
	var error := _thread.start(_transcribe.bind(path, script))
	if error != OK:
		DirAccess.remove_absolute(path)
		_set_state("error", "Speech recognition could not start.")
		return
	_set_state("transcribing", "Understanding what you said…")

func _transcribe(path: String, script: String) -> Dictionary:
	var output: Array = []
	var result := OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-AudioPath", path], output, false, false)
	DirAccess.remove_absolute(path)
	var data = JSON.parse_string(str(output[0]).strip_edges()) if not output.is_empty() else null
	if result != 0 or not data is Dictionary: return {"error":"Speech recognition is unavailable. Check your Windows speech language."}
	return data

func _process(_delta: float) -> void:
	if state == "listening" and Time.get_ticks_msec()-_started >= 20000: release()
	if _thread.is_started() and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		if _thread_generation != _generation: return
		if result.has("error"):
			_set_state("error", str(result.error))
		else:
			accept_transcript(str(result.get("text", "")))

func cancel() -> void:
	_generation += 1
	_record.set_recording_active(false)
	_mic.stop()
	_http.cancel_request()
	quote = 0
	_set_state("idle", "")

func _exit_tree() -> void:
	cancel()
	if _thread.is_started(): _thread.wait_to_finish()
	if _bus >= 0: AudioServer.remove_bus(_bus)

func _call(path: String, body: Dictionary = {}) -> Dictionary:
	var headers := PackedStringArray(["Accept: application/json"])
	if not _cookie.is_empty(): headers.append("Cookie: " + _cookie)
	if not body.is_empty():
		headers.append("Content-Type: application/json")
		headers.append("Origin: " + _origin)
		headers.append("x-gamenight-csrf: " + _csrf)
	var error := _http.request(_origin + path, headers, HTTPClient.METHOD_GET if body.is_empty() else HTTPClient.METHOD_POST, "" if body.is_empty() else JSON.stringify(body))
	if error != OK: return {"code":0}
	var response: Array = await _http.request_completed
	for header in response[2]:
		if str(header).to_lower().begins_with("set-cookie:"):
			var cookie := str(header).substr(11).strip_edges().get_slice(";",0)
			if cookie.begins_with("gn_session="): _cookie = cookie
	var data = JSON.parse_string(response[3].get_string_from_utf8())
	return {"code":int(response[1]), "data":data if data is Dictionary else {}}

func _failure(code: int) -> void:
	var notes := {401:"Reconnect your profile to the assistant session.", 403:"Join the assistant’s running room first.", 402:"This session has no available AI credits.", 409:"Another request is running. Try again shortly.", 412:"The estimate changed. Please try your request again.", 503:"The session’s AI provider is not available."}
	if code in [401,403]: _cookie = ""; _csrf = ""
	_set_state("error", notes.get(code,"The assistant could not be reached. Your game is still running."))

func accept_transcript(text: String) -> void:
	transcript = text.strip_edges().left(2000)
	if transcript.is_empty():
		_set_state("error", "I didn’t catch that. Check your microphone and try again.")
		return
	_set_state("sending", "Connecting to your assistant…")
	var generation := _generation
	var scheme_end := entry_url.find("://")
	var path_start := entry_url.find("/", scheme_end+3)
	_origin = entry_url if path_start < 0 else entry_url.substr(0,path_start)
	# The preview entry grants the same disposable session as its browser page.
	# Redirects are never followed, so credentials cannot move to another origin.
	if _cookie.is_empty() and path_start >= 0 and entry_url.substr(path_start).begins_with("/start/"):
		var login := await _call(entry_url.substr(path_start))
		if generation != _generation: return
		if login.code != 303 or _cookie.is_empty(): _failure(login.code); return
	if _csrf.is_empty():
		var session := await _call("/auth/session")
		if generation != _generation: return
		if session.code != 200: _failure(session.code); return
		_csrf = str(session.data.get("csrf", ""))
		if _csrf.is_empty(): _failure(401); return
	var status := await _call("/v1/rooms/agent")
	if generation != _generation: return
	if status.code != 200: _failure(status.code); return
	if not status.data.get("provider_configured", false): _failure(503); return
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var hex := bytes.hex_encode()
	_request_id = "%s-%s-%s-%s-%s" % [hex.substr(0,8),hex.substr(8,4),hex.substr(12,4),hex.substr(16,4),hex.substr(20,12)]
	quote = 0
	if not status.data.get("local_model", false):
		var estimate := await _call("/v1/rooms/agent/quote", {"request_id":_request_id,"text":transcript})
		if generation != _generation: return
		if estimate.code != 200: _failure(estimate.code); return
		quote = int(estimate.data.get("maximum_credits", 0))
		_set_state("quote", "Send for up to %d credits?" % quote)
	else:
		_send(generation)

func confirm() -> void:
	if state == "quote": _send(_generation)

func _send(generation: int) -> void:
	_set_state("sending", "Sending your request…")
	var response := await _call("/v1/rooms/agent", {"request_id":_request_id,"text":transcript,"max_credits":quote})
	if generation != _generation: return
	if response.code not in [200,202]: _failure(response.code); return
	_set_state("thinking", "Thinking… Your lobby stays open")
	for attempt in 45:
		await get_tree().create_timer(2).timeout
		if generation != _generation: return
		var status := await _call("/v1/rooms/agent")
		if generation != _generation: return
		if status.code != 200: _failure(status.code); return
		for request in status.data.get("requests", []):
			if request.get("id", "") == _request_id and request.get("state", "") not in ["queued", "thinking"]:
				var result = request.get("result")
				_set_state("done" if request.get("state") == "complete" else "error", str(result) if result else "Request finished.")
				return
	_set_state("error", "The assistant is taking longer than expected. Check the game before retrying.")
