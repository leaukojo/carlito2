@tool
extends RefCounted
## Draw-on-terrain road authoring. The built-in Path3D gizmo places
## points on a plane at the node's origin; this tool instead appends ground-snapped
## curve points to the selected RoadPath — each viewport click resolves the ground via
## the shared ground-snap fallback chain (ground_snap.gd), lifts it by the road's
## draw_clearance, and commits ONE undoable curve point (the placement_tool pattern).
## Right-click / Escape exits Draw mode. A ghost line previews the next segment from
## the curve's last point to the cursor (the brush-cursor discipline: unowned,
## unshaded, no-depth-test — never serialized).
##
## Inert (handle_input returns false) unless a RoadPath is targeted AND the panel's
## Draw mode is on, so editor navigation/selection is untouched otherwise. The live
## ribbon rebuild (RoadPath's curve_changed debounce) is the per-click feedback.

const GroundSnap := preload("res://addons/carlito_kit/ground_snap.gd")
const RoadBuilderScript := preload("res://kit/helpers/road_builder.gd")

## The default stub curve _ensure_path authors on a fresh RoadPath (two points, zero
## handles). The first draw click replaces it, so drawing a road from scratch never
## keeps the placeholder segment at the node origin.
const STUB_A := Vector3.ZERO
const STUB_B := Vector3(0, 0, 12)

signal deactivated  # RMB/Escape exit -> the panel flips its toggle back to Off

var _undo: EditorUndoRedoManager
var _road: Node3D = null
var _active := false
var _ghost: MeshInstance3D = null
var _no_excludes: Array[RID] = []


func _init(undo: EditorUndoRedoManager) -> void:
	_undo = undo


## Selection tracking (plugin): the tool follows the selected RoadPath; deselecting
## drops the target and leaves Draw mode.
func set_target(road: Node3D) -> void:
	if road == _road:
		return
	_road = road
	if _road == null and _active:
		_exit()
	_free_ghost()


## Panel toggle. Turning off programmatically never emits `deactivated` (the panel
## already knows); only input-driven exits (_exit) do.
func set_active(active: bool) -> void:
	_active = active
	if not _active:
		_free_ghost()


func teardown() -> void:
	_free_ghost()
	_road = null


# ------------------------------------------------------------------ input

## Returns true when the event was consumed (the plugin then returns
## AFTER_GUI_INPUT_STOP).
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not _active or not _target_valid():
		_hide_ghost()
		return false

	if event is InputEventKey and event.pressed \
			and (event as InputEventKey).keycode == KEY_ESCAPE:
		_exit()
		return true

	if event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_exit()
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_commit_point(_snap(camera, mb.position))
			return true

	if event is InputEventMouseMotion:
		_update_ghost(camera, (event as InputEventMouseMotion).position)
		return true

	return false


func _target_valid() -> bool:
	return is_instance_valid(_road) and _road.is_inside_tree()


func _exit() -> void:
	set_active(false)
	deactivated.emit()


## Ground hit + the road's clearance, so the ribbon never starts buried before
## Conform runs.
func _snap(camera: Camera3D, mouse_pos: Vector2) -> Vector3:
	var clearance: float = _road.get("draw_clearance")
	return GroundSnap.ground_point(camera, mouse_pos, _no_excludes) \
			+ Vector3.UP * clearance


# ------------------------------------------------------------------ commit

## One undoable action per click (the placement_tool undo-context pattern). When the
## curve is still the untouched default stub, the same action swaps it for the first
## drawn point. Each click also gives the PREVIOUS point Catmull-Rom handles
## (RoadBuilder.smooth_handles): a zero-handle polyline corner folds the extruded
## ribbon over itself, so drawn roads must come out C1-smooth.
func _commit_point(world: Vector3) -> void:
	var path := _road.get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		push_warning("Kit: RoadPath '%s' has no Path child to draw into." % _road.name)
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var curve := path.curve
	var local := path.global_transform.affine_inverse() * world

	_undo.create_action("Add road point", UndoRedo.MERGE_DISABLE, scene_root)
	if _is_default_stub(curve):
		_undo.add_do_method(curve, "remove_point", 1)
		_undo.add_do_method(curve, "remove_point", 0)
		_undo.add_do_method(curve, "add_point", local)
		_undo.add_undo_method(curve, "remove_point", 0)
		_undo.add_undo_method(curve, "add_point", STUB_A)
		_undo.add_undo_method(curve, "add_point", STUB_B)
	else:
		var idx := curve.point_count   # index the new point will take
		_undo.add_do_method(curve, "add_point", local)
		if idx >= 2:
			var h: Dictionary = RoadBuilderScript.smooth_handles(
					curve.get_point_position(idx - 2),
					curve.get_point_position(idx - 1), local)
			_undo.add_do_method(curve, "set_point_in", idx - 1, h["in"])
			_undo.add_do_method(curve, "set_point_out", idx - 1, h["out"])
			# undo runs in reverse registration order: the added point goes first,
			# then these restore the previous point's handles
			_undo.add_undo_method(curve, "set_point_in", idx - 1, curve.get_point_in(idx - 1))
			_undo.add_undo_method(curve, "set_point_out", idx - 1, curve.get_point_out(idx - 1))
		_undo.add_undo_method(curve, "remove_point", idx)
	_undo.commit_action()


## Close the loop (panel button): append a point AT the first point's position and
## give the seam matching Catmull-Rom tangents — the first point's out-handle and the
## new end point's in-handle both follow the last->second chord (smooth_handles with
## the seam treated as an interior point), so the ribbon is C1 through the seam. The
## extruder needs no special-casing (the duplicated seam ring welds at bake). The
## previous point is smoothed like any other click, and Draw mode exits — clicking
## past a closed loop makes no sense. One undoable action.
func close_loop() -> void:
	if not _target_valid():
		return
	var path := _road.get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		return
	var curve := path.curve
	var n := curve.point_count
	if n < 3 or _is_default_stub(curve):
		push_warning("Kit: draw at least 3 points before closing the loop.")
		return
	var first := curve.get_point_position(0)
	var last := curve.get_point_position(n - 1)
	if last.is_equal_approx(first):
		push_warning("Kit: the road already ends on its first point.")
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var seam: Dictionary = RoadBuilderScript.smooth_handles(
			last, first, curve.get_point_position(1))
	var prev_h: Dictionary = RoadBuilderScript.smooth_handles(
			curve.get_point_position(n - 2), last, first)

	_undo.create_action("Close road loop", UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_method(curve, "add_point", first)
	_undo.add_do_method(curve, "set_point_in", n, seam["in"])
	_undo.add_do_method(curve, "set_point_out", 0, seam["out"])
	_undo.add_do_method(curve, "set_point_in", n - 1, prev_h["in"])
	_undo.add_do_method(curve, "set_point_out", n - 1, prev_h["out"])
	# undo runs in reverse registration order: the seam point goes first, then the
	# handle restores
	_undo.add_undo_method(curve, "set_point_out", n - 1, curve.get_point_out(n - 1))
	_undo.add_undo_method(curve, "set_point_in", n - 1, curve.get_point_in(n - 1))
	_undo.add_undo_method(curve, "set_point_out", 0, curve.get_point_out(0))
	_undo.add_undo_method(curve, "remove_point", n)
	_undo.commit_action()
	if _active:
		_exit()


static func _is_default_stub(curve: Curve3D) -> bool:
	return curve.point_count == 2 \
			and curve.get_point_position(0) == STUB_A \
			and curve.get_point_position(1) == STUB_B \
			and curve.get_point_in(1) == Vector3.ZERO \
			and curve.get_point_out(0) == Vector3.ZERO


# ------------------------------------------------------------------ ghost

## Preview line from the curve's last point (world) to the snapped cursor, plus a
## short vertical tick at the cursor. First point of a fresh road: tick only.
func _update_ghost(camera: Camera3D, mouse_pos: Vector2) -> void:
	var world := _snap(camera, mouse_pos)
	if not is_instance_valid(_ghost) or _ghost.get_parent() != _road:
		_free_ghost()
		_ghost = MeshInstance3D.new()
		_ghost.name = "__RoadDrawGhost"
		_ghost.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.albedo_color = Color(1.0, 0.75, 0.2)
		_ghost.material_override = mat
		_road.add_child(_ghost)  # unowned on purpose -> never serialized

	var im := _ghost.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	var last := _last_point_world()
	if last != null:
		im.surface_add_vertex(_ghost.to_local(last))
		im.surface_add_vertex(_ghost.to_local(world))
	im.surface_add_vertex(_ghost.to_local(world))
	im.surface_add_vertex(_ghost.to_local(world + Vector3.UP * 2.0))
	im.surface_end()
	_ghost.visible = true


## World position of the last curve point, or null when there is nothing to draw
## from (empty curve, or the default stub the first click will replace).
func _last_point_world() -> Variant:
	var path := _road.get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null or path.curve.point_count == 0 \
			or _is_default_stub(path.curve):
		return null
	return path.global_transform \
			* path.curve.get_point_position(path.curve.point_count - 1)


func _hide_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.visible = false


func _free_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.free()
	_ghost = null
