extends RefCounted
## Platformer simulation in metres, stepped at a fixed 60 Hz. Pure data, no
## nodes, so tests can run it headless and the view can be rebuilt freely.

const Layout = preload("res://src/layout.gd")

const DT := 1.0 / 60.0
const WALK := 7.2
const ACCEL_GROUND := 70.0
const ACCEL_AIR := 42.0
const FRICTION := 60.0
const JUMP := 14.6
const GRAVITY := 40.0
const FAST_FALL := 2.0          # extra gravity multiplier after releasing jump
const TERMINAL := 26.0
const WALL_SLIDE := 2.6
const COYOTE := 0.09
const BUFFER := 0.12
const HALF_W := 0.42
const HEIGHT := 1.7

const BTN_A := 1
const BTN_B := 2
const BTN_X := 4
const BTN_Y := 8
const BTN_START := 128
## Right trigger, folded into the button mask by main (the wire sends it as an axis).
const BTN_RT := 1 << 20
const BTN_UP := 1 << 10
const BTN_DOWN := 1 << 11
const BTN_LEFT := 1 << 12
const BTN_RIGHT := 1 << 13

const ITEM_KINDS := ["bomb", "blaster", "popcorn", "minigun", "bazooka", "laser", "saber", "bomb", "blaster", "ball"]
## Weapons fired with X. Shots: speed, life, knock (sideways), lift, stun,
## gravity (0 flies straight) and blast (explodes where it lands).
const WEAPONS := {
	"blaster": {"ammo": 8, "cooldown": 0.22, "recoil": 1.5, "speed": 20.0, "life": 0.7, "knock": 6.5, "lift": 4.5, "stun": 0.3},
	"minigun": {"ammo": 60, "cooldown": 0.06, "recoil": 0.7, "speed": 24.0, "life": 0.6, "knock": 3.4, "lift": 2.2, "stun": 0.12, "spread": 0.12},
	"bazooka": {"ammo": 2, "cooldown": 0.9, "recoil": 7.0, "speed": 12.0, "life": 1.8, "knock": 0.0, "lift": 0.0, "stun": 0.0, "blast": true},
	"popcorn": {"ammo": 10, "cooldown": 0.3, "recoil": 0.0, "speed": 7.0, "life": 1.4, "knock": 1.8, "lift": 1.6, "stun": 0.06, "gravity": 0.6, "handful": 6},
	"laser": {"ammo": 4, "cooldown": 0.55, "recoil": 2.5, "knock": 10.0, "lift": 5.0, "stun": 0.45},
	"saber": {"ammo": 14, "cooldown": 0.32, "recoil": 0.0, "knock": 11.0, "lift": 7.0, "stun": 0.45},
}
const DROP_EVERY := 9.0
const MAX_ITEMS := 6
const ITEM_LIFE := 30.0

var players: Dictionary = {}   # id -> state dictionary
var items: Array = []
var shots: Array = []
var events: Array = []         # consumed by the view each frame
var ejected: Array = []        # players thrown out the exit, consumed by main
var time := 0.0
var _drop_at := 4.0
var _next_item := 1
var rng := RandomNumberGenerator.new()

func _init(seed_value: int = 7) -> void:
	rng.seed = seed_value

func ensure_player(id: String, slot: int) -> Dictionary:
	if players.has(id): return players[id]
	var x: float = Layout.SPAWN_X[slot % Layout.SPAWN_X.size()]
	var p := {"id": id, "x": x, "y": 3.0 + slot * 0.4, "vx": 0.0, "vy": 0.0,
		"facing": 1.0 if x < 0 else -1.0, "grounded": false, "wall": 0, "held": 0,
		"pressed": 0, "stick": Vector2.ZERO, "coyote": 0.0, "buffer": 0.0,
		"drop": 0.0, "item": -1, "hat": "none", "punch": 0.0, "punch_cd": 0.0,
		"stun": 0.0, "fire_cd": 0.0, "last_input": time, "sleeping": false,
		"walk_phase": 0.0, "land": 0.0, "spawn": 0.6, "cheer": 0.0,
		"carrying": "", "carried_by": "", "flung": 0.0}
	players[id] = p
	events.append({"type": "spawn", "x": p.x, "y": p.y, "player": id})
	return p

func remove_player(id: String) -> void:
	if not players.has(id): return
	_drop_item(players[id], false)
	_release(players[id])
	players.erase(id)

## held: button bitmask, stick: x right, y down (SDL convention), -1..1.
func set_input(id: String, held: int, stick: Vector2) -> void:
	if not players.has(id): return
	var p: Dictionary = players[id]
	p.pressed |= held & ~int(p.held)
	if held != 0 or stick.length() > 0.3:
		p.last_input = time
		# Carrying is for players who are away: any input wriggles free.
		if p.carried_by != "": _release(p)
	p.held = held
	p.stick = stick

func step() -> void:
	time += DT
	for id in players: _step_player(players[id])
	_step_items()
	_step_shots()
	_maybe_drop()
	for id in players: players[id].pressed = 0

func _axis(p: Dictionary) -> float:
	var x: float = p.stick.x
	if absf(x) < 0.25: x = 0.0
	if p.held & BTN_LEFT: x = -1.0
	if p.held & BTN_RIGHT: x = 1.0
	return clampf(x, -1, 1)

func _down(p: Dictionary) -> bool:
	return p.stick.y > 0.6 or (p.held & BTN_DOWN) != 0

func _step_player(p: Dictionary) -> void:
	if p.carried_by != "":
		_follow_carrier(p)
		return
	p.flung = maxf(0, p.flung - DT)
	p.spawn = maxf(0, p.spawn - DT)
	p.land = maxf(0, p.land - DT)
	p.cheer = maxf(0, p.cheer - DT)
	p.punch = maxf(0, p.punch - DT)
	p.punch_cd = maxf(0, p.punch_cd - DT)
	p.fire_cd = maxf(0, p.fire_cd - DT)
	p.drop = maxf(0, p.drop - DT)
	var stunned: bool = p.stun > 0
	p.stun = maxf(0, p.stun - DT)
	var axis := 0.0 if stunned or p.sleeping else _axis(p)
	if axis != 0: p.facing = signf(axis)
	# Horizontal movement with snappy acceleration and friction.
	var target := axis * WALK
	var accel := ACCEL_GROUND if p.grounded else ACCEL_AIR
	if stunned: accel = 4.0
	if axis == 0 and p.grounded and not stunned:
		p.vx = move_toward(p.vx, 0, FRICTION * DT)
	else:
		p.vx = move_toward(p.vx, target, accel * DT)
	# Jumping: coyote time, buffered presses, variable height, wall jumps.
	p.coyote = COYOTE if p.grounded else maxf(0, p.coyote - DT)
	if p.pressed & BTN_A and not p.sleeping: p.buffer = BUFFER
	else: p.buffer = maxf(0, p.buffer - DT)
	if p.buffer > 0 and not stunned:
		if _down(p) and p.grounded and _on_platform(p):
			p.drop = 0.25
			p.grounded = false
			p.y -= 0.05
			p.buffer = 0
		elif p.coyote > 0:
			p.vy = JUMP
			p.grounded = false
			p.coyote = 0
			p.buffer = 0
			events.append({"type": "jump", "x": p.x, "y": p.y, "player": p.id})
		elif p.wall != 0:
			p.vy = JUMP * 0.92
			p.vx = -p.wall * WALK * 1.15
			p.facing = -p.wall
			p.buffer = 0
			events.append({"type": "walljump", "x": p.x, "y": p.y, "player": p.id})
	var gravity := GRAVITY
	if p.vy > 0 and not (p.held & BTN_A): gravity *= 1.0 + FAST_FALL
	p.vy = maxf(p.vy - gravity * DT, -TERMINAL)
	if p.wall != 0 and p.vy < -WALL_SLIDE and axis == p.wall: p.vy = -WALL_SLIDE
	_move_body(p)
	if p.grounded and absf(p.vx) > 0.2: p.walk_phase += absf(p.vx) * DT * 1.6
	if p.flung > 0 and absf(p.x - Layout.EXIT_DOOR) <= 0.7 and p.y < 2.6:
		p.flung = 0.0
		ejected.append(p.id)
		events.append({"type": "ejected", "x": p.x, "y": p.y + 0.8, "player": p.id})
	elif p.grounded: p.flung = 0.0
	_actions(p, stunned)

func _on_platform(p: Dictionary) -> bool:
	return p.y > 0.01

func _move_body(p: Dictionary) -> void:
	var was_grounded: bool = p.grounded
	var old_y: float = p.y
	var fall: float = p.vy
	p.x += p.vx * DT
	p.y += p.vy * DT
	p.wall = 0
	if p.x - HALF_W < Layout.LEFT:
		p.x = Layout.LEFT + HALF_W
		p.vx = maxf(p.vx, 0)
		if not p.grounded: p.wall = -1
	if p.x + HALF_W > Layout.RIGHT:
		p.x = Layout.RIGHT - HALF_W
		p.vx = minf(p.vx, 0)
		if not p.grounded: p.wall = 1
	if p.y + HEIGHT > Layout.CEILING:
		p.y = Layout.CEILING - HEIGHT
		p.vy = minf(p.vy, 0)
	p.grounded = false
	var top := _landing(p.x, HALF_W, old_y, p.y, p.drop > 0)
	if p.vy <= 0 and top > -INF:
		p.y = top
		p.vy = 0
		p.grounded = true
		if not was_grounded and fall < -8:
			p.land = 0.12
			events.append({"type": "land", "x": p.x, "y": p.y, "player": p.id, "speed": -fall})

## Highest surface crossed while falling from old_y to new_y, or -INF.
func _landing(x: float, half: float, old_y: float, new_y: float, dropping: bool) -> float:
	if new_y <= 0.0: return 0.0
	var best := -INF
	if dropping: return best
	for plat in Layout.PLATFORMS:
		if x + half * 0.6 < plat[0] or x - half * 0.6 > plat[1]: continue
		if old_y >= plat[2] - 0.001 and new_y <= plat[2] and plat[2] > best:
			best = plat[2]
	return best

func _actions(p: Dictionary, stunned: bool) -> void:
	if stunned or p.sleeping: return
	var item := _item(int(p.item))
	if p.carrying != "":
		if p.pressed & BTN_B: _throw_player(p)
		return
	if p.pressed & BTN_B:
		if not item.is_empty(): _drop_item(p, true)
		elif not pickup_target(p).is_empty(): _grab(p)
		else: _grab_player(p)
	# RT uses the held item, or punches empty-handed. X is only for the room's
	# buttons, so it does nothing here. The minigun fires while RT is held,
	# everything else once per pull.
	if item.is_empty():
		if p.pressed & BTN_RT: _punch(p)
		return
	if item.kind == "minigun" and p.held & BTN_RT:
		_fire(p, item)
	elif p.pressed & BTN_RT:
		if item.kind == "bomb": _drop_item(p, true)
		elif item.kind == "laser": _laser(p, item)
		elif item.kind == "saber": _slash(p, item)
		elif WEAPONS.has(item.kind): _fire(p, item)

## The exact item B will use, shared with the floating pickup hint.
func pickup_target(p: Dictionary) -> Dictionary:
	if p.sleeping or p.stun > 0 or not _item(int(p.item)).is_empty(): return {}
	for item in items:
		if item.holder != "" or item.dead: continue
		if absf(item.x - p.x) < 0.8 and item.y < p.y + HEIGHT and item.y + 0.6 > p.y:
			return item
	return {}

func _grab(p: Dictionary) -> void:
	var item := pickup_target(p)
	if item.is_empty(): return
	if item.kind == "ball":
		_kick(p, item, 1.6)
		return
	item.holder = p.id
	p.item = item.id
	if item.kind == "bomb" and item.fuse < 0: item.fuse = 3.2
	events.append({"type": "grab", "x": item.x, "y": item.y, "player": p.id})

## The player B lifts when no item is in reach: someone close by who is not
## already carrying or being carried.
func carry_target(p: Dictionary) -> Dictionary:
	if p.sleeping or p.stun > 0 or p.carrying != "" or p.carried_by != "" or not _item(int(p.item)).is_empty(): return {}
	for id in players:
		var other: Dictionary = players[id]
		if other == p or other.carrying != "" or other.carried_by != "" or other.spawn > 0: continue
		if absf(other.x - p.x) < 1.1 and absf(other.y - p.y) < 0.9: return other
	return {}

func _grab_player(p: Dictionary) -> void:
	var other := carry_target(p)
	if other.is_empty(): return
	_drop_item(other, false)
	p.carrying = other.id
	other.carried_by = p.id
	_follow_carrier(other)
	events.append({"type": "grab", "x": other.x, "y": other.y, "player": p.id})

## A carried player lies across the carrier's raised arms.
func _follow_carrier(p: Dictionary) -> void:
	var carrier: Dictionary = players.get(p.carried_by, {})
	if carrier.is_empty() or carrier.carrying != p.id:
		p.carried_by = ""
		return
	p.x = carrier.x
	p.y = carrier.y + HEIGHT * 0.85
	p.vx = carrier.vx
	p.vy = carrier.vy
	p.grounded = false

## Lets go of whoever this player carries or is carried by.
func _release(p: Dictionary) -> void:
	var carried: Dictionary = players.get(p.carrying, {})
	if not carried.is_empty():
		carried.carried_by = ""
		carried.vy = 3.0
	var carrier: Dictionary = players.get(p.carried_by, {})
	if not carrier.is_empty():
		carrier.carrying = ""
		p.vy = 3.0
	p.carrying = ""
	p.carried_by = ""

## Throws the carried player; landing in the exit door takes them out.
func _throw_player(p: Dictionary) -> void:
	var other: Dictionary = players.get(p.carrying, {})
	p.carrying = ""
	if other.is_empty(): return
	other.carried_by = ""
	other.x = p.x + p.facing * 0.5
	other.vx = p.facing * 12.0 + p.vx * 0.5
	other.vy = 7.0
	other.grounded = false
	other.stun = 0.5
	other.flung = 1.4
	events.append({"type": "throw", "x": other.x, "y": other.y, "player": p.id})

func _drop_item(p: Dictionary, thrown: bool) -> void:
	var item := _item(int(p.item))
	p.item = -1
	if item.is_empty(): return
	item.holder = ""
	item.x = p.x + p.facing * 0.5
	item.y = p.y + 0.7
	if thrown:
		item.vx = p.facing * 11.0 + p.vx * 0.5
		item.vy = 6.5
		item.thrower = p.id
		events.append({"type": "throw", "x": item.x, "y": item.y, "player": p.id})
	else:
		item.vx = p.vx
		item.vy = 2.0

func _punch(p: Dictionary) -> void:
	if p.punch_cd > 0: return
	p.punch = 0.24
	p.punch_cd = 0.36
	events.append({"type": "punch", "x": p.x, "y": p.y, "player": p.id})
	var reach := Rect2(p.x + (0.0 if p.facing > 0 else -1.25), p.y + 0.25, 1.25, 0.8)
	for id in players:
		var other: Dictionary = players[id]
		if other == p: continue
		if reach.intersects(Rect2(other.x - HALF_W, other.y, HALF_W * 2, HEIGHT)):
			_knock(other, p.facing * 7.5, 5.0, 0.28)
			events.append({"type": "hit", "x": other.x, "y": other.y + 0.8, "player": other.id})
	for item in items:
		if item.kind == "ball" and reach.has_point(Vector2(item.x, item.y + 0.4)): _kick(p, item, 1.8)

func _fire(p: Dictionary, item: Dictionary) -> void:
	if p.fire_cd > 0: return
	var w: Dictionary = WEAPONS[item.kind]
	p.fire_cd = w.cooldown
	for n in w.get("handful", 1):
		var spread: float = w.get("spread", 0.0)
		var shot := {"kind": item.kind, "x": p.x + p.facing * 0.7, "y": p.y + 0.72 + rng.randf_range(-spread, spread),
			"vx": p.facing * w.speed, "vy": 0.0, "owner": p.id, "life": w.life, "hue": rng.randf(),
			"knock": w.knock, "lift": w.lift, "stun": w.stun, "gravity": w.get("gravity", 0.0), "blast": w.get("blast", false)}
		if w.has("handful"):
			shot.vx = p.facing * rng.randf_range(w.speed * 0.6, w.speed * 1.3)
			shot.vy = rng.randf_range(3.0, 7.5)
		shots.append(shot)
	events.append({"type": "fire", "kind": item.kind, "x": p.x + p.facing * 0.8, "y": p.y + 0.72, "player": p.id})
	p.vx -= p.facing * w.recoil
	_use_ammo(p, item)

## A beam across the room: everyone in its line flies, nothing stops it.
func _laser(p: Dictionary, item: Dictionary) -> void:
	if p.fire_cd > 0: return
	var w: Dictionary = WEAPONS.laser
	p.fire_cd = w.cooldown
	var y: float = p.y + 0.72
	var end: float = Layout.RIGHT if p.facing > 0 else Layout.LEFT
	for id in players:
		var other: Dictionary = players[id]
		if other == p or y < other.y or y > other.y + HEIGHT: continue
		if signf(other.x - p.x) != signf(p.facing): continue
		_knock(other, p.facing * w.knock, w.lift, w.stun)
		events.append({"type": "hit", "x": other.x, "y": y, "player": id})
	events.append({"type": "laser", "x": p.x + p.facing * 0.8, "x1": end, "y": y, "player": p.id})
	p.vx -= p.facing * w.recoil
	_use_ammo(p, item)

## A wide, hard swing. Wears out after a number of swings.
func _slash(p: Dictionary, item: Dictionary) -> void:
	if p.fire_cd > 0: return
	var w: Dictionary = WEAPONS.saber
	p.fire_cd = w.cooldown
	p.punch = 0.24
	var reach := Rect2(p.x + (-0.3 if p.facing > 0 else -1.9), p.y, 2.2, HEIGHT + 0.3)
	for id in players:
		var other: Dictionary = players[id]
		if other == p: continue
		if reach.intersects(Rect2(other.x - HALF_W, other.y, HALF_W * 2, HEIGHT)):
			_knock(other, p.facing * w.knock, w.lift, w.stun)
			events.append({"type": "hit", "x": other.x, "y": other.y + 0.8, "player": other.id})
	for other in items:
		if other.kind == "ball" and reach.has_point(Vector2(other.x, other.y + 0.4)): _kick(p, other, 2.4)
	events.append({"type": "slash", "x": p.x + p.facing * 0.9, "y": p.y + 0.9, "player": p.id, "facing": p.facing})
	_use_ammo(p, item)

func _use_ammo(p: Dictionary, item: Dictionary) -> void:
	item.ammo -= 1
	if item.ammo <= 0:
		item.dead = true
		p.item = -1

func _knock(p: Dictionary, vx: float, vy: float, stun: float) -> void:
	_drop_item(p, false)
	if p.carrying != "": _release(p)
	p.vx = vx
	p.vy = maxf(p.vy, vy)
	p.grounded = false
	p.stun = maxf(p.stun, stun)

func _kick(p: Dictionary, item: Dictionary, power: float) -> void:
	item.vx = p.facing * 5.5 * power + p.vx * 0.6
	item.vy = 5.0 * power
	events.append({"type": "kick", "x": item.x, "y": item.y, "player": p.id})

func _item(id: int) -> Dictionary:
	if id < 0: return {}
	for item in items:
		if item.id == id and not item.get("dead", false): return item
	return {}

func spawn_item(kind: String, x: float, y: float) -> Dictionary:
	var item := {"id": _next_item, "kind": kind, "x": x, "y": y, "vx": rng.randf_range(-1, 1),
		"vy": 0.0, "holder": "", "fuse": -1.0, "ammo": WEAPONS.get(kind, {}).get("ammo", 0), "age": 0.0, "spin": 0.0,
		"thrower": "", "dead": false}
	_next_item += 1
	items.append(item)
	return item

func _maybe_drop() -> void:
	if players.is_empty() or time < _drop_at: return
	_drop_at = time + DROP_EVERY
	var free := items.filter(func(i): return i.holder == "")
	if free.size() >= MAX_ITEMS: return
	var kind: String = ITEM_KINDS[rng.randi() % ITEM_KINDS.size()]
	if kind == "ball" and items.any(func(i): return i.kind == "ball"): kind = "popcorn"
	spawn_item(kind, rng.randf_range(Layout.LEFT + 1.5, Layout.RIGHT - 1.5), Layout.CEILING - 0.6)
	events.append({"type": "drop", "x": items[-1].x, "y": items[-1].y})

func _step_items() -> void:
	for item in items:
		if item.dead: continue
		item.age += DT
		if item.holder != "":
			var p: Dictionary = players.get(item.holder, {})
			if p.is_empty():
				item.holder = ""
			else:
				item.x = p.x + p.facing * 0.62
				item.y = p.y + 0.7
				item.vx = p.vx
				item.vy = p.vy
				item.age = 0
		else:
			var ball: bool = item.kind == "ball"
			item.vy = maxf(item.vy - GRAVITY * (0.55 if ball else 1.0) * DT, -TERMINAL)
			var old_y: float = item.y
			item.x += item.vx * DT
			item.y += item.vy * DT
			item.spin += item.vx * DT * 2.0
			var half := 0.45 if ball else 0.25
			if item.x - half < Layout.LEFT:
				item.x = Layout.LEFT + half; item.vx = absf(item.vx) * 0.7
			if item.x + half > Layout.RIGHT:
				item.x = Layout.RIGHT - half; item.vx = -absf(item.vx) * 0.7
			if item.y + half * 2 > Layout.CEILING:
				item.y = Layout.CEILING - half * 2; item.vy = -absf(item.vy) * 0.5
			var top := _landing(item.x, half, old_y, item.y, false)
			if item.vy <= 0 and top > -INF:
				item.y = top
				if absf(item.vy) > 3:
					item.vy = -item.vy * (0.72 if ball else 0.3)
					events.append({"type": "bounce", "x": item.x, "y": item.y, "kind": item.kind})
				else:
					item.vy = 0
				item.vx *= 0.97 if ball else 0.8
			if ball:
				for id in players:
					var p: Dictionary = players[id]
					if absf(p.x - item.x) < HALF_W + half and item.y < p.y + HEIGHT and item.y + half * 2 > p.y:
						if absf(item.vx - p.vx) < 3 or signf(item.x - p.x) != signf(item.vx - p.vx):
							item.vx = signf(item.x - p.x) * maxf(absf(p.vx) * 1.3, 4.0)
							item.vy = maxf(item.vy, 3.5)
		if item.kind == "bomb" and item.fuse >= 0:
			item.fuse -= DT
			if item.fuse <= 0: _explode(item)
		if item.holder == "" and item.age > ITEM_LIFE and item.kind != "ball": item.dead = true
	for item in items:
		if item.dead:
			for id in players:
				if players[id].item == item.id: players[id].item = -1
	items = items.filter(func(i): return not i.dead)

func _explode(item: Dictionary) -> void:
	item.dead = true
	_blast(item.x, item.y + 0.25, item)

## Bombs and bazooka rockets: everyone and everything nearby flies.
func _blast(x: float, y: float, source: Dictionary = {}) -> void:
	events.append({"type": "explode", "x": x, "y": y})
	for id in players:
		var p: Dictionary = players[id]
		var offset := Vector2(p.x - x, p.y + 0.85 - y)
		var distance := offset.length()
		if distance < 2.6:
			var push := (1.0 - distance / 2.6) * 16.0 + 4.0
			var direction := offset.normalized() if distance > 0.05 else Vector2.UP
			_knock(p, direction.x * push, absf(direction.y) * push * 0.6 + 6.0, 0.6)
	for other in items:
		if other == source or other.holder != "": continue
		var offset := Vector2(other.x - x, other.y + 0.25 - y)
		if offset.length() < 2.6:
			other.vx += signf(offset.x) * 9.0
			other.vy += 7.0
			if other.kind == "bomb" and other.fuse < 0: other.fuse = 0.25

func _step_shots() -> void:
	for shot in shots:
		var gravity: float = shot.get("gravity", 0.0)
		if gravity > 0:
			shot.vy -= GRAVITY * gravity * DT
			shot.y += shot.vy * DT
		shot.x += shot.vx * DT
		shot.life -= DT
		if shot.x < Layout.LEFT or shot.x > Layout.RIGHT or shot.y < 0.0:
			shot.life = 0
			if shot.get("blast", false): _blast(clampf(shot.x, Layout.LEFT, Layout.RIGHT), maxf(shot.y, 0.3))
		elif shot.life <= 0 and shot.get("blast", false):
			_blast(shot.x, shot.y)
		for id in players:
			var p: Dictionary = players[id]
			if id == shot.owner or shot.life <= 0: continue
			if absf(p.x - shot.x) < HALF_W + 0.1 and shot.y > p.y and shot.y < p.y + HEIGHT:
				shot.life = 0
				if shot.get("blast", false):
					_blast(shot.x, shot.y)
				else:
					_knock(p, signf(shot.vx) * shot.get("knock", 6.5), shot.get("lift", 4.5), shot.get("stun", 0.3))
					events.append({"type": "hit", "x": shot.x, "y": shot.y, "player": id, "kind": shot.get("kind", "")})
		for item in items:
			if item.kind == "ball" and Vector2(item.x - shot.x, item.y + 0.45 - shot.y).length() < 0.55:
				item.vx += signf(shot.vx) * 4
				item.vy += 3
				shot.life = 0
	shots = shots.filter(func(s): return s.life > 0)

## The player standing in a floor zone centred at x, or "" when nobody.
func grounded_near(id: String, x: float, half: float, floor_y: float = 0.0) -> bool:
	var p: Dictionary = players.get(id, {})
	return not p.is_empty() and p.grounded and absf(p.y - floor_y) < 0.1 and absf(p.x - x) <= half
