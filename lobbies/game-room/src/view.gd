extends Node3D
## Draws the simulation: pixel-art players as lit sprites in the 3D room,
## items as small 3D props, plus particles and light flashes for events.

const Character = preload("res://src/character.gd")
const Face = preload("res://addons/gamenight/face.gd")

var room                       # room.gd
var faces = Face.new()
var actors: Dictionary = {}    # player id -> {node, sprite, light, zzz, key}
var item_nodes: Dictionary = {}
var shot_nodes: Array = []
var _time := 0.0

func sync_profiles(profiles: Dictionary, sim_players: Dictionary) -> void:
	for id in actors.keys():
		if not sim_players.has(id):
			actors[id].node.queue_free()
			actors.erase(id)
	for id in sim_players:
		var profile: Dictionary = profiles.get(id, {})
		var hat: String = sim_players[id].hat
		var key := "%s|%s|%s|%s" % [profile.get("color", ""), profile.get("skin_color", ""), str(profile.get("avatar", "")).hash(), hat]
		if not actors.has(id): actors[id] = _make_actor(profile)
		var actor: Dictionary = actors[id]
		if actor.key != key:
			actor.key = key
			actor.sprite.texture = Character.build(profile, Character.decode_face(faces, profile), hat)
			var color := Color.from_string(str(profile.get("color", "")), Color("7c5cff"))
			actor.light.light_color = color

func _make_actor(_profile: Dictionary) -> Dictionary:
	var node := Node3D.new()
	add_child(node)
	var sprite := Sprite3D.new()
	sprite.pixel_size = 0.04
	sprite.hframes = Character.FRAMES.size()
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.shaded = true
	sprite.double_sided = true
	sprite.offset = Vector2(0, Character.H / 2.0 - 2)
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	node.add_child(sprite)
	# A soft personal glow so every player pops out of the haze.
	var light := OmniLight3D.new()
	light.light_energy = 0.9
	light.omni_range = 2.2
	light.position = Vector3(0, 0.8, 0.8)
	node.add_child(light)
	var zzz := Label3D.new()
	zzz.text = "z"
	zzz.font = room.font
	zzz.font_size = 48
	zzz.pixel_size = 0.01
	zzz.modulate = Color(1.6, 1.6, 2.2)
	zzz.outline_size = 8
	zzz.position = Vector3(0.6, 1.8, 0.1)
	zzz.visible = false
	node.add_child(zzz)
	return {"node": node, "sprite": sprite, "light": light, "zzz": zzz, "key": ""}

func update(world, delta: float) -> void:
	_time += delta
	for id in world.players:
		if not actors.has(id): continue
		var p: Dictionary = world.players[id]
		var actor: Dictionary = actors[id]
		actor.node.position = Vector3(p.x, p.y, 0)
		var sprite: Sprite3D = actor.sprite
		sprite.flip_h = p.facing < 0
		sprite.frame = Character.frame_index(_frame(p))
		# Squash on landing, stretch while rising; the sprite stays pixel-sharp.
		var squash := 1.0
		if p.land > 0: squash = 0.86
		elif not p.grounded and p.vy > 4: squash = 1.08
		sprite.scale = Vector3(1.0 / sqrt(squash), squash, 1)
		if p.spawn > 0: sprite.scale *= 1.0 - p.spawn * 0.8
		if p.stun > 0: sprite.rotation.z = sin(_time * 30) * 0.15
		else: sprite.rotation.z = 0
		actor.zzz.visible = p.sleeping
		if p.sleeping:
			var t := fmod(_time * 0.45, 1.0)
			actor.zzz.position = Vector3(0.6 + t * 0.3, 1.5 + t * 0.9, 0.1)
			actor.zzz.modulate.a = 1.0 - t
			actor.zzz.text = ["z", "zZ", "zZz"][int(_time * 0.45 * 3) % 3]
	_update_items(world)
	_update_shots(world)
	for event in world.events: _event(event, world)
	world.events.clear()

func _frame(p: Dictionary) -> String:
	if p.sleeping: return "sleep"
	if p.cheer > 0: return "cheer"
	if p.punch > 0.08: return "throw"
	if not p.grounded: return "jump" if p.vy > 0 else "fall"
	if p.item >= 0: return "carry"
	if absf(p.vx) > 0.4: return "walk%d" % (int(p.walk_phase * 2.2) % 4)
	return "idle%d" % (int(_time * 1.6 + p.x) % 2)

func _update_items(world) -> void:
	var seen := {}
	for item in world.items:
		seen[item.id] = true
		if not item_nodes.has(item.id): item_nodes[item.id] = _make_item(item)
		var node: Node3D = item_nodes[item.id]
		node.position = Vector3(item.x, item.y, 0.05)
		if item.kind == "ball":
			node.get_meta("spinner").rotation.z = -item.spin
		elif item.kind == "hatbox":
			node.rotation.y = sin(_time * 2 + item.id) * 0.4
			node.position.y += 0.05 + sin(_time * 3 + item.id) * 0.05
		elif item.kind == "bomb":
			var spark: OmniLight3D = node.get_node("spark")
			if item.fuse >= 0:
				spark.light_energy = 1.5 + randf() * 2.0
				var pulse: float = 1.0 + (0.12 if fmod(item.fuse, 0.4 if item.fuse > 1 else 0.15) < 0.07 else 0.0)
				node.scale = Vector3.ONE * pulse
			else:
				spark.light_energy = 0.0
		elif item.kind == "blaster":
			var players: Dictionary = world.players
			var facing: float = players[item.holder].facing if players.has(item.holder) else 1.0
			node.rotation.y = 0 if facing > 0 else PI
		# Blink before an unheld item disappears.
		node.visible = not (item.holder == "" and item.age > world.ITEM_LIFE - 3 and int(_time * 8) % 2 == 0 and item.kind != "ball")
	for id in item_nodes.keys():
		if not seen.has(id):
			item_nodes[id].queue_free()
			item_nodes.erase(id)

func _make_item(item: Dictionary) -> Node3D:
	var node := Node3D.new()
	add_child(node)
	match item.kind:
		"bomb":
			room.sphere(0.27, Vector3(0, 0.27, 0), room.mat(Color("1b1a26"), 0.25, 0.6), node)
			room.sphere(0.07, Vector3(0.1, 0.38, 0.2), room.mat(Color("6a6880"), 0.2, 0.3), node)
			room.cylinder(0.09, 0.12, Vector3(0, 0.56, 0), room.mat(Color("3a3848"), 0.4, 0.7), node)
			room.cylinder(0.015, 0.14, Vector3(0.03, 0.68, 0), room.mat(Color("c8a46a"), 0.8), node)
			var spark := OmniLight3D.new()
			spark.name = "spark"
			spark.light_color = Color("ffb454")
			spark.omni_range = 1.8
			spark.light_energy = 0
			spark.position = Vector3(0.05, 0.8, 0.1)
			node.add_child(spark)
			room.sphere(0.04, Vector3(0.05, 0.76, 0), room.mat(Color("ffd27a"), 0.2, 0, Color("ffb454"), 6.0), node)
		"blaster":
			var glow: Color = Color.from_hsv(fmod(item.id * 0.37, 1.0), 0.75, 1.0)
			room.box(Vector3(0.55, 0.18, 0.16), Vector3(0.12, 0.1, 0), room.mat(Color("e9e6f5"), 0.3), node)
			room.box(Vector3(0.12, 0.25, 0.12), Vector3(-0.08, -0.08, 0), room.mat(Color("2b2b3d"), 0.4), node)
			room.cylinder(0.07, 0.05, Vector3(0.42, 0.1, 0), room.mat(glow, 0.3, 0, glow, 4.0), node).rotation.z = PI / 2
			room.box(Vector3(0.4, 0.04, 0.17), Vector3(0.12, 0.17, 0), room.mat(glow, 0.3, 0, glow, 3.0), node)
		"hatbox":
			var c: Color = [Color("ff4f8b"), Color("38d6ff"), Color("3ddc97"), Color("ffb454")][item.id % 4]
			room.box(Vector3(0.5, 0.42, 0.42), Vector3(0, 0.21, 0), room.mat(c, 0.5), node)
			room.box(Vector3(0.54, 0.1, 0.46), Vector3(0, 0.44, 0), room.mat(c.darkened(0.15), 0.5), node)
			room.box(Vector3(0.08, 0.48, 0.44), Vector3(0, 0.24, 0), room.mat(Color("f2f1f8"), 0.4, 0, Color("ffffff"), 0.3), node)
			room.box(Vector3(0.52, 0.48, 0.08), Vector3(0, 0.24, 0), room.mat(Color("f2f1f8"), 0.4, 0, Color("ffffff"), 0.3), node)
			var question: Label3D = room.label("?", Vector3(0, 0.95, 0), 48, Color(2.2, 2.0, 0.8), node, 8)
			question.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		"ball":
			var ball := Node3D.new()
			ball.position = Vector3(0, 0.45, 0)
			node.add_child(ball)
			var m := StandardMaterial3D.new()
			var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
			var stripes := [Color("ff4f8b"), Color("f2f1f8"), Color("38d6ff"), Color("f2f1f8"), Color("ffb454"), Color("f2f1f8")]
			for y in 32:
				for x in 64: img.set_pixel(x, y, stripes[(x * 6 / 64) % 6])
			m.albedo_texture = ImageTexture.create_from_image(img)
			m.roughness = 0.35
			room.sphere(0.45, Vector3.ZERO, m, ball)
			node.set_meta("spinner", ball)
	return node

func _update_shots(world) -> void:
	while shot_nodes.size() < world.shots.size():
		var node := Node3D.new()
		add_child(node)
		var core: MeshInstance3D = room.sphere(0.09, Vector3.ZERO, room.mat(Color.WHITE, 0.2, 0, Color.WHITE, 8.0), node)
		core.name = "core"
		var light := OmniLight3D.new()
		light.name = "light"
		light.omni_range = 2.0
		light.light_energy = 2.0
		node.add_child(light)
		shot_nodes.append(node)
	for i in shot_nodes.size():
		var node: Node3D = shot_nodes[i]
		if i >= world.shots.size():
			node.visible = false
			continue
		var shot: Dictionary = world.shots[i]
		node.visible = true
		node.position = Vector3(shot.x, shot.y, 0.1)
		var c := Color.from_hsv(shot.hue, 0.8, 1.0)
		var core: MeshInstance3D = node.get_node("core")
		core.material_override.emission = c
		core.scale = Vector3(2.2, 0.8, 0.8)
		node.get_node("light").light_color = c

func _event(event: Dictionary, world) -> void:
	var pos := Vector3(event.get("x", 0.0), event.get("y", 0.0), 0.2)
	match event.type:
		"explode":
			room.flash(pos, Color("ffb454"), 16.0, 9.0)
			room.fireball(pos, Color("ff6a2a"), 1.4)
			room.fireball(pos, Color("ffd27a"), 0.7)
			room.shake(0.9)
			burst(pos, 60, [Color("ffd27a"), Color("ff7a3c"), Color("fff3c8")], 9.0, 0.7, 0.09)
			burst(pos, 26, [Color("4a4458"), Color("2b2838")], 3.0, 1.4, 0.22)
		"hit":
			burst(pos, 14, [Color("ffffff"), Color("ffe066")], 5.0, 0.35, 0.06)
			room.shake(0.25)
		"fire":
			room.flash(pos, Color.from_hsv(randf(), 0.7, 1.0), 2.5, 2.5)
		"hat":
			burst(pos + Vector3(0, 0.6, 0), 40, [Color("ff4f8b"), Color("38d6ff"), Color("3ddc97"), Color("ffb454"), Color("7c5cff")], 6.0, 1.2, 0.07, true)
			room.flash(pos, Color("ff4f8b"), 4.0, 3.0)
		"land":
			if event.get("speed", 0.0) > 14: burst(pos, 10, [Color("8c80b0")], 2.0, 0.4, 0.06)
		"walljump", "jump":
			burst(pos, 5, [Color("8c80b0")], 1.4, 0.3, 0.05)
		"spawn":
			burst(pos + Vector3(0, 0.6, 0), 24, [Color("7c5cff"), Color("ffb454"), Color("f2f1f8")], 3.5, 0.6, 0.06)
			room.flash(pos + Vector3(0, 0.6, 0), Color("7c5cff"), 5.0, 3.0)
		"drop":
			pass

## Short-lived particle burst. Confetti falls and flutters, sparks don't.
func burst(pos: Vector3, amount: int, colors: Array, speed: float, lifetime: float, size: float, confetti := false) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.emitting = true
	p.amount = amount
	p.lifetime = lifetime
	p.explosiveness = 0.95
	p.direction = Vector3(0, 1, 0)
	p.spread = 180
	p.initial_velocity_min = speed * 0.4
	p.initial_velocity_max = speed
	p.gravity = Vector3(0, -9 if confetti else -3, 0)
	p.damping_min = 1.0
	p.damping_max = 3.0
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.2
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray(colors.map(func(c): return Color(c.r * 2.2, c.g * 2.2, c.b * 2.2) if not confetti else c))
	gradient.offsets = PackedFloat32Array(range(colors.size()).map(func(i): return float(i) / maxf(1, colors.size() - 1)))
	p.color_initial_ramp = gradient
	var mesh := QuadMesh.new()
	mesh.size = Vector2(size, size * (0.6 if confetti else 1.0))
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED if not confetti else BaseMaterial3D.SHADING_MODE_PER_PIXEL
	m.vertex_color_use_as_albedo = true
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES if not confetti else BaseMaterial3D.BILLBOARD_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = m
	p.mesh = mesh
	if confetti:
		p.angular_velocity_min = -400
		p.angular_velocity_max = 400
		p.particle_flag_rotate_y = true
	p.position = pos
	add_child(p)
	get_tree().create_timer(lifetime + 0.3).timeout.connect(p.queue_free)
