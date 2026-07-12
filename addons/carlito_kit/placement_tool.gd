@tool
extends RefCounted
## LK2 click-to-place tool (level_kit_plan.md §4 LK2). All viewport/placement/editor-undo
## logic lives here, driven by the plugin's forwarded 3D input — the editor half of the
## editor/runtime split (plan §2: editor APIs stay in addons/carlito_kit).
##
## Flow: the dock arms a prefab -> a non-saved "ghost" instance follows the ground-snapped
## cursor -> left-click commits a real, owned, undoable copy under the level's AuthoringRoot
## and stays armed (sticky placement). Right-click / Escape disarms.
##
## Ground resolution is a fallback chain so a click never dead-drops: physics raycast first,
## then the level's HeightmapTerrain height sample, then the Y=0 plane.

const GroundSnap := preload("res://addons/carlito_kit/ground_snap.gd")

const PREFAB_DIR := "res://kit/prefabs"
const PALETTE_DIR := "res://kit/palettes"
const RECIPE_DIR := "res://kit/import"
const ROTATE_STEP := deg_to_rad(15.0)

signal yaw_changed(degrees: float)  # so the dock's Yaw field tracks the live ghost angle

## Toolbar-driven placement options (pushed by the plugin from the dock toolbar).
var random_yaw := true
var snap_enabled := false
var snap_step := 1.0
var base_yaw := 0.0  # manual yaw (radians) from the dock field, used when random is off

var _undo: EditorUndoRedoManager

var _armed_kit := ""
var _armed_name := ""
var _ghost: Node3D = null
var _ghost_excludes: Array[RID] = []
var _preview_yaw := 0.0
var _last_point := Vector3.ZERO


func _init(undo: EditorUndoRedoManager) -> void:
	_undo = undo


# ------------------------------------------------------------------ arming

func is_armed() -> bool:
	return not _armed_name.is_empty()


## Arm a prefab for placement. Refuses (and warns) if the edited scene has no AuthoringRoot,
## so the author fixes the level before dropping props that would have nowhere to live.
func arm(kit: String, name: String) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		push_warning("Kit: open a level scene before placing.")
		return
	if _find_authoring(scene_root) == null:
		push_warning("Kit: this scene has no AuthoringRoot — add one before placing '%s'." % name)
		disarm()
		return
	var scene := _load_prefab(kit, name)
	if scene == null:
		push_warning("Kit: prefab not found: %s/%s" % [kit, name])
		return

	disarm()
	_armed_kit = kit
	_armed_name = name
	_preview_yaw = randf() * TAU if random_yaw else base_yaw
	yaw_changed.emit(rad_to_deg(_preview_yaw))

	_ghost = scene.instantiate() as Node3D
	if _ghost == null:
		_armed_name = ""
		return
	_ghost.name = "__KitGhost"
	scene_root.add_child(_ghost)  # unowned on purpose -> never serialized
	_ghost.visible = false        # until the first motion positions it
	# Keep the ghost's own collision out of the placement raycast (it hugs the cursor).
	_ghost_excludes.clear()
	for body in _collect_bodies(_ghost):
		body.collision_layer = 0
		_ghost_excludes.append(body.get_rid())


func disarm() -> void:
	if is_instance_valid(_ghost):
		_ghost.free()  # detaches from its parent on its own
	_ghost = null
	_ghost_excludes.clear()
	_armed_kit = ""
	_armed_name = ""


# ------------------------------------------------------------------ input

## Returns true when the event was consumed (the plugin then returns AFTER_GUI_INPUT_STOP).
## The ghost is WYSIWYG: [ and ] rotate it live, and the click places it exactly as shown.
func handle_input(camera: Camera3D, event: InputEvent) -> bool:
	if not is_armed():
		return false

	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				disarm()
				return true
			KEY_BRACKETLEFT:
				return _nudge_yaw(-ROTATE_STEP)
			KEY_BRACKETRIGHT:
				return _nudge_yaw(ROTATE_STEP)

	# Shift + mouse wheel rotates the ghost. A wheel tick emits BOTH a press and a release;
	# swallow both so the editor camera can't zoom on the half we don't act on. When random
	# yaw owns the angle we don't rotate, so let the wheel zoom as usual.
	if event is InputEventMouseButton and event.shift_pressed \
			and (event.button_index == MOUSE_BUTTON_WHEEL_UP \
				or event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
		if event.pressed:
			_nudge_yaw(ROTATE_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else -ROTATE_STEP)
		return true

	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		disarm()
		return true

	if event is InputEventMouseMotion:
		_last_point = _ground_point(camera, event.position)
		_update_ghost()
		return true

	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		_last_point = _ground_point(camera, event.position)
		_commit(_place_xform(_last_point, _preview_yaw))
		if random_yaw:            # re-seed the next drop; keep it visible where the cursor is
			_set_yaw(randf() * TAU)
		return true

	return false


## Manual rotate ([ ] / Shift+wheel). Returns whether it acted, so the caller only consumes
## the event when random yaw isn't owning the angle (otherwise the editor keeps the input).
func _nudge_yaw(delta: float) -> bool:
	_set_yaw(_preview_yaw + delta)
	return true


## Set the live yaw, refresh the ghost, and notify the dock field. Single source of truth
## for the placement angle.
func _set_yaw(yaw: float) -> void:
	_preview_yaw = fposmod(yaw, TAU)
	_update_ghost()
	yaw_changed.emit(rad_to_deg(_preview_yaw))


## Called by the plugin when the dock's Yaw field changes.
func set_base_yaw(degrees: float) -> void:
	base_yaw = deg_to_rad(degrees)
	if not random_yaw and is_armed():
		_set_yaw(base_yaw)


func _update_ghost() -> void:
	if is_instance_valid(_ghost):
		_ghost.visible = true
		_ghost.global_transform = _place_xform(_last_point, _preview_yaw)


func _place_xform(pos: Vector3, yaw: float) -> Transform3D:
	if snap_enabled and snap_step > 0.0:
		pos.x = snappedf(pos.x, snap_step)
		pos.z = snappedf(pos.z, snap_step)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


# ------------------------------------------------------------------ ground raycast

## Fallback chain (plan LK2), extracted to ground_snap.gd (shared with the LK7 road
## draw tool); the ghost's zeroed collision stays excluded from the ray.
func _ground_point(camera: Camera3D, mouse_pos: Vector2) -> Vector3:
	return GroundSnap.ground_point(camera, mouse_pos, _ghost_excludes)


# ------------------------------------------------------------------ commit

func _commit(world_xform: Transform3D) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return
	var authoring := _find_authoring(scene_root)
	if authoring == null:
		push_warning("Kit: AuthoringRoot vanished — re-arm to place.")
		disarm()
		return
	var scene := _load_prefab(_armed_kit, _armed_name)
	if scene == null:
		return
	var node := scene.instantiate() as Node3D
	if node == null:
		return
	node.name = _armed_name.to_pascal_case()
	# AuthoringRoot may be translated; store the placement as a local transform under it.
	var local := (authoring as Node3D).global_transform.affine_inverse() * world_xform

	# custom_context pins the action to the edited scene's undo history — without it the
	# manager infers the global history from the orphan node and errors "history mismatch".
	_undo.create_action("Place " + _armed_name, UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_method(authoring, "add_child", node)
	_undo.add_do_method(node, "set_owner", scene_root)
	_undo.add_do_property(node, "transform", local)
	_undo.add_do_reference(node)
	_undo.add_undo_method(authoring, "remove_child", node)
	_undo.commit_action()


# ------------------------------------------------------------------ palette tiles

## Route a palette-tile pick to the built-in GridMap workflow (plan LK2: never reimplement
## painting). Selects — creating if absent — the AuthoringRoot GridMap that uses this kit's
## meshlib, so the built-in palette (with LK1b thumbnails) opens ready to paint.
func select_tile(kit: String, name: String) -> void:
	# Painting tiles is the built-in GridMap workflow, so drop any armed prefab — otherwise
	# the ghost stays on the cursor and swallows the clicks meant for the GridMap.
	disarm()
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		push_warning("Kit: open a level scene before selecting a tile.")
		return
	var authoring := _find_authoring(scene_root)
	if authoring == null:
		push_warning("Kit: this scene has no AuthoringRoot — add one before painting tiles.")
		return
	var meshlib_path := "%s/%s.meshlib" % [PALETTE_DIR, kit]
	var meshlib := load(meshlib_path) as MeshLibrary
	if meshlib == null:
		push_warning("Kit: no palette meshlib for kit '%s'." % kit)
		return

	var grid := _find_gridmap(authoring, meshlib_path)
	if grid == null:
		grid = _create_gridmap(kit, meshlib, authoring, scene_root)

	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(grid)
	EditorInterface.edit_node(grid)

	var item_id := _meshlib_item_id(meshlib, name)
	if item_id < 0:
		push_warning("Kit: tile '%s' not in %s." % [name, kit])
	else:
		# The built-in GridMapEditorPlugin instance isn't reachable via public API, so we
		# can't force its selected palette item. The name/id below tells the author which
		# tile to click in the now-open palette (which shows the same thumbnail).
		print("Kit: paint tile '%s' (item %d) in the GridMap palette." % [name, item_id])


func _create_gridmap(kit: String, meshlib: MeshLibrary, authoring: Node, scene_root: Node) -> GridMap:
	var grid := GridMap.new()
	grid.name = "%sTiles" % kit.capitalize()
	grid.mesh_library = meshlib
	grid.cell_center_y = false
	var cell := _palette_cell_size(kit)
	if cell != Vector3.ZERO:
		grid.cell_size = cell
	_undo.create_action("Add %s GridMap" % kit, UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_method(authoring, "add_child", grid)
	_undo.add_do_method(grid, "set_owner", scene_root)
	_undo.add_do_reference(grid)
	_undo.add_undo_method(authoring, "remove_child", grid)
	_undo.commit_action()
	return grid


# ------------------------------------------------------------------ helpers

func _load_prefab(kit: String, name: String) -> PackedScene:
	var path := "%s/%s/%s.tscn" % [PREFAB_DIR, kit, name]
	if not ResourceLoader.exists(path):
		return null
	return load(path) as PackedScene


static func _find_authoring(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_carlito_authoring"):
		return node
	for child in node.get_children():
		var found := _find_authoring(child)
		if found != null:
			return found
	return null


static func _find_gridmap(node: Node, meshlib_path: String) -> GridMap:
	if node is GridMap:
		var ml := (node as GridMap).mesh_library
		if ml != null and ml.resource_path == meshlib_path:
			return node
	for child in node.get_children():
		var found := _find_gridmap(child, meshlib_path)
		if found != null:
			return found
	return null


static func _collect_bodies(node: Node) -> Array[CollisionObject3D]:
	var out: Array[CollisionObject3D] = []
	_gather_bodies(node, out)
	return out


static func _gather_bodies(node: Node, out: Array[CollisionObject3D]) -> void:
	if node is CollisionObject3D:
		out.append(node)
	for child in node.get_children():
		_gather_bodies(child, out)


static func _meshlib_item_id(meshlib: MeshLibrary, name: String) -> int:
	for id in meshlib.get_item_list():
		if meshlib.get_item_name(id) == name:
			return id
	return -1


## Read the kit recipe's palette cell_size so a created GridMap matches the baked lattice.
static func _palette_cell_size(kit: String) -> Vector3:
	var path := "%s/%s.json" % [RECIPE_DIR, kit]
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary and (parsed as Dictionary).has("palette"):
		var cell: Array = (parsed as Dictionary).palette.get("cell_size", [])
		if cell.size() == 3:
			return Vector3(float(cell[0]), float(cell[1]), float(cell[2]))
	return Vector3.ZERO
