class_name LoadingScreen
extends Control
## Loading overlay shown while a level scene streams in (threaded load in boot.gd).
## Plain text + a progress bar, no emoji. Built in code (like LevelSelect) — a
## transient overlay the shell frees once the level is up.

const TITLE_COLOR := Color(0.90, 0.93, 0.98)
const BG_COLOR := Color(0.05, 0.06, 0.08, 0.96)
const BAR_FILL := Color(0.55, 0.75, 0.95)
const BAR_BG := Color(0.16, 0.18, 0.22)

var _bar: ProgressBar = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow clicks while loading
	add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	col.grow_horizontal = Control.GROW_DIRECTION_BOTH
	col.grow_vertical = Control.GROW_DIRECTION_BOTH
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 16)
	add_child(col)

	var title := Label.new()
	title.text = "LOADING"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	col.add_child(title)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(320, 18)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = BAR_BG
	var fill_style := StyleBoxFlat.new()
	fill_style.bg_color = BAR_FILL
	_bar.add_theme_stylebox_override("background", bg_style)
	_bar.add_theme_stylebox_override("fill", fill_style)
	col.add_child(_bar)


func set_progress(p: float) -> void:
	if _bar != null:
		_bar.value = clampf(p, 0.0, 1.0)
