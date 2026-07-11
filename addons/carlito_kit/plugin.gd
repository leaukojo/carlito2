@tool
extends EditorPlugin
## Kit editor surface: the export-time authoring stripper (always), the LK2 palette dock +
## click-to-place tool, and the LK4 terrain sculpt/paint brush. The dock browses the LK1 kit
## assets; viewport clicks are forwarded here to whichever tool is active — the brush when a
## HeightmapTerrain is selected with a mode picked, else the placement tool. All editor API
## stays in this addon (plan §2's editor/runtime split).

const StripExport := preload("res://addons/carlito_kit/strip_export.gd")
const PaletteDock := preload("res://addons/carlito_kit/palette_dock.gd")
const PlacementTool := preload("res://addons/carlito_kit/placement_tool.gd")
const TerrainBrush := preload("res://addons/carlito_kit/terrain_brush.gd")
const BrushPanel := preload("res://addons/carlito_kit/brush_panel.gd")

var _strip: EditorExportPlugin
var _dock: Control
var _tool  # PlacementTool (RefCounted)
var _brush  # TerrainBrush (RefCounted)
var _panel: Control


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

	_brush = TerrainBrush.new(get_undo_redo())
	_panel = BrushPanel.new()
	_panel.mode_changed.connect(_on_brush_mode)
	_panel.channel_changed.connect(func(ch): _brush.channel = ch)
	_panel.params_changed.connect(func(r, s, f):
		_brush.radius = r
		_brush.strength = s
		_brush.falloff = f)
	_brush.radius_display.connect(func(r): _panel.set_radius_display(r))
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _panel)

	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# Placement works regardless of selection, so we need every viewport event (docs:
	# "especially usable if your plugin will want to use raycast in the scene").
	set_input_event_forwarding_always_enabled()


func _exit_tree() -> void:
	remove_export_plugin(_strip)
	_strip = null

	EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)

	if _tool != null:
		_tool.disarm()
	_tool = null
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.free()
	_dock = null

	if _brush != null:
		_brush.teardown()
	_brush = null
	if _panel != null:
		remove_control_from_docks(_panel)
		_panel.free()
	_panel = null


## Save hook (plan LK4): brush edits accumulate in memory and are written to the heightmap /
## splat PNGs only when the scene is saved — never reimported per stroke.
func _save_external_data() -> void:
	if _brush != null:
		_brush.flush_all()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _brush != null and _brush.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _tool != null and _tool.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_brush_mode(mode: int) -> void:
	_brush.set_mode(mode)
	_panel.on_mode(mode)
	if mode != 0:  # a brush mode owns the viewport — drop any armed placement ghost
		_tool.disarm()


func _on_selection_changed() -> void:
	var terrain: HeightmapTerrain = null
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is HeightmapTerrain:
			terrain = node
			break
	_brush.set_target(terrain)
	_panel.set_has_terrain(terrain != null)


func _on_settings_changed(random_yaw: bool, snap_enabled: bool, snap_step: float,
		yaw_deg: float) -> void:
	if _tool == null:
		return
	_tool.random_yaw = random_yaw
	_tool.snap_enabled = snap_enabled
	_tool.snap_step = snap_step
	_tool.set_base_yaw(yaw_deg)
