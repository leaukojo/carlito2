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
##
## Port snapping (docs/level_kit.md): a click near an open roads-GridMap tile edge
## snaps onto its port (RoadPorts, kit/helpers/road_ports.gd) with the tangent locked
## along the outward face normal, so spline roads join city tiles seamlessly. A fresh
## road can START on a port; ARRIVING at one commits the point and exits Draw mode —
## the road ends there, which also keeps the locked tangent safe from the next click's
## smooth-handle rewrite. The port cache refreshes on activation / grid change only:
## mode exclusivity guarantees tiles can't be painted while Draw mode owns the
## viewport. Snap Ends (panel button) is the post-gizmo-drag fixup: the built-in
## Path3D point gizmo can't be intercepted, so dragged endpoints are re-snapped
## destructively-by-button instead.

const GroundSnap := preload("res://addons/carlito_kit/ground_snap.gd")
const RoadBuilderScript := preload("res://kit/helpers/road_builder.gd")
const RoadPortsScript := preload("res://kit/helpers/road_ports.gd")

const RECIPE_PATH := "res://kit/import/roads.json"
const SNAP_RADIUS := 3.0  # draw-click snap capture (XZ), ~1/4 cell
const SNAP_ENDS_RADIUS := 6.0  # Snap Ends button: forgiving post-drag fixup, 1/2 cell
const HANDLE_LEN := 4.0  # locked end tangent length, ~1/3 cell
const PORT_MARKER_RANGE := 30.0  # ghost draws port markers within this XZ range

const LINE_COLOR := Color(1.0, 0.75, 0.2)
const PORT_COLOR := Color(0.35, 0.75, 1.0)
const SNAP_COLOR := Color(0.4, 1.0, 0.5)

## The default stub curve _ensure_path authors on a fresh RoadPath (two points, zero
## handles). The first draw click replaces it, so drawing a road from scratch never
## keeps the placeholder segment at the node origin.
const STUB_A := Vector3.ZERO
const STUB_B := Vector3(0, 0, 12)

signal deactivated  # RMB/Escape exit -> the panel flips its toggle back to Off

## Panel checkbox (default ON): each click gives the PREVIOUS point Catmull-Rom
## handles. OFF draws a zero-handle polyline — the road follows the clicks exactly;
## the extruder's corner miter rings + inside-edge fold clamp render the angled
## connections cleanly.
var smooth_corners := true

## Panel checkbox (default ON): drawn end points capture onto GridMap ports.
var snap_ports := true

var _undo: EditorUndoRedoManager
var _road: Node3D = null
var _active := false
var _ghost: MeshInstance3D = null
var _no_excludes: Array[RID] = []
var _grid: GridMap = null
var _ports: Array[Dictionary] = []
var _table := {}
var _table_loaded := false


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
	if _active:
		_refresh_ports()
	else:
		_free_ghost()


## Selection tracking (plugin): the roads GridMap ports snap onto, re-resolved per
## selection change like the terrain brush's set_grid.
func set_grid(grid: GridMap) -> void:
	if grid == _grid:
		return
	_grid = grid
	if _active:
		_refresh_ports()


func teardown() -> void:
	_free_ghost()
	_road = null
	_grid = null
	_ports = []


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
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			return false  # editor freelook drag -> don't steal look motion
		_update_ghost(camera, mm.position)
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
## drawn point. With smooth_corners on, each click also gives the PREVIOUS point
## Catmull-Rom handles (RoadBuilder.smooth_handles) so drawn roads come out C1-smooth;
## off skips them for an exact angled polyline.
## A click within SNAP_RADIUS of an open port lands ON the port (exactly at the tile's
## asphalt surface — no draw_clearance, so the ribbon meets the deck flush) with the
## end tangent locked outward; arriving at a port also exits Draw mode.
func _commit_point(world: Vector3) -> void:
	var path := _road.get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		push_warning("Kit: RoadPath '%s' has no Path child to draw into." % _road.name)
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var curve := path.curve
	var inv := path.global_transform.affine_inverse()
	var port := _snap_port(world)
	var port_handle := Vector3.ZERO
	if not port.is_empty():
		world = port["position"]
		port_handle = (inv.basis * (port["normal"] as Vector3)).normalized() * HANDLE_LEN
	var local := inv * world

	_undo.create_action("Add road point", UndoRedo.MERGE_DISABLE, scene_root)
	if _is_default_stub(curve):
		_undo.add_do_method(curve, "remove_point", 1)
		_undo.add_do_method(curve, "remove_point", 0)
		_undo.add_do_method(curve, "add_point", local)
		if not port.is_empty():
			# leaving the port: lock the start tangent along the outward face normal
			_undo.add_do_method(curve, "set_point_out", 0, port_handle)
		_undo.add_undo_method(curve, "remove_point", 0)
		_undo.add_undo_method(curve, "add_point", STUB_A)
		_undo.add_undo_method(curve, "add_point", STUB_B)
	else:
		var idx := curve.point_count   # index the new point will take
		_undo.add_do_method(curve, "add_point", local)
		if not port.is_empty():
			# arriving at the port: lock the end tangent perpendicular to the face
			_undo.add_do_method(curve, "set_point_in", idx, port_handle)
		if smooth_corners and idx >= 2:
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
	# after commit a snapped FIRST point leaves 1 point (keep drawing away from the
	# tile); a snapped ARRIVAL leaves >= 2 and ends the road
	if not port.is_empty() and curve.point_count >= 2:
		_exit()


## Close the loop (panel button): append a point AT the first point's position. With
## smooth_corners on, the seam gets matching Catmull-Rom tangents — the first point's
## out-handle and the new end point's in-handle both follow the last->second chord
## (smooth_handles with the seam treated as an interior point), so the ribbon is C1
## through the seam, and the previous point is smoothed like any other click. Off, the
## seam point lands with NO handles (the extruder's closed-loop bisector frame miters
## the angled seam). The duplicated seam ring welds at bake. Draw mode exits —
## clicking past a closed loop makes no sense. One undoable action.
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
	_undo.create_action("Close road loop", UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_method(curve, "add_point", first)
	if smooth_corners:
		var seam: Dictionary = RoadBuilderScript.smooth_handles(
				last, first, curve.get_point_position(1))
		var prev_h: Dictionary = RoadBuilderScript.smooth_handles(
				curve.get_point_position(n - 2), last, first)
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


## Panel button: snap the selected road's FIRST and LAST curve points to their nearest
## open port (within SNAP_ENDS_RADIUS) and lock the end tangents — the fixup for
## endpoints dragged with the built-in Path3D gizmo. Works with Draw mode off; one
## undoable action. Ends that find no port are left alone.
func snap_ends() -> void:
	if not _target_valid():
		return
	var path := _road.get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		return
	var curve := path.curve
	if curve.point_count < 2 or _is_default_stub(curve):
		push_warning("Kit: draw the road before snapping its ends.")
		return
	_refresh_ports()
	if _ports.is_empty():
		push_warning("Kit: no open ports found (is there a painted roads GridMap?).")
		return
	var inv := path.global_transform.affine_inverse()
	var last := curve.point_count - 1
	var ends := []  # [point index, port]
	for i in [0, last]:
		var port: Dictionary = RoadPortsScript.nearest_port(_ports,
				path.global_transform * curve.get_point_position(i), SNAP_ENDS_RADIUS)
		if not port.is_empty():
			ends.append([i, port])
	if ends.size() == 2 and ends[0][1]["position"] == ends[1][1]["position"]:
		ends.remove_at(1)  # both ends captured the same port: the first end wins
	if ends.is_empty():
		push_warning("Kit: no port within %.0f m of either road end." % SNAP_ENDS_RADIUS)
		return
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	_undo.create_action("Snap road ends to ports", UndoRedo.MERGE_DISABLE, scene_root)
	for e in ends:
		var i: int = e[0]
		var port: Dictionary = e[1]
		var handle: Vector3 = (inv.basis * (port["normal"] as Vector3)).normalized() \
				* HANDLE_LEN
		_undo.add_do_method(curve, "set_point_position", i, inv * (port["position"] as Vector3))
		_undo.add_undo_method(curve, "set_point_position", i, curve.get_point_position(i))
		if i == 0:
			_undo.add_do_method(curve, "set_point_out", 0, handle)
			_undo.add_undo_method(curve, "set_point_out", 0, curve.get_point_out(0))
		else:
			_undo.add_do_method(curve, "set_point_in", i, handle)
			_undo.add_undo_method(curve, "set_point_in", i, curve.get_point_in(i))
	_undo.commit_action()


# ------------------------------------------------------------------ ports

## Rebuild the port cache from the current grid. Cheap enough per activation; never
## per-frame (ghost updates only read the cache).
func _refresh_ports() -> void:
	_ports = []
	if _grid == null or not is_instance_valid(_grid) or not _grid.is_inside_tree():
		return
	_ports = RoadPortsScript.enumerate_ports(_grid, _load_table(), _grid.global_transform)


## Nearest open port a click at `world` would capture, or {}.
func _snap_port(world: Vector3) -> Dictionary:
	if not snap_ports or _ports.is_empty():
		return {}
	return RoadPortsScript.nearest_port(_ports, world, SNAP_RADIUS)


## The recipe's ports table, loaded once per tool instance (recipe edits are rare and
## come with a plugin reload). Validation problems are warnings, not hard stops.
func _load_table() -> Dictionary:
	if _table_loaded:
		return _table
	_table_loaded = true
	var recipe: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECIPE_PATH))
	if recipe is Dictionary:
		for err in RoadPortsScript.validate(recipe):
			push_warning("Kit: roads ports table: %s" % err)
		_table = RoadPortsScript.parse_table(recipe)
	else:
		push_warning("Kit: cannot read %s for road port snapping." % RECIPE_PATH)
	return _table


static func _is_default_stub(curve: Curve3D) -> bool:
	return curve.point_count == 2 \
			and curve.get_point_position(0) == STUB_A \
			and curve.get_point_position(1) == STUB_B \
			and curve.get_point_in(1) == Vector3.ZERO \
			and curve.get_point_out(0) == Vector3.ZERO


# ------------------------------------------------------------------ ghost

## Preview line from the curve's last point (world) to the snapped cursor, plus a
## short vertical tick at the cursor. First point of a fresh road: tick only. With
## port snapping on, nearby ports draw as small diamond markers and the preview locks
## onto the port a click would capture (highlighted larger, in SNAP_COLOR).
func _update_ghost(camera: Camera3D, mouse_pos: Vector2) -> void:
	var world := _snap(camera, mouse_pos)
	var target := _snap_port(world)
	if not is_instance_valid(_ghost) or _ghost.get_parent() != _road:
		_free_ghost()
		_ghost = MeshInstance3D.new()
		_ghost.name = "__RoadDrawGhost"
		_ghost.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true
		mat.vertex_color_use_as_albedo = true
		mat.albedo_color = Color.WHITE
		_ghost.material_override = mat
		_road.add_child(_ghost)  # unowned on purpose -> never serialized

	var dest: Vector3 = world if target.is_empty() else target["position"]
	var im := _ghost.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(LINE_COLOR)
	var last := _last_point_world()
	if last != null:
		im.surface_add_vertex(_ghost.to_local(last))
		im.surface_add_vertex(_ghost.to_local(dest))
	im.surface_add_vertex(_ghost.to_local(dest))
	im.surface_add_vertex(_ghost.to_local(dest + Vector3.UP * 2.0))
	if snap_ports:
		for port: Dictionary in _ports:
			var pos: Vector3 = port["position"]
			if port == target \
					or Vector2(pos.x - world.x, pos.z - world.z).length() > PORT_MARKER_RANGE:
				continue
			im.surface_set_color(PORT_COLOR)
			_add_marker(im, _ghost.to_local(pos), 0.9)
		if not target.is_empty():
			im.surface_set_color(SNAP_COLOR)
			_add_marker(im, _ghost.to_local(target["position"]), 1.6)
	im.surface_end()
	_ghost.visible = true


## Horizontal diamond + vertical tick, in ghost-local space (PRIMITIVE_LINES pairs).
func _add_marker(im: ImmediateMesh, center: Vector3, size: float) -> void:
	var corners := [
		center + Vector3(0, 0, -size), center + Vector3(size, 0, 0),
		center + Vector3(0, 0, size), center + Vector3(-size, 0, 0),
	]
	for i in 4:
		im.surface_add_vertex(corners[i])
		im.surface_add_vertex(corners[(i + 1) % 4])
	im.surface_add_vertex(center)
	im.surface_add_vertex(center + Vector3.UP * 1.5)


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
