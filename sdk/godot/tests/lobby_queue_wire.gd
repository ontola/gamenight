extends SceneTree
## Exercise the actual JSON wire format, not Dictionary equality (3 == 3.0).
class RecordingClient extends "res://addons/gamenight/lobby.gd":
	var wires: Array[String] = []
	func _send(message: Dictionary) -> void:
		wires.append(JSON.stringify(message))

func _initialize() -> void:
	var client := RecordingClient.new()
	client.connected = true
	for cursor in ["3", "0", "null", "absent"]:
		var raw := '{"entries":[{"game":"the-builders","title":"The Builders"}],"queued":2'
		if cursor != "absent": raw += ',"current":' + cursor
		raw += '}'
		client.party = {"playlist": JSON.parse_string(raw)}
		var before := JSON.stringify(client.party)
		client.remove_from_queue(4)
		client.move_in_queue(4, 5)
		# The Game Room also sends queue commands directly.
		client._command({"type":"remove_playlist_entry", "expected":client.party.playlist, "index":4})
		assert(JSON.stringify(client.party) == before, "Queue edits must not mutate the snapshot")
	client.set_setting("spaceracer", "speed", 1.25)
	for wire in client.wires: print("QUEUE_WIRE " + wire)
	client.free()
	quit()
