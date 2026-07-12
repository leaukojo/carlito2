class_name DebugOverlay
extends Label
## Always-available perf overlay ("the FPS/draw-call overlay is always
## available"). Toggle with F3 (the "debug_overlay" action). Reads the engine's own
## Performance monitors — FPS, frame time, draw calls, primitives, VRAM, node count —
## so the §5.4 web budget (60 fps, < ~500 draw calls) can be checked while driving.
## Plain text only.

const REFRESH := 0.25  ## s between text rebuilds (per-frame churn is pointless and noisy)

var _accum := 0.0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	offset_left = -260.0
	offset_top = 8.0
	offset_right = -8.0
	add_theme_color_override("font_color", Color(0.55, 1.0, 0.65))
	add_theme_font_size_override("font_size", 13)
	# Keep updating (to toggle) even if the tree is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_overlay"):
		visible = not visible
		if visible:
			_refresh()
		accept_event()


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum >= REFRESH:
		_accum = 0.0
		_refresh()


func _refresh() -> void:
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var prims := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var vram := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var frame_ms := (Performance.get_monitor(Performance.TIME_PROCESS)
			+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	text = "FPS %d  (%.1f ms)\ndraw calls %d\nprimitives %d\nVRAM %.1f MB\nnodes %d" % [
		Engine.get_frames_per_second(), frame_ms, draw_calls, prims, vram, nodes]
