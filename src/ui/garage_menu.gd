class_name GarageMenu
extends Control
## In-play garage menu (plan §4.6): lists the level's allowed vehicles and asks the shell
## to respawn the player as the chosen one at a matching spawn marker. Reads
## LevelInfo.allowed_vehicles (passed by the shell) — it never touches the scene tree
## itself. Plain text, no emoji (plan §2 rule 10).

signal vehicle_chosen(type: String)
signal closed

const TITLE_COLOR := Color(0.90, 0.93, 0.98)
const BG_COLOR := Color(0.05, 0.06, 0.08, 0.90)

var _allowed: PackedStringArray = []


## Populate from LevelInfo.allowed_vehicles; call before adding to the tree.
func setup(allowed: PackedStringArray) -> void:
	_allowed = allowed


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 10)
	add_child(col)

	var title := Label.new()
	title.text = "GARAGE  -  CHOOSE VEHICLE"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	col.add_child(title)

	for type in _allowed:
		var b := Button.new()
		b.text = String(type).to_upper()
		b.custom_minimum_size = Vector2(240, 42)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(_on_vehicle_pressed.bind(String(type)))
		col.add_child(b)

	var close := Button.new()
	close.text = "CLOSE"
	close.custom_minimum_size = Vector2(240, 36)
	close.pressed.connect(func() -> void: closed.emit())
	col.add_child(close)


func _on_vehicle_pressed(type: String) -> void:
	vehicle_chosen.emit(type)
