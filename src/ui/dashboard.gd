class_name Dashboard
extends Control
## Instrument cluster. The mandated split:
##   - the tell-tale row and the bars are GENERATED from contract signal metadata
##     (name, range, warn thresholds) — add a bool "in" signal or a warn'd "out"
##     signal to the JSON and it appears here, no code change;
##   - the two radial gauges (speedo, tacho) are HAND-BUILT widgets that only READ
##     their scale/redline from the contract.
## This is emphatically NOT a generic dashboard-from-JSON framework: which two signals
## are gauges, and the cosmetic lamp labels/colors, are hand-picked here; the repetitive
## parts (the lamp row, the bars) are generated. Plain text + color only.

## The two signals rendered as bespoke radial gauges (never as generated bars).
const GAUGE_SIGNALS: PackedStringArray = ["kmh", "rpm"]
## Enum "in" signals shown as small state chips (gear is shown on the tacho instead).
const ENUM_CHIPS: PackedStringArray = ["key", "lights"]

## Cosmetic tell-tale presentation (UI styling, not signal data): short caption + lit
## color per known lamp. Unknown lamps fall back to the upper-cased signal name / amber.
const LAMP_TEXT := {
	"handbrake": "BRAKE", "turnL": "<L", "turnR": "R>", "horn": "HORN",
	"checkEngine": "CHECK", "battery": "BATT", "brakeLamp": "STOP",
	"pto_state": "PTO",
}
const LAMP_COLOR := {
	"handbrake": Color(0.95, 0.35, 0.30), "turnL": Color(0.35, 0.85, 0.45),
	"turnR": Color(0.35, 0.85, 0.45), "horn": Color(0.45, 0.72, 1.0),
	"checkEngine": Color(1.0, 0.70, 0.15), "battery": Color(0.95, 0.35, 0.30),
	"brakeLamp": Color(0.95, 0.35, 0.30), "pto_state": Color(0.35, 0.85, 0.45),
}
## Cosmetic short captions for the generated "out" bars (like LAMP_TEXT for lamps).
const BAR_LABEL := {
	"hitch_pos_actual": "HITCH", "pto_rpm": "PTO", "engine_load": "LOAD",
}
const LAMP_OFF := Color(0.28, 0.30, 0.34)
const CHIP_COLOR := Color(0.85, 0.88, 0.93)
const READOUT_COLOR := Color(0.62, 0.66, 0.72)

var _level: Node = null
var _gear_def: RefCounted = null  ## contract "gear" out SignalDef, for gear-byte -> "D3"/"N"/"R"
var _speedo: Gauge
var _tach: Gauge
var _bars := {}      ## signal name -> DashBar
var _lamps := {}     ## signal name -> Label (input bool tell-tales)
var _out_lamps := {} ## signal name -> Label (bool "out" ISOBUS tell-tales, driven from telemetry)
var _chips := {}     ## signal name -> [Label, SignalDef]
var _readout: Label


## Attach to a running Level and build the cluster for its active vehicle type.
## Called by the shell once the level has spawned its vehicle.
func bind(level: Node) -> void:
	_level = level
	# Prefer the vehicle actually spawned (a garage swap changes it); fall back to the
	# level's default before the first spawn.
	var vtype := GameState.current_vehicle
	if vtype == "" and level != null and level.get("info") != null:
		vtype = level.info.default_vehicle
	_build(vtype)


func _build(vehicle_type: String) -> void:
	for c in get_children():
		c.queue_free()
	_bars.clear()
	_lamps.clear()
	_out_lamps.clear()
	_chips.clear()

	# The Dashboard control stays full-rect (set in boot.tscn). Pin the cluster panel
	# across the bottom edge and grow it UPWARD to fit its content: with the default
	# grow direction (down) the panel would slide off the bottom of the screen once its
	# children give it a real height, since its anchors/offsets are set before they exist.
	var panel := PanelContainer.new()
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.07, 0.09, 0.82)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)

	if Contract.data == null or not Contract.data.is_valid():
		var err := Label.new()
		err.text = "dashboard: contract unavailable"
		col.add_child(err)
		return
	_gear_def = Contract.data.get_signal_def("gear", "out")

	col.add_child(_build_telltale_row(vehicle_type))

	var cluster := HBoxContainer.new()
	cluster.alignment = BoxContainer.ALIGNMENT_CENTER
	cluster.add_theme_constant_override("separation", 24)
	col.add_child(cluster)

	# A gauge is only built when the vehicle declares its signal (contract-driven like
	# the bars/lamps): the boat has no 'rpm'/'gear', so its cluster is speedo-only —
	# the gear text lives in the tacho gap and goes with it.
	var out_names: Array = Contract.data.signals_for_vehicle(vehicle_type, "out") \
			.map(func(s: RefCounted) -> String: return s.name)

	_speedo = null
	if out_names.has("kmh"):
		_speedo = _make_gauge("kmh", "SPEED", 8)
		cluster.add_child(_speedo)

	var mid := VBoxContainer.new()
	mid.custom_minimum_size = Vector2(280, 0)
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_theme_constant_override("separation", 8)
	cluster.add_child(mid)
	_build_bars(vehicle_type, mid)
	_readout = Label.new()
	_readout.add_theme_font_size_override("font_size", 12)
	_readout.add_theme_color_override("font_color", READOUT_COLOR)
	mid.add_child(_readout)

	_tach = null
	if out_names.has("rpm"):
		_tach = _make_gauge("rpm", "RPM", 8)
		cluster.add_child(_tach)


## Build the tell-tale row: state chips for the enum inputs, then a lamp per bool
## input — generated by walking the contract's "in" signals for this vehicle.
func _build_telltale_row(vehicle_type: String) -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)

	for sig in Contract.data.signals_for_vehicle(vehicle_type, "in"):
		if sig.has_enum() and sig.name in ENUM_CHIPS:
			var chip := Label.new()
			chip.add_theme_font_size_override("font_size", 13)
			chip.add_theme_color_override("font_color", CHIP_COLOR)
			row.add_child(chip)
			_chips[sig.name] = [chip, sig]

	for sig in Contract.data.signals_for_vehicle(vehicle_type, "in"):
		if sig.type != "bool":
			continue
		_lamps[sig.name] = _make_lamp(sig.name, row)

	# ISOBUS bool "out" signals become tell-tales too (e.g. pto_state), driven from
	# telemetry rather than input — generated from contract signal metadata.
	for sig in Contract.data.signals_for_vehicle(vehicle_type, "out"):
		if sig.type != "bool" or sig.flavor != "isobus":
			continue
		_out_lamps[sig.name] = _make_lamp(sig.name, row)
	return row


## One tell-tale Label (caption from LAMP_TEXT, unlit color), added to `into`.
func _make_lamp(sig_name: String, into: Node) -> Label:
	var lamp := Label.new()
	lamp.text = LAMP_TEXT.get(sig_name, sig_name.to_upper())
	lamp.add_theme_font_size_override("font_size", 13)
	lamp.add_theme_color_override("font_color", LAMP_OFF)
	into.add_child(lamp)
	return lamp


## Bars for every "out" signal (this vehicle) that has a range and is either warn'd
## (fuel/coolant) or an ISOBUS signal (the tractor implement panel — driven
## from the contract 'flavor' metadata, not hardcoded names), except the two gauges.
func _build_bars(vehicle_type: String, into: Node) -> void:
	for sig in Contract.data.signals_for_vehicle(vehicle_type, "out"):
		if sig.name in GAUGE_SIGNALS or sig.range.size() != 2:
			continue
		if not sig.has_warn() and sig.flavor != "isobus":
			continue
		var bar := DashBar.new()
		bar.custom_minimum_size = Vector2(0, 18)
		bar.label = BAR_LABEL.get(sig.name, sig.name.to_upper())
		bar.units = _short_unit(sig.unit)
		bar.min_value = float(sig.range[0])
		bar.max_value = float(sig.range[1])
		bar.warn = sig.warn
		bar.warn_is_low = sig.warn_is_low()
		into.add_child(bar)
		_bars[sig.name] = bar


func _make_gauge(signal_name: String, caption: String, ticks: int) -> Gauge:
	var g := Gauge.new()
	g.custom_minimum_size = Vector2(150, 150)
	g.caption = caption
	g.major_ticks = ticks
	var sig := Contract.data.get_signal_def(signal_name, "out")
	if sig != null and sig.range.size() == 2:
		g.min_value = float(sig.range[0])
		g.max_value = float(sig.range[1])
	if sig != null and sig.has_warn():
		g.redline = sig.warn
	g.units = _short_unit(sig.unit) if sig != null else ""
	return g


func _short_unit(unit: String) -> String:
	# Percent/degree read better glued to the number; keep the rest spaced.
	match unit:
		"%": return "%"
		"degC": return "°C"
		_: return ""


func _process(_dt: float) -> void:
	if not visible or _level == null:
		return
	var vehicle: Node = _level.get("vehicle")
	if vehicle == null:
		return
	var t: VehicleTelemetry = vehicle.get("telemetry")
	if t == null:
		return

	if _speedo != null:
		_speedo.value = t.kmh
	if _tach != null:
		_tach.value = t.rpm
		_tach.center_text = _gear_def.enum_label(t.gear_byte) if _gear_def != null else ""

	for sig_name in _bars:
		# Bars are keyed by contract signal name; telemetry fields share those names
		# (fuel, coolant). Guard the lookup so warn'ing a signal whose telemetry field
		# is spelled differently (e.g. accLong -> acc_long) degrades to a static bar
		# rather than assigning null into a float.
		var v: Variant = t.get(sig_name)
		if typeof(v) != TYPE_NIL:
			_bars[sig_name].value = v

	# ISOBUS bool "out" tell-tales (pto_state) are telemetry-driven, unlike the input
	# lamps in _update_telltales. Only present on vehicles that declare them (tractor).
	for sig_name in _out_lamps:
		var on := bool(t.get(sig_name))
		var col: Color = LAMP_COLOR.get(sig_name, Color(1.0, 0.70, 0.15)) if on else LAMP_OFF
		_out_lamps[sig_name].add_theme_color_override("font_color", col)

	_update_telltales()
	if _readout != null:
		_readout.text = "HDG %03d  ODO %.1f km  %.4f, %.4f" % [
			roundi(t.heading), t.odo, t.lat, t.lon]


func _update_telltales() -> void:
	var vi := InputRouter.get_vehicle_input()
	# Mirror every lamp/warning bit the input carries. sloppyCAN is the sole
	# authority when the bridge is live; locally only handbrake/horn/brake_lamp are
	# driven and the turn/warning LEDs stay off — their correct default.
	var active := {
		"handbrake": vi.handbrake > 0.0,
		"horn": vi.horn,
		"turnL": vi.turn_left,
		"turnR": vi.turn_right,
		"brakeLamp": vi.brake_lamp,
		"checkEngine": vi.check_engine,
		"battery": vi.battery_warn,
	}
	for sig_name in _lamps:
		var on: bool = active.get(sig_name, false)
		var col: Color = LAMP_COLOR.get(sig_name, Color(1.0, 0.70, 0.15)) if on else LAMP_OFF
		_lamps[sig_name].add_theme_color_override("font_color", col)

	var enums := {"key": vi.key, "lights": vi.lights}
	for sig_name in _chips:
		var label: Label = _chips[sig_name][0]
		var sig: RefCounted = _chips[sig_name][1]
		var raw: int = enums.get(sig_name, 0)
		label.text = "%s:%s" % [sig_name.to_upper(), sig.enum_label(raw)]
