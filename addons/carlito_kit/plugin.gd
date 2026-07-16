@tool
extends EditorPlugin
## Kit editor surface: the export-time authoring stripper (always), the palette dock +
## click-to-place tool, and the terrain sculpt/paint brush. The dock browses the kit
## assets; viewport clicks are forwarded here to whichever tool is active — the brush when a
## HeightmapTerrain is selected with a mode picked, else the placement tool. All editor API
## stays in this addon (the editor/runtime split).

const StripExport := preload("res://addons/carlito_kit/strip_export.gd")
const PaletteDock := preload("res://addons/carlito_kit/palette_dock.gd")
const PlacementTool := preload("res://addons/carlito_kit/placement_tool.gd")
const TerrainBrush := preload("res://addons/carlito_kit/terrain_brush.gd")
const BrushPanel := preload("res://addons/carlito_kit/brush_panel.gd")
const ScatterGizmo := preload("res://addons/carlito_kit/scatter_gizmo.gd")
const ScatterBrush := preload("res://addons/carlito_kit/scatter_brush.gd")
const ScatterPanel := preload("res://addons/carlito_kit/scatter_panel.gd")
const RoadDrawTool := preload("res://addons/carlito_kit/road_draw_tool.gd")
const RoadPanel := preload("res://addons/carlito_kit/road_panel.gd")

var _strip: EditorExportPlugin
var _dock: Control
var _tool  # PlacementTool (RefCounted)
var _brush  # TerrainBrush (RefCounted)
var _panel: Control
var _scatter_gizmo: EditorNode3DGizmoPlugin
var _scatter_brush  # ScatterBrush (RefCounted)
var _scatter_panel: Control
var _road_tool  # RoadDrawTool (RefCounted)
var _road_panel: Control
var _tools_root: Control


func _enter_tree() -> void:
	_strip = StripExport.new()
	add_export_plugin(_strip)

	_scatter_gizmo = ScatterGizmo.new()
	add_node_3d_gizmo_plugin(_scatter_gizmo)

	_tool = PlacementTool.new(get_undo_redo())
	_dock = PaletteDock.new()
	_dock.prefab_armed.connect(func(kit, name):
		_drop_road_draw()  # the placement ghost owns the viewport now
		_tool.arm(kit, name))
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
	_panel.flatten_changed.connect(func(fixed, height, step):
		_brush.flatten_fixed = fixed
		_brush.flatten_height = height
		_brush.snap_step = step)
	_panel.shape_changed.connect(func(square): _brush.square = square)
	_panel.grid_snap_changed.connect(func(on):
		_brush.grid_snap = on
		if on:
			_panel.set_snap_step(_brush.grid_cell_y()))
	_panel.pick_requested.connect(func(): _brush.arm_pick())
	_panel.fill_requested.connect(func(): _brush.fill_terrain())
	_brush.radius_display.connect(func(r): _panel.set_radius_display(r))
	_brush.height_picked.connect(func(y): _panel.set_picked_height(y))

	_scatter_brush = ScatterBrush.new(get_undo_redo())
	_scatter_panel = ScatterPanel.new()
	_scatter_panel.mode_changed.connect(_on_scatter_mode)
	_scatter_panel.radius_changed.connect(func(r): _scatter_brush.radius = r)
	_scatter_brush.radius_display.connect(func(r): _scatter_panel.set_radius_display(r))

	_road_tool = RoadDrawTool.new(get_undo_redo())
	_road_panel = RoadPanel.new()
	_road_panel.mode_changed.connect(_on_road_mode)
	_road_panel.close_requested.connect(func(): _road_tool.close_loop())
	_road_panel.smooth_corners_changed.connect(func(on): _road_tool.smooth_corners = on)
	_road_tool.deactivated.connect(func(): _road_panel.show_off())

	# The three tool panels share a "Kit Tools" bottom panel (like the Kit dock):
	# add_control_to_dock is a deprecated compatibility path in 4.6 whose EditorDock
	# wrapper breaks 3D viewport navigation (WASD freelook, F focus, wheel speed).
	_tools_root = ScrollContainer.new()
	_tools_root.name = "Kit Tools"
	_tools_root.custom_minimum_size = Vector2(0, 240)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 24)
	_tools_root.add_child(box)
	for panel in [_panel, _scatter_panel, _road_panel]:
		panel.custom_minimum_size = Vector2(300, 0)
		box.add_child(panel)
	_panel.custom_minimum_size = Vector2(600, 0)  # terrain brush: extra room for mode grid + spinners
	add_control_to_bottom_panel(_tools_root, "Kit Tools")

	EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	# Placement works regardless of selection, so we need every viewport event (docs:
	# "especially usable if your plugin will want to use raycast in the scene").
	set_input_event_forwarding_always_enabled()


func _exit_tree() -> void:
	remove_export_plugin(_strip)
	_strip = null

	remove_node_3d_gizmo_plugin(_scatter_gizmo)
	_scatter_gizmo = null

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
	_panel = null

	if _scatter_brush != null:
		_scatter_brush.teardown()
	_scatter_brush = null
	_scatter_panel = null

	if _road_tool != null:
		_road_tool.teardown()
	_road_tool = null
	_road_panel = null

	if _tools_root != null:
		remove_control_from_bottom_panel(_tools_root)
		_tools_root.free()  # frees the three panels with it
	_tools_root = null


## Save hook: brush edits accumulate in memory and are written to the heightmap /
## splat PNGs only when the scene is saved — never reimported per stroke.
func _save_external_data() -> void:
	if _brush != null:
		_brush.flush_all()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if _brush != null and _brush.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _scatter_brush != null and _scatter_brush.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _road_tool != null and _road_tool.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _tool != null and _tool.handle_input(camera, event):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _on_brush_mode(mode: int) -> void:
	_brush.set_mode(mode)
	_panel.on_mode(mode)
	if mode != 0:  # a brush mode owns the viewport — drop any armed placement ghost
		_tool.disarm()
		_drop_road_draw()


## Scatter brush mode picked: a non-Off mode owns the viewport, so drop the placement ghost
## (same rule as the terrain brush).
func _on_scatter_mode(mode: int) -> void:
	_scatter_brush.set_mode(mode)
	if mode != 0:
		_tool.disarm()
		_drop_road_draw()


## Road Draw mode picked: same viewport-ownership rule as the brushes.
func _on_road_mode(mode: int) -> void:
	_road_tool.set_active(mode == 1)
	if mode != 0:
		_tool.disarm()


func _drop_road_draw() -> void:
	_road_tool.set_active(false)
	_road_panel.show_off()


func _on_selection_changed() -> void:
	var terrain: HeightmapTerrain = null
	var canvas: ScatterCanvas = null
	var road: RoadPath = null
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is HeightmapTerrain:
			terrain = node
		elif node is ScatterCanvas:
			canvas = node
		elif node is RoadPath:
			road = node
	_brush.set_target(terrain)
	_brush.set_grid(_find_road_gridmap())
	_panel.set_has_terrain(terrain != null)
	if terrain != null:
		# Channel names and colors are the terrain's own data, so the picker is rebuilt per
		# selection rather than hard-coded in the panel.
		var colors := PackedColorArray()
		for i in 8:
			colors.append(terrain.channel_color(i))
		_panel.set_channels(terrain.channel_names, colors)
	_scatter_brush.set_target(canvas)
	_scatter_panel.set_has_canvas(canvas != null)
	_road_tool.set_target(road)
	_road_panel.set_has_road(road != null)
	if terrain != null or canvas != null or road != null:
		make_bottom_panel_item_visible(_tools_root)


## The road GridMap the brush snaps to (null if the level has none yet — the brush then falls
## back to a 12 m lattice at origin). Prefers the conventional "RoadsTiles" node; else the
## first GridMap found in the edited scene.
func _find_road_gridmap() -> GridMap:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var found: GridMap = null
	for node in root.find_children("*", "GridMap", true, false):
		var gm := node as GridMap
		if gm.name == "RoadsTiles":
			return gm
		if found == null:
			found = gm
	return found


func _on_settings_changed(random_yaw: bool, snap_enabled: bool, snap_step: float,
		yaw_deg: float) -> void:
	if _tool == null:
		return
	_tool.random_yaw = random_yaw
	_tool.snap_enabled = snap_enabled
	_tool.snap_step = snap_step
	_tool.set_base_yaw(yaw_deg)
