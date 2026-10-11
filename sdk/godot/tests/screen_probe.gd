extends "res://addons/gamenight/screen.gd"
## Loaded after autoload initialization by screen_lifecycle.gd.
var calls: Array[String] = []

func _park_warm_window() -> void:
	calls.append("park")

func _leave_the_screen(_requested_epoch: int) -> void:
	calls.append("minimize")

func _claim_the_screen(_requested_epoch: int) -> void:
	calls.append("show")
