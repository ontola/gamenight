extends "res://src/main.gd"
## Simulate a delayed/denied foreground grant without changing native focus APIs.
var allow_focus := true
var focus_requests := 0
var reported_focus: Variant = null

func _window_has_focus() -> bool:
	return super._window_has_focus() if reported_focus == null else bool(reported_focus)

func _request_window_focus() -> void:
	focus_requests += 1
	if allow_focus:
		if reported_focus != null:
			reported_focus = true
			get_window().focus_entered.emit()
		else: super._request_window_focus()

var foreground_grants := 0
var grant_before_minimize := true

func _release_game_focus() -> void:
	foreground_grants += 1
	grant_before_minimize = grant_before_minimize and get_window().mode != Window.MODE_MINIMIZED
