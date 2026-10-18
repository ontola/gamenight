extends Node2D
## A complete, small GameNight game to grow your own from: everyone races for
## orbs, A dashes and knocks others aside, a round lasts 60 seconds.
##
## Everything an agent needs to see the game without a person is a flag:
##   godot --path . -- --seed 7 --players 3        play standalone, 3 seats (rest bots)
##   godot --path . -- --shot out.png --frames 90  all bots; save frame 90 and quit
##   godot --headless --fixed-fps 60 --path . -- --sim 4000 --seed 1
##                                                 bots play; checks the rules, prints a state hash
## With GAME_TRACE=1 the game prints what happens (tests/lifecycle.py reads it).
##
## Determinism: all randomness comes from the global RNG, seeded once from
## --seed, and the simulation only moves in _physics_process. Same seed and
## --fixed-fps give the same run, so tests, balance numbers and the store clip
## can be reproduced.

const ARENA := Rect2(80, 80, 1760, 920)
const ROUND_SECONDS := 60.0
const RESULTS_SECONDS := 4.0
const SPEED := 420.0
const DASH_SPEED := 1300.0
const DASH_TIME := 0.18
const DASH_COOLDOWN := 0.9
const RADIUS := 28.0
const ORBS := 6
const COLORS := [Color("#e8553d"), Color("#3d8fe0"), Color("#5cc45a"), Color("#e6c13a"),
	Color("#b05ce0"), Color("#3ac9c4"), Color("#e07ab8"), Color("#9aa3ad")]
const NAMES := ["Red", "Blue", "Green", "Yellow", "Purple", "Teal", "Pink", "Grey"]

var players: Array[Dictionary] = []
var orbs: Array[Vector2] = []
var clock := ROUND_SECONDS
var results := 0.0
var round_number := 0
var host_paused := false
var session := ""
var stats := {"dashes": 0, "orbs": 0, "bumps": 0, "rounds": 0}

var seed_value := 0
var standalone_players := 1
var shot := ""
var shot_frames := 60
var sim_frames := 0
var frame := 0
var trace := OS.get_environment("GAME_TRACE") == "1"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		var next: String = args[i + 1] if i + 1 < args.size() else ""
		match args[i]:
			"--seed": seed_value = int(next)
			"--players": standalone_players = int(next)
			"--shot": shot = next
			"--frames": shot_frames = int(next)
			"--sim": sim_frames = int(next)
	if seed_value != 0:
		seed(seed_value)
	else:
		randomize()
	if GameNight.launched_by_daemon and shot == "" and sim_frames == 0:
		GameNight.prepared.connect(_on_prepared)
		GameNight.started.connect(func(_s): _set_paused(false))
		GameNight.resumed.connect(func(_s): _set_paused(false))
		GameNight.paused.connect(func(_s): _set_paused(true))
		GameNight.disposed.connect(_on_disposed)
		host_paused = true
		return
	# Standalone, screenshot and sim: local pads first, bots fill the rest.
	var bots := shot != "" or sim_frames > 0
	var count := maxi(2, standalone_players if not bots else 4)
	var roster: Array = []
	for i in count:
		roster.append({"bot": bots or i >= standalone_players, "seat": -1, "pad": i})
	_seat(roster)
	_new_round()


func _on_prepared(session_id: String, seats: Array, profiles: Array) -> void:
	session = session_id
	var roster: Array = []
	for seat in seats:
		var occupant: Dictionary = seat.get("occupant", {})
		var kind := str(occupant.get("kind", "empty"))
		if kind != "local" and kind != "ai":
			continue
		var entry := {"bot": kind == "ai", "seat": int(seat.get("index", 0)), "pad": -1}
		for p in profiles:
			if str(p.get("id", "")) != "" and str(p.get("id")) == str(occupant.get("player_id", "")):
				entry.name = str(p.get("name", ""))
				if p.has("color"):
					entry.color = Color.from_string(str(p.color), Color.WHITE)
		roster.append(entry)
	if roster.is_empty():
		roster.append({"bot": true, "seat": -1, "pad": -1})
	_seat(roster)
	_new_round()
	_set_paused(true)
	_trace("seated " + ", ".join(players.map(func(p): return "bot" if p.bot else "%s (seat %d)" % [p.name, p.seat])))
	# Ready only once the first frame can be drawn: the level is built above.
	GameNight.notify_ready(session_id)


func _on_disposed(_s: String) -> void:
	session = ""
	_set_paused(true)
	_trace("disposed")


func _set_paused(p: bool) -> void:
	host_paused = p
	_trace("paused" if p else "running")


func _seat(roster: Array) -> void:
	players.clear()
	for i in roster.size():
		var r: Dictionary = roster[i]
		players.append({
			"name": r.get("name", NAMES[i % NAMES.size()]), "color": r.get("color", COLORS[i % COLORS.size()]),
			"bot": r.bot, "seat": r.seat, "pad": r.pad, "pos": Vector2.ZERO, "vel": Vector2.ZERO,
			"dash": 0.0, "cooldown": 0.0, "score": 0, "was_a": false,
		})


func _new_round() -> void:
	round_number += 1
	clock = ROUND_SECONDS
	results = 0.0
	for i in players.size():
		var angle := TAU * i / players.size()
		players[i].pos = ARENA.get_center() + Vector2.from_angle(angle) * 300.0
		players[i].vel = Vector2.ZERO
		players[i].score = 0
	orbs.clear()
	for i in ORBS:
		orbs.append(_free_spot())


func _free_spot() -> Vector2:
	return Vector2(randf_range(ARENA.position.x + 60, ARENA.end.x - 60),
		randf_range(ARENA.position.y + 60, ARENA.end.y - 60))


## Returns [move, dash pressed this frame] for one player.
func _input_for(p: Dictionary) -> Array:
	var move := Vector2.ZERO
	var a := false
	if p.bot:
		var target := _nearest_orb(p.pos)
		move = (target - p.pos).limit_length(1.0)
		a = p.pos.distance_to(target) < 260.0 and randf() < 0.03
	elif p.seat >= 0:
		var f := GameNight.frame_for_seat(p.seat)
		move = Vector2(GameNight.axis(f, 0), GameNight.axis(f, 1))
		a = GameNight.button(f, 0)
	else:
		move = Vector2(Input.get_joy_axis(p.pad, JOY_AXIS_LEFT_X), Input.get_joy_axis(p.pad, JOY_AXIS_LEFT_Y))
		a = Input.is_joy_button_pressed(p.pad, JOY_BUTTON_A)
		if p.pad == 0:
			move += Vector2(float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
				float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
			a = a or Input.is_key_pressed(KEY_SPACE)
	if move.length() < 0.2:
		move = Vector2.ZERO
	var pressed: bool = a and not p.was_a
	p.was_a = a
	return [move.limit_length(1.0), pressed]


func _nearest_orb(from: Vector2) -> Vector2:
	var best := ARENA.get_center()
	var best_d := INF
	for o in orbs:
		var d := from.distance_squared_to(o)
		if d < best_d:
			best_d = d
			best = o
	return best


func _physics_process(delta: float) -> void:
	frame += 1
	if sim_frames > 0 and frame >= sim_frames:
		_finish_sim()
		return
	if shot != "" and frame == shot_frames:
		_save_shot()
	if host_paused or players.is_empty():
		return
	if results > 0.0:
		results -= delta
		if results <= 0.0:
			_new_round()
		queue_redraw()
		return
	clock -= delta
	for p in players:
		var input := _input_for(p)
		var move: Vector2 = input[0]
		p.cooldown = maxf(0.0, p.cooldown - delta)
		p.dash = maxf(0.0, p.dash - delta)
		if input[1] and p.cooldown == 0.0:
			p.dash = DASH_TIME
			p.cooldown = DASH_COOLDOWN
			p.vel = (move if move != Vector2.ZERO else Vector2.RIGHT) * DASH_SPEED
			stats.dashes += 1
			_trace("dash " + p.name)
		if p.dash == 0.0:
			p.vel = p.vel.lerp(move * SPEED, 1.0 - exp(-12.0 * delta))
		p.pos = (p.pos + p.vel * delta).clamp(ARENA.position + Vector2.ONE * RADIUS, ARENA.end - Vector2.ONE * RADIUS)
		if not p.bot and move != Vector2.ZERO and frame % 30 == 0:
			_trace("moved " + p.name)
	_collide()
	for p in players:
		for i in orbs.size():
			if p.pos.distance_to(orbs[i]) < RADIUS + 14.0:
				p.score += 1
				stats.orbs += 1
				orbs[i] = _free_spot()
	if clock <= 0.0:
		_end_round()
	queue_redraw()


func _collide() -> void:
	for i in players.size():
		for j in range(i + 1, players.size()):
			var a: Dictionary = players[i]
			var b: Dictionary = players[j]
			var gap: Vector2 = b.pos - a.pos
			var overlap := RADIUS * 2.0 - gap.length()
			if overlap <= 0.0 or gap == Vector2.ZERO:
				continue
			var n := gap.normalized()
			a.pos -= n * overlap * 0.5
			b.pos += n * overlap * 0.5
			# A dashing player shoves the other one away.
			if a.dash > 0.0 or b.dash > 0.0:
				var a_hits: bool = a.dash > b.dash
				var hitter: Dictionary = a if a_hits else b
				var hit: Dictionary = b if a_hits else a
				hit.vel = (hit.pos - hitter.pos).normalized() * DASH_SPEED * 0.8
				hit.dash = DASH_TIME
				stats.bumps += 1


func _end_round() -> void:
	results = RESULTS_SECONDS
	stats.rounds += 1
	var ranking := players.duplicate()
	ranking.sort_custom(func(x, y): return x.score > y.score)
	_trace("round %d won by %s" % [round_number, ranking[0].name])
	if session != "":
		# The host keeps the session going: we show results, then the next round.
		GameNight.notify_finished(session)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(1920, 1080)), Color("#14121c"))
	draw_rect(ARENA, Color("#1f1c2b"))
	draw_rect(ARENA, Color("#3a3550"), false, 6.0)
	for o in orbs:
		draw_circle(o, 14.0, Color("#ffe58a"))
	for p in players:
		var c: Color = p.color
		draw_circle(p.pos, RADIUS, c.lightened(0.35) if p.dash > 0.0 else c)
		draw_arc(p.pos, RADIUS + 6.0, 0.0, TAU * (1.0 - p.cooldown / DASH_COOLDOWN), 24, c.darkened(0.3), 4.0)
	# The only text is the clock and scores: everything else reads from shapes.
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(900, 60), "%d" % ceili(maxf(clock, 0.0)), HORIZONTAL_ALIGNMENT_CENTER, 120, 48)
	for i in players.size():
		var p: Dictionary = players[i]
		draw_circle(Vector2(120 + i * 140, 1040), 14.0, p.color)
		draw_string(font, Vector2(145 + i * 140, 1054), str(p.score), HORIZONTAL_ALIGNMENT_LEFT, -1, 36)


func _save_shot() -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shot)
	print("shot: ", shot)
	get_tree().quit()


func _finish_sim() -> void:
	set_physics_process(false)
	var state := PackedStringArray()
	for p in players:
		state.append("%.3f,%.3f,%d" % [p.pos.x, p.pos.y, p.score])
	print("sim: ", stats, " hash ", ";".join(state).sha256_text().left(16))
	var missing := stats.keys().filter(func(k): return stats[k] <= 0)
	if missing.is_empty():
		print("sim: ok")
		get_tree().quit(0)
	else:
		printerr("sim: never happened: ", missing)
		get_tree().quit(1)


func _trace(line: String) -> void:
	if trace:
		print(line)
