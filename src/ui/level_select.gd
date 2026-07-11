class_name LevelSelect
extends Control
## Level-select screen (plan §4.6): the shell's first screen. Walks LevelRegistry and
## emits the chosen scene path. Plain text + a dim backdrop, no emoji (plan §2 rule 10).
## Built in code (like the dashboard) — it is a transient overlay the shell frees on pick.

signal level_chosen(scene_path: String)

const TITLE_COLOR := Color(0.90, 0.93, 0.98)
const BG_COLOR := Color(0.05, 0.06, 0.08, 0.96)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks behind the menu
	add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 12)
	add_child(col)

	var title := Label.new()
	title.text = "CARLITO 2  -  SELECT LEVEL"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	col.add_child(title)

	for entry in LevelRegistry.LEVELS:
		# Temporary: dev fixtures (kit_fixture, terrain_demo) are normally hidden as
		# CI/bake assets, but shown here to facilitate testing (revert this later).
		var b := Button.new()
		b.text = entry["name"]
		b.custom_minimum_size = Vector2(260, 44)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(_on_level_pressed.bind(String(entry["scene"])))
		col.add_child(b)


func _on_level_pressed(scene_path: String) -> void:
	level_chosen.emit(scene_path)
