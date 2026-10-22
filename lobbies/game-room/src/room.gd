extends Node3D
## The 3D game room: geometry, materials, lights and in-world screens.
## Built in code so layout constants stay the single source of truth.

const Layout = preload("res://src/layout.gd")
const Canvas = preload("res://src/canvas.gd")

const AMBER := Color("ffb454")
const VIOLET := Color("7c5cff")
const NIGHT_LILAC := Color("a78bfa")  # "Night" in the wordmark
const GREEN := Color("3ddc97")
const PINK := Color("ff4f8b")
const CYAN := Color("38d6ff")
const BG := Color("0b0b12")
const TEXT := Color("f2f1f8")

var _pads: Array = []
var _pad_activity := 0.0
var font: FontFile
var bold: FontFile
var wordmark: FontFile              # Bungee, the GameNight wordmark only
var _label_font: FontFile
var _label_bold: FontFile
var camera: Camera3D
var environment: Environment
var screens: Dictionary = {}       # name -> {viewport, canvas}
var _neon: Array = []              # [{material, base, phase, speed}]
var _strip_materials: Array = []
var _movers: Array = []            # moving-head spotlights
var _disco: Node3D
var _tv_light: OmniLight3D
var _flash_lights: Array = []
var _shake := 0.0
var _camera_base := Vector3(0, 4.7, 20.4)
var _camera_target := Vector3(0, 4.55, 0)
var _time := 0.0
var doors: Array = []              # profile door nodes, see set_doors
var featured_box: Node3D
var queue_preview: Node3D
var queue_titles: Node3D
var _queue_tween: Tween
const QUEUE_TITLE_ROWS := 4
const NEXT_SIZE := Vector2(2.7, 1.77)
const NEXT_POSITION := Vector3(-4.95, 2.38, Layout.BACK + 0.92)
const TITLES_POSITION := Vector3(-4.95, 0.8, Layout.BACK + 0.96)
var _prompts: Dictionary = {}       # floating button rows, see prompt()
var _bumper_presses: Dictionary = {}
var _spine_root: Node3D
var _eq_bars: Array = []
var music_playing := false
var mood := VIOLET                 # tinted by the next game's colour

func _ready() -> void:
	font = load_font()
	bold = load_font(800)
	wordmark = load_wordmark_font()
	_label_font = load_font(600, true)
	_label_bold = load_font(800, true)
	_environment()
	_camera()
	_shell()
	_window()
	_logo()
	_tv()
	_game_shelf()
	_up_next()
	_shelves()
	_couch_corner()
	_jukebox()
	_exit_door()
	prompt("music", [["LB", "Previous"], ["Y", "Pause"], ["RB", "Next"]], Vector3(Layout.JUKEBOX, 3.35, Layout.BACK + 1.2))
	prompt("exit", [["Y", "Leave"]], Vector3(Layout.EXIT_DOOR, 3.0, Layout.BACK + 0.4))
	for i in Layout.PROFILE_DOORS.size():
		prompt("door%d" % i, [["Y", "Pick up"]], Vector3(Layout.PROFILE_DOORS[i], 3.15, Layout.BACK + 0.4))
	_plaque()
	_ceiling_lights()
	_foreground()
	_string_lights()
	_dust()

# ---------------------------------------------------------------- helpers

## Fonts load straight from the files, so the project runs without an editor
## import step (.godot/ and *.import are ignored). Outfit is the GameNight UI
## face; Bungee is the GameNight wordmark, as in the app and on the website.
static func load_font(weight := 600, msdf := false) -> FontFile:
	var f := FontFile.new()
	f.load_dynamic_font("res://assets/fonts/outfit-%d.woff2" % weight)
	# MSDF keeps 3D labels sharp at any distance; 2D text draws at its real
	# pixel size, where plain hinted glyphs look cleaner.
	f.multichannel_signed_distance_field = msdf
	f.generate_mipmaps = msdf
	return f

static func load_wordmark_font() -> FontFile:
	var f := FontFile.new()
	f.load_dynamic_font("res://assets/fonts/bungee-regular.ttf")
	return f

func mat(color: Color, roughness := 0.7, metallic := 0.0, emission := Color.BLACK, energy := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	if energy > 0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = energy
	return m

func box(size: Vector3, pos: Vector3, material: Material, parent: Node = self, shadows := true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node

func cylinder(radius: float, height: float, pos: Vector3, material: Material, parent: Node = self) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	parent.add_child(node)
	return node

func sphere(radius: float, pos: Vector3, material: Material, parent: Node = self) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	parent.add_child(node)
	return node

func quad(size: Vector2, pos: Vector3, material: Material, parent: Node = self) -> MeshInstance3D:
	var mesh := QuadMesh.new()
	mesh.size = size
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(node)
	return node

## A glowing tube between two points on a plane facing the camera.
func neon_line(a: Vector3, b: Vector3, color: Color, energy := 5.0, thickness := 0.07, flicker := 0.0) -> MeshInstance3D:
	var length := a.distance_to(b)
	var m := mat(color, 0.3, 0, color, energy)
	var node := box(Vector3(length + thickness, thickness, thickness), (a + b) / 2, m, self, false)
	node.rotation.z = atan2(b.y - a.y, b.x - a.x)
	_neon.append({"material": m, "base": energy, "phase": randf() * TAU, "speed": flicker})
	return node

func label(text: String, pos: Vector3, size: int, color: Color, parent: Node = self, outline := 0) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = _label_bold if size >= 32 else _label_font
	l.font_size = size
	l.pixel_size = 0.01
	l.modulate = color
	l.outline_size = outline
	l.outline_modulate = Color(0, 0, 0, 0.8)
	l.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	l.position = pos
	l.shaded = false
	parent.add_child(l)
	return l

func screen(name: String, size: Vector2i, painter: Callable) -> ViewportTexture:
	var viewport := SubViewport.new()
	viewport.size = size
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	var canvas := Canvas.new()
	canvas.painter = painter
	canvas.size = size
	viewport.add_child(canvas)
	add_child(viewport)
	screens[name] = {"viewport": viewport, "canvas": canvas}
	return viewport.get_texture()

func redraw(name: String) -> void:
	if screens.has(name): screens[name].canvas.queue_redraw()

func screen_material(texture: Texture2D, energy := 1.6) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = texture
	m.albedo_color = Color(energy, energy, energy)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return m

# ---------------------------------------------------------------- environment

func _environment() -> void:
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("06060b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("3b3170")
	environment.ambient_light_energy = 1.3
	# Indirect light: the neon, screens and spots bounce off walls and floor,
	# so the room reads as a dim lived-in space instead of black.
	environment.sdfgi_enabled = true
	environment.sdfgi_use_occlusion = true
	environment.sdfgi_energy = 1.6
	environment.sdfgi_bounce_feedback = 0.6
	environment.sdfgi_cascades = 4
	environment.sdfgi_min_cell_size = 0.1
	environment.ssil_enabled = true
	environment.ssil_intensity = 1.4
	environment.ssil_radius = 4.0
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 1.05
	environment.glow_enabled = true
	environment.glow_intensity = 0.7
	environment.glow_strength = 1.05
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 0.9
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	for level in 7: environment.set_glow_level(level, level in [2, 3, 4, 5])
	environment.set_glow_level(2, true)
	environment.volumetric_fog_enabled = true
	environment.volumetric_fog_density = 0.04
	environment.volumetric_fog_albedo = Color("b8a8ff")
	environment.volumetric_fog_emission = Color("0a0718")
	environment.volumetric_fog_emission_energy = 0.15
	environment.volumetric_fog_length = 40.0
	environment.volumetric_fog_anisotropy = 0.5
	environment.ssr_enabled = true
	environment.ssr_max_steps = 48
	environment.ssao_enabled = true
	environment.ssao_intensity = 1.6
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.12
	environment.adjustment_contrast = 1.06
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)

func _camera() -> void:
	camera = Camera3D.new()
	camera.fov = 36
	camera.position = _camera_base
	add_child(camera)
	camera.look_at(_camera_target)
	# Only the foreground props blur, like a tilt-shift lens. The play plane
	# and the wall with the QR code stay sharp.
	var attributes := CameraAttributesPractical.new()
	attributes.dof_blur_near_enabled = true
	attributes.dof_blur_near_distance = 17.0
	attributes.dof_blur_near_transition = 2.0
	attributes.dof_blur_amount = 0.06
	camera.attributes = attributes

# ---------------------------------------------------------------- room shell

func _plank_texture() -> ImageTexture:
	var img := Image.create(512, 512, true, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var rows := 8
	for row in rows:
		var y0 := row * 512 / rows
		var offset := rng.randi_range(0, 400)
		var seams := [offset % 512, (offset + 256) % 512]
		for x in 512:
			var plank := 0 if absi(x - seams[0]) < absi(x - seams[1]) else 1
			var base := Color("5a3826").lerp(Color("7a4e32"), rng.randf() * 0.15 + plank * 0.25)
			for y in range(y0, y0 + 512 / rows):
				var grain := sin(x * 0.07 + y * 0.9 + row) * 0.03 + sin(x * 0.013 + row * 3.0) * 0.04
				var c := base.lightened(grain) if grain > 0 else base.darkened(-grain)
				if y == y0 or x in seams: c = Color("24150e")
				img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _wallpaper_texture() -> ImageTexture:
	var img := Image.create(256, 256, true, Image.FORMAT_RGBA8)
	for y in 256:
		for x in 256:
			var stripe := (x / 32) % 2 == 0
			var c := Color("2b2552") if stripe else Color("251f49")
			# Small diamond pattern, like a retro arcade carpet on the wall.
			var dx := absi((x % 32) - 16)
			var dy := absi((y % 32) - 16)
			if dx + dy == 9: c = Color("372e66")
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _shell() -> void:
	var floor_mat := mat(Color.WHITE, 0.32, 0.0)
	floor_mat.albedo_texture = _plank_texture()
	floor_mat.uv1_scale = Vector3(5, 2.4, 1)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(26, 9.6)
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.material_override = floor_mat
	floor_node.position = Vector3(0, 0, Layout.BACK + 4.8)
	add_child(floor_node)
	# Back wall with wallpaper and wainscot.
	var wall_mat := mat(Color.WHITE, 0.9)
	wall_mat.albedo_texture = _wallpaper_texture()
	wall_mat.uv1_scale = Vector3(12, 5.4, 1)
	quad(Vector2(26, 11.2), Vector3(0, 5.6, Layout.BACK), wall_mat)
	box(Vector3(26, 1.2, 0.08), Vector3(0, 0.6, Layout.BACK + 0.04), mat(Color("2c2140"), 0.6))
	box(Vector3(26, 0.06, 0.12), Vector3(0, 1.22, Layout.BACK + 0.06), mat(Color("392a52"), 0.5))
	# Side walls, slightly warmer, so the perspective reads.
	var side := mat(Color("1a1530"), 0.85)
	side.albedo_texture = wall_mat.albedo_texture
	side.uv1_scale = Vector3(5, 5.4, 1)
	for s in [-1, 1]:
		var wall := quad(Vector2(10, 11.2), Vector3(s * 12.0, 5.6, Layout.BACK + 5), side)
		wall.rotation.y = -s * PI / 2
	# Ceiling with beams.
	var ceiling := quad(Vector2(26, 10), Vector3(0, 10.9, Layout.BACK + 5), mat(Color("0f0c1e"), 0.9))
	ceiling.rotation.x = PI / 2
	for i in 6:
		box(Vector3(26, 0.35, 0.4), Vector3(0, 10.7, Layout.BACK + 0.6 + i * 1.8), mat(Color("1c1530"), 0.8))

## Everything you can stand on gets the same light oak lip along its front
## top edge, and nothing else in the room has one.
func platform_edge(x0: float, x1: float, top: float, z_front: float) -> void:
	var lip := mat(Color("e2bd88"), 0.45, 0.0, Color("ffd9a0"), 0.25)
	box(Vector3(x1 - x0, 0.045, 0.06), Vector3((x0 + x1) / 2, top - 0.0225, z_front), lip, self, false)

func _strip(pos: Vector3, length: float) -> void:
	var m := mat(VIOLET, 0.4, 0, VIOLET, 4.0)
	box(Vector3(length, 0.05, 0.05), pos, m, self, false)
	_strip_materials.append(m)

# ---------------------------------------------------------------- set pieces

func _window() -> void:
	# A night city behind glass, with moonlight pouring in through the fog.
	var center := Vector3(-8.5, 7.0, Layout.BACK + 0.02)
	var size := Vector2(2.2, 3.0)
	var sky := Image.create(110, 150, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for y in 150:
		var c := Color("1a1240").lerp(Color("4a2a6e"), y / 150.0)
		for x in 110: sky.set_pixel(x, y, c)
	for i in 40:
		sky.set_pixel(rng.randi_range(0, 109), rng.randi_range(0, 70), Color(1, 1, 1, 1))
	for y in range(18, 34):
		for x in range(68, 84):
			if Vector2(x - 76, y - 26).length() < 7.5: sky.set_pixel(x, y, Color("fff3c8"))
	var x := 0
	while x < 110:
		var w := rng.randi_range(8, 18)
		var h := rng.randi_range(40, 95)
		var tone := Color("0d0a1f").lerp(Color("1d1638"), rng.randf())
		for bx in range(x, mini(110, x + w)):
			for by in range(150 - h, 150): sky.set_pixel(bx, by, tone)
		for wy in range(150 - h + 4, 148, 6):
			for wx in range(x + 2, mini(110, x + w) - 1, 4):
				if rng.randf() < 0.35:
					sky.set_pixel(wx, wy, Color("ffd27a") if rng.randf() < 0.7 else Color("8cf2ff"))
		x += w + rng.randi_range(0, 3)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = ImageTexture.create_from_image(sky)
	m.albedo_color = Color(1.25, 1.25, 1.35)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	quad(size, center, m)
	var frame := mat(Color("2d2140"), 0.6)
	box(Vector3(size.x + 0.3, 0.16, 0.2), center + Vector3(0, size.y / 2 + 0.08, 0.05), frame)
	box(Vector3(size.x + 0.3, 0.2, 0.3), center + Vector3(0, -size.y / 2 - 0.1, 0.1), frame)
	for s in [-1, 0, 1]:
		box(Vector3(0.1 if s == 0 else 0.16, size.y, 0.14), center + Vector3(s * (size.x / 2 + 0.07) * absf(s), 0, 0.05), frame)
	box(Vector3(size.x, 0.08, 0.1), center + Vector3(0, 0.3, 0.04), frame)
	var moon := SpotLight3D.new()
	moon.light_color = Color("9fb4ff")
	moon.light_energy = 6.0
	moon.light_volumetric_fog_energy = 3.0
	moon.spot_range = 22
	moon.spot_angle = 22
	moon.shadow_enabled = true
	moon.position = center + Vector3(0.6, 0.6, -0.5)
	add_child(moon)
	moon.look_at(Vector3(-4.0, 0, 2.5))

func _logo() -> void:
	# The GameNight wordmark as a real neon sign, in the app's two colours:
	# the text is rendered once into a transparent texture and used as
	# emission, so glow picks it up.
	var y := 8.0
	var z := Layout.BACK + 0.12
	var sign_texture := screen("logo", Vector2i(1280, 320), func(canvas: Control):
		var words := [["Game", AMBER], ["Night", NIGHT_LILAC]]
		var size := 180
		var widths := words.map(func(w): return wordmark.get_string_size(w[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
		var total: float = widths[0] + widths[1]
		if total > 1200:
			size = int(size * 1200 / total)
			widths = words.map(func(w): return wordmark.get_string_size(w[0], HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
			total = widths[0] + widths[1]
		var sub := "COUCH MULTIPLAYER CLUB"
		# Soft halo first, then the tube itself, per word in its own colour.
		var x := (1280 - total) / 2
		for i in words.size():
			var at := Vector2(x, 196)
			var color: Color = words[i][1]
			for k in [30, 18, 10]:
				canvas.draw_string_outline(wordmark, at, words[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, k, Color(color, 0.2))
			canvas.draw_string_outline(wordmark, at, words[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, color.lightened(0.2))
			canvas.draw_string(wordmark, at, words[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
			x += widths[i]
		for k in [16, 9, 5]:
			canvas.draw_string_outline(font, Vector2(0, 286), sub, HORIZONTAL_ALIGNMENT_CENTER, 1280, 46, k, Color(VIOLET, 0.15))
		canvas.draw_string(font, Vector2(0, 286), sub, HORIZONTAL_ALIGNMENT_CENTER, 1280, 46, Color("d9d0ff")))
	screens.logo.viewport.transparent_bg = true
	screens.logo.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = sign_texture
	m.albedo_color = Color(0.3, 0.3, 0.3)
	m.emission_enabled = true
	m.emission_texture = sign_texture
	# Bright enough to glow, low enough that the two colours stay apart.
	m.emission_energy_multiplier = 3.2
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	quad(Vector2(10.4, 2.6), Vector3(0, y - 0.3, z), m)
	_neon.append({"material": m, "base": 3.2, "phase": 0.0, "speed": 0.0, "flicker": true})
	var lamp := OmniLight3D.new()
	lamp.light_color = AMBER
	lamp.light_energy = 2.2
	lamp.omni_range = 6.5
	lamp.position = Vector3(0, y, z + 1.0)
	add_child(lamp)

func _tv() -> void:
	var c := Layout.TV_CENTER
	var s := Layout.TV_SIZE
	box(Vector3(s.x + 0.36, s.y + 0.36, 0.22), c + Vector3(0, 0, -0.08), mat(Color("0e0d16"), 0.35, 0.4))
	var texture := screen("tv", Vector2i(896, 504), func(_canvas): pass)
	quad(s, c + Vector3(0, 0, 0.05), screen_material(texture, 1.35))
	# TV console with game boxes; its top is a platform.
	box(Vector3(6.6, 0.85, 0.9), Vector3(0, 0.43, Layout.BACK + 0.5), mat(Color("231a2e"), 0.5))
	box(Vector3(6.6, 0.05, 0.92), Vector3(0, 0.87, Layout.BACK + 0.5), mat(Color("3b2c4a"), 0.3))
	platform_edge(-3.3, 3.3, 0.9, Layout.BACK + 0.96)
	var cases := [VIOLET, GREEN, AMBER, PINK, CYAN, Color("f5e663")]
	for i in cases.size():
		box(Vector3(0.12, 0.62, 0.45), Vector3(-2.9 + i * 0.15, 1.2, Layout.BACK + 0.45), mat(cases[i].darkened(0.3), 0.5))
	box(Vector3(0.9, 0.18, 0.5), Vector3(2.45, 0.98, Layout.BACK + 0.45), mat(Color("e9e6f5"), 0.3))
	box(Vector3(0.3, 0.04, 0.02), Vector3(2.45, 0.98, Layout.BACK + 0.71), mat(GREEN, 0.3, 0, GREEN, 4.0), self, false)
	# A floating button over the console says the TV is something to use.
	prompt("tv", [["Y", "Start"]], Vector3(0, 5.9, Layout.BACK + 0.3))
	_tv_light = OmniLight3D.new()
	_tv_light.light_color = VIOLET
	_tv_light.light_energy = 3.0
	_tv_light.omni_range = 10
	_tv_light.light_volumetric_fog_energy = 0.6
	_tv_light.position = c + Vector3(0, -0.4, 1.6)
	add_child(_tv_light)
	# Speakers either side, sitting on floating shelves.
	for s2 in [-1, 1]:
		var x: float = s2 * 4.2
		box(Vector3(1.0, 0.1, 0.6), Vector3(x, 3.55, Layout.BACK + 0.3), mat(Color("5b3b2a"), 0.55))
		platform_edge(x - 0.5, x + 0.5, 3.6, Layout.BACK + 0.61)
		var body := box(Vector3(0.8, 1.3, 0.55), Vector3(x, 2.85, Layout.BACK + 0.32), mat(Color("4a3a5e"), 0.45))
		cylinder(0.3, 0.04, Vector3(x, 2.65, Layout.BACK + 0.61), mat(Color("1a1622"), 0.3, 0.6)).rotation.x = PI / 2
		cylinder(0.12, 0.04, Vector3(x, 3.22, Layout.BACK + 0.61), mat(Color("1a1622"), 0.3, 0.6)).rotation.x = PI / 2
		body.name = "speaker"

func _game_shelf() -> void:
	# Game spines in the cupboard, with a selected cover on top while browsing.
	var wood := mat(Color("5b3b2a"), 0.55)
	var dark := mat(Color("3a261c"), 0.6)
	var z := Layout.BACK + 0.4
	var bx := (Layout.BOOKCASE.x + Layout.BOOKCASE.y) / 2
	var bw := Layout.BOOKCASE.y - Layout.BOOKCASE.x
	box(Vector3(bw, 2.65, 0.06), Vector3(bx, 1.325, z - 0.3), dark)
	for side in [-1, 1]:
		box(Vector3(0.08, 2.65, 0.66), Vector3(bx + side * (bw / 2 - 0.04), 1.325, z), wood)
	for y in Layout.SPINE_ROWS + [1.79, 2.65]:
		box(Vector3(bw, 0.07, 0.66), Vector3(bx, y - 0.035, z), wood)
	platform_edge(Layout.BOOKCASE.x, Layout.BOOKCASE.y, 2.65, z + 0.34)
	# Top compartment: a retro console and a plant, so the case never looks empty.
	box(Vector3(0.6, 0.14, 0.4), Vector3(bx - 0.25, 1.86, z), mat(Color("c9c4d8"), 0.4, 0.2))
	box(Vector3(0.12, 0.02, 0.02), Vector3(bx - 0.4, 1.9, z + 0.21), mat(PINK, 0.3, 0, PINK, 3.0), self, false)
	box(Vector3(0.22, 0.06, 0.14), Vector3(bx - 0.25, 1.96, z + 0.1), mat(Color("2a2838"), 0.5))
	cylinder(0.13, 0.22, Vector3(bx + 0.4, 1.9, z), mat(Color("c46c4a"), 0.8))
	sphere(0.22, Vector3(bx + 0.4, 2.15, z), mat(Color("2f8f5a"), 0.9))
	_spine_root = Node3D.new()
	add_child(_spine_root)
	# Display stand: low cabinet, the featured box on an easel, a spot on it.
	var dx := (Layout.DISPLAY.x + Layout.DISPLAY.y) / 2
	var dw := Layout.DISPLAY.y - Layout.DISPLAY.x
	box(Vector3(dw, 0.78, 0.8), Vector3(dx, 0.39, z + 0.05), wood)
	box(Vector3(dw - 0.14, 0.5, 0.02), Vector3(dx, 0.39, z + 0.46), mat(Color("24170f"), 0.5))
	box(Vector3(dw + 0.05, 0.05, 0.85), Vector3(dx, 0.8, z + 0.05), dark)
	platform_edge(Layout.DISPLAY.x, Layout.DISPLAY.y, 0.83, z + 0.48)
	var front_texture := screen("box_front", Vector2i(300, 420), func(_canvas): pass)
	featured_box = game_box(Vector2(1.25, 1.75), Vector3(bx, 3.56, z + 0.1), front_texture)
	featured_box.visible = false
	featured_box.rotation.x = -0.06
	for side in [-1, 1]:
		# Xbox-style bumper buttons, drawn smooth like the Y badge in the hints.
		var key := "LB" if side < 0 else "RB"
		var texture := screen("bumper_" + key, Vector2i(400, 200), func(canvas: Control):
			draw_bumper(canvas, Rect2(60 if side < 0 else 20, 36, 320, 128), key, bold, side, _bumper_presses.get(key, 0.0)))
		screens["bumper_" + key].viewport.transparent_bg = true
		screens["bumper_" + key].viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		var m := screen_material(texture, 1.6)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.disable_fog = true
		var button := quad(Vector2(0.7, 0.35), Vector3(bx + side * 0.98, 3.56, z + 0.3), m)
		button.name = "shelf_lb" if side < 0 else "shelf_rb"
		button.visible = false
	prompt("shelf", [["Y", "Set up next"], ["X", "Queue"]], Vector3(bx, 5.0, z + 0.3))
	var spot := SpotLight3D.new()
	spot.light_color = Color("ffd7a0")
	spot.light_energy = 9.0
	spot.spot_range = 5.0
	spot.spot_angle = 22
	spot.light_volumetric_fog_energy = 0.6
	spot.position = Vector3(bx, 5.4, z + 1.6)
	add_child(spot)
	spot.look_at(Vector3(bx, 3.56, z), Vector3.UP)
	var glow := OmniLight3D.new()
	glow.light_color = Color("b9a6ff")
	glow.light_energy = 3.0
	glow.omni_range = 3.2
	glow.position = Vector3(bx, 1.4, z + 1.0)
	add_child(glow)

## An Xbox-style bumper: dark rounded shape with a soft rim and the label in
## white, plus a small chevron pointing the way it browses (-1 left, 1 right,
## 0 none). Shared by the shelf stand and the HUD hints.
static func draw_bumper(canvas: CanvasItem, rect: Rect2, text: String, f: Font, direction := 0, pressed := 0.0) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color("30303f").darkened(pressed * .3)
	rect.position.y += pressed * 6.0
	box.border_color = Color("b4b2c8")
	box.set_border_width_all(maxi(1, int(rect.size.y * 0.05)))
	var r := int(rect.size.y * 0.5)
	box.corner_radius_top_left = r if text.begins_with("L") else int(r * 0.45)
	box.corner_radius_top_right = r if text.begins_with("R") else int(r * 0.45)
	box.corner_radius_bottom_left = int(r * 0.45)
	box.corner_radius_bottom_right = int(r * 0.45)
	box.anti_aliasing = true
	canvas.draw_style_box(box, rect)
	var size := int(rect.size.y * 0.58)
	canvas.draw_string(f, Vector2(rect.position.x, rect.get_center().y + size * 0.36), text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, size, Color("f2f1f8"))
	if direction != 0:
		var tip := Vector2(rect.position.x - rect.size.y * 0.32 if direction < 0 else rect.end.x + rect.size.y * 0.32, rect.get_center().y)
		var back := tip.x - direction * rect.size.y * 0.24
		var half := rect.size.y * 0.2
		canvas.draw_colored_polygon(PackedVector2Array([tip, Vector2(back, tip.y - half), Vector2(back, tip.y + half)]), Color("f2f1f8"))

## A game box like a DVD case: dark plastic shell with the cover in front.
func game_box(size: Vector2, pos: Vector3, cover: Texture2D, parent: Node = self) -> Node3D:
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	box(Vector3(size.x + 0.05, size.y + 0.05, 0.1), Vector3.ZERO, mat(Color("12141f"), 0.35, 0.2), root)
	box(Vector3(0.05, size.y + 0.05, 0.11), Vector3(-size.x / 2 - 0.0, 0, 0), mat(Color("23263a"), 0.3, 0.3), root, false)
	var face := mat(Color.WHITE, 0.85)
	face.albedo_texture = cover
	face.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# Printed artwork belongs to the room: receive its light and fog, unlike the TV.
	quad(size, Vector3(0, 0, 0.051), face, root)
	return root

## Rebuilds the spines: games is [{title, color}].
func set_shelf(games: Array, selected: int) -> void:
	for child in _spine_root.get_children(): child.queue_free()
	var bw := Layout.BOOKCASE.y - Layout.BOOKCASE.x - 0.24
	var per_row := int(bw / 0.22)
	var slots := per_row * Layout.SPINE_ROWS.size()
	# With more games than slots, show the window around the selection.
	var first := 0
	if games.size() > slots: first = clampi(selected - slots / 2, 0, games.size() - slots)
	for n in mini(games.size(), slots):
		var i := first + n
		var row: float = Layout.SPINE_ROWS[n / per_row]
		var x := Layout.BOOKCASE.x + 0.23 + (n % per_row) * 0.22
		var color := Color.from_string(str(games[i].get("color", "")), VIOLET)
		var height := 0.7
		box(Vector3(0.2, height, 0.5), Vector3(x, row + height / 2, Layout.BACK + 0.4), mat(color.darkened(0.25), 0.45, 0.1), _spine_root)
		box(Vector3(0.205, 0.08, 0.505), Vector3(x, row + height - 0.06, Layout.BACK + 0.4), mat(Color("12141f"), 0.35), _spine_root, false)
		var title := label(str(games[i].get("title", "")).to_upper(), Vector3(x, row + height / 2 - 0.04, Layout.BACK + 0.66), 16, Color(1.4, 1.4, 1.5), _spine_root, 4)
		title.rotation.z = PI / 2
		title.pixel_size = 0.01
		var width := font.get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x * 0.01
		if width > 0.58: title.pixel_size *= 0.58 / width

## Little hop of the featured box when browsing.
func pop_box(step: int) -> void:
	if featured_box == null: return
	var tween := create_tween()
	featured_box.rotation.y = -0.6 * step
	featured_box.scale = Vector3.ONE * 0.9
	tween.set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(featured_box, "rotation:y", 0.0, 0.35)
	tween.tween_property(featured_box, "scale", Vector3.ONE, 0.35)

## One substantial preview for the next game; every later entry is text only.
func _up_next() -> void:
	var z := Layout.BACK + 0.5
	var frame := mat(Color("211d32"), 0.5)
	box(Vector3(2.88, 1.38, 0.65), Vector3(-4.95, 0.72, z), frame)
	box(Vector3(2.88, 1.94, 0.16), NEXT_POSITION - Vector3(0, 0, 0.1), frame)
	prompt("queue", [["Y", "Play next"], ["X", "Skip next"]], Vector3(-4.95, 3.5, z + 0.3))
	var texture := screen("queue0", Vector2i(640, 420), func(_canvas): pass)
	queue_preview = quad(NEXT_SIZE, NEXT_POSITION, screen_material(texture, 1.05))
	var titles := screen("queue_titles", Vector2i(640, 300), func(_canvas): pass)
	queue_titles = quad(Vector2(2.7, 1.27), TITLES_POSITION, screen_material(titles, 1.05))
	neon_line(NEXT_POSITION + Vector3(-1.35, 0.92, 0.02), NEXT_POSITION + Vector3(1.35, 0.92, 0.02), GREEN, 1.5, 0.025)

## Both surfaces move gently as the queue changes; later entries never become
## cover objects or fly across the room. Cancel a previous transition first.
func animate_queue(next_changed: bool, advance: bool) -> void:
	if _queue_tween != null: _queue_tween.kill()
	queue_preview.position = NEXT_POSITION
	queue_preview.scale = Vector3.ONE * (0.97 if next_changed else 1.0)
	queue_titles.position = TITLES_POSITION + Vector3(0, -0.10 if advance else 0.10, 0)
	_queue_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_queue_tween.tween_property(queue_preview, "scale", Vector3.ONE, 0.32)
	_queue_tween.tween_property(queue_titles, "position", TITLES_POSITION, 0.32)

## A floating row of controller buttons over a station, e.g. [["Y", "Play next"]].
## Hidden until someone is in interaction range.
func prompt(name: String, items: Array, pos: Vector3) -> void:
	var state := {"items": items, "enabled": true}
	var px := _prompt_size(items)
	var texture := screen("prompt_" + name, px, func(canvas: Control): draw_prompt(canvas, state, bold))
	screens["prompt_" + name].viewport.transparent_bg = true
	var m := screen_material(texture, 1.0)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.disable_fog = true
	var node := quad(Vector2(px.x, px.y) * 0.0042, pos, m)
	node.name = "prompt_" + name
	node.visible = false
	_prompts[name] = {"node": node, "material": m, "base": pos, "state": state, "active": false}

func _prompt_size(items: Array) -> Vector2i:
	var width := 40.0
	for item in items:
		width += (150 if str(item[0]) in ["LB", "RB"] else 96) + bold.get_string_size(str(item[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x + 36
	return Vector2i(ceili(width), 96)

func set_prompt(name: String, items: Array, enabled: bool, active: bool) -> void:
	var p: Dictionary = _prompts.get(name, {})
	if p.is_empty(): return
	p.active = active
	p.node.visible = active
	if JSON.stringify(p.state.items) != JSON.stringify(items) or p.state.enabled != enabled:
		p.state.items = items
		p.state.enabled = enabled
		var px := _prompt_size(items)
		screens["prompt_" + name].viewport.size = px
		screens["prompt_" + name].canvas.size = px
		p.node.mesh.size = Vector2(px) * 0.0042
		redraw("prompt_" + name)

## How far a held button has charged, 0 to 1; 0 clears the ring.
func hold_prompt(name: String, key: String, amount: float) -> void:
	if not _prompts.has(name): return
	var state: Dictionary = _prompts[name].state
	var current: float = state.get("hold", {}).get(key, 0.0)
	if is_equal_approx(current, amount): return
	state["hold"] = {key: amount} if amount > 0.0 else {}
	redraw("prompt_" + name)

func press_prompt(name: String, key: String) -> void:
	if _prompts.has(name):
		_prompts[name].state["pressed"] = {key: 1.0}
		redraw("prompt_" + name)
	if name == "shelf" and key in ["LB", "RB"]:
		_bumper_presses[key] = 1.0
		redraw("bumper_" + key)

## Xbox face buttons in their colours, each followed by what it does.
## `base` places the whole prompt (the HUD scales it to an object on screen);
## the badge press animation composes with it instead of replacing it.
static func draw_prompt(canvas: CanvasItem, state: Dictionary, f: Font, base := Transform2D.IDENTITY) -> void:
	canvas.draw_set_transform_matrix(base)
	var colors := {"A": Color("5cb85c"), "B": Color("e2574c"), "X": Color("3b8eea"), "Y": Color("f8cd34")}
	var h := 96.0
	var x := 20.0
	for item in state.items:
		var key := str(item[0])
		var text := str(item[1])
		var bumper := key in ["LB", "RB"]
		var badge_width := 150.0 if bumper else 96.0
		var tw := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 44).x
		var pill := StyleBoxFlat.new()
		pill.bg_color = Color(0.03, 0.03, 0.06, 0.82)
		pill.set_corner_radius_all(int(h / 2) - 6)
		pill.anti_aliasing = true
		canvas.draw_style_box(pill, Rect2(x, 6, badge_width + tw + 16, h - 12))
		var color: Color = colors.get(key, Color("f2f1f8")) if state.enabled else Color("55516a")
		var pressed: float = state.get("pressed", {}).get(key, 0.0)
		if bumper:
			draw_bumper(canvas, Rect2(x + 12, 18, 122, 60), key, f, 0, pressed)
		else:
			var center := Vector2(x + h / 2 - 4, h / 2)
			# Depress the physical badge, keeping the label and pill stationary.
			# A stronger travel + compressed face remains readable across the room.
			canvas.draw_circle(center, h / 2 - 13, color.darkened(.65))
			# A ring fills around the badge while a hold action charges.
			var hold: float = state.get("hold", {}).get(key, 0.0)
			if hold > 0.0:
				canvas.draw_arc(center, h / 2 - 4, -PI / 2, -PI / 2 + TAU * hold, 48, color.lightened(0.3), 7.0, true)
			canvas.draw_set_transform_matrix(base * Transform2D(0, Vector2(1.0, 1.0 - pressed * .18), 0, center + Vector2(0, pressed * 10)))
			canvas.draw_circle(Vector2.ZERO, h / 2 - 14, color.darkened(pressed * .12))
			canvas.draw_set_transform_matrix(base)
			canvas.draw_string(f, Vector2(x + 10, h / 2 + 17 + pressed * 10), key, HORIZONTAL_ALIGNMENT_CENTER, h - 28, 48, Color("0b0b12"))
		canvas.draw_string(f, Vector2(x + badge_width - 6, h / 2 + 16), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 44, Color("f2f1f8") if state.enabled else Color("9a98ad"))
		x += badge_width + tw + 36

func _shelves() -> void:
	var wood := mat(Color("5b3b2a"), 0.55)
	var defs := [[-11.6, -8.6, 4.7], [-7.4, -5.2, 5.9], [-2.6, 2.6, 6.55], [5.2, 7.7, 4.3],
		[-11.6, -9.6, 7.3], [-6.4, -4.4, 8.2], [-1.2, 1.2, 9.2], [4.4, 6.4, 8.2], [9.0, 11.6, 6.6]]
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for d in defs:
		var bare: bool = d[2] == 6.55  # the TV shelf stays clear for the neon sign
		var x0: float = maxf(d[0], -11.95)
		var x1: float = minf(d[1], 11.95)
		var w := x1 - x0
		var cx := (x0 + x1) / 2
		box(Vector3(w, 0.12, 0.7), Vector3(cx, d[2] - 0.06, Layout.BACK + 0.35), wood)
		platform_edge(x0, x1, d[2], Layout.BACK + 0.71)
		# Props: books, a plant or a trophy, kept to the back of the shelf.
		var x := x0 + 0.25
		while x < x1 - 0.4 and not bare:
			var roll := rng.randf()
			if roll < 0.45:
				for b in rng.randi_range(2, 5):
					var h := rng.randf_range(0.35, 0.55)
					var bc := Color.from_hsv(rng.randf(), 0.55, 0.55)
					box(Vector3(0.09, h, 0.38), Vector3(x, d[2] + h / 2, Layout.BACK + 0.25), mat(bc, 0.7))
					x += 0.1
				x += 0.25
			elif roll < 0.65:
				cylinder(0.15, 0.25, Vector3(x + 0.1, d[2] + 0.125, Layout.BACK + 0.3), mat(Color("c46c4a"), 0.8))
				sphere(0.26, Vector3(x + 0.1, d[2] + 0.42, Layout.BACK + 0.3), mat(Color("2f8f5a"), 0.9))
				x += 0.6
			elif roll < 0.8:
				var gold := mat(Color("ffcf5a"), 0.25, 0.9)
				cylinder(0.12, 0.08, Vector3(x + 0.1, d[2] + 0.04, Layout.BACK + 0.3), gold)
				cylinder(0.03, 0.2, Vector3(x + 0.1, d[2] + 0.18, Layout.BACK + 0.3), gold)
				sphere(0.13, Vector3(x + 0.1, d[2] + 0.38, Layout.BACK + 0.3), gold)
				x += 0.5
			else:
				x += 0.45

func _couch_corner() -> void:
	var fabric := mat(Color("4a3290"), 0.95)
	var dark := mat(Color("35246b"), 0.95)
	var z := Layout.BACK + 0.75
	box(Vector3(3.3, 0.55, 1.2), Vector3(6.45, 0.45, z + 0.1), fabric)
	box(Vector3(3.3, 0.9, 0.4), Vector3(6.45, 1.1, z - 0.4), dark)
	for s in [-1, 1]:
		box(Vector3(0.35, 0.95, 1.2), Vector3(6.45 + s * 1.75, 0.5, z + 0.1), dark)
	for i in 3:
		box(Vector3(1.02, 0.18, 1.0), Vector3(5.4 + i * 1.05, 0.8, z + 0.15), fabric)
	box(Vector3(0.5, 0.42, 0.18), Vector3(5.2, 1.08, z - 0.12), mat(AMBER, 0.9)).rotation.z = 0.25
	box(Vector3(0.5, 0.42, 0.18), Vector3(7.7, 1.08, z - 0.12), mat(GREEN.darkened(0.2), 0.9)).rotation.z = -0.2
	# Floor lamp: warm light, a nice contrast to the neon.
	var lamp_x := 4.5  # between jukebox and couch, clear of the doors
	cylinder(0.025, 2.6, Vector3(lamp_x, 1.3, Layout.BACK + 0.5), mat(Color("c8a46a"), 0.3, 0.8))
	cylinder(0.2, 0.04, Vector3(lamp_x, 0.02, Layout.BACK + 0.5), mat(Color("c8a46a"), 0.3, 0.8))
	var shade := CylinderMesh.new()
	shade.top_radius = 0.22
	shade.bottom_radius = 0.38
	shade.height = 0.45
	var shade_node := MeshInstance3D.new()
	shade_node.mesh = shade
	shade_node.material_override = mat(Color("ffd9a0"), 0.8, 0, Color("ffb454"), 1.6)
	shade_node.position = Vector3(lamp_x, 2.65, Layout.BACK + 0.5)
	add_child(shade_node)
	var warm := OmniLight3D.new()
	warm.light_color = Color("ffb36b")
	warm.light_energy = 2.4
	warm.omni_range = 5.5
	warm.shadow_enabled = true
	warm.position = Vector3(lamp_x, 2.4, Layout.BACK + 0.9)
	add_child(warm)

func _jukebox() -> void:
	# A proper jukebox: arched cabinet, now-playing screen, bubbling tubes
	# that dance while music plays, and three buttons on the front.
	var x := Layout.JUKEBOX
	var z := Layout.BACK + 0.55
	var wood := mat(Color("5a2438"), 0.35, 0.1)
	box(Vector3(1.7, 2.1, 0.9), Vector3(x, 1.05, z), wood)
	var arch := cylinder(0.85, 0.9, Vector3(x, 2.1, z), wood)
	arch.rotation.x = PI / 2
	var chrome := mat(Color("d8d4e8"), 0.15, 0.9)
	var rim := cylinder(0.88, 0.06, Vector3(x, 2.1, z + 0.44), chrome)
	rim.rotation.x = PI / 2
	var dome := cylinder(0.74, 0.04, Vector3(x, 2.1, z + 0.47), mat(Color("ffcf8a"), 0.2, 0, AMBER, 1.3))
	dome.rotation.x = PI / 2
	_neon.append({"material": dome.material_override, "base": 1.3, "phase": 0.0, "speed": 1.3})
	# The title strip has a transparent background and stays inside the dome.
	var texture := screen("jukebox", Vector2i(320, 160), func(_canvas): pass)
	screens.jukebox.viewport.transparent_bg = true
	var strip_mat := screen_material(texture, 1.0)
	strip_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	quad(Vector2(1.1, 0.55), Vector3(x, 2.15, z + 0.5), strip_mat)
	for i in 7:
		var c := Color.from_hsv(i / 7.0, 0.75, 1.0)
		var tube := box(Vector3(0.1, 0.7, 0.05), Vector3(x - 0.6 + i * 0.2, 0.9, z + 0.47), mat(c, 0.3, 0, c, 3.0), self, false)
		_neon.append({"material": tube.material_override, "base": 3.0, "phase": i * 1.2, "speed": 3.0})
		_eq_bars.append(tube)
	box(Vector3(1.75, 0.08, 0.95), Vector3(x, 0.45, z), chrome)
	box(Vector3(1.75, 0.08, 0.95), Vector3(x, 1.3, z), chrome)
	for i in 3:
		var px: float = Layout.MUSIC_PADS[i]
		var button := cylinder(0.13, 0.06, Vector3(px, 0.28, z + 0.48), mat(PINK, 0.3, 0, PINK, 2.0))
		button.rotation.x = PI / 2
		var icon_texture := screen("music_icon%d" % i, Vector2i(64, 64), _draw_music_icon.bind(i))
		screens["music_icon%d" % i].viewport.transparent_bg = true
		screens["music_icon%d" % i].viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		var icon_mat := screen_material(icon_texture, 1.0)
		icon_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		quad(Vector2(0.18, 0.18), Vector3(px, 0.28, z + 0.52), icon_mat)
	var light := OmniLight3D.new()
	light.light_color = Color("ff8fb8")
	light.light_energy = 1.8
	light.omni_range = 3.5
	light.position = Vector3(x, 0.9, z + 1.3)
	add_child(light)

func _exit_door() -> void:
	var x := Layout.EXIT_DOOR
	var z := Layout.BACK + 0.06
	box(Vector3(1.2, 2.3, 0.12), Vector3(x, 1.15, z), mat(Color("6a4532"), 0.6))
	box(Vector3(1.0, 2.1, 0.06), Vector3(x, 1.05, z + 0.08), mat(Color("9a6544"), 0.55))
	for p in [[Vector3(-0.62, 0, 0.14), Vector3(-0.62, 2.32, 0.14)], [Vector3(0.62, 0, 0.14), Vector3(0.62, 2.32, 0.14)], [Vector3(-0.62, 2.32, 0.14), Vector3(0.62, 2.32, 0.14)]]:
		neon_line(Vector3(x, 0, z) + p[0], Vector3(x, 0, z) + p[1], GREEN, 2.5, 0.04)
	sphere(0.05, Vector3(x + 0.35, 1.05, z + 0.14), mat(Color("ffcf5a"), 0.2, 0.9))
	var sign_node := box(Vector3(0.8, 0.3, 0.06), Vector3(x, 2.55, z + 0.06), mat(Color("0b2a1c"), 0.3, 0, GREEN, 1.4), self, false)
	sign_node.name = "exit_sign"
	label("EXIT", Vector3(x, 2.55, z + 0.1), 40, Color(0.6, 2.6, 1.4), self)
	var light := OmniLight3D.new()
	light.light_color = GREEN
	light.light_energy = 2.0
	light.omni_range = 3.5
	light.position = Vector3(x, 2.4, z + 0.5)
	add_child(light)

func _plaque() -> void:
	var c := Layout.PLAQUE_CENTER
	box(Vector3(2.3, 2.75, 0.1), c + Vector3(0, 0, -0.02), mat(Color("0e0c18"), 0.4))
	var texture := screen("plaque", Vector2i(320, 380), func(_canvas): pass)
	screens.plaque.canvas.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST  # crisp QR modules
	# White enough to read after tone mapping, low enough not to bloom.
	var m := screen_material(texture, 1.15)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	quad(Vector2(2.2, 2.63), c + Vector3(0, 0, 0.04), m)

func _ceiling_lights() -> void:
	# Fixed spots that paint coloured cones through the haze. They hang in
	# front of the play line and off to the side, so the light hits players at
	# an angle and throws a real shadow back onto the floor and wall.
	var spots := [[-6.8, VIOLET, Vector3(-4.4, 0, -0.6)], [-1.6, PINK, Vector3(0.6, 0, -0.6)], [7.6, AMBER, Vector3(5.6, 0, -0.6)]]
	for s in spots:
		var housing := cylinder(0.22, 0.4, Vector3(s[0], 10.4, 6.0), mat(Color("221d30"), 0.4, 0.6))
		housing.name = "spot"
		var light := SpotLight3D.new()
		light.light_color = s[1]
		light.light_energy = 18.0
		light.light_volumetric_fog_energy = 5.0
		light.spot_range = 16
		light.spot_angle = 15
		light.spot_angle_attenuation = 0.4
		light.spot_attenuation = 0.5
		light.shadow_enabled = true
		light.shadow_blur = 1.5
		light.position = Vector3(s[0], 9.95, 6.0)
		add_child(light)
		light.look_at(s[2])
	# Two moving heads that sweep slowly across the room.
	for s in [-1, 1]:
		var head := Node3D.new()
		head.position = Vector3(s * 9.5, 10.2, 1.5)
		add_child(head)
		cylinder(0.18, 0.35, Vector3.ZERO, mat(Color("2a2438"), 0.4, 0.6), head)
		var beam := SpotLight3D.new()
		beam.light_color = CYAN if s < 0 else GREEN
		beam.light_energy = 14.0
		beam.light_volumetric_fog_energy = 8.0
		beam.spot_range = 20
		beam.spot_angle = 6
		beam.spot_angle_attenuation = 0.3
		head.add_child(beam)
		_movers.append({"node": head, "light": beam, "side": s})
	# Disco ball: tiny mirrors are faked by a faceted metallic sphere.
	_disco = Node3D.new()
	_disco.position = Vector3(2.8, 9.8, 0.4)
	add_child(_disco)
	cylinder(0.01, 0.8, Vector3(0, 0.45, 0), mat(Color("888888"), 0.3, 1.0), _disco)
	var ball := SphereMesh.new()
	ball.radius = 0.38
	ball.height = 0.76
	ball.radial_segments = 14
	ball.rings = 7
	var ball_node := MeshInstance3D.new()
	ball_node.mesh = ball
	var mirror := mat(Color("dcdcf0"), 0.05, 1.0)
	mirror.emission_enabled = true
	mirror.emission = Color("6a5cff")
	mirror.emission_energy_multiplier = 0.4
	ball_node.material_override = mirror
	_disco.add_child(ball_node)
	var disco_light := OmniLight3D.new()
	disco_light.light_color = Color("c8c0ff")
	disco_light.light_energy = 1.2
	disco_light.omni_range = 4
	disco_light.position = Vector3(0, -0.8, 0.5)
	_disco.add_child(disco_light)

func _foreground() -> void:
	# A rug, a coffee table with snacks and plants close to the camera give
	# the room depth without ever covering the players' plane.
	var rug := mat(Color("2a1f4a"), 1.0)
	box(Vector3(9.0, 0.02, 3.4), Vector3(0, 0.01, 1.4), rug, self, false)
	box(Vector3(8.6, 0.022, 3.0), Vector3(0, 0.012, 1.4), mat(Color("3a2a66"), 1.0), self, false)
	for i in 3:
		var c: Color = [AMBER, VIOLET, PINK][i]
		box(Vector3(8.2 - i * 0.6, 0.024, 0.06), Vector3(0, 0.013, 0.0 + i * 0.12), mat(c.darkened(0.2), 1.0), self, false)
	var table_z := 3.6
	box(Vector3(3.0, 0.1, 1.1), Vector3(-0.5, 0.5, table_z), mat(Color("6b4430"), 0.35))
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			box(Vector3(0.08, 0.45, 0.08), Vector3(-0.5 + sx * 1.35, 0.23, table_z + sz * 0.45), mat(Color("3b2618"), 0.5))
	cylinder(0.32, 0.12, Vector3(-1.2, 0.61, table_z), mat(Color("e9e6f5"), 0.3))
	for i in 7:
		sphere(0.07, Vector3(-1.35 + (i % 4) * 0.1, 0.72, table_z - 0.1 + (i / 4) * 0.15), mat(Color("ffcf5a"), 0.9))
	for i in 3:
		var can_color: Color = [PINK, GREEN, CYAN][i]
		cylinder(0.06, 0.2, Vector3(-0.75 + i * 0.25, 0.65, table_z + 0.1 * (i - 1)), mat(can_color, 0.25, 0.7))
	# The two controllers from the GameNight logo, put down mid-evening.
	_logo_pad(AMBER, Vector3(0.3, 0.6, table_z - 0.1), 0.24)
	_logo_pad(VIOLET, Vector3(0.75, 0.62, table_z + 0.2), -0.23)
	# A controller nobody has joined with yet makes these jump: that is the hint.
	for s in [-1, 1]:
		var x: float = s * 11.0
		cylinder(0.35, 0.6, Vector3(x, 0.3, 2.5), mat(Color("c46c4a"), 0.8))
		for leaf in 7:
			var a := leaf * TAU / 7
			var l := box(Vector3(0.12, 1.4, 0.02), Vector3(x + cos(a) * 0.2, 1.2, 2.5 + sin(a) * 0.2), mat(Color("2f8f5a").darkened(leaf * 0.05), 0.9))
			l.rotation = Vector3(sin(a) * 0.5, a, cos(a) * 0.5)

## A controller shaped like the ones in the logo: a rounded body with two
## round grips, a d-pad and two buttons knocked out in dark.
func _logo_pad(color: Color, pos: Vector3, yaw: float) -> void:
	var pad := Node3D.new()
	pad.position = pos
	pad.rotation.y = yaw
	pad.scale = Vector3.ONE * 1.6
	add_child(pad)
	# A faint glow of their own keeps them readable in the dim foreground.
	var body := mat(color, 0.45, 0.0, color, 0.5)
	_pads.append({"node": pad, "pos": pos, "yaw": yaw, "body": body})
	var ink := mat(Color("0b0b12"), 0.6)
	box(Vector3(0.36, 0.07, 0.17), Vector3(0, 0, -0.02), body, pad)
	for side in [-1, 1]:
		cylinder(0.085, 0.07, Vector3(side * 0.13, 0, 0.04), body, pad)
	box(Vector3(0.09, 0.012, 0.028), Vector3(-0.1, 0.04, -0.02), ink, pad, false)
	box(Vector3(0.028, 0.012, 0.09), Vector3(-0.1, 0.04, -0.02), ink, pad, false)
	for b in [Vector3(0.09, 0.04, -0.05), Vector3(0.13, 0.04, 0.0)]:
		cylinder(0.022, 0.012, b, ink, pad)

func _string_lights() -> void:
	# Party bulbs sagging along the top of the back wall.
	var colors := [AMBER, PINK, CYAN, GREEN, VIOLET]
	var spans := [[-11.8, -4.0], [-4.0, 4.0], [4.0, 11.8]]
	var k := 0
	for span in spans:
		var count := 14
		var prev := Vector3.ZERO
		for i in count + 1:
			var t := float(i) / count
			var x: float = lerpf(span[0], span[1], t)
			var y := 10.15 - sin(t * PI) * 0.7
			var pos := Vector3(x, y, Layout.BACK + 0.3)
			if i > 0:
				var wire := box(Vector3(pos.distance_to(prev), 0.015, 0.015), (pos + prev) / 2, mat(Color("15121f"), 0.8), self, false)
				wire.rotation.z = atan2(pos.y - prev.y, pos.x - prev.x)
			prev = pos
			if i == 0 or i == count: continue
			var c: Color = colors[k % colors.size()]
			k += 1
			var bulb := sphere(0.07, pos + Vector3(0, -0.09, 0), mat(c, 0.3, 0, c, 6.0))
			bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_neon.append({"material": bulb.material_override, "base": 6.0, "phase": k * 0.9, "speed": 1.7})

func _dust() -> void:
	var particles := CPUParticles3D.new()
	particles.amount = 70
	particles.lifetime = 12
	particles.preprocess = 12
	particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	particles.emission_box_extents = Vector3(12, 5, 2.5)
	particles.position = Vector3(0, 5, 0.5)
	particles.direction = Vector3(0, 1, 0)
	particles.spread = 180
	particles.gravity = Vector3(0, 0.02, 0)
	particles.initial_velocity_min = 0.02
	particles.initial_velocity_max = 0.12
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.018, 0.018)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.2, 1.1, 1.5, 0.35)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = m
	particles.mesh = mesh
	add_child(particles)

# ---------------------------------------------------------------- live updates

## Brief light flash, for explosions and confetti.
func flash(pos: Vector3, color: Color, energy: float, radius := 6.0) -> void:
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = energy
	light.omni_range = radius
	light.light_volumetric_fog_energy = 2.0
	light.position = pos
	add_child(light)
	_flash_lights.append({"light": light, "energy": energy})

## Expanding fireball with a bright core that fades out.
func fireball(pos: Vector3, color: Color, radius: float) -> void:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(color.r * 1.8, color.g * 1.8, color.b * 1.8, 0.75)
	var ball := sphere(radius, pos, m)
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ball.scale = Vector3.ONE * 0.2
	var tween := create_tween().set_parallel()
	tween.tween_property(ball, "scale", Vector3.ONE, 0.22).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	tween.tween_property(m, "albedo_color:a", 0.0, 0.35).set_delay(0.08)
	tween.chain().tween_callback(ball.queue_free)

func shake(amount: float) -> void:
	_shake = maxf(_shake, amount)

func set_mood(color: Color) -> void:
	mood = color

## Shows that an unjoined controller is being heard: the table pads jump
## and "A Join" appears for a moment. Called on every frame of its input.
func nudge_pads() -> void:
	_pad_activity = 2.0

func _animate_pads(delta: float) -> void:
	_pad_activity = maxf(0.0, _pad_activity - delta)
	var k := clampf(_pad_activity / 0.6, 0.0, 1.0)
	for i in _pads.size():
		var p: Dictionary = _pads[i]
		var node: Node3D = p.node
		node.position = p.pos + Vector3(0, absf(sin(_time * 13.0 + i * 1.3)) * 0.12 * k, 0)
		node.rotation = Vector3(sin(_time * 19.0 + i) * 0.12 * k, p.yaw, sin(_time * 23.0 + i * 1.7) * 0.18 * k)
		p.body.emission_energy_multiplier = 0.5 + 1.6 * k

func _process(delta: float) -> void:
	_time += delta
	_animate_pads(delta)
	for name in _prompts:
		var presses: Dictionary = _prompts[name].state.get("pressed", {})
		for key in presses.keys():
			presses[key] = maxf(0.0, presses[key] - delta / .36)
			if presses[key] == 0.0: presses.erase(key)
			redraw("prompt_" + name)
	for key in _bumper_presses.keys():
		_bumper_presses[key] = maxf(0.0, _bumper_presses[key] - delta / .36)
		if _bumper_presses[key] == 0.0: _bumper_presses.erase(key)
		redraw("bumper_" + key)
	for n in _neon:
		var f := 1.0
		if n.speed > 0: f = 0.75 + 0.25 * sin(_time * n.speed + n.phase)
		if n.get("flicker", false) and fmod(_time, 9.0) > 8.6: f = 0.35 if int(_time * 20) % 3 == 0 else 1.0
		n.material.emission_energy_multiplier = n.base * f
	# LED strips slowly cycle around the brand colours, tinted by the mood.
	var hue := fmod(_time * 0.03, 1.0)
	for i in _strip_materials.size():
		var c := Color.from_hsv(fmod(hue + i * 0.07, 1.0), 0.65, 1.0).lerp(mood, 0.45)
		_strip_materials[i].emission = c
		_strip_materials[i].albedo_color = c
	for m in _movers:
		var t: float = _time * 0.35 + (0.0 if m.side < 0 else PI)
		m.node.look_at(Vector3(sin(t) * 7.0 - m.side * 1.5, 0, 1.0 + cos(t * 0.7) * 1.5))
	if _disco: _disco.rotation.y = _time * 0.6
	for i in _eq_bars.size():
		var level := 0.35
		if music_playing: level = 0.45 + 0.55 * absf(sin(_time * (3.1 + i * 0.7) + i * 1.9) * sin(_time * 1.7 + i))
		_eq_bars[i].scale.y = level
		_eq_bars[i].position.y = 0.55 + level * 0.35  # grows up from the base, never into the dome
	if _tv_light:
		_tv_light.light_color = _tv_light.light_color.lerp(mood, delta * 2.0)
		_tv_light.light_energy = 3.0 + sin(_time * 7.0) * 0.12 + sin(_time * 2.3) * 0.15
	for f in _flash_lights:
		f.light.light_energy = move_toward(f.light.light_energy, 0, f.energy * delta * 3.5)
		if f.light.light_energy <= 0.01: f.light.queue_free()
	_flash_lights = _flash_lights.filter(func(f): return is_instance_valid(f.light) and f.light.light_energy > 0.01)
	for name in _prompts:
		var p: Dictionary = _prompts[name]
		p.node.position = p.base + Vector3(0, sin(_time * 2.2 + p.base.x) * 0.05, 0)
		var target := 1.6 if p.active else 0.85
		var energy := move_toward(p.material.albedo_color.r, target, delta * 3.0)
		p.material.albedo_color = Color(energy, energy, energy, 1.0 if p.active else 0.8)
	_shake = move_toward(_shake, 0, delta * 1.8)
	var sway := Vector3(sin(_time * 0.21) * 0.25, sin(_time * 0.17) * 0.12, 0)
	var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * _shake * 0.25
	camera.position = _camera_base + sway + jitter
	camera.look_at(_camera_target + sway * 0.5)

## Previous, play/pause and next, drawn as clean shapes.
func _draw_music_icon(canvas: Control, index: int) -> void:
	var ink := Color(0.12, 0.03, 0.08)
	var c := Vector2(32, 32)
	match index:
		0:
			canvas.draw_rect(Rect2(14, 18, 5, 28), ink)
			canvas.draw_colored_polygon(PackedVector2Array([Vector2(48, 18), Vector2(48, 46), Vector2(21, 32)]), ink)
		1:
			canvas.draw_colored_polygon(PackedVector2Array([Vector2(13, 17), Vector2(13, 47), Vector2(33, 32)]), ink)
			canvas.draw_rect(Rect2(38, 18, 5, 28), ink)
			canvas.draw_rect(Rect2(47, 18, 5, 28), ink)
		_:
			canvas.draw_colored_polygon(PackedVector2Array([Vector2(16, 18), Vector2(16, 46), Vector2(43, 32)]), ink)
			canvas.draw_rect(Rect2(45, 18, 5, 28), ink)
