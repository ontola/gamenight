extends RefCounted
## The room in metres. The play plane is z = 0, x grows right, y grows up.
## Collision lives here so the simulation and the 3D room never disagree.

const LEFT := -11.6
const RIGHT := 11.6
const CEILING := 10.4
const BACK := -2.6

## One-way platforms: [x0, x1, top].
const PLATFORMS := [
	# Arcade cabinet tops.
	[-10.25, -9.0, 2.7], [-8.95, -7.7, 2.7], [-7.65, -6.4, 2.7],
	# Shelves on the left wall.
	[-11.6, -8.6, 4.7], [-7.4, -5.2, 5.9],
	# Neon shelf above the TV.
	[-2.6, 2.6, 6.55],
	# Little floating speakers either side of the TV.
	[-4.7, -3.7, 3.6], [3.7, 4.7, 3.6],
	# Couch seat and back.
	[4.9, 8.0, 0.85], [5.0, 7.9, 1.55],
	# Shelf over the couch and the plaque ledge on the right.
	[5.2, 7.7, 4.3], [8.6, 11.6, 3.15],
	# High ledges for the brave.
	[-11.6, -9.6, 7.3], [-6.4, -4.4, 8.2], [-1.2, 1.2, 9.2], [4.4, 6.4, 8.2], [9.0, 11.6, 6.6],
]

const SPAWN_X := [-3.0, -1.0, 1.0, 3.0, -5.0, 5.0, -2.0, 2.0]

## Stations: the player stands in [x - half, x + half] on the floor and presses Y.
const CABINETS := [-9.625, -8.325, -7.025]
const TV_PADS := [-1.9, 0.0, 1.9]
const PAD_HALF := 0.75
const EXIT_DOOR := -11.0
const JUKEBOX := 3.6
const MUSIC_PADS := [3.05, 3.6, 4.15]
const PROFILE_DOORS := [9.35, 10.75]
const DOOR_HALF := 0.6

const TV_CENTER := Vector3(0, 3.95, BACK + 0.12)
const TV_SIZE := Vector2(5.6, 3.15)
const PLAQUE_CENTER := Vector3(10.1, 4.9, BACK + 0.08)
const QUEUE_BOARD := Vector3(6.45, 2.95, BACK + 0.06)
