@tool
extends "res://addons/carlito_kit/brush_chassis.gd"
## Scatter brush. Rides the shared brush chassis; adds the
## scatter-specific half: PAINT lays instances into a selected ScatterCanvas density-per-stroke,
## ERASE removes them within the brush radius. The second front-end on the scatter core —
## it reuses the seeded sampler (ScatterRegion.generate_placements), the jitter knobs and ground
## snapping (ScatterBase), and the canvas's pure erase, so painted and regenerated scatter share
## one placement philosophy and one bake path.
##
## Editor-only by construction (editor/runtime split): the brush mutates the canvas's
## stored transforms (authored, serialized content) live during a stroke for feedback, and
## commits ONE undoable stored_transforms swap at stroke end (whole-array, like Regenerate — the
## arrays are small). No new runtime or baker code: the canvas is a ScatterBase, so it renders
## and bakes exactly as a ScatterRegion does.

const ScatterBaseScript := preload("res://kit/helpers/scatter_base.gd")

enum { OFF, PAINT, ERASE }

var mode := OFF

var _undo: EditorUndoRedoManager
var _canvas: ScatterCanvas = null

# Active-stroke state.
var _before: Array[PackedFloat32Array] = []   # snapshot for undo
var _before_hash := ""
var _work: Array[PackedFloat32Array] = []      # the array we mutate; pushed to the canvas at end
var _spacing_grid := {}                        # world XZ spatial hash (paint spacing)
var _dab_seed := 0
var _dirty := false

# Stroke-scoped live preview: the merged per-item mesh is built ONCE at stroke begin and reused
# every dab (index-matched to the canvas's items; null where an item has no prefab). Each dab
# only rewrites the MultiMesh instance transforms/count — no prefab re-instantiate, no re-merge.
var _live_mms: Array[MultiMesh] = []


func _init(undo: EditorUndoRedoManager) -> void:
	_undo = undo


# ------------------------------------------------------------------ plugin API

func set_target(canvas: ScatterCanvas) -> void:
	if canvas == _canvas:
		return
	_free_cursor()  # cursor lives under the canvas; a new target needs a new one
	if is_instance_valid(_canvas):
		_canvas.end_live_edit()  # clear the flag if we swap targets mid-stroke
	_reset_stroke()
	_canvas = canvas


func set_mode(m: int) -> void:
	mode = m
	if mode == OFF:
		_hide_cursor()


func teardown() -> void:
	_free_cursor()
	_canvas = null


# ------------------------------------------------------------------ chassis virtuals

func _target_valid() -> bool:
	return Engine.is_editor_hint() and mode != OFF and is_instance_valid(_canvas)


func _cursor_parent() -> Node3D:
	return _canvas


func _cursor_color() -> Color:
	return Color(0.4, 1.0, 0.45) if mode == PAINT else Color(1.0, 0.45, 0.4)


## Ground point under the cursor: edited-scene physics ray -> terrain sample -> Y=0 plane (the
## shared fallback chain — a click never dead-drops). Returns a world Vector3.
func _project(camera: Camera3D, mouse: Vector2) -> Variant:
	if not is_instance_valid(_canvas):
		return null
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var space := _canvas.get_world_3d().direct_space_state
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * 100000.0)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			return hit.position
	for t in _terrains():
		var xz: Variant = _ray_plane(origin, dir, (t as Node3D).global_position.y)
		if xz != null and t.contains_xz(xz):
			return Vector3((xz as Vector3).x, t.height_at(xz), (xz as Vector3).z)
	return _ray_plane(origin, dir, 0.0)


# ------------------------------------------------------------------ stroke

func _stroke_begin(_center: Vector3) -> void:
	_dirty = false
	if not is_instance_valid(_canvas):
		return
	_before = _snapshot(_canvas.stored_transforms)
	_before_hash = _canvas.stored_ground_hash
	_work = _snapshot(_canvas.stored_transforms)
	# Pad to one array per item so a fresh canvas (empty stored_transforms) can be painted.
	while _work.size() < _canvas.items.size():
		_work.append(PackedFloat32Array())
	_rebuild_spacing_grid()
	_canvas.begin_live_edit()  # suppress the per-assignment stale recompute for the whole stroke
	_setup_live_preview()


func _stroke_apply(center: Vector3) -> void:
	if not is_instance_valid(_canvas):
		return
	# Only touch anything when a dab actually changes content — a paint dab that snaps nothing,
	# or an erase over empty ground, must not commit a no-op undo.
	var changed := false
	if mode == PAINT:
		changed = _paint_dab(center) > 0
	else:
		var before_total := _total(_work)
		_work = ScatterCanvas.erase_within(_work, _canvas.global_transform, center, radius)
		changed = _total(_work) < before_total
	if changed:
		_update_live_preview()  # cheap: rewrite MultiMesh transforms/count, no re-merge
		_dirty = true


func _stroke_end() -> void:
	if not is_instance_valid(_canvas):
		_reset_stroke()
		return
	if not _dirty:
		_canvas.end_live_edit()  # nothing changed; the live preview already matches the canvas
		_reset_stroke()
		return
	# Commit the accumulated work to the canvas ONCE: the stored_transforms setter rebuilds the
	# authoritative preview (freeing our stroke-scoped one) with stale still suppressed, then
	# end_live_edit does the single stale recompute for the whole stroke.
	var final := _work
	var level_root: Node = _canvas.owner if _canvas.owner != null else _canvas
	var new_hash := ScatterBaseScript.ground_hash(level_root)
	_canvas.stored_ground_hash = new_hash
	_canvas.stored_transforms = final
	_canvas.end_live_edit()

	var scene_root := EditorInterface.get_edited_scene_root()
	_undo.create_action("Paint scatter" if mode == PAINT else "Erase scatter",
			UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_property(_canvas, &"stored_transforms", final)
	_undo.add_undo_property(_canvas, &"stored_transforms", _before)
	_undo.add_do_property(_canvas, &"stored_ground_hash", new_hash)
	_undo.add_undo_property(_canvas, &"stored_ground_hash", _before_hash)
	_undo.commit_action(false)  # edits are already live — don't re-run the do now
	_reset_stroke()


func _reset_stroke() -> void:
	_before = []
	_work = []
	_live_mms = []


# --------------------------------------------------------- stroke-scoped live preview

## Build the stroke's preview once: one MultiMesh per item over its merged mesh, under the
## canvas's "Preview" node (named to match ScatterBase._rebuild_preview, so the stroke-end
## stored_transforms assignment cleanly frees this and rebuilds the authoritative version).
func _setup_live_preview() -> void:
	var old := _canvas.get_node_or_null(^"Preview")
	if old != null:
		old.free()
	var preview := Node3D.new()
	preview.name = "Preview"
	_canvas.add_child(preview)  # unowned on purpose -> never serialized
	_live_mms = []
	for i in _canvas.items.size():
		var item: Resource = _canvas.items[i]
		if item == null or item.get("prefab") == null:
			_live_mms.append(null)
			continue
		var template: Node = (item.get("prefab") as PackedScene).instantiate()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ScatterBaseScript.build_item_mesh(template)
		template.free()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Item%d" % i
		mmi.multimesh = mm
		preview.add_child(mmi)
		_live_mms.append(mm)
	_update_live_preview()


## Per-dab update: rewrite each item's MultiMesh instance count + transforms from `_work`. No
## prefab instancing or mesh merging — the meshes were built once in _setup_live_preview.
func _update_live_preview() -> void:
	for i in _live_mms.size():
		var mm: MultiMesh = _live_mms[i]
		if mm == null or i >= _work.size():
			continue
		var flat := _work[i]
		var count := ScatterBaseScript.stored_count(flat)
		mm.instance_count = count
		for j in count:
			mm.set_instance_transform(j, ScatterBaseScript.stored_transform(flat, j))


# ------------------------------------------------------------------ painting

## Lay one dab: seed the region sampler over a world-XZ square bounding the brush disc, then keep
## the candidates that fall in the disc, snap to ground, pass the slope filter, and clear the
## min-spacing hash (which carries prior dabs + existing instances, so density is even
## regardless of stroke speed). Region-local transforms are appended to `_work`. Returns the
## number of instances actually placed (0 = nothing snapped, so the caller skips a no-op commit).
func _paint_dab(center: Vector3) -> int:
	var weights := PackedFloat32Array()
	var any := false
	for item in _canvas.items:
		var w: float = item.weight if item != null and item.get("prefab") != null else 0.0
		weights.append(w)
		any = any or w > 0.0
	if not any:
		return 0

	var cx := center.x
	var cz := center.z
	var square := PackedVector2Array([
		Vector2(cx - radius, cz - radius), Vector2(cx + radius, cz - radius),
		Vector2(cx + radius, cz + radius), Vector2(cx - radius, cz + radius)])
	_dab_seed += 1
	var candidates := ScatterRegion.generate_placements({
		"polygon": square,
		"density": _canvas.paint_density,
		"min_spacing": _canvas.min_spacing,
		"seed": _dab_seed,
		"weights": weights,
		"yaw_jitter_deg": _canvas.yaw_jitter_deg,
		"scale_min": _canvas.scale_range.x,
		"scale_max": _canvas.scale_range.y,
	})

	var space := _canvas.get_world_3d().direct_space_state
	var terrains := _terrains()
	var cos_max := cos(deg_to_rad(_canvas.max_slope_deg))
	var inv := _canvas.global_transform.affine_inverse()
	var spacing := _canvas.min_spacing
	var r2 := radius * radius

	while _work.size() < _canvas.items.size():
		_work.append(PackedFloat32Array())

	var placed := 0
	for i in candidates.size():
		var flat := candidates[i]
		for j in flat.size() / 4:
			var o := j * 4
			var px := flat[o]
			var pz := flat[o + 1]
			if (px - cx) * (px - cx) + (pz - cz) * (pz - cz) > r2:
				continue  # square sampler -> keep the inscribed disc
			if spacing > 0.0 and not ScatterBaseScript.spacing_ok(Vector2(px, pz), spacing, _spacing_grid):
				continue
			var hit := ScatterBaseScript.snap_ground(space, terrains, Vector3(px, center.y, pz))
			if hit.is_empty() or (hit.normal as Vector3).y < cos_max:
				continue
			var local: Vector3 = inv * (hit.position as Vector3)
			_work[i].append_array(PackedFloat32Array(
					[local.x, local.y, local.z, flat[o + 2], flat[o + 3]]))
			_grid_add(Vector2(px, pz), spacing)
			placed += 1
	return placed


# ------------------------------------------------------------------ spacing hash

func _rebuild_spacing_grid() -> void:
	_spacing_grid = {}
	var spacing := _canvas.min_spacing
	if spacing <= 0.0:
		return
	var base := _canvas.global_transform
	for i in _work.size():
		var flat := _work[i]
		for j in ScatterBaseScript.stored_count(flat):
			var world := base * ScatterBaseScript.stored_transform(flat, j).origin
			_grid_add(Vector2(world.x, world.z), spacing)


func _grid_add(p: Vector2, spacing: float) -> void:
	var key := Vector2i(floori(p.x / spacing), floori(p.y / spacing))
	if not _spacing_grid.has(key):
		_spacing_grid[key] = PackedVector2Array()
	_spacing_grid[key].append(p)


# ------------------------------------------------------------------ helpers

func _terrains() -> Array[Node]:
	var out: Array[Node] = []
	var level_root: Node = _canvas.owner if _canvas.owner != null else _canvas
	ScatterBaseScript.find_terrains_under(level_root, out)
	return out


static func _snapshot(src: Array[PackedFloat32Array]) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	for flat in src:
		out.append(flat.duplicate())
	return out


static func _total(work: Array[PackedFloat32Array]) -> int:
	var n := 0
	for flat in work:
		n += ScatterBaseScript.stored_count(flat)
	return n
