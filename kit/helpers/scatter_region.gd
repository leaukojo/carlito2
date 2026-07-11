@tool
class_name ScatterRegion
extends Node3D
## Seeded procedural fill region (level_kit_plan.md §4 LK5). Placed under the level's
## AuthoringRoot; fills a box/polygon footprint with weighted kit prefabs.
##
## The stored-transform contract (the LK5 non-negotiable): expansion happens exactly
## once, in the editor Regenerate button — it runs the pure seeded placement,
## ground-snaps every instance against the live edited scene, and STORES the final
## region-local transforms in the scene (one compact packed array per item). The baker
## and dev-play only ever consume the stored transforms — no raycast, no expansion, no
## physics outside this file's editor path — so editor and bake can never diverge, and
## the CI hash story is just "transforms live in the .tscn".
##
## Stale-scatter guard: Regenerate also stores a hash of every terrain heightmap in the
## level. On mismatch the node shows a configuration warning, LevelBaker refuses to
## bake, and check_bakes reports the level stale — sculpt-after-scatter can never
## silently bake floating or buried props (decision recorded in the LK5 plan).
##
## Pure logic (placement, area, hashes, stride-5 decode) is static and unit-tested in
## tests/test_scatter.gd; everything the baker touches here runs editor-free.

## Stored-transform layout: 5 floats per instance (x, y, z, yaw, uniform scale),
## region-local. 500 trees ~ 10 KB of scene text.
const STRIDE := 5
## Rejection-sampling budget: attempts per requested instance before giving up
## (dense + tightly spaced regions fill to less than the density target).
const ATTEMPTS_PER_TARGET := 8
const RAY_UP := 1000.0

# Footprint setters poke the editor gizmo (addons/carlito_kit/scatter_gizmo.gd
# draws the border while the node is selected); update_gizmos is a no-op in game.
@export_enum("box", "polygon") var footprint_kind := "box":
	set(value):
		footprint_kind = value
		update_gizmos()
## Box footprint: full X/Z extent, centred on the node origin (region-local).
@export var box_size := Vector2(32, 32):
	set(value):
		box_size = value
		update_gizmos()
## Polygon footprint: region-local XZ vertices (CW or CCW, may be concave).
@export var polygon := PackedVector2Array():
	set(value):
		polygon = value
		update_gizmos()

@export_group("Placement")
## Target instances per square metre (spacing may cap the reachable count).
@export var density := 0.05
## Minimum XZ distance between any two instances (all items). 0 disables.
@export var min_spacing := 2.0
@export var placement_seed := 0
## Total random yaw range, centred on 0 (360 = any facing).
@export_range(0.0, 360.0) var yaw_jitter_deg := 360.0
## Uniform scale jitter: each instance picks a scale in [x, y].
@export var scale_range := Vector2(0.85, 1.15)
## Instances landing on ground steeper than this are dropped.
@export_range(0.0, 89.0) var max_slope_deg := 30.0

@export var items: Array[ScatterItem] = []:
	set(value):
		items = value
		_rebuild_preview_if_ready()
		if Engine.is_editor_hint():
			update_configuration_warnings()

@warning_ignore("unused_private_class_variable")
@export_tool_button("Regenerate (expands + snaps + stores)") var _regen_action := _regenerate

## Regenerate's output — the ONLY thing dev-play and the baker read. Index-matched to
## `items`; each entry is STRIDE floats per instance, region-local. Serialized (that is
## the point) but hidden from the inspector.
@export_storage var stored_transforms: Array[PackedFloat32Array] = []:
	set(value):
		stored_transforms = value
		_rebuild_preview_if_ready()
		if Engine.is_editor_hint():
			_refresh_stale()
## ground_hash() of the level at the moment Regenerate snapped — the stale guard.
@export_storage var stored_ground_hash := "":
	set(value):
		stored_ground_hash = value
		if Engine.is_editor_hint():
			_refresh_stale()

var _stale := false
var _stale_accum := 0.0


## Duck-typing marker: the baker detects scatter nodes via has_method() so CLI runs
## never depend on class_name cache state (same contract as is_carlito_kit_piece).
func is_carlito_scatter() -> bool:
	return true


func _ready() -> void:
	_rebuild_preview()
	if Engine.is_editor_hint():
		_refresh_stale()
		update_configuration_warnings()
	else:
		set_process(false)


# --------------------------------------------------------------- pure placement

## Deterministic seeded placement (pure static, unit-tested): rejection-sample points
## into the polygon with a min-spacing guarantee, assigning each accepted point a
## weighted item, a yaw and a uniform scale. Same params = bit-identical output.
## params: polygon (PackedVector2Array), density, min_spacing, seed,
##         weights (PackedFloat32Array, one per item), yaw_jitter_deg,
##         scale_min, scale_max.
## Returns one PackedFloat32Array per item, 4 floats per instance (x, z, yaw, scale).
static func generate_placements(params: Dictionary) -> Array[PackedFloat32Array]:
	var weights: PackedFloat32Array = params.get("weights", PackedFloat32Array())
	var out: Array[PackedFloat32Array] = []
	for i in weights.size():
		out.append(PackedFloat32Array())
	var poly: PackedVector2Array = params.get("polygon", PackedVector2Array())
	var area := polygon_area(poly)
	var density_v := float(params.get("density", 0.0))
	if weights.is_empty() or area <= 0.0 or density_v <= 0.0:
		return out
	var total_weight := 0.0
	for w in weights:
		total_weight += maxf(w, 0.0)
	if total_weight <= 0.0:
		return out

	var spacing := float(params.get("min_spacing", 0.0))
	var yaw_jitter := deg_to_rad(float(params.get("yaw_jitter_deg", 360.0)))
	var scale_min := float(params.get("scale_min", 1.0))
	var scale_max := float(params.get("scale_max", 1.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(params.get("seed", 0))

	var bmin := poly[0]
	var bmax := poly[0]
	for p in poly:
		bmin = bmin.min(p)
		bmax = bmax.max(p)

	var target := int(round(area * density_v))
	var accepted := 0
	# Spatial hash with cell = spacing: any point closer than `spacing` must sit in
	# one of the 3x3 neighbouring cells, so the check is O(1) per attempt.
	var grid := {}
	for _attempt in target * ATTEMPTS_PER_TARGET:
		if accepted >= target:
			break
		var p := Vector2(rng.randf_range(bmin.x, bmax.x), rng.randf_range(bmin.y, bmax.y))
		if not Geometry2D.is_point_in_polygon(p, poly):
			continue
		if spacing > 0.0 and not _spacing_ok(p, spacing, grid):
			continue
		var idx := weights.size() - 1
		var pick := rng.randf() * total_weight
		for i in weights.size():
			pick -= maxf(weights[i], 0.0)
			if pick <= 0.0:
				idx = i
				break
		var yaw := rng.randf_range(-0.5, 0.5) * yaw_jitter
		var scl := rng.randf_range(scale_min, scale_max)
		out[idx].append_array(PackedFloat32Array([p.x, p.y, yaw, scl]))
		if spacing > 0.0:
			var key := Vector2i(floori(p.x / spacing), floori(p.y / spacing))
			if not grid.has(key):
				grid[key] = PackedVector2Array()
			grid[key].append(p)
		accepted += 1
	return out


static func _spacing_ok(p: Vector2, spacing: float, grid: Dictionary) -> bool:
	var cell := Vector2i(floori(p.x / spacing), floori(p.y / spacing))
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var key := cell + Vector2i(dx, dz)
			if not grid.has(key):
				continue
			for q: Vector2 in grid[key]:
				if p.distance_to(q) < spacing:
					return false
	return true


## Shoelace area of a simple polygon (absolute; winding-agnostic).
static func polygon_area(points: PackedVector2Array) -> float:
	if points.size() < 3:
		return 0.0
	var twice := 0.0
	for i in points.size():
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		twice += a.x * b.y - b.x * a.y
	return absf(twice) * 0.5


## Decode one stored stride-5 instance into a region-local Transform3D
## (yaw around Y, uniform scale). The single source of truth for the stored layout —
## preview, dev collision, and the baker all go through it.
static func stored_transform(flat: PackedFloat32Array, index: int) -> Transform3D:
	var o := index * STRIDE
	var basis := Basis(Vector3.UP, flat[o + 3]).scaled(Vector3.ONE * flat[o + 4])
	return Transform3D(basis, Vector3(flat[o], flat[o + 1], flat[o + 2]))


static func stored_count(flat: PackedFloat32Array) -> int:
	return flat.size() / STRIDE


# ------------------------------------------------------------- ground hashing

## Hash of every terrain heightmap under `root` (walk order, so deterministic per
## scene): image dims + bytes, plus the node's name/position/size/height amplitude —
## anything that moves the ground an instance was snapped to. Off-tree safe (no
## global transforms), so LevelBaker can call it on an instantiated, untreed level.
## Empty string when the level has no terrain.
static func ground_hash(root: Node) -> String:
	var terrains: Array[Node] = []
	_find_terrains_under(root, terrains)
	if terrains.is_empty():
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for t in terrains:
		var header := "%s|%s|%s|%s" % [t.name, var_to_str((t as Node3D).position),
				var_to_str(t.get("terrain_size")), var_to_str(t.get("height"))]
		ctx.update(header.to_utf8_buffer())
		var tex: Texture2D = t.get("heightmap")
		var img := tex.get_image() if tex != null else null
		if img == null:
			ctx.update("null".to_utf8_buffer())
			continue
		if img.is_compressed():
			img = img.duplicate()
			img.decompress()
		ctx.update(("%dx%d" % [img.get_width(), img.get_height()]).to_utf8_buffer())
		ctx.update(img.get_data())
	return ctx.finish().hex_encode()


## HeightmapTerrain nodes by duck type (height_at + contains_xz), never class_name
## (the CLI-robustness rule the whole kit follows).
static func _find_terrains_under(node: Node, out: Array[Node]) -> void:
	if node is Node3D and node.has_method("height_at") and node.has_method("contains_xz"):
		out.append(node)
	for child in node.get_children():
		_find_terrains_under(child, out)


# ----------------------------------------------------------- item mesh building

## Merge a prefab's render meshes (prefab-local space) into one ArrayMesh, one surface
## per distinct material — the mesh a MultiMesh stores ONCE per item. Used by the
## editor/dev preview and duck-called by the baker, so both render the identical mesh.
## Surfaces keep the prefab's original materials; the baker swaps in its deduplicated
## copies so the baked scene never references kit resources.
static func build_item_mesh(prefab_root: Node) -> ArrayMesh:
	var groups := {}   # material_key -> SurfaceAccumulator
	var mats := {}     # material_key -> Material
	var order: Array[String] = []
	_accumulate_item_meshes(prefab_root, Transform3D.IDENTITY, groups, mats, order)
	var mesh := ArrayMesh.new()
	for mk in order:
		(groups[mk] as LevelBaker.SurfaceAccumulator).commit(mesh, mats[mk])
	return mesh


static func _accumulate_item_meshes(node: Node, xform: Transform3D, groups: Dictionary,
		mats: Dictionary, order: Array[String]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var src := (node as MeshInstance3D).mesh
		for si in src.get_surface_count():
			var mat := src.surface_get_material(si)
			var mk := LevelBaker.material_key(mat)
			if not groups.has(mk):
				groups[mk] = LevelBaker.SurfaceAccumulator.new()
				mats[mk] = mat
				order.append(mk)
			(groups[mk] as LevelBaker.SurfaceAccumulator).append(src.surface_get_arrays(si), xform)
	for child in node.get_children():
		var cxform := xform
		if child is Node3D:
			cxform = xform * (child as Node3D).transform
		_accumulate_item_meshes(child, cxform, groups, mats, order)


## Every CollisionShape3D under a prefab as [Shape3D, prefab-local Transform3D] pairs —
## the shared harvest for dev collision here and the baked chunk bodies (duck-called by
## LevelBaker so collision is identical either way).
static func shape_entries(prefab_root: Node) -> Array:
	var out: Array = []
	_gather_shapes(prefab_root, Transform3D.IDENTITY, out)
	return out


static func _gather_shapes(node: Node, xform: Transform3D, out: Array) -> void:
	if node is CollisionShape3D and (node as CollisionShape3D).shape != null:
		out.append([(node as CollisionShape3D).shape, xform])
	for child in node.get_children():
		var cxform := xform
		if child is Node3D:
			cxform = xform * (child as Node3D).transform
		_gather_shapes(child, cxform, out)


# --------------------------------------------------- preview / dev-play rendering

func _rebuild_preview_if_ready() -> void:
	if is_inside_tree():
		_rebuild_preview()


## Rebuild the unowned preview subtree from the STORED transforms (never serialized —
## the HeightmapTerrain Chunks discipline): one MultiMeshInstance3D per item; in
## dev-play (not the editor) also one StaticBody3D per collision-on item holding the
## prefab's shapes per instance, so unbaked levels are drivable. The editor gets
## visuals only, which keeps Regenerate's raycasts from hitting our own instances.
func _rebuild_preview() -> void:
	var old := get_node_or_null(^"Preview")
	if old != null:
		old.free()
	var preview := Node3D.new()
	preview.name = "Preview"
	add_child(preview)
	for i in items.size():
		var item := items[i]
		if item == null or item.prefab == null or i >= stored_transforms.size():
			continue
		var flat := stored_transforms[i]
		var count := stored_count(flat)
		if count == 0:
			continue
		var template := item.prefab.instantiate()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = build_item_mesh(template)
		mm.instance_count = count
		for j in count:
			mm.set_instance_transform(j, stored_transform(flat, j))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Item%d" % i
		mmi.multimesh = mm
		preview.add_child(mmi)

		# Mirror the baker's use_collision rule (LevelBaker._collect_scatter) exactly so
		# dev-play and the bake can never diverge: only box/hull/multiconvex prefabs get
		# dev collision (weld is a bake error, none has no shapes).
		var mode := "none"
		if template.has_method("is_carlito_kit_piece"):
			mode = String(template.get("collision_mode"))
		if not Engine.is_editor_hint() and item.collision and mode in ["box", "hull", "multiconvex"]:
			var entries := shape_entries(template)
			if not entries.is_empty():
				var body := StaticBody3D.new()
				body.name = "Item%dCollision" % i
				preview.add_child(body)
				for j in count:
					var inst := stored_transform(flat, j)
					for entry: Array in entries:
						var cs := CollisionShape3D.new()
						cs.shape = entry[0]
						cs.transform = inst * (entry[1] as Transform3D)
						body.add_child(cs)
		template.free()


# ------------------------------------------------------- Regenerate (editor only)

## The one expansion site (plan LK5): pure placement -> ground snap against the live
## edited scene -> slope filter -> store region-local transforms + the ground hash,
## all as one undoable action.
func _regenerate() -> void:
	if not Engine.is_editor_hint():
		return
	if _find_authoring_ancestor() == null:
		push_warning("ScatterRegion: place the region under the level's AuthoringRoot before regenerating.")
		return
	if items.is_empty():
		push_warning("ScatterRegion: add at least one ScatterItem first.")
		return

	var placements := generate_placements(build_params())
	var level_root := owner if owner != null else self
	var terrains: Array[Node] = []
	_find_terrains_under(level_root, terrains)
	var space := get_world_3d().direct_space_state
	var cos_max := cos(deg_to_rad(max_slope_deg))
	var inv := global_transform.affine_inverse()

	var new_stored: Array[PackedFloat32Array] = []
	var dropped := 0
	for i in placements.size():
		var flat := placements[i]
		var stored := PackedFloat32Array()
		for j in flat.size() / 4:
			var o := j * 4
			var world := global_transform * Vector3(flat[o], 0.0, flat[o + 1])
			var hit := _snap_ground(space, terrains, world)
			if hit.is_empty() or (hit.normal as Vector3).y < cos_max:
				dropped += 1
				continue
			var local: Vector3 = inv * (hit.position as Vector3)
			stored.append_array(PackedFloat32Array(
					[local.x, local.y, local.z, flat[o + 2], flat[o + 3]]))
		new_stored.append(stored)

	var new_hash := ground_hash(level_root)
	var undo_redo: EditorUndoRedoManager = \
			Engine.get_singleton(&"EditorInterface").get_editor_undo_redo()
	undo_redo.create_action("Regenerate scatter '%s'" % name)
	undo_redo.add_do_property(self, &"stored_transforms", new_stored)
	undo_redo.add_undo_property(self, &"stored_transforms", stored_transforms)
	undo_redo.add_do_property(self, &"stored_ground_hash", new_hash)
	undo_redo.add_undo_property(self, &"stored_ground_hash", stored_ground_hash)
	undo_redo.commit_action()

	var total := 0
	for flat in stored_transforms:
		total += stored_count(flat)
	print("ScatterRegion '%s': stored %d instances (%d dropped by slope/ground)" %
			[name, total, dropped])


## Footprint + knobs -> generate_placements params. Public so the fixture builder can
## expand a region programmatically (flat ground, no editor).
func build_params() -> Dictionary:
	var weights := PackedFloat32Array()
	for item in items:
		weights.append(item.weight if item != null and item.prefab != null else 0.0)
	return {
		"polygon": footprint_polygon(),
		"density": density,
		"min_spacing": min_spacing,
		"seed": placement_seed,
		"weights": weights,
		"yaw_jitter_deg": yaw_jitter_deg,
		"scale_min": scale_range.x,
		"scale_max": scale_range.y,
	}


## The footprint as a region-local XZ polygon (box unifies into the polygon path).
func footprint_polygon() -> PackedVector2Array:
	if footprint_kind == "polygon":
		return polygon
	var hx := box_size.x * 0.5
	var hz := box_size.y * 0.5
	return PackedVector2Array([
		Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)])


## Ground snap, LK2-fallback-chain style: physics ray straight down (editor space may
## be unpopulated) -> HeightmapTerrain bilinear sample (normal by finite difference)
## -> empty (the point is dropped; scatter has no Y=0 fallback on purpose — a floating
## instance is worse than a missing one). Returns {position, normal} or {}.
func _snap_ground(space: PhysicsDirectSpaceState3D, terrains: Array[Node],
		world: Vector3) -> Dictionary:
	if space != null:
		var from := Vector3(world.x, world.y + RAY_UP, world.z)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * RAY_UP * 2.0)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return {"position": hit.position, "normal": hit.normal}
	for t in terrains:
		if t.contains_xz(world):
			var y: float = t.height_at(world)
			var e := 0.5
			var dx: float = (t.height_at(world + Vector3(e, 0, 0))
					- t.height_at(world - Vector3(e, 0, 0))) / (2.0 * e)
			var dz: float = (t.height_at(world + Vector3(0, 0, e))
					- t.height_at(world - Vector3(0, 0, e))) / (2.0 * e)
			return {"position": Vector3(world.x, y, world.z),
					"normal": Vector3(-dx, 1.0, -dz).normalized()}
	return {}


func _find_authoring_ancestor() -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method("is_carlito_authoring"):
			return node
		node = node.get_parent()
	return null


# ----------------------------------------------------------- stale-scatter guard

## Editor-only slow poll: recompute the ground hash every few seconds and refresh the
## configuration warning when staleness flips (sculpting happens outside this node, so
## there is no signal to react to).
func _process(delta: float) -> void:
	if not Engine.is_editor_hint():
		set_process(false)
		return
	_stale_accum += delta
	if _stale_accum < 3.0:
		return
	_stale_accum = 0.0
	_refresh_stale()


func _refresh_stale() -> void:
	var now_stale := _compute_stale()
	if now_stale != _stale:
		_stale = now_stale
		update_configuration_warnings()


func _compute_stale() -> bool:
	var total := 0
	for flat in stored_transforms:
		total += stored_count(flat)
	if total == 0:
		return false
	return stored_ground_hash != ground_hash(owner if owner != null else self)


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if items.is_empty():
		warnings.append("No items. In Items, Add Element, then open the element's dropdown and pick 'New ScatterItem' (it is a Resource — prefabs are dragged into ITS 'prefab' slot, not into the array).")
	if _stale:
		warnings.append("Terrain changed since this region was scattered — Regenerate, then re-bake the level.")
	return warnings
