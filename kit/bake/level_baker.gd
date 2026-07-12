class_name LevelBaker
extends RefCounted
## The level bake tool (plan §2 rule 1, §4.5). Reads a level's AuthoringRoot subtree
## (GridMap road palettes + KitPiece prefabs + ScatterRegion stored transforms), and
## produces the shipping form:
##  - render: static meshes merged per chunk (tunable chunk_size), one MeshInstance3D
##    per chunk with one surface per distinct material (batching), verts chunk-local;
##  - collision: one StaticBody3D per chunk holding the prefab-authored box/hull
##    shapes, plus ONE level-wide "Drivable" body whose ConcavePolygonShape3D is the
##    vertex-welded union of every drivable surface (road tiles, ramps, bridges,
##    piers) — a drivable structure is never split across bodies, so there are no
##    body-seam ghost collisions (§2 rule 1a);
##  - a manifest JSON stamped with a hash of the authoring inputs so CI can fail on
##    stale bakes (§5.1).
##
## Everything that can be pure is a static fn (weld, chunking, hashing, spawn
## validation) — unit-tested in tests/test_bake.gd, same discipline as Drivetrain.
## The baker never touches the scene tree: transforms are accumulated manually, so
## it runs identically from the editor Bake button and headless CLI scripts.

## Bump when bake semantics change: stale-bake checks treat old-version manifests
## as stale, forcing a re-bake after tool upgrades.
## v4: road extrusion anchors a ring at every interior curve control point (corner miters).
const BAKER_VERSION := 4

## LK5 scatter: items with at least this many stored instances bake as one
## MultiMeshInstance3D per chunk x item (geometry stored once) instead of merging
## their verts into the chunk meshes. ScatterItem.bake_threshold_override overrides
## per item.
const SCATTER_MULTIMESH_THRESHOLD := 64

## Weld snap distance (1 mm): vertices this close become bit-identical, so shared
## tile/ramp edges read as internal edges to Jolt instead of body seams.
const WELD_EPSILON := 0.001

## Extensions hashed as CRLF-normalized text (git/editor line-ending drift must not
## flag a bake stale); everything else is hashed as raw bytes.
const TEXT_EXTS: PackedStringArray = ["tscn", "tres", "json", "gd", "import", "cfg", "md", "txt"]


# ---------------------------------------------------------------- pure helpers

## XZ chunk cell for a piece origin. Pieces are assigned whole by their origin —
## a piece is never split across chunks.
static func chunk_key(origin: Vector3, chunk_size: float) -> Vector2i:
	return Vector2i(floori(origin.x / chunk_size), floori(origin.z / chunk_size))


## World-space origin of a chunk (its MeshInstance3D position; verts are stored
## relative to it for float precision and per-chunk culling AABBs).
static func chunk_origin(key: Vector2i, chunk_size: float) -> Vector3:
	return Vector3(key.x * chunk_size, 0.0, key.y * chunk_size)


## World scatter transforms -> chunk-local (their MultiMeshInstance3D sits at the
## chunk origin, so instance transforms drop the chunk offset — same convention as
## chunk render meshes). Extracted as a pure fn because MultiMesh instance data does
## not read back through the headless RenderingServer, so this is the only way the
## bake's chunk-local placement can be unit-tested (tests/test_bake.gd).
static func chunk_local_multimesh_transforms(world_xforms: Array, key: Vector2i,
		chunk_size: float) -> Array[Transform3D]:
	var to_local := Transform3D(Basis.IDENTITY, -chunk_origin(key, chunk_size))
	var out: Array[Transform3D] = []
	for t in world_xforms:
		out.append(to_local * (t as Transform3D))
	return out


## Weld a triangle soup: snap every vertex to a WELD_EPSILON grid so coincident
## verts become bit-identical, and drop triangles that degenerate. The result is
## what the Drivable body's ConcavePolygonShape3D gets (§2 rule 2: welded, no
## interior seams).
static func weld_faces(faces: PackedVector3Array, epsilon := WELD_EPSILON) -> PackedVector3Array:
	var out := PackedVector3Array()
	var canon := {}
	var tri := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	for i in range(0, faces.size() - 2, 3):
		for j in 3:
			var v := faces[i + j]
			var key := Vector3i(roundi(v.x / epsilon), roundi(v.y / epsilon), roundi(v.z / epsilon))
			if not canon.has(key):
				canon[key] = Vector3(key) * epsilon
			tri[j] = canon[key]
		if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]:
			continue
		out.push_back(tri[0])
		out.push_back(tri[1])
		out.push_back(tri[2])
	return out


## Normalize line endings so the same file hashes the same on Windows and CI.
static func normalize_text(s: String) -> String:
	return s.replace("\r\n", "\n").replace("\r", "\n")


## Hash one file: text formats as normalized text, binaries as raw bytes.
static func hash_file(path: String) -> String:
	if TEXT_EXTS.has(path.get_extension().to_lower()):
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			return "MISSING"
		return normalize_text(f.get_as_text()).sha256_text()
	var h := FileAccess.get_sha256(path)
	return h if h != "" else "MISSING"


## Combined input hash: order-independent over `paths` (sorted internally) plus
## extra tokens (baker version, chunk size). This is the manifest stamp.
static func hash_inputs(paths: PackedStringArray, extra := PackedStringArray()) -> String:
	var sorted := paths.duplicate()
	sorted.sort()
	var lines := PackedStringArray()
	for p in sorted:
		lines.append(p + ":" + hash_file(p))
	for e in extra:
		lines.append(String(e))
	return ("\n".join(lines)).sha256_text()


## Validate the level's spawn coverage (bake gate, plan §4.5). `spawns` is a list of
## {types: PackedStringArray, is_water: bool}; empty types = accepts any. Boats need
## a water spawn, land vehicles a land spawn. Returns human-readable errors.
static func validate_spawns(allowed: PackedStringArray, default_vehicle: String,
		spawns: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	if spawns.is_empty():
		errors.append("level has no VehicleSpawn markers")
		return errors
	if not allowed.is_empty() and not allowed.has(default_vehicle):
		errors.append("default vehicle '%s' is not in allowed_vehicles" % default_vehicle)
	var types := allowed.duplicate()
	if default_vehicle != "" and not types.has(default_vehicle):
		types.append(default_vehicle)
	for t in types:
		var wants_water := t == "boat"
		var found := false
		for s in spawns:
			var st: PackedStringArray = s.get("types", PackedStringArray())
			if (st.is_empty() or st.has(t)) and bool(s.get("is_water", false)) == wants_water:
				found = true
				break
		if not found:
			var kind := "water" if wants_water else "land"
			errors.append("no %s spawn accepts vehicle type '%s'" % [kind, t])
	return errors


## Split one indexed triangle surface into per-chunk sub-surfaces, keyed by the WORLD
## triangle centroid's chunk (LK7 road ribbons: a road is long, so its render mesh is
## bucketed for frustum culling; `world_xform` is applied for KEYING ONLY — the output
## arrays stay in the source space, vertices remapped/deduped per chunk). Render-only:
## collision never splits (the ribbon welds into the single level-wide Drivable body,
## §2 rule 1a). Handles VERTEX/NORMAL/TEX_UV channels; triangle count is conserved.
static func split_arrays_by_chunk(arrays: Array, world_xform: Transform3D,
		chunk_size: float) -> Dictionary:
	var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# regular Arrays (by-reference) during accumulation: Packed*Arrays stored in a
	# Dictionary are value types, so appending through the dict would mutate a copy
	var tri_lists := {}   # Vector2i -> Array of source vertex indices (3 per triangle)
	for i in range(0, idx.size() - 2, 3):
		var centroid := (pos[idx[i]] + pos[idx[i + 1]] + pos[idx[i + 2]]) / 3.0
		var key := chunk_key(world_xform * centroid, chunk_size)
		if not tri_lists.has(key):
			tri_lists[key] = []
		var list: Array = tri_lists[key]
		list.append(idx[i])
		list.append(idx[i + 1])
		list.append(idx[i + 2])

	var src_n: Variant = arrays[Mesh.ARRAY_NORMAL]
	var has_n: bool = src_n is PackedVector3Array \
			and (src_n as PackedVector3Array).size() == pos.size()
	var src_uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
	var has_uv: bool = src_uv is PackedVector2Array \
			and (src_uv as PackedVector2Array).size() == pos.size()

	var out := {}
	for key: Vector2i in tri_lists:
		var remap := {}   # source index -> chunk-local index
		var cpos := PackedVector3Array()
		var cnrm := PackedVector3Array()
		var cuv := PackedVector2Array()
		var cidx := PackedInt32Array()
		for si: int in tri_lists[key]:
			if not remap.has(si):
				remap[si] = cpos.size()
				cpos.append(pos[si])
				if has_n:
					cnrm.append((src_n as PackedVector3Array)[si])
				if has_uv:
					cuv.append((src_uv as PackedVector2Array)[si])
			cidx.append(remap[si])
		var carrays := []
		carrays.resize(Mesh.ARRAY_MAX)
		carrays[Mesh.ARRAY_VERTEX] = cpos
		if has_n:
			carrays[Mesh.ARRAY_NORMAL] = cnrm
		if has_uv:
			carrays[Mesh.ARRAY_TEX_UV] = cuv
		carrays[Mesh.ARRAY_INDEX] = cidx
		out[key] = carrays
	return out


## Semantic material key so identical Kenney materials re-imported per GLB merge
## into one surface instead of one surface per source file.
static func material_key(mat: Material) -> String:
	if mat == null:
		return "null"
	var bm := mat as BaseMaterial3D
	if bm == null:
		return "id:%d" % mat.get_instance_id()
	var texkey := ""
	if bm.albedo_texture != null:
		texkey = bm.albedo_texture.resource_path
		if texkey.is_empty():
			texkey = "texid:%d" % bm.albedo_texture.get_instance_id()
	return "%s|%s|t%d|c%d|v%s" % [texkey, bm.albedo_color.to_html(),
			bm.transparency, bm.cull_mode, bm.vertex_color_use_as_albedo]


# ------------------------------------------------------------ dependency walk

## Every file whose change must flag a bake stale: the level scene itself, its
## transitive dependencies under res://kit/ (prefabs, palettes, GLBs, textures),
## and their .import sidecars. Sorted + deduped for a stable hash.
static func gather_bake_inputs(level_path: String) -> PackedStringArray:
	var seen := {level_path: true}
	var kept := {level_path: true}
	var queue: Array[String] = [level_path]
	while not queue.is_empty():
		var p: String = queue.pop_back()
		for dep in ResourceLoader.get_dependencies(p):
			var dp := _dep_path(String(dep))
			if dp.is_empty() or seen.has(dp):
				continue
			seen[dp] = true
			queue.append(dp)
			if dp.begins_with("res://kit/"):
				kept[dp] = true
	var out := PackedStringArray()
	for p: String in kept:
		out.append(p)
		if FileAccess.file_exists(p + ".import"):
			out.append(p + ".import")
	out.sort()
	return out


## get_dependencies entries look like "uid://xx::type::res://path" (or subsets);
## pull out the res:// path, resolving a bare uid:// if that's all there is.
static func _dep_path(dep: String) -> String:
	var best := ""
	for part in dep.split("::"):
		if part.begins_with("res://"):
			best = part
	if best.is_empty() and dep.begins_with("uid://"):
		var id := ResourceUID.text_to_id(dep.get_slice("::", 0))
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			best = ResourceUID.get_id_path(id)
	return best


# ------------------------------------------------------------------- manifest

static func baked_scene_path(level_path: String) -> String:
	return level_path.get_basename() + ".baked.scn"


static func manifest_path(level_path: String) -> String:
	return level_path.get_basename() + ".bake.json"


## Manifest is deliberately timestamp-free: re-baking unchanged inputs produces a
## byte-identical file (clean git diffs, deterministic CI).
static func write_manifest(level_path: String, input_hash: String, chunk_size: float,
		stats: Dictionary) -> Error:
	var doc := {
		"baker_version": BAKER_VERSION,
		"level": level_path,
		"chunk_size": chunk_size,
		"input_hash": input_hash,
		"stats": stats,
	}
	var f := FileAccess.open(manifest_path(level_path), FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(doc, "\t") + "\n")
	return OK


static func read_manifest(level_path: String) -> Dictionary:
	var f := FileAccess.open(manifest_path(level_path), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## The extra hash tokens stamped alongside the file hashes. chunk_size is included
## so turning the knob flags the bake stale until re-baked.
static func hash_extra(chunk_size: float) -> PackedStringArray:
	return PackedStringArray(["baker_version:%d" % BAKER_VERSION, "chunk_size:%s" % var_to_str(chunk_size)])


# ------------------------------------------------------------ scene discovery

## First AuthoringRoot under `root` (duck-typed marker, see AuthoringRoot); null
## if the level has no kit authoring content.
static func find_authoring(root: Node) -> Node:
	if root.has_method("is_carlito_authoring"):
		return root
	for child in root.get_children():
		var found := find_authoring(child)
		if found != null:
			return found
	return null


## Spawn descriptors for validate_spawns, pulled off VehicleSpawn markers anywhere
## in the level (duck-typed on accepts()).
static func collect_spawn_descriptors(root: Node) -> Array:
	var out := []
	for node in root.find_children("*", "Marker3D", true, false):
		if node.has_method("accepts"):
			out.append({
				"types": node.get("vehicle_types"),
				"is_water": bool(node.get("is_water")),
			})
	return out


## Stale-scatter guard (LK5, shared by the bake gate and check_level_file): a region
## with stored instances whose stored_ground_hash no longer matches the level's
## terrain heightmaps was snapped against ground that has since been sculpted — the
## author must Regenerate in the editor (only that re-snaps), then re-bake. The
## terrain PNGs live beside the level scene, outside gather_bake_inputs' res://kit/
## net, so without this check a sculpt would ship floating/buried props CI-green.
static func scatter_ground_errors(level_root: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	var regions: Array[Node] = []
	_find_scatter_nodes(level_root, regions)
	if regions.is_empty():
		return errors
	var current := String(regions[0].call("ground_hash", level_root))
	for region in regions:
		var total := 0
		for flat in (region.get("stored_transforms") as Array):
			total += int(region.call("stored_count", flat))
		if total == 0:
			continue
		if String(region.get("stored_ground_hash")) != current:
			errors.append("scatter region '%s': terrain changed since it was scattered — Regenerate or Re-snap to ground in the editor, then re-bake" % region.name)
	return errors


static func _find_scatter_nodes(node: Node, out: Array[Node]) -> void:
	if node.has_method("is_carlito_scatter"):
		out.append(node)
	for child in node.get_children():
		_find_scatter_nodes(child, out)


# ----------------------------------------------------------------- bake proper

## Bake the level rooted at `level_root` (an instantiated level scene; it does NOT
## need to be inside a tree). Returns:
##   { ok: bool, errors: PackedStringArray, root: Node3D or null, stats: Dictionary }
## On ok, `root` is the assembled Baked scene root (caller packs + frees it).
static func bake(level_root: Node) -> Dictionary:
	var errors := PackedStringArray()
	var authoring := find_authoring(level_root)
	if authoring == null:
		return _fail(["level has no AuthoringRoot node — nothing to bake"])
	var chunk_size := float(authoring.get("chunk_size"))
	if chunk_size <= 0.0:
		return _fail(["AuthoringRoot.chunk_size must be > 0 (got %s)" % chunk_size])

	# Spawn validation is a bake gate: a level that can't spawn its vehicles must
	# not produce a shippable bake.
	var info: Resource = level_root.get("info")
	var allowed: PackedStringArray = info.get("allowed_vehicles") if info != null else PackedStringArray()
	var default_vehicle := String(info.get("default_vehicle")) if info != null else "car"
	errors.append_array(validate_spawns(allowed, default_vehicle, collect_spawn_descriptors(level_root)))
	# Stale-scatter is a bake gate too (LK5): sculpt-after-scatter must never
	# silently bake floating or buried props.
	errors.append_array(scatter_ground_errors(level_root))

	var ctx := BakeContext.new()
	ctx.chunk_size = chunk_size
	_collect(authoring, _authoring_xform(level_root, authoring), ctx, errors)
	if ctx.total_vertices == 0:
		errors.append("AuthoringRoot has no bakeable content (GridMaps / KitPiece prefabs)")
	if not errors.is_empty():
		return _fail(errors)
	return {"ok": true, "errors": errors, "root": _assemble(ctx), "stats": ctx.stats()}


## Authoring transform relative to the level root, accumulated manually (the level
## instance may not be in a tree, so global_transform is off-limits).
static func _authoring_xform(level_root: Node, authoring: Node) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var node := authoring
	while node != null and node != level_root:
		if node is Node3D:
			xform = (node as Node3D).transform * xform
		node = node.get_parent()
	return xform


static func _fail(errors: PackedStringArray) -> Dictionary:
	return {"ok": false, "errors": errors, "root": null, "stats": {}}


## Recursive gather. GridMap cells are all drivable (palettes hold road tiles only);
## KitPiece prefabs contribute render meshes plus collision per their mode.
static func _collect(node: Node, xform: Transform3D, ctx: BakeContext,
		errors: PackedStringArray) -> void:
	for child in node.get_children():
		var cxform := xform
		if child is Node3D:
			cxform = xform * (child as Node3D).transform
		if child is GridMap:
			_collect_gridmap(child as GridMap, cxform, ctx, errors)
		elif child.has_method("is_carlito_kit_piece"):
			_collect_piece(child, cxform, ctx, errors)
		elif child.has_method("is_carlito_scatter"):
			_collect_scatter(child, cxform, ctx, errors)
		elif child.has_method("is_carlito_road"):
			_collect_road(child, cxform, ctx, errors)
		else:
			_collect(child, cxform, ctx, errors)


static func _collect_gridmap(gm: GridMap, xform: Transform3D, ctx: BakeContext,
		errors: PackedStringArray) -> void:
	var ml := gm.mesh_library
	if ml == null:
		errors.append("GridMap '%s' has no MeshLibrary" % gm.name)
		return
	var cells := gm.get_used_cells()
	cells.sort()  # deterministic bake output
	for cell: Vector3i in cells:
		var item := gm.get_cell_item(cell)
		var mesh := ml.get_item_mesh(item)
		if mesh == null:
			continue
		var basis := gm.get_basis_with_orthogonal_index(gm.get_cell_item_orientation(cell))
		var cell_xform := xform * Transform3D(basis, gm.map_to_local(cell))
		var mesh_xform := cell_xform * ml.get_item_mesh_transform(item)
		var key := chunk_key(cell_xform.origin, ctx.chunk_size)
		ctx.add_render_mesh(key, mesh, mesh_xform)
		ctx.add_weld_mesh(mesh, mesh_xform)


static func _collect_piece(piece: Node, xform: Transform3D, ctx: BakeContext,
		errors: PackedStringArray) -> void:
	var mode := String(piece.get("collision_mode"))
	var key := chunk_key(xform.origin, ctx.chunk_size)
	_collect_piece_content(piece, xform, key, mode, ctx, errors)


static func _collect_piece_content(node: Node, xform: Transform3D, key: Vector2i,
		mode: String, ctx: BakeContext, errors: PackedStringArray) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			ctx.add_render_mesh(key, mi.mesh, xform)
			if mode == "weld":
				ctx.add_weld_mesh(mi.mesh, xform)
	elif node is CollisionShape3D and mode in ["box", "hull", "multiconvex"]:
		var cs := node as CollisionShape3D
		if cs.shape != null:
			ctx.add_body_shape(key, cs.shape, xform)
	for child in node.get_children():
		var cxform := xform
		if child is Node3D:
			cxform = xform * (child as Node3D).transform
		_collect_piece_content(child, cxform, key, mode, ctx, errors)


## LK5 scatter (plan §4 LK5): consume the region's STORED transforms only — no
## expansion, no raycast, no physics here, so editor and bake can never diverge.
## Per item: at or above the MultiMesh threshold the render side becomes chunked
## MultiMeshes over ONE merged item mesh (an island forest never duplicates its
## verts into chunk meshes); below it every instance routes through the existing
## prefab merge path. Collision harvest is identical either way: the prefab's
## shapes per instance into the per-chunk bodies (collision-off items add zero
## physics). All prefab-shaped logic is duck-called on the region's script
## (stored_transform / build_item_mesh / shape_entries) so the stored layout has
## one owner.
static func _collect_scatter(region: Node, xform: Transform3D, ctx: BakeContext,
		errors: PackedStringArray) -> void:
	var items: Array = region.get("items")
	var stored: Array = region.get("stored_transforms")
	for i in items.size():
		var item: Resource = items[i]
		if item == null or item.get("prefab") == null or i >= stored.size():
			continue
		var flat: PackedFloat32Array = stored[i]
		var count := int(region.call("stored_count", flat))
		if count == 0:
			continue
		var template: Node = (item.get("prefab") as PackedScene).instantiate()
		var mode := "none"
		if template.has_method("is_carlito_kit_piece"):
			mode = String(template.get("collision_mode"))
		if mode == "weld":
			errors.append("scatter region '%s' item %d: weld-mode prefabs cannot be scattered (drivable structures are placed, never scattered)" % [region.name, i])
			template.free()
			continue
		var use_collision: bool = bool(item.get("collision")) and mode != "none"
		var threshold := int(item.get("bake_threshold_override"))
		if threshold < 0:
			threshold = SCATTER_MULTIMESH_THRESHOLD

		var xforms: Array[Transform3D] = []
		for j in count:
			xforms.append(xform * (region.call("stored_transform", flat, j) as Transform3D))
		ctx.scatter_instances += count

		if count >= threshold:
			var mesh: ArrayMesh = region.call("build_item_mesh", template)
			# Swap the prefab's materials for the bake's deduplicated copies, so the
			# baked scene never references kit resources (same rule as chunk merges).
			for si in mesh.get_surface_count():
				var mat := mesh.surface_get_material(si)
				var mk := material_key(mat)
				if not ctx.materials.has(mk):
					ctx.materials[mk] = mat.duplicate() if mat != null else null
				mesh.surface_set_material(si, ctx.materials[mk])
				ctx.total_vertices += (mesh.surface_get_arrays(si)[Mesh.ARRAY_VERTEX]
						as PackedVector3Array).size()
			var mesh_index := ctx.add_scatter_mesh(mesh)
			var entries: Array = region.call("shape_entries", template) if use_collision else []
			for t in xforms:
				var key := chunk_key(t.origin, ctx.chunk_size)
				ctx.add_multimesh(key, mesh_index, t)
				for entry: Array in entries:
					ctx.add_body_shape(key, entry[0], t * (entry[1] as Transform3D))
		else:
			for t in xforms:
				_collect_piece_content(template, t, chunk_key(t.origin, ctx.chunk_size),
						mode if use_collision else "none", ctx, errors)
		template.free()


## LK7 spline road: duck-call the RoadPath's geometry API (ribbon_surfaces /
## ribbon_faces — the stored layout has one owner, and both depend only on the
## serialized Path child + profile, so they work on the baker's untreed instance).
## Render surfaces are chunk-bucketed by triangle centroid for frustum culling;
## collision is NOT split — every ribbon triangle joins the level-wide welded
## Drivable body through the same 1 mm snap as weld prefabs (§2 rule 1a). No
## recursion into the road: Preview/DevCollision never exist off-tree, and the
## Path child carries no bakeable content of its own.
static func _collect_road(road: Node, xform: Transform3D, ctx: BakeContext,
		errors: PackedStringArray) -> void:
	if road.get("profile") == null:
		errors.append("RoadPath '%s' has no profile — assign one from kit/roads/" % road.name)
		return
	var entries: Array = road.call("ribbon_surfaces")
	if entries.is_empty():
		errors.append("RoadPath '%s' has no usable curve (needs at least 2 points)" % road.name)
		return
	for e: Dictionary in entries:
		var buckets := split_arrays_by_chunk(e.arrays, xform, ctx.chunk_size)
		for key: Vector2i in buckets:
			ctx.add_render_arrays(key, e.material, buckets[key], xform)
	ctx.add_weld_faces(road.call("ribbon_faces"), xform)
	ctx.roads += 1


## Assemble the Baked scene: Chunks/ (merged render meshes), Bodies/ (one
## StaticBody3D per chunk with the harvested shapes), Drivable (the single welded
## body). Everything the scene stores is duplicated so the bake has zero
## dependencies on kit prefabs, palettes, or GLBs (they're export-stripped).
static func _assemble(ctx: BakeContext) -> Node3D:
	var root := Node3D.new()
	root.name = "Baked"

	var chunks := Node3D.new()
	chunks.name = "Chunks"
	root.add_child(chunks)
	var chunk_keys := ctx.render.keys()
	chunk_keys.sort()
	for key: Vector2i in chunk_keys:
		var mesh := ArrayMesh.new()
		var groups: Dictionary = ctx.render[key]
		var mat_keys := groups.keys()
		mat_keys.sort()
		for mk: String in mat_keys:
			var acc: SurfaceAccumulator = groups[mk]
			acc.commit(mesh, ctx.materials[mk])
		var mi := MeshInstance3D.new()
		mi.name = "chunk_%d_%d" % [key.x, key.y]
		mi.mesh = mesh
		mi.position = chunk_origin(key, ctx.chunk_size)
		chunks.add_child(mi)

	if not ctx.body_shapes.is_empty():
		var bodies := Node3D.new()
		bodies.name = "Bodies"
		root.add_child(bodies)
		var body_keys := ctx.body_shapes.keys()
		body_keys.sort()
		for key: Vector2i in body_keys:
			var body := StaticBody3D.new()
			body.name = "body_%d_%d" % [key.x, key.y]
			bodies.add_child(body)
			for entry: Array in ctx.body_shapes[key]:
				var cs := CollisionShape3D.new()
				cs.shape = (entry[0] as Shape3D).duplicate()
				cs.transform = entry[1]
				body.add_child(cs)

	if not ctx.multimesh.is_empty():
		var scatter := Node3D.new()
		scatter.name = "Scatter"
		root.add_child(scatter)
		var mm_keys := ctx.multimesh.keys()
		mm_keys.sort()
		for key: Vector2i in mm_keys:
			var groups: Dictionary = ctx.multimesh[key]
			var mesh_ids := groups.keys()
			mesh_ids.sort()
			for mid: int in mesh_ids:
				var list: Array = groups[mid]
				var locals := chunk_local_multimesh_transforms(list, key, ctx.chunk_size)
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = ctx.scatter_meshes[mid]
				mm.instance_count = locals.size()
				for j in locals.size():
					mm.set_instance_transform(j, locals[j])
				var mmi := MultiMeshInstance3D.new()
				mmi.name = "scatter_%d_%d_%d" % [mid, key.x, key.y]
				mmi.multimesh = mm
				mmi.position = chunk_origin(key, ctx.chunk_size)
				scatter.add_child(mmi)

	if not ctx.weld_pool.is_empty():
		var drivable := StaticBody3D.new()
		drivable.name = "Drivable"
		root.add_child(drivable)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(weld_faces(ctx.weld_pool))
		var cs := CollisionShape3D.new()
		cs.name = "WeldedCollision"
		cs.shape = shape
		drivable.add_child(cs)

	_own_recursive(root, root)
	return root


static func _own_recursive(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own_recursive(child, owner_node)


# ------------------------------------------------------------------ save + check

## Full bake for a level scene file: load, bake, save the .scn, stamp the manifest,
## and verify the saved bake leaked no kit dependencies. Returns
## {ok, errors, stats}. This is the one entry point the editor button and the CLI
## tools share.
static func bake_level_file(level_path: String) -> Dictionary:
	var packed := load(level_path) as PackedScene
	if packed == null:
		return _fail(["cannot load level scene '%s'" % level_path])
	var level_root := packed.instantiate()
	var result := bake(level_root)
	var chunk_size := 0.0
	var authoring := find_authoring(level_root)
	if authoring != null:
		chunk_size = float(authoring.get("chunk_size"))
	level_root.free()
	if not result.ok:
		return result

	var baked_root: Node3D = result.root
	var out := PackedScene.new()
	var errors := PackedStringArray()
	if out.pack(baked_root) != OK:
		errors.append("failed to pack baked scene")
	else:
		var scn := baked_scene_path(level_path)
		var err := ResourceSaver.save(out, scn)
		if err != OK:
			errors.append("failed to save '%s' (error %d)" % [scn, err])
		else:
			for dep in ResourceLoader.get_dependencies(scn):
				var dp := _dep_path(String(dep))
				if dp.ends_with(".glb") or dp.contains("/kit/prefabs/") or dp.contains("/kit/palettes/"):
					errors.append("baked scene leaked authoring dependency: %s" % dp)
	baked_root.free()
	if errors.is_empty():
		var input_hash := hash_inputs(gather_bake_inputs(level_path), hash_extra(chunk_size))
		if write_manifest(level_path, input_hash, chunk_size, result.stats) != OK:
			errors.append("failed to write manifest '%s'" % manifest_path(level_path))
	if not errors.is_empty():
		return _fail(errors)
	return {"ok": true, "errors": errors, "stats": result.stats}


## Freshness check for CI (§5.1): "fresh" | "stale" | "missing" for a level that has
## kit authoring content, "no_authoring" for levels the bake doesn't apply to.
static func check_level_file(level_path: String) -> Dictionary:
	var packed := load(level_path) as PackedScene
	if packed == null:
		return {"status": "error", "detail": "cannot load level scene '%s'" % level_path}
	var level_root := packed.instantiate()
	var authoring := find_authoring(level_root)
	# read everything BEFORE freeing the tree: a freed node compares equal to null
	var has_authoring := authoring != null
	var chunk_size := float(authoring.get("chunk_size")) if has_authoring else 0.0
	var scatter_errors := scatter_ground_errors(level_root)
	level_root.free()
	if not has_authoring:
		return {"status": "no_authoring", "detail": ""}

	var manifest := read_manifest(level_path)
	if manifest.is_empty() or not FileAccess.file_exists(baked_scene_path(level_path)):
		return {"status": "missing", "detail": "no bake output — run the bake tool"}
	if int(manifest.get("baker_version", -1)) != BAKER_VERSION:
		return {"status": "stale", "detail": "baked with baker v%s, current v%d" %
				[manifest.get("baker_version"), BAKER_VERSION]}
	var current := hash_inputs(gather_bake_inputs(level_path), hash_extra(chunk_size))
	if String(manifest.get("input_hash", "")) != current:
		return {"status": "stale", "detail": "authoring inputs changed since last bake"}
	# Terrain PNGs sit outside the input hash's res://kit/ net, so stale scatter needs
	# its own check (and Regenerate — not just a re-bake — clears it).
	if not scatter_errors.is_empty():
		return {"status": "stale", "detail": scatter_errors[0]}
	return {"status": "fresh", "detail": ""}


# --------------------------------------------------------------- inner classes

## Accumulates everything one bake collects before assembly.
class BakeContext:
	var chunk_size := 48.0
	## Vector2i chunk key -> { material_key: SurfaceAccumulator }
	var render := {}
	## material_key -> duplicated Material stored in the baked scene
	var materials := {}
	## Vector2i chunk key -> Array of [Shape3D, Transform3D]
	var body_shapes := {}
	## world-space triangle soup for the single welded drivable body
	var weld_pool := PackedVector3Array()
	var total_vertices := 0
	## LK5 scatter: merged item meshes, geometry stored ONCE (shared across chunks)
	var scatter_meshes: Array[ArrayMesh] = []
	## Vector2i chunk key -> { mesh index -> Array of world Transform3D }
	var multimesh := {}
	var scatter_instances := 0
	## LK7 spline roads collected
	var roads := 0

	func add_render_mesh(key: Vector2i, mesh: Mesh, world_xform: Transform3D) -> void:
		for si in mesh.get_surface_count():
			add_render_arrays(key, mesh.surface_get_material(si),
					mesh.surface_get_arrays(si), world_xform)

	## One raw surface into a chunk's per-material accumulator — the shared dedup/merge
	## path add_render_mesh loops through, and what LK7 road ribbons (already split into
	## per-chunk arrays) feed directly.
	func add_render_arrays(key: Vector2i, mat: Material, arrays: Array,
			world_xform: Transform3D) -> void:
		var local := Transform3D(Basis.IDENTITY, -LevelBaker.chunk_origin(key, chunk_size)) * world_xform
		if not render.has(key):
			render[key] = {}
		var groups: Dictionary = render[key]
		var mk := LevelBaker.material_key(mat)
		if not materials.has(mk):
			materials[mk] = mat.duplicate() if mat != null else null
		if not groups.has(mk):
			groups[mk] = SurfaceAccumulator.new()
		(groups[mk] as SurfaceAccumulator).append(arrays, local)
		total_vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()

	func add_weld_mesh(mesh: Mesh, world_xform: Transform3D) -> void:
		for face in mesh.get_faces():
			weld_pool.push_back(world_xform * face)

	## A pre-built triangle soup into the level-wide weld pool (LK7 road ribbons).
	func add_weld_faces(faces: PackedVector3Array, world_xform: Transform3D) -> void:
		for v in faces:
			weld_pool.push_back(world_xform * v)

	func add_body_shape(key: Vector2i, shape: Shape3D, world_xform: Transform3D) -> void:
		if not body_shapes.has(key):
			body_shapes[key] = []
		(body_shapes[key] as Array).append([shape, world_xform])

	func add_scatter_mesh(mesh: ArrayMesh) -> int:
		scatter_meshes.append(mesh)
		return scatter_meshes.size() - 1

	func add_multimesh(key: Vector2i, mesh_index: int, world_xform: Transform3D) -> void:
		if not multimesh.has(key):
			multimesh[key] = {}
		var groups: Dictionary = multimesh[key]
		if not groups.has(mesh_index):
			groups[mesh_index] = []
		(groups[mesh_index] as Array).append(world_xform)

	func stats() -> Dictionary:
		var surfaces := 0
		for key: Vector2i in render:
			surfaces += (render[key] as Dictionary).size()
		var shape_count := 0
		for key: Vector2i in body_shapes:
			shape_count += (body_shapes[key] as Array).size()
		var multimesh_count := 0
		for key: Vector2i in multimesh:
			multimesh_count += (multimesh[key] as Dictionary).size()
		return {
			"chunks": render.size(),
			"surfaces": surfaces,
			"vertices": total_vertices,
			"bodies": body_shapes.size(),
			"shapes": shape_count,
			"drivable_triangles": weld_pool.size() / 3,
			"scatter_instances": scatter_instances,
			"scatter_multimeshes": multimesh_count,
			"roads": roads,
		}


## Merges mesh surfaces that share a material into one surface, applying transforms
## at array level: positions by the full transform, normals rotated by the
## inverse-transpose basis and re-normalized (correct under the uniform scales the
## kit uses — SurfaceTool.append_from leaves scaled normals unnormalized).
class SurfaceAccumulator:
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var has_uv := false
	var has_color := false

	func append(arrays: Array, xform: Transform3D) -> void:
		var src_pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var base := positions.size()
		for v in src_pos:
			positions.push_back(xform * v)

		var nbasis := xform.basis.inverse().transposed()
		var src_n: Variant = arrays[Mesh.ARRAY_NORMAL]
		if src_n is PackedVector3Array and (src_n as PackedVector3Array).size() == src_pos.size():
			for n: Vector3 in src_n:
				normals.push_back((nbasis * n).normalized())
		else:
			for i in src_pos.size():
				normals.push_back(Vector3.UP)

		var src_uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var uv_ok: bool = src_uv is PackedVector2Array \
				and (src_uv as PackedVector2Array).size() == src_pos.size()
		if uv_ok and not has_uv:
			has_uv = true
			uvs.resize(base)  # zero-fill vertices appended before UVs appeared
		if has_uv:
			if uv_ok:
				uvs.append_array(src_uv)
			else:
				uvs.resize(uvs.size() + src_pos.size())

		var src_col: Variant = arrays[Mesh.ARRAY_COLOR]
		var col_ok: bool = src_col is PackedColorArray \
				and (src_col as PackedColorArray).size() == src_pos.size()
		if col_ok and not has_color:
			has_color = true
			for i in base:
				colors.push_back(Color.WHITE)
		if has_color:
			if col_ok:
				colors.append_array(src_col)
			else:
				for i in src_pos.size():
					colors.push_back(Color.WHITE)

		var src_idx: Variant = arrays[Mesh.ARRAY_INDEX]
		if src_idx is PackedInt32Array and (src_idx as PackedInt32Array).size() > 0:
			for ix: int in src_idx:
				indices.push_back(base + ix)
		else:
			for i in src_pos.size():
				indices.push_back(base + i)

	func commit(mesh: ArrayMesh, material: Material) -> int:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = positions
		arrays[Mesh.ARRAY_NORMAL] = normals
		if has_uv:
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		if has_color:
			arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var si := mesh.get_surface_count() - 1
		if material != null:
			mesh.surface_set_material(si, material)
		return si
