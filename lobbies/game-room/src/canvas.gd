extends Control
## A Control whose drawing is supplied by its owner. Used inside SubViewports
## for every in-world screen: TV, game boxes, jukebox and QR plaque.
var painter: Callable

func _draw() -> void:
	if painter.is_valid(): painter.call(self)
