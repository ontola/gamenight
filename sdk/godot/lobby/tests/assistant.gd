extends SceneTree
var failed := false
var assistant: Node

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, note: String) -> void:
	if not condition:
		failed = true
		push_error(note)

func wait_state(states: Array) -> void:
	var deadline := Time.get_ticks_msec()+10000
	while assistant.state not in states and Time.get_ticks_msec()<deadline: await process_frame
	check(assistant.state in states, "Assistant timed out: " + assistant.state + " " + assistant.message)

func run() -> void:
	assistant = load("res://lobby/assistant.gd").new()
	assistant.entry_url = OS.get_environment("GAMENIGHT_ASSISTANT_TEST_URL")
	root.add_child(assistant)
	var speech_file := OS.get_environment("GAMENIGHT_ASSISTANT_TEST_WAV")
	if not speech_file.is_empty():
		var speech: Dictionary = assistant._transcribe(speech_file, ProjectSettings.globalize_path("res://lobby/transcribe-windows.ps1"))
		check(not str(speech.get("text", "")).is_empty(), "Windows speech helper transcribes the generated audio")
		check(not FileAccess.file_exists(speech_file), "Temporary speech audio is removed")
	assistant.accept_transcript("Queue a short game")
	await wait_state(["done","error"])
	check(assistant.state == "done" and assistant.message == "The host confirmed the game is queued.", "Authenticated request returns host result")
	assistant.cancel()
	assistant.accept_transcript("Paid request")
	await wait_state(["quote","error"])
	check(assistant.state == "quote" and assistant.quote == 3, "Paid request waits for explicit credit confirmation")
	assistant.confirm()
	await wait_state(["done","error"])
	check(assistant.state == "done", "Confirmed paid request completes")
	assistant.cancel()
	assistant.accept_transcript("   ")
	check(assistant.state == "error", "Silence is never submitted")
	assistant.cancel()
	print("ASSISTANT_TEST_", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
