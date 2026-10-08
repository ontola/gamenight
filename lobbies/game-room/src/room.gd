extends Node3D
## The 3D game room: geometry, materials, lights and in-world screens.
## Built in code so layout constants stay the single source of truth.

const Layout = preload("res://src/layout.gd")
const Canvas = preload("res://src/canvas.gd")

const AMBER := Color("ffb454")
const VIOLET := Color("7c5cff")
const GREEN := Color("3ddc97")
const PINK := Color("ff4f8b")
const CYAN := Color("38d6ff")
const BG := Color("0b0b12")
const TEXT := Color("f2f1f8")

var font: FontFile
var bold: FontFile
var pixel: FontFile                 # wordmark only
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
var queue_boxes: Array = []
var queue_more: Label3D
var queue_empty: Label3D
var _spine_root: Node3D
var _eq_bars: Array = []
var music_playing := false
var mood := VIOLET                 # tinted by the next game's colour

func _ready() -> void:
	font = load_font()
	bold = load_font(800)
	pixel = load_pixel_font()
	_label_font = load_font(600, true)
	_label_bold = load_font(800, true)
	_environment()
	_camera()
	_shell()
	_window()
	_logo()
	_tv()
	_game_shelf()
	_shelves()
	_couch_corner()
	_jukebox()
	_exit_door()
	_plaque()
	_ceiling_lights()
	_foreground()
	_string_lights()
	_dust()

# ---------------------------------------------------------------- helpers

## Fonts load straight from the files, so the project runs without an editor
## import step (.godot/ and *.import are ignored). Outfit is the GameNight UI
## face; the pixel font is kept only for the wordmark on the neon sign.
static func load_font(weight := 600, msdf := false) -> FontFile:
	var f := FontFile.new()
	f.load_dynamic_font("res://assets/fonts/outfit-%d.woff2" % weight)
	# MSDF keeps 3D labels sharp at any distance; 2D text draws at its real
	# pixel size, where plain hinted glyphs look cleaner.
	f.multichannel_signed_distance_field = msdf
	f.generate_mipmaps = msdf
	return f

static func load_pixel_font() -> FontFile:
	var f := FontFile.new()
	f.load_dynamic_font("res://assets/fonts/ark-pixel-16px-latin.ttf")
	f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	f.hinting = TextServer.HINTING_NONE
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
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
	environment.ambient_light_color = Color("2a2050")
	environment.ambient_light_energy = 0.8
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
			var c := Color("191634") if stripe else Color("15122c")
			# Small diamond pattern, like a retro arcade carpet on the wall.
			var dx := absi((x % 32) - 16)
			var dy := absi((y % 32) - 16)
			if dx + dy == 9: c = Color("231d48")
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
	# Back wall with wallpaper, wainscot and a skirting LED strip.
	var wall_mat := mat(Color.WHITE, 0.9)
	wall_mat.albedo_texture = _wallpaper_texture()
	wall_mat.uv1_scale = Vector3(12, 5.4, 1)
	quad(Vector2(26, 11.2), Vector3(0, 5.6, Layout.BACK), wall_mat)
	box(Vector3(26, 1.2, 0.08), Vector3(0, 0.6, Layout.BACK + 0.04), mat(Color("1d1530"), 0.6))
	box(Vector3(26, 0.06, 0.12), Vector3(0, 1.22, Layout.BACK + 0.06), mat(Color("392a52"), 0.5))
	_strip(Vector3(0, 0.05, Layout.BACK + 0.1), 26)
	# Side walls, slightly warmer, so the perspective reads.
	var side := mat(Color("1a1530"), 0.85)
	side.albedo_texture = wall_mat.albedo_texture
	side.uv1_scale = Vector3(5, 5.4, 1)
	for s in [-1, 1]:
		var wall := quad(Vector2(10, 11.2), Vector3(s * 12.0, 5.6, Layout.BACK + 5), side)
		wall.rotation.y = -s * PI / 2
		box(Vector3(0.1, 0.05, 10), Vector3(s * 11.95, 10.35, Layout.BACK + 5), mat(VIOLET, 0.4, 0, VIOLET, 3.0), self, false)
	# Ceiling with beams and an LED strip along the back.
	var ceiling := quad(Vector2(26, 10), Vector3(0, 10.9, Layout.BACK + 5), mat(Color("0f0c1e"), 0.9))
	ceiling.rotation.x = PI / 2
	for i in 6:
		box(Vector3(26, 0.35, 0.4), Vector3(0, 10.7, Layout.BACK + 0.6 + i * 1.8), mat(Color("1c1530"), 0.8))
	_strip(Vector3(0, 10.45, Layout.BACK + 0.1), 26)

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
	# GameNight wordmark as a real neon sign: the text is rendered once into a
	# transparent texture and used as emission, so glow picks it up.
	var y := 8.0
	var z := Layout.BACK + 0.12
	var sign_texture := screen("logo", Vector2i(1024, 256), func(canvas: Control):
		var f: Font = pixel
		var sub := "COUCH MULTIPLAYER CLUB"
		# Soft halo first, then the tube itself.
		for k in [30, 18, 10]:
			canvas.draw_string_outline(f, Vector2(0, 150), "GAMENIGHT", HORIZONTAL_ALIGNMENT_CENTER, 1024, 160, k, Color(AMBER, 0.12))
			canvas.draw_string_outline(font, Vector2(0, 222), sub, HORIZONTAL_ALIGNMENT_CENTER, 1024, 44, k / 2, Color(VIOLET, 0.15))
		canvas.draw_string_outline(f, Vector2(0, 150), "GAMENIGHT", HORIZONTAL_ALIGNMENT_CENTER, 1024, 160, 4, AMBER.lightened(0.2))
		canvas.draw_string(f, Vector2(0, 150), "GAMENIGHT", HORIZONTAL_ALIGNMENT_CENTER, 1024, 160, Color("ffd59a"))
		canvas.draw_string(font, Vector2(0, 222), sub, HORIZONTAL_ALIGNMENT_CENTER, 1024, 44, Color("d9d0ff")))
	screens.logo.viewport.transparent_bg = true
	screens.logo.viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_texture = sign_texture
	m.albedo_color = Color(0.3, 0.3, 0.3)
	m.emission_enabled = true
	m.emission_texture = sign_texture
	m.emission_energy_multiplier = 5.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	quad(Vector2(10.24, 2.56), Vector3(0.75, y - 0.35, z), m)
	_neon.append({"material": m, "base": 5.0, "phase": 0.0, "speed": 0.0, "flicker": true})
	var svg := FileAccess.get_file_as_string("res://assets/icon.svg")
	var img := Image.new()
	if img.load_svg_from_string(svg, 0.5) == OK:
		var icon := StandardMaterial3D.new()
		icon.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		icon.albedo_texture = ImageTexture.create_from_image(img)
		icon.albedo_color = Color(0.4, 0.4, 0.4)
		icon.emission_enabled = true
		icon.emission_texture = icon.albedo_texture
		icon.emission_energy_multiplier = 1.6
		quad(Vector2(1.6, 1.6), Vector3(-5.0, y - 0.1, z), icon)
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
	# TV console with game boxes and LED strip.
	box(Vector3(6.6, 0.85, 0.9), Vector3(0, 0.43, Layout.BACK + 0.5), mat(Color("231a2e"), 0.5))
	box(Vector3(6.6, 0.05, 0.92), Vector3(0, 0.87, Layout.BACK + 0.5), mat(Color("3b2c4a"), 0.3))
	var led := mat(AMBER, 0.4, 0, AMBER, 3.5)
	box(Vector3(6.4, 0.04, 0.04), Vector3(0, 0.08, Layout.BACK + 0.97), led, self, false)
	_strip_materials.append(led)
	var cases := [VIOLET, GREEN, AMBER, PINK, CYAN, Color("f5e663")]
	for i in cases.size():
		box(Vector3(0.12, 0.62, 0.45), Vector3(-2.9 + i * 0.15, 1.2, Layout.BACK + 0.45), mat(cases[i].darkened(0.3), 0.5))
	box(Vector3(0.9, 0.18, 0.5), Vector3(2.45, 0.98, Layout.BACK + 0.45), mat(Color("e9e6f5"), 0.3))
	box(Vector3(0.3, 0.04, 0.02), Vector3(2.45, 0.98, Layout.BACK + 0.71), mat(GREEN, 0.3, 0, GREEN, 4.0), self, false)
	# Floor pads in front of the TV.
	for i in Layout.TV_PADS.size():
		var pad_mat := mat(Color("1c1530"), 0.3, 0.2, VIOLET, 1.0)
		box(Vector3(Layout.PAD_HALF * 2 - 0.1, 0.04, 1.4), Vector3(Layout.TV_PADS[i], 0.02, 0), pad_mat, self, false)
		screens["pad%d" % i] = {"material": pad_mat}
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
		box(Vector3(1.0, 0.1, 0.6), Vector3(x, 3.55, Layout.BACK + 0.3), mat(Color("3b2c4a"), 0.4))
		var body := box(Vector3(0.8, 1.3, 0.55), Vector3(x, 2.85, Layout.BACK + 0.32), mat(Color("4a3a5e"), 0.45))
		cylinder(0.3, 0.04, Vector3(x, 2.65, Layout.BACK + 0.61), mat(Color("1a1622"), 0.3, 0.6)).rotation.x = PI / 2
		cylinder(0.12, 0.04, Vector3(x, 3.22, Layout.BACK + 0.61), mat(Color("1a1622"), 0.3, 0.6)).rotation.x = PI / 2
		body.name = "speaker"

func _game_shelf() -> void:
	# Old-fashioned game boxes: a bookcase of spines and a display stand
	# showing the selected box face forward.
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
	var led := mat(VIOLET, 0.3, 0, VIOLET, 3.0)
	for y in Layout.SPINE_ROWS:
		box(Vector3(bw - 0.2, 0.025, 0.025), Vector3(bx, y + 0.76, z + 0.3), led, self, false)
	_strip_materials.append(led)
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
	var front_texture := screen("box_front", Vector2i(300, 420), func(_canvas): pass)
	featured_box = game_box(Vector2(1.5, 2.1), Vector3(dx, 1.9, z + 0.1), front_texture, 1.45)
	featured_box.rotation.x = -0.06
	for side in [-1, 1]:
		var arrow := label("< LB" if side < 0 else "RB >", Vector3(dx + side * 0.98, 1.9, z + 0.3), 32, Color(1.6, 1.3, 2.4), self, 6)
		arrow.name = "shelf_lb" if side < 0 else "shelf_rb"
	var spot := SpotLight3D.new()
	spot.light_color = Color("ffd7a0")
	spot.light_energy = 9.0
	spot.spot_range = 5.0
	spot.spot_angle = 22
	spot.light_volumetric_fog_energy = 0.6
	spot.position = Vector3(dx, 4.2, z + 1.6)
	add_child(spot)
	spot.look_at(Vector3(dx, 1.9, z), Vector3.UP)
	var glow := OmniLight3D.new()
	glow.light_color = Color("b9a6ff")
	glow.light_energy = 3.0
	glow.omni_range = 3.2
	glow.position = Vector3(bx, 1.4, z + 1.0)
	add_child(glow)

## A game box like a DVD case: dark plastic shell with the cover in front.
func game_box(size: Vector2, pos: Vector3, cover: Texture2D, energy := 1.2, parent: Node = self) -> Node3D:
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	box(Vector3(size.x + 0.05, size.y + 0.05, 0.1), Vector3.ZERO, mat(Color("12141f"), 0.35, 0.2), root)
	box(Vector3(0.05, size.y + 0.05, 0.11), Vector3(-size.x / 2 - 0.0, 0, 0), mat(Color("23263a"), 0.3, 0.3), root, false)
	var face := screen_material(cover, energy)
	face.disable_fog = true  # covers stay crisp through the haze
	quad(size, Vector3(0, 0, 0.051), face, root)
	return root

## Rebuilds the spines: games is [{title, color}], selected sits on the stand.
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
		if i == selected:
			# The box is out on the stand: leave a gap with a glowing marker.
			box(Vector3(0.16, 0.03, 0.4), Vector3(x, row + 0.02, Layout.BACK + 0.45), mat(AMBER, 0.3, 0, AMBER, 3.0), _spine_root, false)
			continue
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

## Up next: boxes on a ledge over the couch. count of up to 3 visible.
func set_queue(count: int, more: int) -> void:
	for i in queue_boxes.size(): queue_boxes[i].visible = i < count
	queue_more.text = "+%d" % more if more > 0 else ""
	queue_empty.visible = count == 0

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
		var strip_color: Color = [VIOLET, CYAN, PINK, AMBER][rng.randi() % 4]
		var led := mat(strip_color, 0.3, 0, strip_color, 3.0)
		box(Vector3(w - 0.1, 0.03, 0.03), Vector3(cx, d[2] - 0.13, Layout.BACK + 0.68), led, self, false)
		_strip_materials.append(led)
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
	# Up next: game boxes on a ledge above the couch, next in line on the left,
	# high enough that people on the couch do not hide them.
	var q := Layout.QUEUE_BOARD
	var ledge := q.y
	box(Vector3(3.3, 0.1, 0.4), Vector3(q.x, ledge - 0.05, q.z + 0.16), mat(Color("5b3b2a"), 0.55))
	var strip := mat(GREEN, 0.3, 0, GREEN, 3.0)
	box(Vector3(3.2, 0.025, 0.025), Vector3(q.x, ledge - 0.11, q.z + 0.36), strip, self, false)
	_strip_materials.append(strip)
	label("UP NEXT", Vector3(q.x - 0.95, ledge - 0.3, q.z + 0.3), 32, Color(0.8, 3.0, 1.8), self, 8)
	var sizes := [Vector2(1.2, 1.68), Vector2(0.82, 1.15), Vector2(0.82, 1.15)]
	var xs := [-0.95, 0.24, 1.14]
	for i in 3:
		var texture := screen("queue%d" % i, Vector2i(200, 280), func(_canvas): pass)
		var size: Vector2 = sizes[i]
		var node := game_box(size, Vector3(q.x + xs[i], ledge + size.y / 2 + 0.03, q.z + 0.14), texture, 1.3 if i == 0 else 1.05)
		node.rotation.z = [0.0, -0.03, 0.04][i]
		queue_boxes.append(node)
	queue_more = label("", Vector3(q.x + 1.14, ledge - 0.32, q.z + 0.3), 32, Color(0.8, 2.2, 1.4), self, 6)
	queue_empty = label("Press Y at the game shelf", Vector3(q.x + 0.3, ledge + 0.5, q.z + 0.2), 24, Color(0.9, 0.9, 1.1), self, 6)
	var light := OmniLight3D.new()
	light.light_color = Color("bff5dc")
	light.light_energy = 2.0
	light.omni_range = 3.0
	light.position = Vector3(q.x, ledge + 1.0, q.z + 1.4)
	add_child(light)
	# Floor lamp: warm light, a nice contrast to the neon.
	var lamp_x := 8.55
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
	# that dance while music plays, and three buttons above the floor pads.
	var x := Layout.JUKEBOX
	var z := Layout.BACK + 0.55
	var wood := mat(Color("5a2438"), 0.35, 0.1)
	box(Vector3(1.7, 2.1, 0.9), Vector3(x, 1.05, z), wood)
	var arch := cylinder(0.85, 0.9, Vector3(x, 2.1, z), wood)
	arch.rotation.x = PI / 2
	var chrome := mat(Color("d8d4e8"), 0.15, 0.9)
	var rim := cylinder(0.88, 0.06, Vector3(x, 2.1, z + 0.44), chrome)
	rim.rotation.x = PI / 2
	var dome := cylinder(0.74, 0.04, Vector3(x, 2.1, z + 0.47), mat(Color("ffcf8a"), 0.2, 0, AMBER, 2.2))
	dome.rotation.x = PI / 2
	_neon.append({"material": dome.material_override, "base": 2.2, "phase": 0.0, "speed": 1.3})
	var texture := screen("jukebox", Vector2i(320, 160), func(_canvas): pass)
	quad(Vector2(1.3, 0.65), Vector3(x, 2.2, z + 0.5), screen_material(texture, 1.4))
	for i in 7:
		var c := Color.from_hsv(i / 7.0, 0.75, 1.0)
		var tube := box(Vector3(0.1, 1.0, 0.05), Vector3(x - 0.6 + i * 0.2, 1.05, z + 0.47), mat(c, 0.3, 0, c, 3.0), self, false)
		_neon.append({"material": tube.material_override, "base": 3.0, "phase": i * 1.2, "speed": 3.0})
		_eq_bars.append(tube)
	box(Vector3(1.75, 0.08, 0.95), Vector3(x, 0.45, z), chrome)
	box(Vector3(1.75, 0.08, 0.95), Vector3(x, 1.62, z), chrome)
	var icons := ["<<", "> ||", ">>"]
	for i in 3:
		var px: float = Layout.MUSIC_PADS[i]
		var button := cylinder(0.13, 0.06, Vector3(px, 0.28, z + 0.48), mat(PINK, 0.3, 0, PINK, 2.0))
		button.rotation.x = PI / 2
		label(icons[i], Vector3(px, 0.28, z + 0.53), 22, Color(0.05, 0.02, 0.08), self)
		box(Vector3(0.5, 0.03, 0.7), Vector3(px, 0.015, 0.0), mat(Color("1c1530"), 0.3, 0.2, PINK, 0.8), self, false)
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
	box(Vector3(1.1, 0.03, 0.9), Vector3(x, 0.015, 0.0), mat(Color("0b2a1c"), 0.3, 0, GREEN, 1.2), self, false)
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
	# Bright enough to read as white after tone mapping: QR codes need contrast.
	var m := screen_material(texture, 1.7)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	quad(Vector2(2.2, 2.63), c + Vector3(0, 0, 0.04), m)
	for p in [[Vector2(-1.15, -1.37), Vector2(1.15, -1.37)], [Vector2(-1.15, 1.37), Vector2(1.15, 1.37)],
			[Vector2(-1.15, -1.37), Vector2(-1.15, 1.37)], [Vector2(1.15, -1.37), Vector2(1.15, 1.37)]]:
		neon_line(c + Vector3(p[0].x, p[0].y, 0.08), c + Vector3(p[1].x, p[1].y, 0.08), AMBER, 3.0, 0.05)

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
		cylinder(0.06, 0.2, Vector3(0.2 + i * 0.3, 0.65, table_z + 0.1 * (i - 1)), mat(can_color, 0.25, 0.7))
	var pad := box(Vector3(0.5, 0.06, 0.28), Vector3(0.95, 0.58, table_z + 0.2), mat(Color("1a1a24"), 0.4))
	pad.rotation.y = 0.4
	for s in [-1, 1]:
		var x: float = s * 11.0
		cylinder(0.35, 0.6, Vector3(x, 0.3, 2.5), mat(Color("c46c4a"), 0.8))
		for leaf in 7:
			var a := leaf * TAU / 7
			var l := box(Vector3(0.12, 1.4, 0.02), Vector3(x + cos(a) * 0.2, 1.2, 2.5 + sin(a) * 0.2), mat(Color("2f8f5a").darkened(leaf * 0.05), 0.9))
			l.rotation = Vector3(sin(a) * 0.5, a, cos(a) * 0.5)

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

func _process(delta: float) -> void:
	_time += delta
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
		_eq_bars[i].position.y = 0.55 + level * 0.5
	if _tv_light:
		_tv_light.light_color = _tv_light.light_color.lerp(mood, delta * 2.0)
		_tv_light.light_energy = 3.0 + sin(_time * 7.0) * 0.12 + sin(_time * 2.3) * 0.15
	for f in _flash_lights:
		f.light.light_energy = move_toward(f.light.light_energy, 0, f.energy * delta * 3.5)
		if f.light.light_energy <= 0.01: f.light.queue_free()
	_flash_lights = _flash_lights.filter(func(f): return is_instance_valid(f.light) and f.light.light_energy > 0.01)
	_shake = move_toward(_shake, 0, delta * 1.8)
	var sway := Vector3(sin(_time * 0.21) * 0.25, sin(_time * 0.17) * 0.12, 0)
	var jitter := Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * _shake * 0.25
	camera.position = _camera_base + sway + jitter
	camera.look_at(_camera_target + sway * 0.5)

func set_pad_glow(index: int, color: Color, energy: float) -> void:
	var pad: Dictionary = screens.get("pad%d" % index, {})
	if pad.is_empty(): return
	pad.material.emission = color
	pad.material.emission_energy_multiplier = energy
