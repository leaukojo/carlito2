@tool
extends VBoxContainer
## Terrain-brush panel: the inspector-side controls for the
## sculpt/paint brush. Mode buttons (Off/Raise/Lower/Smooth/Flatten/Paint), a splat-channel
## picker shown only in Paint mode, and radius/strength/falloff spinners. UI only — the
## viewport/edit logic lives in terrain_brush.gd (the editor/runtime split). Modes are
## index-matched to terrain_brush.gd's enum (0 = Off .. 5 = Paint).

signal mode_changed(mode: int)
signal channel_changed(channel: int)
signal params_changed(radius: float, strength: float, falloff: float)

const MODE_LABELS := ["Off", "Raise", "Lower", "Smooth", "Flatten", "Paint"]
const MODE_TOOLTIPS := [
	"Brush disabled. Click another mode to start editing.",
	"Drag in the 3D view to pull the ground up.",
	"Drag in the 3D view to push the ground down.",
	"Averages out bumps and jaggies. Use it to soften an area you overdid.",
	"Levels the ground to the height where your drag STARTED — good for building pads " \
			+ "and fields. (Smooth rounds things; Flatten makes them level.)",
	"Colors the ground with the selected channel instead of changing its shape.",
]
const CHANNEL_LABELS := ["Grass", "Dirt", "Sand", "Rock"]

var _status: Label
var _mode_group := ButtonGroup.new()
var _mode_buttons: Array[Button] = []
var _channel_box: OptionButton
var _channel_row: HBoxContainer
var _radius: SpinBox
var _strength: SpinBox
var _falloff: SpinBox


func _init() -> void:
	name = "Terrain Brush"
	add_theme_constant_override("separation", 6)
	_build()
	set_has_terrain(false)


func _build() -> void:
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)

	add_child(_heading("Mode"))
	var grid := GridContainer.new()
	grid.columns = 3
	add_child(grid)
	for i in MODE_LABELS.size():
		var b := Button.new()
		b.text = MODE_LABELS[i]
		b.toggle_mode = true
		b.button_group = _mode_group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = MODE_TOOLTIPS[i]
		if i == 0:
			b.button_pressed = true
		b.pressed.connect(func(): mode_changed.emit(i))
		_mode_buttons.append(b)
		grid.add_child(b)

	_channel_row = HBoxContainer.new()
	add_child(_channel_row)
	var ch_label := Label.new()
	ch_label.text = "Channel"
	ch_label.tooltip_text = "Which ground color to paint."
	_channel_row.add_child(ch_label)
	_channel_box = OptionButton.new()
	_channel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_channel_box.tooltip_text = "Which ground color to paint."
	for name in CHANNEL_LABELS:
		_channel_box.add_item(name)
	_channel_box.item_selected.connect(func(i): channel_changed.emit(i))
	_channel_row.add_child(_channel_box)
	_channel_row.visible = false

	add_child(HSeparator.new())
	_radius = _spinner("Radius", 0.5, 512.0, 0.5, 8.0,
			"Brush size in meters. The car is 1.8 m long; a two-lane road is ~12 m wide. " \
			+ "[ and ] change it while brushing.")
	_strength = _spinner("Strength", 0.0, 1.0, 0.05, 0.5,
			"How much each stroke changes things. Low = gentle passes, high = fast.")
	_falloff = _spinner("Edge softness", 0.0, 1.0, 0.05, 0.5,
			"How the effect fades toward the brush rim. 0 = hard-edged stamp, " \
			+ "1 = smooth dome that fades from the center.")

	var hint := Label.new()
	hint.text = "Select a HeightmapTerrain, pick a mode, then drag in the 3D view.\n" \
			+ "[ and ] shrink / grow the brush."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	hint.add_theme_font_size_override("font_size", 11)
	add_child(hint)


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.7, 0.8, 1.0))
	return l


func _spinner(label: String, lo: float, hi: float, step: float, value: float,
		tooltip: String) -> SpinBox:
	var row := HBoxContainer.new()
	add_child(row)
	var l := Label.new()
	l.text = label
	l.tooltip_text = tooltip
	l.custom_minimum_size = Vector2(70, 0)
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = lo
	sb.max_value = hi
	sb.step = step
	sb.value = value
	sb.tooltip_text = tooltip
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(func(_v): _emit_params())
	row.add_child(sb)
	return sb


func _emit_params() -> void:
	params_changed.emit(_radius.value, _strength.value, _falloff.value)


# ------------------------------------------------------------------ plugin API

## Called by the plugin when a mode button is pressed, so the panel can reveal the channel
## picker for Paint and hint at the required source image.
func on_mode(mode: int) -> void:
	_channel_row.visible = (mode == 5)  # PAINT


## Reflect a bracket-key radius change without re-emitting params_changed.
func set_radius_display(r: float) -> void:
	_radius.set_block_signals(true)
	_radius.value = r
	_radius.set_block_signals(false)


func set_has_terrain(has: bool) -> void:
	for b in _mode_buttons:
		b.disabled = not has
	_channel_box.disabled = not has
	if has:
		_status.text = "Terrain selected — ready to brush."
		_status.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
	else:
		_status.text = "No HeightmapTerrain selected."
		_status.add_theme_color_override("font_color", Color(0.9, 0.7, 0.4))
		# Snap back to Off so a stale mode can't act on the next selected terrain.
		# Setting button_pressed programmatically does NOT emit `pressed`, so emit
		# mode_changed ourselves — otherwise the brush keeps its old mode and would
		# sculpt the next selected terrain even though the panel reads "Off".
		if not _mode_buttons.is_empty() and not _mode_buttons[0].button_pressed:
			_mode_buttons[0].button_pressed = true
			_channel_row.visible = false
			mode_changed.emit(0)
