@tool
extends VBoxContainer
## Road-draw panel: the inspector-side toggle for the draw-on-terrain road tool.
## Off/Draw mode buttons only — clearance lives on the RoadPath node itself
## (draw_clearance), matching where a ScatterCanvas keeps its knobs. UI only; the
## viewport/edit logic lives in road_draw_tool.gd (the editor/runtime split).
## Modes are index-matched to the plugin's expectation (0 = Off, 1 = Draw).

signal mode_changed(mode: int)
signal close_requested
signal smooth_corners_changed(on: bool)
signal snap_ports_changed(on: bool)
signal snap_ends_requested

const MODE_LABELS := ["Off", "Draw"]

var _status: Label
var _mode_group := ButtonGroup.new()
var _mode_buttons: Array[Button] = []
var _smooth: CheckBox
var _snap_ports: CheckBox
var _close: Button
var _snap_ends: Button


func _init() -> void:
	name = "Road Draw"
	add_theme_constant_override("separation", 6)
	_build()
	set_has_road(false)


func _build() -> void:
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	var heading := Label.new()
	heading.text = "Mode"
	heading.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	add_child(heading)

	var row := HBoxContainer.new()
	add_child(row)
	for i in MODE_LABELS.size():
		var b := Button.new()
		b.text = MODE_LABELS[i]
		b.toggle_mode = true
		b.button_group = _mode_group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if i == 0:
			b.button_pressed = true
		b.pressed.connect(func(): mode_changed.emit(i))
		_mode_buttons.append(b)
		row.add_child(b)

	_smooth = CheckBox.new()
	_smooth.text = "Smooth corners"
	_smooth.button_pressed = true
	_smooth.tooltip_text = "Give each drawn point Catmull-Rom handles. Off: the road " \
			+ "follows the clicks exactly, with angled connections at the corners."
	_smooth.toggled.connect(func(on: bool): smooth_corners_changed.emit(on))
	add_child(_smooth)

	_snap_ports = CheckBox.new()
	_snap_ports.text = "Snap to ports"
	_snap_ports.button_pressed = true
	_snap_ports.tooltip_text = "Drawn end points near an open city-tile edge capture " \
			+ "onto its port with the tangent locked perpendicular to the face; " \
			+ "arriving at a port ends the draw."
	_snap_ports.toggled.connect(func(on: bool): snap_ports_changed.emit(on))
	add_child(_snap_ports)

	_close = Button.new()
	_close.text = "Close loop"
	_close.tooltip_text = "Append a point on the first point with a smooth seam, then exit Draw."
	_close.pressed.connect(func(): close_requested.emit())
	add_child(_close)

	_snap_ends = Button.new()
	_snap_ends.text = "Snap ends to ports"
	_snap_ends.tooltip_text = "Snap the road's first/last points to the nearest open " \
			+ "tile port (within 6 m) and lock their tangents — the fixup after " \
			+ "dragging an end with the gizmo. One undo step."
	_snap_ends.pressed.connect(func(): snap_ends_requested.emit())
	add_child(_snap_ends)

	var hint := Label.new()
	hint.text = "Select a RoadPath, pick Draw, then click the ground in the 3D view " \
			+ "to append curve points (each click is one undo step). Right-click or " \
			+ "Escape exits; Close loop joins the road back to its first point. " \
			+ "Clearance is draw_clearance on the node; Drape and " \
			+ "Conform buttons are on its inspector."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hint.add_theme_font_size_override("font_size", 11)
	add_child(hint)


# ------------------------------------------------------------------ plugin API

## Reflect a tool-driven exit (RMB/Escape) without re-emitting mode_changed — the
## plugin already knows (programmatic button_pressed doesn't emit `pressed`).
func show_off() -> void:
	if not _mode_buttons.is_empty():
		_mode_buttons[0].button_pressed = true


func set_has_road(has: bool) -> void:
	for b in _mode_buttons:
		b.disabled = not has
	_smooth.disabled = not has
	_snap_ports.disabled = not has
	_close.disabled = not has
	_snap_ends.disabled = not has
	if has:
		_status.text = "RoadPath selected — ready to draw."
		_status.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	else:
		_status.text = "No RoadPath selected."
		_status.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4))
		# Snap back to Off so a stale mode can't act on the next selected road (the
		# scatter panel pattern: programmatic button_pressed doesn't emit, so emit).
		if not _mode_buttons.is_empty() and not _mode_buttons[0].button_pressed:
			_mode_buttons[0].button_pressed = true
			mode_changed.emit(0)
