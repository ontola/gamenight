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
const BTN_UP := 1 << 10
const BTN_DOWN := 1 << 11
const BTN_LEFT := 1 << 12
const BTN_RIGHT := 1 << 13

const ITEM_KINDS := ["bomb", "blaster", "hatbox", "bomb", "blaster", "ball"]
const DROP_EVERY := 9.0
const MAX_ITEMS := 6
const ITEM_LIFE := 30.0

var players: Dictionary = {}   # id -> state dictionary
var items: Array = []
var shots: Array = []
var events: Array = []         # consumed by the view each frame
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
		"walk_phase": 0.0, "land": 0.0, "spawn": 0.6, "cheer": 0.0}
	players[id] = p
	events.append({"type": "spawn", "x": p.x, "y": p.y, "player": id})
	return p

func remove_player(id: String) -> void:
	if not players.has(id): return
	_drop_item(players[id], false)
	players.erase(id)

## held: button bitmask, stick: x right, y down (SDL convention), -1..1.
func set_input(id: String, held: int, stick: Vector2) -> void:
	if not players.has(id): return
	var p: Dictionary = players[id]
	p.pressed |= held & ~int(p.held)
	if held != 0 or stick.length() > 0.3: p.last_input = time
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
	if p.pressed & BTN_B:
		if not item.is_empty(): _drop_item(p, true)
		else: _grab(p)
	if p.pressed & BTN_X:
		if item.is_empty(): _punch(p)
		elif item.kind == "blaster": _fire(p, item)
		elif item.kind == "bomb": _drop_item(p, true)

func _grab(p: Dictionary) -> void:
	for item in items:
		if item.holder != "" : continue
		if absf(item.x - p.x) < 0.8 and item.y < p.y + HEIGHT and item.y + 0.6 > p.y:
			if item.kind == "ball":
				_kick(p, item, 1.6)
				return
			if item.kind == "hatbox":
				p.hat = item.hat
				p.cheer = 0.6
				item.dead = true
				events.append({"type": "hat", "x": item.x, "y": item.y, "player": p.id, "hat": item.hat})
				return
			item.holder = p.id
			p.item = item.id
			if item.kind == "bomb" and item.fuse < 0: item.fuse = 3.2
			events.append({"type": "grab", "x": item.x, "y": item.y, "player": p.id})
			return

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
	p.fire_cd = 0.22
	item.ammo -= 1
	shots.append({"x": p.x + p.facing * 0.7, "y": p.y + 0.72, "vx": p.facing * 20.0, "owner": p.id,
		"life": 0.7, "hue": rng.randf()})
	events.append({"type": "fire", "x": p.x + p.facing * 0.8, "y": p.y + 0.72, "player": p.id})
	p.vx -= p.facing * 1.5
	if item.ammo <= 0:
		item.dead = true
		p.item = -1

func _knock(p: Dictionary, vx: float, vy: float, stun: float) -> void:
	_drop_item(p, false)
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
	var hats := ["cap", "crown", "party", "tophat", "beanie", "headphones"]
	var item := {"id": _next_item, "kind": kind, "x": x, "y": y, "vx": rng.randf_range(-1, 1),
		"vy": 0.0, "holder": "", "fuse": -1.0, "ammo": 8, "age": 0.0, "spin": 0.0,
		"hat": hats[rng.randi() % hats.size()], "thrower": "", "dead": false}
	_next_item += 1
	items.append(item)
	return item

func _maybe_drop() -> void:
	if players.is_empty() or time < _drop_at: return
	_drop_at = time + DROP_EVERY
	var free := items.filter(func(i): return i.holder == "")
	if free.size() >= MAX_ITEMS: return
	var kind: String = ITEM_KINDS[rng.randi() % ITEM_KINDS.size()]
	if kind == "ball" and items.any(func(i): return i.kind == "ball"): kind = "hatbox"
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
	events.append({"type": "explode", "x": item.x, "y": item.y + 0.25})
	for id in players:
		var p: Dictionary = players[id]
		var offset := Vector2(p.x - item.x, p.y + 0.6 - item.y)
		var distance := offset.length()
		if distance < 2.6:
			var push := (1.0 - distance / 2.6) * 16.0 + 4.0
			var direction := offset.normalized() if distance > 0.05 else Vector2.UP
			_knock(p, direction.x * push, absf(direction.y) * push * 0.6 + 6.0, 0.6)
	for other in items:
		if other == item or other.holder != "": continue
		var offset := Vector2(other.x - item.x, other.y - item.y)
		if offset.length() < 2.6:
			other.vx += signf(offset.x) * 9.0
			other.vy += 7.0
			if other.kind == "bomb" and other.fuse < 0: other.fuse = 0.25

func _step_shots() -> void:
	for shot in shots:
		shot.x += shot.vx * DT
		shot.life -= DT
		if shot.x < Layout.LEFT or shot.x > Layout.RIGHT: shot.life = 0
		for id in players:
			var p: Dictionary = players[id]
			if id == shot.owner or shot.life <= 0: continue
			if absf(p.x - shot.x) < HALF_W + 0.1 and shot.y > p.y and shot.y < p.y + HEIGHT:
				_knock(p, signf(shot.vx) * 6.5, 4.5, 0.3)
				shot.life = 0
				events.append({"type": "hit", "x": shot.x, "y": shot.y, "player": id})
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
