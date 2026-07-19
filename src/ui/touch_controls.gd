class_name TouchControls
extends Control
## On-screen touch controls, rebuilt on the InputRouter as a second local source
##: a steering joystick (bottom-left), gas/brake pedals (bottom-right),
## and a right-edge button stack. It reports raw intents via poll() exactly like
## local_source.gd — arbitration stays in InputRouter. Plain text, no
## emoji.
##
## Bridge-conflicting buttons (horn / lights / handbrake — sloppyCAN owns those while the
## bridge is live) are hidden whenever Bridge.is_active(); the shell buttons
## (garage / respawn) stay. Widgets respond to touch AND mouse, so the layout is
## verifiable on desktop with the F4 toggle.

signal garage_pressed
signal respawn_pressed
signal next_vehicle_pressed

const JOY_RADIUS := 90.0
const KNOB_SIZE := 66.0
const BTN_SIZE := Vector2(96, 44)

var _steer := 0.0
var _accel := 0.0
var _brake := 0.0
var _handbrake := 0.0
var _horn := false
var _lights_cycle_pending := false  ## latched on the LIGHTS tap, consumed by poll()

var _joy_knob: Panel
var _joy_center := Vector2.ZERO
var _bridge_buttons: Array[Pad] = []  ## hidden while the bridge drives


## Touch-first press widget. It tracks WHICH pointer is holding it (a finger index, or
## MOUSE for a desktop click) so several pads can be held at the same time. A plain
## Button cannot: on mobile a Button only ever sees the mouse events Godot emulates from
## touch, and that emulation mirrors a single finger — hold GAS and the joystick goes
## deaf. Emulated events (device == DEVICE_ID_EMULATION) are ignored here so a real
## finger is never counted twice.
class Pad extends Panel:
	signal held(down: bool)
	signal moved(local_pos: Vector2)

	const NONE := -99
	const MOUSE := -1

	var _pointer := NONE

	func _gui_input(event: InputEvent) -> void:
		if event.device == InputEvent.DEVICE_ID_EMULATION:
			return
		var id := NONE
		var pressed := false
		if event is InputEventScreenTouch:
			id = event.index
			pressed = event.pressed
		elif event is InputEventMouseButton:
			if event.button_index != MOUSE_BUTTON_LEFT:
				return
			id = MOUSE
			pressed = event.pressed
		elif event is InputEventScreenDrag:
			if event.index == _pointer:
				moved.emit(event.position)
			return
		elif event is InputEventMouseMotion:
			if _pointer == MOUSE:
				moved.emit(event.position)
			return
		else:
			return

		if pressed:
			if _pointer == NONE:
				_pointer = id
				held.emit(true)
				moved.emit(event.position)
		elif id == _pointer:
			_pointer = NONE
			held.emit(false)

	## A pad hidden or removed mid-press never gets its release event; drop the hold so it
	## cannot stick once it comes back.
	func _notification(what: int) -> void:
		if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree() and _pointer != NONE:
			_pointer = NONE
			held.emit(false)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # only the widgets capture input
	_build_joystick()
	_build_pedals()
	_build_button_stack()
	visible = _should_show()
	InputRouter.set_touch_source(self)


func _exit_tree() -> void:
	InputRouter.clear_touch_source(self)


## Shell gate: show the controls only while a level is being played AND this is a device
## that wants them (touch / web). The F4 toggle can still force them on for desktop tests.
func set_active(active: bool) -> void:
	visible = active and _should_show()


## The raw intent dict InputRouter merges with the keyboard each tick (same keys as
## local_source.gd). Consumes the one-shot lights-cycle latch. Contributes nothing while
## hidden: a Button hidden mid-press (e.g. F4 while holding GAS) never emits button_up,
## so its held state would otherwise leak through merge_local's max and stick.
func poll() -> Dictionary:
	if not visible:
		return {}
	var cycle := _lights_cycle_pending
	_lights_cycle_pending = false
	return {
		"accel": _accel,
		"brake_reverse": _brake,
		"steer": _steer,
		"handbrake": _handbrake,
		"horn": _horn,
		"lights_cycle": cycle,
	}


func _process(_dt: float) -> void:
	# Hide the buttons sloppyCAN owns while it is driving.
	var driving := Bridge.is_active()
	for b in _bridge_buttons:
		b.visible = not driving
	if driving:
		# These buttons just hid mid-press won't emit button_up; clear their held state
		# so it can't persist once the bridge releases and they reappear.
		_horn = false
		_handbrake = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_touch"):
		visible = not visible


func _should_show() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.has_feature("web")


# --- joystick (steer) --------------------------------------------------------

func _build_joystick() -> void:
	var base := Pad.new()
	base.custom_minimum_size = Vector2(JOY_RADIUS * 2.0, JOY_RADIUS * 2.0)
	base.size = base.custom_minimum_size
	base.anchor_top = 1.0
	base.anchor_bottom = 1.0
	base.grow_vertical = Control.GROW_DIRECTION_BEGIN
	base.position = Vector2(40, -JOY_RADIUS * 2.0 - 40)
	base.add_theme_stylebox_override("panel", _ring_style(JOY_RADIUS))
	base.moved.connect(_move_knob)
	base.held.connect(func(down: bool) -> void:
		if not down:
			_steer = 0.0
			_reset_knob()
	)
	add_child(base)
	_joy_center = Vector2(JOY_RADIUS, JOY_RADIUS)

	_joy_knob = Panel.new()
	_joy_knob.size = Vector2(KNOB_SIZE, KNOB_SIZE)
	_joy_knob.add_theme_stylebox_override("panel", _ring_style(KNOB_SIZE * 0.5, Color(0.30, 0.34, 0.42, 0.95)))
	base.add_child(_joy_knob)
	_reset_knob()


func _move_knob(local_pos: Vector2) -> void:
	var offset := (local_pos - _joy_center).limit_length(JOY_RADIUS)
	_joy_knob.position = _joy_center + offset - Vector2(KNOB_SIZE, KNOB_SIZE) * 0.5
	_steer = clampf(offset.x / JOY_RADIUS, -1.0, 1.0)  # steering is the horizontal axis


func _reset_knob() -> void:
	_joy_knob.position = _joy_center - Vector2(KNOB_SIZE, KNOB_SIZE) * 0.5


# --- pedals (gas / brake+reverse) --------------------------------------------

func _build_pedals() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.anchor_left = 1.0
	row.anchor_right = 1.0
	row.anchor_top = 1.0
	row.anchor_bottom = 1.0
	row.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.position = Vector2(-40, -40)
	add_child(row)

	var brake := _hold_button("BRAKE\nREV", func(down: bool) -> void: _brake = 1.0 if down else 0.0)
	brake.custom_minimum_size = Vector2(110, 150)
	row.add_child(brake)

	var gas := _hold_button("GAS", func(down: bool) -> void: _accel = 1.0 if down else 0.0)
	gas.custom_minimum_size = Vector2(110, 150)
	row.add_child(gas)


# --- right-edge button stack -------------------------------------------------

func _build_button_stack() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.anchor_left = 1.0
	col.anchor_right = 1.0
	col.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	col.position = Vector2(-BTN_SIZE.x - 10, 80)
	add_child(col)

	var horn := _hold_button("HORN", func(down: bool) -> void: _horn = down)
	col.add_child(horn)
	_bridge_buttons.append(horn)

	var lights := _tap_button("LIGHTS", func() -> void: _lights_cycle_pending = true)
	col.add_child(lights)
	_bridge_buttons.append(lights)

	var hand := _hold_button("HAND", func(down: bool) -> void: _handbrake = 1.0 if down else 0.0)
	col.add_child(hand)
	_bridge_buttons.append(hand)

	col.add_child(_tap_button("GARAGE", func() -> void: garage_pressed.emit()))
	col.add_child(_tap_button("NEXT CAR", func() -> void: next_vehicle_pressed.emit()))
	col.add_child(_tap_button("RESPAWN", func() -> void: respawn_pressed.emit()))


# --- widget helpers ----------------------------------------------------------

func _hold_button(text: String, on_change: Callable) -> Pad:
	var b := _make_button(text)
	b.held.connect(func(down: bool) -> void: on_change.call(down))
	return b


## Fires on the press edge — snappier than waiting for the release, and the pad has no
## "click cancelled by sliding off" notion to honour.
func _tap_button(text: String, on_tap: Callable) -> Pad:
	var b := _make_button(text)
	b.held.connect(func(down: bool) -> void:
		if down:
			on_tap.call()
	)
	return b


func _make_button(text: String) -> Pad:
	var b := Pad.new()
	b.custom_minimum_size = BTN_SIZE
	b.add_theme_stylebox_override("panel", _ring_style(6.0))
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 15)
	b.add_child(label)
	# Pads are bare Panels, so press feedback is ours to draw.
	b.held.connect(func(down: bool) -> void:
		b.modulate = Color(1.5, 1.5, 1.5) if down else Color.WHITE
	)
	return b


func _ring_style(radius: float, color := Color(0.16, 0.18, 0.22, 0.75)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(int(radius))
	return s
