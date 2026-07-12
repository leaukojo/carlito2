@tool
class_name HeightmapTerrain
extends StaticBody3D
## Terrain from a heightmap image: a greyscale texture becomes both a
## welded ground mesh and a matching HeightMapShape3D. This is the §2-rule-2 ground
## path — a dedicated collision surface, never a trimesh scatter. One grid cell = one
## world unit, so the mesh and collision vertices coincide exactly (no shape scaling).
##
## @tool so authors see the terrain in the editor; call rebuild() after changing the
## image or size. Cells sample the red channel as normalized height [0,1] * height.
##
## Generation/chunking:
##  - The render mesh is CHUNKED (one MeshInstance3D per chunk_cells tile) so island-
##    scale maps frustum-cull instead of drawing one giant always-on mesh. Culling
##    granularity only, not LOD. Collision stays ONE HeightMapShape3D (§2-2 untouched).
##  - A FastNoiseLite GENERATOR (preset/seed/feature scale/octaves + island falloff +
##    terrace plateaus) behind Generate / Generate-random tool buttons ("random" just
##    rolls a fresh seed into gen_seed): destructive-by-button, deterministic from the seed,
##    one undoable action, writes the level's heightmap PNG (pipeline unchanged). The
##    world amplitude is the existing `height` export — generated pixels stay [0,1].
##  - An AUTO-SPLAT button seeding the RGBA splatmap (kit/terrain/terrain_splat.gdshader
##    colors: R=grass G=dirt B=sand A=rock) from slope + height, same undo discipline.
##    Pure math lives in TerrainGen (kit/terrain/terrain_gen.gd), unit-tested.

const SPLAT_SHADER_PATH := "res://kit/terrain/terrain_splat.gdshader"

@export var heightmap: Texture2D:
	set(value):
		heightmap = value
		_rebuild_if_ready()
## World-unit extent on X (width) and Z (depth). Also the collision/mesh grid size.
@export var terrain_size := Vector2(64, 64):
	set(value):
		terrain_size = value
		_rebuild_if_ready()
## World-unit Y of a fully white pixel (black = 0). The hill's peak height — and
## therefore the generator's amplitude knob (presets peak at a fraction of it).
@export var height := 8.0:
	set(value):
		height = value
		_rebuild_if_ready()
@export var material: Material:
	set(value):
		material = value
		_rebuild_if_ready()
## Render-mesh tile size in cells (one MeshInstance3D per tile — the frustum-cull unit).
@export var chunk_cells := 64:
	set(value):
		chunk_cells = maxi(1, value)
		_rebuild_if_ready()
@warning_ignore("unused_private_class_variable")
@export_tool_button("Rebuild terrain") var _rebuild_action := rebuild

@export_group("Generation")
@export var preset: TerrainGen.Preset = TerrainGen.Preset.ISLAND
@export var gen_seed := 0
## Meters per noise feature (grid cells are 1 m).
@export var feature_scale := 60.0
@export_range(1, 8) var gen_octaves := 4
## Island preset only: fraction of the radius where the descent to sea level starts/ends.
@export_range(0.0, 1.0) var falloff_start := 0.55
@export_range(0.0, 1.0) var falloff_end := 0.95
## Plateau bands (buildable flats for villages/farms). < 2 disables terracing.
@export_range(0, 12) var terrace_steps := 4
## Portion of each terrace band that stays dead flat; the rest ramps between plateaus.
@export_range(0.0, 0.9) var terrace_flat := 0.6
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate heightmap") var _generate_action := _generate
## Same generator, fresh random seed (written back to gen_seed, so the result stays
## reproducible — and undo restores the old seed with the old image).
@warning_ignore("unused_private_class_variable")
@export_tool_button("Generate random") var _generate_random_action := _generate_random

@export_group("Splat")
@export var splatmap: Texture2D:
	set(value):
		splatmap = value
		_push_splat_param()
## Below this world height the flat ground splats as sand (the beach band fades out
## over another half of it); above, grass.
@export var sand_height := 2.0
## Slope (degrees) where dirt fully takes over from flat ground.
@export var dirt_slope_deg := 22.0
## Slope (degrees) where rock fully takes over from dirt.
@export var rock_slope_deg := 38.0
@warning_ignore("unused_private_class_variable")
@export_tool_button("Auto-splat") var _auto_splat_action := _auto_splat


func _ready() -> void:
	rebuild()


func _rebuild_if_ready() -> void:
	if is_inside_tree():
		rebuild()


## (Re)generate the mesh + collision from the current heightmap. Safe to call in the
## editor or at runtime; a null heightmap flattens to a plane at y=0.
func rebuild() -> void:
	var dims := _grid_dims()
	var cols := dims.x   # vertices along X
	var rows := dims.y   # vertices along Z
	var img := _read_image()
	var heights := _sample_heights(img, cols, rows)

	_apply_chunks(cols, rows, heights)
	_apply_collision(cols, rows, heights)
	_push_splat_param()


## Editor incremental rebuild (terrain brush): remesh only the render chunks overlapping the
## world-space XZ rectangle, sampling heights from `img` — the brush's live working image,
## not the exported (stale) heightmap texture. Lets a sculpt stroke update geometry without
## remeshing a whole island every sample; collision is refreshed separately on stroke end.
func rebuild_region_world(img: Image, min_x: float, max_x: float,
		min_z: float, max_z: float) -> void:
	var container := get_node_or_null(^"Chunks") as Node3D
	if container == null:
		rebuild()   # nothing to patch yet — fall back to a full build
		return
	var dims := _grid_dims()
	var cols := dims.x
	var rows := dims.y
	var heights := _sample_heights(img, cols, rows)
	# World XZ -> cell indices (see _build_chunk: world x of cell cx = gpos.x - (cols-1)/2 +
	# cx). Expanded one cell each side so an edit on a chunk border also refreshes the
	# neighbour's shared verts/normals.
	var span_x := float(cols - 1)
	var span_z := float(rows - 1)
	var c0 := int(floor(min_x - global_position.x + span_x * 0.5)) - 1
	var c1 := int(ceil(max_x - global_position.x + span_x * 0.5)) + 1
	var r0 := int(floor(min_z - global_position.z + span_z * 0.5)) - 1
	var r1 := int(ceil(max_z - global_position.z + span_z * 0.5)) + 1
	var edit := Rect2i(c0, r0, maxi(c1 - c0, 1), maxi(r1 - r0, 1))
	for rect in TerrainGen.chunk_ranges(cols, rows, chunk_cells):
		if not Rect2i(rect.position, rect.size).intersects(edit):
			continue
		var old := container.get_node_or_null(
				NodePath("Chunk_%d_%d" % [rect.position.x, rect.position.y]))
		if old != null:
			old.free()
		container.add_child(_build_chunk(rect, cols, rows, heights))
	_push_splat_param()


## Rebuild the collision HeightMapShape3D from `img` (terrain brush, called once at stroke end —
## HeightMapShape3D has no partial-update API, so the whole shape is reassigned, but that's
## cheap data next to remeshing and only happens on release).
func rebuild_collision_from_image(img: Image) -> void:
	var dims := _grid_dims()
	_apply_collision(dims.x, dims.y, _sample_heights(img, dims.x, dims.y))


## The source PNG a brush writes on save: the heightmap's / splatmap's own PNG when it
## has one, else beside the scene. Wraps _target_png_path so the addon reuses the exact same
## path logic as the generation buttons.
func png_path_for(kind: String) -> String:
	if kind == "height":
		return _target_png_path(heightmap, "height")
	return _target_png_path(splatmap, "splat")


## Vertex grid dimensions: one cell = one world unit, so verts = extent + 1 (min 2).
## Shared by rebuild() and height_at() so the world<->grid mapping lives in one place.
func _grid_dims() -> Vector2i:
	return Vector2i(maxi(2, int(terrain_size.x) + 1), maxi(2, int(terrain_size.y) + 1))


## World-space surface height under `world_pos`'s XZ, bilinearly sampled from the
## heightmap (the ground query used by the editor placement fallback and
## scatter ground-snap). Assumes the terrain is axis-aligned (unrotated/unscaled, as
## all authored HeightmapTerrains are); a null heightmap is flat at the node's Y.
func height_at(world_pos: Vector3) -> float:
	var img := _read_image()
	if img == null:
		return global_position.y
	var dims := _grid_dims()
	var span_x := float(dims.x - 1)
	var span_z := float(dims.y - 1)
	# grid X spans [-span_x/2, +span_x/2] in local space (see _apply_chunks's x0/z0).
	var lx := world_pos.x - global_position.x
	var lz := world_pos.z - global_position.z
	var u := clampf((lx + span_x * 0.5) / span_x, 0.0, 1.0)
	var v := clampf((lz + span_z * 0.5) / span_z, 0.0, 1.0)
	return global_position.y + _sample_red_bilinear(img, u, v) * height


## Whether `world_pos`'s XZ lies within this terrain's extent (axis-aligned rect).
func contains_xz(world_pos: Vector3) -> bool:
	var lx := world_pos.x - global_position.x
	var lz := world_pos.z - global_position.z
	return absf(lx) <= terrain_size.x * 0.5 and absf(lz) <= terrain_size.y * 0.5


## Bilinear red-channel lookup at normalized (u, v) in [0,1]. Smoother than the mesh's
## nearest sampling, so a placed prop sits on the interpolated surface, not a vertex step.
func _sample_red_bilinear(img: Image, u: float, v: float) -> float:
	var iw := img.get_width()
	var ih := img.get_height()
	var fx := u * float(iw - 1)
	var fy := v * float(ih - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, iw - 1)
	var y1 := mini(y0 + 1, ih - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var top := lerpf(img.get_pixel(x0, y0).r, img.get_pixel(x1, y0).r, tx)
	var bot := lerpf(img.get_pixel(x0, y1).r, img.get_pixel(x1, y1).r, tx)
	return lerpf(top, bot, ty)


## Decoded, uncompressed copy of the heightmap image, or null when unset.
func _read_image() -> Image:
	if heightmap == null:
		return null
	var img := heightmap.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	return img


## Row-major (z*cols + x) height grid: red channel * height, or all-zero without an image.
func _sample_heights(img: Image, cols: int, rows: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(cols * rows)
	if img == null:
		return data
	var iw := img.get_width()
	var ih := img.get_height()
	for z in rows:
		var v := float(z) / float(rows - 1)
		var py := clampi(int(round(v * (ih - 1))), 0, ih - 1)
		for x in cols:
			var u := float(x) / float(cols - 1)
			var px := clampi(int(round(u * (iw - 1))), 0, iw - 1)
			data[z * cols + x] = img.get_pixel(px, py).r * height
	return data


## Rebuild every render chunk (one MeshInstance3D per chunk_cells tile). Full rebuild is
## button/load-time only; brush strokes call _build_chunk for just the touched tiles.
func _apply_chunks(cols: int, rows: int, heights: PackedFloat32Array) -> void:
	var container := get_node_or_null(^"Chunks") as Node3D
	if container == null:
		var legacy := get_node_or_null(^"Mesh")   # legacy single-mesh child (hot reload)
		if legacy != null:
			legacy.free()
		# Left unowned on purpose: the mesh is regenerated from the heightmap on
		# every load, so it must never be serialized into the level scene (an
		# editor save would otherwise bake stale geometry). It
		# still renders in the editor viewport as a preview.
		container = Node3D.new()
		container.name = "Chunks"
		add_child(container)
	for child in container.get_children():
		child.free()
	for rect in TerrainGen.chunk_ranges(cols, rows, chunk_cells):
		container.add_child(_build_chunk(rect, cols, rows, heights))


## One chunk tile: verts chunk-local (the MeshInstance3D carries the offset, so its AABB
## is tile-sized and frustum-culls), UVs global 0..1 across the whole terrain (splat
## continuity), normals analytic from the full grid (chunk borders never seam).
func _build_chunk(rect: Rect2i, cols: int, rows: int,
		heights: PackedFloat32Array) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := rect.size.x   # cells; verts = cells + 1 (border shared with the neighbor)
	var h := rect.size.y
	for z in h + 1:
		for x in w + 1:
			var gx := rect.position.x + x
			var gz := rect.position.y + z
			st.set_uv(Vector2(float(gx) / float(cols - 1), float(gz) / float(rows - 1)))
			st.set_normal(TerrainGen.grid_normal(heights, cols, rows, gx, gz))
			st.add_vertex(Vector3(x, heights[gz * cols + gx], z))
	for z in h:
		for x in w:
			var i := z * (w + 1) + x
			# two triangles per quad, wound CW (Godot's front-face order) so the
			# top surface renders / lights.
			st.add_index(i); st.add_index(i + 1); st.add_index(i + w + 1)
			st.add_index(i + 1); st.add_index(i + w + 2); st.add_index(i + w + 1)
	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [rect.position.x, rect.position.y]
	mi.position = Vector3(
			-float(cols - 1) * 0.5 + float(rect.position.x), 0.0,
			-float(rows - 1) * 0.5 + float(rect.position.y))
	mi.mesh = st.commit()
	mi.material_override = material
	return mi


func _apply_collision(cols: int, rows: int, heights: PackedFloat32Array) -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = cols
	shape.map_depth = rows
	shape.map_data = heights
	var cs := get_node_or_null(^"Collision") as CollisionShape3D
	if cs == null:
		# Unowned like the chunks (see _apply_chunks): regenerated per load, never saved.
		cs = CollisionShape3D.new()
		cs.name = "Collision"
		add_child(cs)
	cs.shape = shape


## Feed the splatmap to the splat ShaderMaterial (no-op on other material types).
func _push_splat_param() -> void:
	if material is ShaderMaterial:
		(material as ShaderMaterial).set_shader_parameter(&"splatmap", splatmap)


# --- generation (editor-only: destructive-by-button, undoable, never per-frame) ---


func _generate() -> void:
	_generate_with_seed(gen_seed)


func _generate_random() -> void:
	_generate_with_seed(randi_range(0, 999_999))


func _generate_with_seed(seed_value: int) -> void:
	if not Engine.is_editor_hint():
		return
	var path := _target_png_path(heightmap, "height")
	if path.is_empty():
		return
	var dims := _grid_dims()
	var img := TerrainGen.generate_heights(preset, seed_value, feature_scale, gen_octaves,
			falloff_start, falloff_end, dims.x, dims.y, terrace_steps, terrace_flat)
	var props := {}
	if seed_value != gen_seed:
		props[&"gen_seed"] = [gen_seed, seed_value]
	_commit_generated("Generate terrain heightmap", &"heightmap", path, img, props)


func _auto_splat() -> void:
	if not Engine.is_editor_hint():
		return
	var img := _read_image()
	if img == null:
		push_warning("Auto-splat needs a heightmap — generate or assign one first.")
		return
	var path := _target_png_path(splatmap, "splat")
	if path.is_empty():
		return
	var px_x := terrain_size.x / maxf(float(img.get_width() - 1), 1.0)
	var px_z := terrain_size.y / maxf(float(img.get_height() - 1), 1.0)
	var splat := TerrainGen.build_splatmap(img, height, px_x, px_z,
			sand_height, dirt_slope_deg, rock_slope_deg)
	# One-click promise: if the current material isn't the splat shader, swap in a fresh
	# splat ShaderMaterial (inside the same undo action, so undo restores the old look).
	var props := {}
	var current := material as ShaderMaterial
	if current == null or current.shader == null \
			or current.shader.resource_path != SPLAT_SHADER_PATH:
		var new_material := ShaderMaterial.new()
		new_material.shader = load(SPLAT_SHADER_PATH)
		props[&"material"] = [material, new_material]
	_commit_generated("Auto-splat terrain", &"splatmap", path, splat, props)


## One undoable action around a generated image (a stray click must not
## destroy hand-sculpted brush work): do applies the new image, undo restores a
## snapshot of the prior one — both through _apply_generated, which writes the PNG and
## reimports, so disk always matches the scene. `props` are sibling property changes
## ({name: [old, new]} — the random seed, the material swap) riding the same action.
func _commit_generated(action_name: String, prop: StringName, path: String,
		new_img: Image, props: Dictionary) -> void:
	var prior: Image = null
	var tex: Texture2D = get(prop)
	if tex != null:
		prior = tex.get_image()
		if prior != null and prior.is_compressed():
			prior.decompress()
	# Untyped on purpose: EditorUndoRedoManager is an editor-only class, so ANNOTATING with it
	# makes this @tool script fail to PARSE in exported (non-editor) builds — which silently
	# breaks every HeightmapTerrain at runtime. The value is fetched by string singleton lookup
	# and this whole function is is_editor_hint()-guarded, so dynamic typing costs nothing.
	var undo_redo = Engine.get_singleton(&"EditorInterface").get_editor_undo_redo()
	undo_redo.create_action(action_name)
	for prop_name: StringName in props:
		# Registered first so e.g. the material is live before the image applies (do
		# runs in registration order, undo reversed).
		undo_redo.add_do_property(self, prop_name, props[prop_name][1])
		undo_redo.add_undo_property(self, prop_name, props[prop_name][0])
	undo_redo.add_do_method(self, &"_apply_generated", prop, path, new_img)
	undo_redo.add_undo_method(self, &"_apply_generated", prop, path, prior)
	undo_redo.commit_action()


## Write the image to its PNG (lossless import sidecar enforced), reimport, and point
## `prop` at the imported texture. A null image (undoing a first-ever Generate) just
## clears the property; the file stays on disk, harmless.
func _apply_generated(prop: StringName, path: String, img: Image) -> void:
	if not Engine.is_editor_hint():
		return
	if img == null:
		set(prop, null)
		return
	var err := img.save_png(path)
	if err != OK:
		push_error("HeightmapTerrain: failed to write %s (%s)" % [path, error_string(err)])
		return
	TerrainGen.ensure_import_settings(path)
	# Untyped: EditorFileSystem is editor-only — see the note in _commit_generated (a type
	# annotation here breaks the exported build's parse of this runtime script).
	var filesystem = Engine.get_singleton(&"EditorInterface").get_resource_filesystem()
	filesystem.update_file(path)
	filesystem.reimport_files(PackedStringArray([path]))
	set(prop, ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE))


## Where a generated PNG lands: over the current texture's source PNG when there is
## one (the level's heightmap), else beside the scene as
## <scene>_<node>_<kind>.png — which requires the scene to be saved once.
func _target_png_path(tex: Texture2D, kind: String) -> String:
	if tex != null and tex.resource_path.begins_with("res://") \
			and tex.resource_path.get_extension() == "png":
		return tex.resource_path
	var root := owner if owner != null else self
	var scene_path := root.scene_file_path
	if scene_path.is_empty():
		push_warning("Save the scene first — the generated PNG is written beside it.")
		return ""
	return "%s/%s_%s_%s.png" % [scene_path.get_base_dir(),
			scene_path.get_file().get_basename(), String(name).to_snake_case(), kind]
