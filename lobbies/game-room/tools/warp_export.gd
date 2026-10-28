extends RefCounted
## Dumps the live 3D room for the Warp engine port: every visible mesh
## (vertices, normals, uvs, indices), its material, textures as PNG, lights,
## Label3D tags, Sprite3D players, particles, camera and environment.
## Run: godot --path . -- --demo --capture=room.png --warp-export=DIR
## Godot and Warp share axes (y up, camera looks down -z); triangles are
## written counter-clockwise (Warp's front face; Godot's is clockwise).

var dir := ""
var bin := PackedByteArray()
var meshes := {}      # Mesh instance id -> index
var materials := {}   # Material instance id -> index
var textures := {}    # Texture instance id -> index
var out := {"meshes": [], "materials": [], "textures": [], "instances": [], "lights": [], "labels": [], "sprites": [], "particles": []}

static func run(root: Node, target: String, camera: Camera3D, environment: Environment) -> void:
	var e = new()
	e.dir = target
	DirAccess.make_dir_recursive_absolute(target)
	e._walk(root)
	e.out.camera = {"transform": _xf(camera.global_transform), "fov_y": camera.fov, "near": camera.near, "far": camera.far}
	e.out.environment = _environment(environment)
	var f := FileAccess.open(target.path_join("meshes.bin"), FileAccess.WRITE)
	f.store_buffer(e.bin)
	f.close()
	f = FileAccess.open(target.path_join("scene.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(e.out, " "))
	f.close()
	print("WARP_EXPORT ", target, " meshes ", e.out.meshes.size(), " instances ", e.out.instances.size(), " lights ", e.out.lights.size(),
		" labels ", e.out.labels.size(), " sprites ", e.out.sprites.size(), " textures ", e.out.textures.size())

static func _xf(t: Transform3D) -> Array:
	# Column-major 4x4 like glam's Mat4::from_cols_array.
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z, 0, t.basis.y.x, t.basis.y.y, t.basis.y.z, 0,
		t.basis.z.x, t.basis.z.y, t.basis.z.z, 0, t.origin.x, t.origin.y, t.origin.z, 1]

static func _c(c: Color) -> Array: return [c.r, c.g, c.b, c.a]

static func _environment(env: Environment) -> Dictionary:
	if env == null: return {}
	var d := {}
	for p in env.get_property_list():
		var v = env.get(p.name)
		if v is Color: d[p.name] = _c(v)
		elif v is float or v is int or v is bool: d[p.name] = v
	return d

func _visible(node: Node) -> bool:
	return not (node is Node3D) or (node as Node3D).is_visible_in_tree()

func _walk(node: Node) -> void:
	if node is Node3D and not _visible(node): return
	if node is MeshInstance3D: _mesh_instance(node)
	elif node is Light3D: _light(node)
	elif node is Label3D: _label(node)
	elif node is Sprite3D: _sprite(node)
	elif node is CPUParticles3D: _particles(node)
	for child in node.get_children(): _walk(child)

func _texture(t: Texture2D) -> int:
	if t == null: return -1
	var key := t.get_instance_id()
	if textures.has(key): return textures[key]
	var img := t.get_image()
	if img == null: return -1
	if img.is_compressed(): img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var index: int = out.textures.size()
	var file := "tex%03d.png" % index
	img.save_png(dir.path_join(file))
	var kind := "viewport" if t is ViewportTexture else "image"
	out.textures.append({"file": file, "width": img.get_width(), "height": img.get_height(), "kind": kind})
	textures[key] = index
	return index

func _material(m: Material) -> int:
	if m == null: return -1
	var key := m.get_instance_id()
	if materials.has(key): return materials[key]
	var d := {"type": m.get_class()}
	if m is BaseMaterial3D:
		var b := m as BaseMaterial3D
		d.merge({"albedo": _c(b.albedo_color), "albedo_texture": _texture(b.albedo_texture), "roughness": b.roughness, "metallic": b.metallic,
			"emission_enabled": b.emission_enabled, "emission": _c(b.emission), "emission_energy": b.emission_energy_multiplier,
			"emission_texture": _texture(b.emission_texture) if b.emission_enabled else -1,
			"unshaded": b.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED, "transparency": b.transparency,
			"cull": b.cull_mode, "filter": b.texture_filter, "uv1_scale": [b.uv1_scale.x, b.uv1_scale.y, b.uv1_scale.z],
			"uv1_offset": [b.uv1_offset.x, b.uv1_offset.y, b.uv1_offset.z], "uv1_triplanar": b.uv1_triplanar,
			"vertex_color": b.vertex_color_use_as_albedo, "billboard": b.billboard_mode, "alpha_scissor": b.alpha_scissor_threshold,
			"no_depth_test": b.no_depth_test, "blend": b.blend_mode})
	var index: int = out.materials.size()
	out.materials.append(d)
	materials[key] = index
	return index

func _floats(values) -> Array:
	var at := bin.size()
	var data := PackedFloat32Array(values).to_byte_array()
	bin.append_array(data)
	return [at, data.size()]

func _mesh(mesh: Mesh) -> int:
	var key := mesh.get_instance_id()
	if meshes.has(key): return meshes[key]
	var surfaces := []
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and (mesh as ArrayMesh).surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES: continue
		var arrays := mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nrm = arrays[Mesh.ARRAY_NORMAL]
		var uv = arrays[Mesh.ARRAY_TEX_UV]
		var col = arrays[Mesh.ARRAY_COLOR]
		var idx = arrays[Mesh.ARRAY_INDEX]
		var p := PackedFloat32Array()
		var n := PackedFloat32Array()
		var t := PackedFloat32Array()
		var c := PackedFloat32Array()
		for i in pos.size():
			p.append_array([pos[i].x, pos[i].y, pos[i].z])
			var nn: Vector3 = nrm[i] if nrm != null and i < nrm.size() else Vector3.UP
			n.append_array([nn.x, nn.y, nn.z])
			var tt: Vector2 = uv[i] if uv != null and i < uv.size() else Vector2.ZERO
			t.append_array([tt.x, tt.y])
			if col != null and i < col.size(): c.append_array([col[i].r, col[i].g, col[i].b, col[i].a])
		var tri := PackedInt32Array()
		if idx == null or idx.size() == 0:
			for i in range(0, pos.size() - 2, 3): tri.append_array([i, i + 2, i + 1])
		else:
			for i in range(0, idx.size() - 2, 3): tri.append_array([idx[i], idx[i + 2], idx[i + 1]])
		var at := bin.size()
		var bytes := tri.to_byte_array()
		bin.append_array(bytes)
		surfaces.append({"positions": _floats(p), "normals": _floats(n), "uvs": _floats(t), "colors": _floats(c) if c.size() > 0 else null,
			"indices": [at, bytes.size()], "vertices": pos.size(), "material": _material(mesh.surface_get_material(s))})
	var index: int = out.meshes.size()
	out.meshes.append({"type": mesh.get_class(), "surfaces": surfaces})
	meshes[key] = index
	return index

func _mesh_instance(node: MeshInstance3D) -> void:
	# Shadow-only stand-ins (the players' capsule bodies) cast shadows but are not drawn.
	if node.mesh == null: return
	var mats := []
	for s in node.mesh.get_surface_count():
		var m := node.get_active_material(s)
		mats.append(_material(m))
	out.instances.append({"name": str(node.get_path()), "mesh": _mesh(node.mesh), "materials": mats, "transform": _xf(node.global_transform),
		"shadow": node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "transparency": node.transparency,
		"shadow_only": node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY})

func _light(node: Light3D) -> void:
	var d := {"name": str(node.get_path()), "type": node.get_class(), "transform": _xf(node.global_transform), "color": _c(node.light_color),
		"energy": node.light_energy, "indirect": node.light_indirect_energy, "fog": node.light_volumetric_fog_energy,
		"specular": node.light_specular, "size": node.light_size, "shadow": node.shadow_enabled, "negative": node.light_negative}
	if node is OmniLight3D:
		d.merge({"range": node.omni_range, "attenuation": node.omni_attenuation})
	elif node is SpotLight3D:
		d.merge({"range": node.spot_range, "attenuation": node.spot_attenuation, "angle": node.spot_angle, "angle_attenuation": node.spot_angle_attenuation})
	out.lights.append(d)

func _font_name(f: Font) -> String:
	if f == null: return ""
	if f is FontFile: return (f as FontFile).resource_path if not (f as FontFile).resource_path.is_empty() else str((f as FontFile).font_name, " ", (f as FontFile).font_weight)
	return f.get_font_name()

func _label(node: Label3D) -> void:
	if node.text.is_empty(): return
	var font: Font = node.font
	out.labels.append({"name": str(node.get_path()), "text": node.text, "transform": _xf(node.global_transform), "font": _font_name(font),
		"weight": (font as FontFile).font_weight if font is FontFile else 400, "font_size": node.font_size, "pixel_size": node.pixel_size,
		"modulate": _c(node.modulate), "outline_size": node.outline_size, "outline_modulate": _c(node.outline_modulate),
		"billboard": node.billboard, "shaded": node.shaded, "align": node.horizontal_alignment, "valign": node.vertical_alignment,
		"width": node.width, "autowrap": node.autowrap_mode, "line_spacing": node.line_spacing, "offset": [node.offset.x, node.offset.y],
		"no_depth_test": node.no_depth_test, "render_priority": node.render_priority})

func _sprite(node: Sprite3D) -> void:
	out.sprites.append({"name": str(node.get_path()), "texture": _texture(node.texture), "transform": _xf(node.global_transform),
		"hframes": node.hframes, "vframes": node.vframes, "frame": node.frame, "region": node.region_enabled,
		"region_rect": [node.region_rect.position.x, node.region_rect.position.y, node.region_rect.size.x, node.region_rect.size.y],
		"pixel_size": node.pixel_size, "centered": node.centered, "offset": [node.offset.x, node.offset.y], "flip_h": node.flip_h,
		"flip_v": node.flip_v, "modulate": _c(node.modulate), "shaded": node.shaded, "billboard": node.billboard,
		"alpha_cut": node.alpha_cut, "transparent": node.transparent, "double_sided": node.double_sided, "filter": node.texture_filter,
		"axis": node.axis, "no_depth_test": node.no_depth_test, "render_priority": node.render_priority})

func _particles(node: CPUParticles3D) -> void:
	var d := {"name": str(node.get_path()), "transform": _xf(node.global_transform), "emitting": node.emitting, "amount": node.amount,
		"lifetime": node.lifetime, "emission_shape": node.emission_shape, "box_extents": [node.emission_box_extents.x, node.emission_box_extents.y, node.emission_box_extents.z],
		"color": _c(node.color), "scale_min": node.scale_amount_min, "scale_max": node.scale_amount_max,
		"velocity_min": node.initial_velocity_min, "velocity_max": node.initial_velocity_max, "gravity": [node.gravity.x, node.gravity.y, node.gravity.z],
		"direction": [node.direction.x, node.direction.y, node.direction.z], "spread": node.spread, "mesh": _mesh(node.mesh) if node.mesh else -1,
		"material": _material(node.mesh.surface_get_material(0)) if node.mesh else -1}
	# Where the particles are right now, for a still frame: the multimesh the
	# emitter draws with (per instance a 3x4 row-major transform, then colour
	# and custom data; dead particles have a zero transform).
	var mm := node.get_base()
	var count := RenderingServer.multimesh_get_instance_count(mm)
	var buffer := RenderingServer.multimesh_get_buffer(mm)
	d.merge({"instances": count, "stride": buffer.size() / count if count > 0 else 0, "buffer": _floats(buffer),
		"quad_size": [node.mesh.size.x, node.mesh.size.y] if node.mesh is QuadMesh else [1.0, 1.0]})
	out.particles.append(d)
