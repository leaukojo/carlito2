@tool
extends EditorPlugin
## Kit editor surface: the export-time authoring stripper (always) plus the LK2 palette
## dock + click-to-place tool. The dock browses the LK1 kit assets; viewport clicks are
## forwarded here to the placement tool. All editor API stays in this addon (plan §2's
## editor/runtime split).

const StripExport := preload("res://addons/carlito_kit/strip_export.gd")
const PaletteDock := preload("res://addons/carlito_kit/palette_dock.gd")
const PlacementTool := preload("res://addons/carlito_kit/placement_tool.gd")

var _strip: EditorExportPlugin
var _dock: Control
var _tool  # PlacementTool (RefCounted)


func _enter_tree() -> void:
	_strip = StripExport.new()
	add_export_plugin(_strip)

	_tool = PlacementTool.new(get_undo_redo())
	_dock = PaletteDock.new()
	_dock.prefab_armed.connect(func(kit, name): _tool.arm(kit, name))
	_dock.tile_selected.connect(func(kit, name): _tool.select_tile(kit, name))
	_dock.settings_changed.connect(_on_settings_changed)
	_tool.yaw_changed.connect(func(deg): _dock.set_yaw_display(deg))
	add_control_to_bottom_panel(_dock, "Kit")
	# Placement works regardless of selection, so we need every viewport event (docs:
	# "especially usable if your plugin will want to use raycast in the scene").
	set_input_event_forwarding_always_enabled()


func _exit_tree() -> void:
	remove_export_plugin(_strip)
	_strip = null

	if _tool != null:
		_tool.disarm()
	_tool = null
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.free()
	_dock = null


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _tool != null and _tool.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_settings_changed(random_yaw: bool, snap_enabled: bool, snap_step: float,
		yaw_deg: float) -> void:
	if _tool == null:
		return
	_tool.random_yaw = random_yaw
	_tool.snap_enabled = snap_enabled
	_tool.snap_step = snap_step
	_tool.set_base_yaw(yaw_deg)
