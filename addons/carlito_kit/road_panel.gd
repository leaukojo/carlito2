@tool
extends VBoxContainer
## LK7 road-draw panel: the inspector-side toggle for the draw-on-terrain road tool.
## Off/Draw mode buttons only — clearance lives on the RoadPath node itself
## (draw_clearance), matching where a ScatterCanvas keeps its knobs. UI only; the
## viewport/edit logic lives in road_draw_tool.gd (plan's editor/runtime split).
## Modes are index-matched to the plugin's expectation (0 = Off, 1 = Draw).

signal mode_changed(mode: int)
signal close_requested

const MODE_LABELS := ["Off", "Draw"]

var _status: Label
var _mode_group := ButtonGroup.new()
var _mode_buttons: Array[Button] = []
var _close: Button


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

	_close = Button.new()
	_close.text = "Close loop"
	_close.tooltip_text = "Append a point on the first point with a smooth seam, then exit Draw."
	_close.pressed.connect(func(): close_requested.emit())
	add_child(_close)

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
	_close.disabled = not has
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
