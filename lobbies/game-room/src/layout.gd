extends RefCounted
## The room in metres. The play plane is z = 0, x grows right, y grows up.
## Collision lives here so the simulation and the 3D room never disagree.

const LEFT := -11.6
const RIGHT := 11.6
const CEILING := 10.4
const BACK := -2.6

## One-way platforms: [x0, x1, top, depth]. Depth is the z a player stands
## at on that surface, so the sprite sits on it instead of hovering in front.
const PLATFORMS := [
	# Game bookcase and the display stand.
	[-10.3, -8.9, 2.65, -1.95], [-8.7, -6.5, 0.8, -1.75],
	# Shelves on the left wall.
	[-11.6, -8.6, 4.7, -2.0], [-7.4, -5.2, 5.9, -2.0],
	# Neon shelf above the TV.
	[-2.6, 2.6, 6.55, -2.0],
	# TV console.
	[-3.3, 3.3, 0.9, -1.8],
	# Little floating speakers either side of the TV.
	[-4.7, -3.7, 3.6, -2.05], [3.7, 4.7, 3.6, -2.05],
	# Couch seat and back.
	[4.9, 8.0, 0.85, -1.5], [5.0, 7.9, 1.55, -2.1],
	# Shelf over the couch and the plaque ledge on the right.
	[5.2, 7.7, 4.3, -2.0], [8.6, 11.6, 3.15, -2.0],
	# High ledges for the brave.
	[-11.6, -9.6, 7.3, -2.0], [-6.4, -4.4, 8.2, -2.0], [-1.2, 1.2, 9.2, -2.0], [4.4, 6.4, 8.2, -2.0], [9.0, 11.6, 6.6, -2.0],
]

## Depth of the surface under a player at (x, y): the highest platform at or
## below their feet, or the floor at z = 0.
static func depth_at(x: float, y: float) -> float:
	var best := 0.0
	var top := 0.05
	for plat in PLATFORMS:
		if x < plat[0] or x > plat[1] or plat[2] > y + 0.05 or plat[2] < top: continue
		top = plat[2]
		best = plat[3]
	return best

const SPAWN_X := [-3.0, -1.0, 1.0, 3.0, -5.0, 5.0, -2.0, 2.0]

## Stations: the player stands in [x - half, x + half] on the floor and presses Y.
const BOOKCASE := Vector2(-10.3, -8.9)       # x range of the spine bookcase
const SPINE_ROWS := [0.07, 0.93]              # shelf heights the spines stand on
const DISPLAY := Vector2(-8.7, -6.5)          # x range of the featured-box stand
const GAME_SHELF := Vector2(-10.3, -3.6)      # bookcase, stand and up next: Y / X / LB / RB
const UP_NEXT := Vector2(-6.2, -3.6)          # x range of the up next cabinet
const TV_STATION := Vector2(-2.9, 2.7)        # in front of the TV: Y starts or resumes
const EXIT_DOOR := -11.0
const JUKEBOX := 3.6
const MUSIC_PADS := [3.05, 3.6, 4.15]
const PROFILE_DOORS := [9.35, 10.75]
const DOOR_HALF := 0.6

const TV_CENTER := Vector3(0, 3.95, BACK + 0.12)
const TV_SIZE := Vector2(5.6, 3.15)
const PLAQUE_CENTER := Vector3(10.1, 4.9, BACK + 0.08)
