extends SceneTree
## Kit asset generator (plan §4.5): turns the CC0 GLBs under kit/raw/ into the two
## authoring surfaces, driven by the kit/import/*.json recipes:
##  - GridMap palettes (kit/palettes/<kit>.meshlib): item meshes with the kit's
##    root_scale and alignment baked into the vertices (mesh_transform stays
##    identity), materials deduped per kit, plus a trimesh shape per item so
##    UNBAKED levels are playable in dev (the bake replaces GridMap collision with
##    the single welded drivable body — palette tiles are all drivable);
##  - prefab scenes (kit/prefabs/<kit>/<name>.tscn): a KitPiece root carrying the
##    collision_mode, a scaled instance of the source GLB (ExtResource, so prefab
##    files stay tiny), and a pre-generated "DevCollision" StaticBody3D whose
##    shapes the baker later harvests into per-chunk bodies.
##
## Run after --import (needs the GLB import cache):
##   godot --headless --path . --script res://tools/gen_kit_assets.gd            # all kits
##   godot --headless --path . --script res://tools/gen_kit_assets.gd -- racing  # one kit
##
## Item ids in an existing .meshlib are preserved (painted GridMap cells reference
## ids), so re-running the generator never re-numbers a palette.

const Baker := preload("res://kit/bake/level_baker.gd")
const KIT_PIECE_SCRIPT := "res://kit/helpers/kit_piece.gd"
const RECIPE_DIR := "res://kit/import"

var _exit_code := 0


func _init() -> void:
	var only := OS.get_cmdline_user_args()
	var dir := DirAccess.open(RECIPE_DIR)
	if dir == null:
		push_error("cannot open " + RECIPE_DIR)
		quit(1)
		return
	var recipes := []
	for f in dir.get_files():
		if f.ends_with(".json") and (only.is_empty() or only.has(f.get_basename())):
			recipes.append(RECIPE_DIR.path_join(f))
	recipes.sort()
	for path in recipes:
		_run_recipe(path)
	quit(_exit_code)


func _run_recipe(recipe_path: String) -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(recipe_path))
	if parsed == null or not parsed is Dictionary:
		_error("bad recipe json: " + recipe_path)
		return
	var recipe: Dictionary = parsed
	var kit := String(recipe.get("kit", recipe_path.get_file().get_basename()))
	var source := String(recipe.get("source", ""))
	var scale := float(recipe.get("scale", 1.0))
	var excludes: Array = recipe.get("exclude", [])

	var dir := DirAccess.open(source)
	if dir == null:
		_error("%s: cannot open source '%s'" % [kit, source])
		return
	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".glb"):
			names.append(f.get_basename())
	names.sort()

	var palette: Dictionary = recipe.get("palette", {})
	var prefabs: Dictionary = recipe.get("prefabs", {})
	var palette_items: Array[String] = []
	var prefab_items := {}  # name -> collision_mode
	var skipped := 0
	var unmatched: Array[String] = []
	for name in names:
		if _matches_any(name, excludes):
			skipped += 1
			continue
		if not palette.is_empty() and _matches_any(name, palette.get("include", [])):
			palette_items.append(name)
			continue
		var mode := _prefab_mode(name, prefabs)
		if mode != "":
			prefab_items[name] = mode
		else:
			unmatched.append(name)

	var mats := {}  # kit-wide material dedup: material_key -> duplicated Material
	if not palette.is_empty():
		_build_palette(kit, source, scale, palette, palette_items, mats)
	if not prefabs.is_empty():
		_build_prefabs(kit, source, scale, prefabs, prefab_items, mats)
	print("[%s] palette=%d prefabs=%d excluded=%d unmatched=%d" %
			[kit, palette_items.size(), prefab_items.size(), skipped, unmatched.size()])
	if not unmatched.is_empty():
		_error("%s: unmatched pieces (add to a recipe list or exclude): %s" %
				[kit, ", ".join(unmatched)])


func _matches_any(name: String, patterns: Array) -> bool:
	for p in patterns:
		if name.match(String(p)):
			return true
	return false


## First matching pattern wins, in recipe order (so "boat-house-*" can precede
## "boat-*"). Returns "" when nothing matches.
func _prefab_mode(name: String, prefabs: Dictionary) -> String:
	var include: Dictionary = prefabs.get("include", {})
	for pattern: String in include:
		if name.match(pattern):
			return String(include[pattern])
	return ""


# -------------------------------------------------------------------- palette

func _build_palette(kit: String, source: String, scale: float, palette: Dictionary,
		items: Array[String], mats: Dictionary) -> void:
	var output := String(palette["output"])
	var cell: Array = palette.get("cell_size", [1, 1, 1])
	var ml := load(output) as MeshLibrary if ResourceLoader.exists(output) else MeshLibrary.new()
	if ml == null:
		ml = MeshLibrary.new()
	# preserve existing ids: painted GridMaps store them in cell data
	var name_to_id := {}
	var next_id := 0
	for id in ml.get_item_list():
		name_to_id[ml.get_item_name(id)] = id
		next_id = maxi(next_id, id + 1)

	for name in items:
		var geo := _load_geometry(source, name)
		if geo.is_empty():
			continue
		var xform := _palette_xform(name, scale, cell, palette, geo.aabb)
		var mesh := _merged_mesh(geo.pairs, xform, mats)
		var id: int = name_to_id.get(name, next_id)
		if not name_to_id.has(name):
			next_id += 1
			ml.create_item(id)
		ml.set_item_name(id, name)
		ml.set_item_mesh(id, mesh)
		ml.set_item_mesh_transform(id, Transform3D.IDENTITY)
		ml.set_item_shapes(id, [mesh.create_trimesh_shape(), Transform3D.IDENTITY])
	_make_dir_for(output)
	var err := ResourceSaver.save(ml, output)
	if err != OK:
		_error("%s: failed to save %s (error %d)" % [kit, output, err])


func _palette_xform(name: String, scale: float, cell: Array, palette: Dictionary,
		aabb: AABB) -> Transform3D:
	var ov: Dictionary = (palette.get("overrides", {}) as Dictionary).get(name, {})
	var off := Vector3(float(ov.get("x_offset", 0)), float(ov.get("y_offset", 0)),
			float(ov.get("z_offset", 0)))
	if String(palette.get("align", "raw")) == "corner":
		# Shared +X/+Z corner lands on (+cell/2, +cell/2) — the racing-kit lattice.
		off.x += float(cell[0]) * 0.5 - aabb.end.x * scale
		off.z += float(cell[2]) * 0.5 - aabb.end.z * scale
	return Transform3D(Basis.from_scale(Vector3.ONE * scale), off)


# -------------------------------------------------------------------- prefabs

func _build_prefabs(kit: String, source: String, scale: float, prefabs: Dictionary,
		items: Dictionary, mats: Dictionary) -> void:
	var out_dir := String(prefabs["output"])
	_make_dir_for(out_dir.path_join("x"))
	var piece_script := load(KIT_PIECE_SCRIPT)
	for name: String in items:
		var mode := String(items[name])
		var geo := _load_geometry(source, name)
		if geo.is_empty():
			continue
		var ov: Dictionary = (prefabs.get("overrides", {}) as Dictionary).get(name, {})
		var align := String(ov.get("align", prefabs.get("align", "center_floor")))
		var off := Vector3(float(ov.get("x_offset", 0)), float(ov.get("y_offset", 0)),
				float(ov.get("z_offset", 0)))
		if align == "center_floor":
			var c: Vector3 = geo.aabb.get_center() * scale
			off += Vector3(-c.x, -geo.aabb.position.y * scale, -c.z)
		var xform := Transform3D(Basis.from_scale(Vector3.ONE * scale), off)

		var root := Node3D.new()
		root.name = name.to_pascal_case()
		root.set_script(piece_script)
		root.set("collision_mode", String(ov.get("collision_mode", mode)))

		var model: Node3D = (geo.scene as PackedScene).instantiate()
		model.name = "Model"
		model.transform = xform
		root.add_child(model)
		model.owner = root

		_add_dev_collision(root, mode, geo.pairs, xform, mats)

		var packed := PackedScene.new()
		var path := out_dir.path_join(name + ".tscn")
		if packed.pack(root) != OK or _save_scene_stable(packed, path) != OK:
			_error("%s: failed to save prefab %s" % [kit, path])
		root.free()


func _add_dev_collision(root: Node3D, mode: String, pairs: Array,
		xform: Transform3D, mats: Dictionary) -> void:
	if mode == "none":
		return
	var body := StaticBody3D.new()
	body.name = "DevCollision"
	root.add_child(body)
	body.owner = root
	var shapes: Array[Dictionary] = []
	match mode:
		"box":
			var aabb := _transformed_aabb(pairs, xform)
			var box := BoxShape3D.new()
			box.size = aabb.size
			shapes.append({"shape": box, "xform": Transform3D(Basis.IDENTITY, aabb.get_center())})
		"hull":
			shapes.append({"shape": _merged_mesh(pairs, xform, mats).create_convex_shape(true, true),
					"xform": Transform3D.IDENTITY})
		"multiconvex":
			for s in _decompose(_merged_mesh(pairs, xform, mats)):
				shapes.append({"shape": s, "xform": Transform3D.IDENTITY})
		"weld":
			# dev-play stand-in only; the bake replaces this with the welded body
			shapes.append({"shape": _merged_mesh(pairs, xform, mats).create_trimesh_shape(),
					"xform": Transform3D.IDENTITY})
	for i in shapes.size():
		var cs := CollisionShape3D.new()
		cs.name = "Shape%d" % i
		cs.shape = shapes[i].shape
		cs.transform = shapes[i].xform
		body.add_child(cs)
		cs.owner = root


## V-HACD decomposition for open structures (grandstands, gantries, dock houses);
## falls back to a single hull if the module yields nothing.
func _decompose(mesh: ArrayMesh) -> Array:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	var settings := MeshConvexDecompositionSettings.new()
	settings.max_convex_hulls = 16
	mi.create_multiple_convex_collisions(settings)
	var shapes := []
	for child in mi.get_children():
		for cs in child.get_children():
			if cs is CollisionShape3D and (cs as CollisionShape3D).shape != null:
				shapes.append((cs as CollisionShape3D).shape)
	root.remove_child(mi)
	mi.free()
	if shapes.is_empty():
		shapes.append(mesh.create_convex_shape(true, true))
	return shapes


# -------------------------------------------------------------------- shared

## Load one GLB and flatten it to {scene, pairs: [[Mesh, Transform3D]...], aabb}.
## The AABB is exact (face-based), in unscaled model space.
func _load_geometry(source: String, name: String) -> Dictionary:
	var path := source.path_join(name + ".glb")
	var scene := load(path) as PackedScene
	if scene == null:
		_error("cannot load " + path)
		return {}
	var inst := scene.instantiate()
	var pairs := []
	_collect_meshes(inst, Transform3D.IDENTITY, pairs)
	inst.free()
	if pairs.is_empty():
		_error("no meshes in " + path)
		return {}
	var aabb := AABB()
	var first := true
	for pair: Array in pairs:
		for v in (pair[0] as Mesh).get_faces():
			var w: Vector3 = (pair[1] as Transform3D) * v
			if first:
				aabb = AABB(w, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(w)
	return {"scene": scene, "pairs": pairs, "aabb": aabb}


func _collect_meshes(node: Node, xform: Transform3D, pairs: Array) -> void:
	var nx := xform
	if node is Node3D:
		nx = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		pairs.append([(node as MeshInstance3D).mesh, nx])
	for child in node.get_children():
		_collect_meshes(child, nx, pairs)


## Merge all mesh pairs into one ArrayMesh (one surface per distinct material),
## with `xform` (scale + alignment) applied on top of each node transform.
## Materials are deduped kit-wide and duplicated so outputs never depend on GLBs.
func _merged_mesh(pairs: Array, xform: Transform3D, mats: Dictionary) -> ArrayMesh:
	var groups := {}  # material_key -> SurfaceAccumulator
	for pair: Array in pairs:
		var mesh: Mesh = pair[0]
		var full: Transform3D = xform * (pair[1] as Transform3D)
		for si in mesh.get_surface_count():
			var mat := mesh.surface_get_material(si)
			var mk := Baker.material_key(mat)
			if not mats.has(mk):
				mats[mk] = mat.duplicate() if mat != null else null
			if not groups.has(mk):
				groups[mk] = Baker.SurfaceAccumulator.new()
			(groups[mk] as Baker.SurfaceAccumulator).append(mesh.surface_get_arrays(si), full)
	var out := ArrayMesh.new()
	var keys := groups.keys()
	keys.sort()
	for mk: String in keys:
		(groups[mk] as Baker.SurfaceAccumulator).commit(out, mats[mk])
	return out


func _transformed_aabb(pairs: Array, xform: Transform3D) -> AABB:
	var aabb := AABB()
	var first := true
	for pair: Array in pairs:
		var full: Transform3D = xform * (pair[1] as Transform3D)
		for v in (pair[0] as Mesh).get_faces():
			var w := full * v
			if first:
				aabb = AABB(w, Vector3.ZERO)
				first = false
			else:
				aabb = aabb.expand(w)
	return aabb


## Godot 4.6 stamps a random per-node `unique_id` into every saved scene, so a
## regeneration that changes nothing real would still churn git and flag every
## bake stale. Save, then restore the previous bytes when the only difference is
## those ids — making re-runs of this tool idempotent for unchanged pieces.
var _unique_id_re := RegEx.create_from_string(" unique_id=\\d+")


func _save_scene_stable(packed: PackedScene, path: String) -> Error:
	var before := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var err := ResourceSaver.save(packed, path)
	if err != OK or before.is_empty():
		return err
	var after := FileAccess.get_file_as_string(path)
	if after != before and _unique_id_re.sub(after, "", true) == _unique_id_re.sub(before, "", true):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(before)
	return OK


func _make_dir_for(path: String) -> void:
	DirAccess.open("res://").make_dir_recursive(path.get_base_dir().trim_prefix("res://"))


func _error(msg: String) -> void:
	push_error(msg)
	printerr(msg)
	_exit_code = 1
