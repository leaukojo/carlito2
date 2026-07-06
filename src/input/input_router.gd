extends Node
## InputRouter autoload — merges input sources into one normalized VehicleInput.
##
## Plan §4.3: three InputSources (keyboard/gamepad, touch, bridge) merge into a
## single VehicleInput. ALL arbitration lives here and nowhere else (plan §2 rule 5):
## throttle only ever comes from the accelerator (brake is never throttle); key must
## be Ignition for throttle; locally S brakes and engages R near standstill; when the
## bridge is active and not Neutral the gear owns direction (plan §6). Vehicles never
## know which source is active.
##
## Arbitration is static/pure (like contract.gd's parser) so tests exercise it without
## the autoload lifecycle — tests/test_input_arbitration.gd MUST stay green. All three
## sources are live (local keyboard, touch via merge_local, bridge). Shared toggles the
## sources can only edge (_lights, _hitch_up, _pto) are owned HERE, not by a source.

const KEY_LOCK := 1
const KEY_ON := 2
const KEY_IGNITION := 3

const GEAR_N := 0x00
const GEAR_D1 := 0x01
const GEAR_R := 0xFF

## m/s below which S (held with no accel) swaps D->R and W swaps R->D.
const REVERSE_ENGAGE_SPEED := 0.5

const LocalSource := preload("res://src/input/sources/local_source.gd")
const BridgeSource := preload("res://src/input/sources/bridge_source.gd")


## The normalized per-tick input every vehicle consumes.
class VehicleInput:
	var throttle := 0.0    ## -1..1, signed by direction (never from the brake)
	var brake := 0.0       ## 0..1 foot brake
	var steer := 0.0       ## -1..1, negative = left
	var handbrake := 0.0   ## 0..1
	var gear_request := 0  ## RAMN gear byte: 0=N, 1..6=D1-D6, 255=R
	var gear_auto := true  ## true: byte is a direction intent, gearbox auto-shifts in D;
	                       ## false (bridge, M3): byte is exact and owns direction
	var key := 1           ## 1=Lock, 2=On, 3=Ignition
	var horn := false
	var lights := 1        ## 1=OFF, 2=CLEARANCE, 3=LOW, 4=HIGH
	# Lamp/warning bits (plan §6). sloppyCAN is the sole authority when the bridge is
	# live; these mirror it verbatim. Locally only brake_lamp is driven (from the foot
	# brake); turn signals + warning LEDs stay off (no local source, no blink timer).
	var turn_left := false
	var turn_right := false
	var brake_lamp := false   ## rear STOP state (0x1BB brake bit / local foot brake)
	var check_engine := false ## warning LED; defaults off when the bridge doesn't send it
	var battery_warn := false ## battery warning LED (distinct from the 'out' voltage)
	# ISOBUS implement request (tractor only, plan §3/§4.4). Flows through the struct
	# like the lamp bits — never a side channel. Default raised/off; other vehicles
	# ignore it (only TractorVehicle reads them).
	var hitch_request := 1.0  ## 0..1 requested hitch height (1 = raised/transport)
	var pto := false          ## PTO engage request

	func copy() -> VehicleInput:
		var c := VehicleInput.new()
		c.throttle = throttle
		c.brake = brake
		c.steer = steer
		c.handbrake = handbrake
		c.gear_request = gear_request
		c.gear_auto = gear_auto
		c.key = key
		c.horn = horn
		c.lights = lights
		c.turn_left = turn_left
		c.turn_right = turn_right
		c.brake_lamp = brake_lamp
		c.check_engine = check_engine
		c.battery_warn = battery_warn
		c.hitch_request = hitch_request
		c.pto = pto
		return c


var _local_source := LocalSource.new()
var _bridge_source := BridgeSource.new()
var _touch_source: Object = null  ## optional on-screen source (touch_controls.gd), if present
var _vehicle: Node3D = null
var _current := VehicleInput.new()
var _lights := 1  ## headlight level owned here so keyboard + touch share one state
# Local tractor implement state, owned here (like _lights) so keyboard + touch share it.
# The bridge path ignores these — sloppyCAN is authoritative there (plan §6).
var _hitch_up := true  ## true = raised (transport), toggled by the local hitch key
var _pto := false      ## local PTO engage, toggled by the local PTO key


## Vehicles register on _ready so arbitration can read speed/gear (local reverse
## needs them); they never expose anything else to the router.
func register_vehicle(vehicle: Node3D) -> void:
	_vehicle = vehicle


## The touch UI registers itself as a second local source (plan §4.3/§4.6). It is
## polled and merged with the keyboard whenever the bridge is not driving.
func set_touch_source(source: Object) -> void:
	_touch_source = source


func clear_touch_source(source: Object) -> void:
	if _touch_source == source:
		_touch_source = null


func unregister_vehicle(vehicle: Node3D) -> void:
	if _vehicle == vehicle:
		_vehicle = null


func _physics_process(delta: float) -> void:
	# Autoloads tick before scene nodes, so this runs ahead of every vehicle's frame.
	# Bridge wins while it has fresh data; otherwise local input works untouched (plan §6).
	var bridge_raw := _bridge_source.poll()
	if bridge_raw.get("active", false):
		_current = arbitrate_bridge(bridge_raw)
		return
	var raw := _local_source.poll(delta)
	if _touch_source != null:
		raw = merge_local(raw, _touch_source.poll())
	# Single headlight owner: either source's cycle edge advances the shared level.
	if bool(raw.get("lights_cycle", false)):
		_lights = _lights % 4 + 1
	raw["lights"] = _lights
	# Local implement toggles owned here too (same pattern as the headlight level).
	if bool(raw.get("hitch_toggle", false)):
		_hitch_up = not _hitch_up
	if bool(raw.get("pto_toggle", false)):
		_pto = not _pto
	raw["hitch_request"] = 1.0 if _hitch_up else 0.0
	raw["pto"] = _pto
	var speed := 0.0
	var gear := GEAR_N
	if _vehicle != null:
		speed = _vehicle.get_speed()
		gear = _vehicle.get_gear_byte()
	_current = arbitrate_local(raw, speed, gear)


## Current merged input. Returns a fresh copy — callers own (and may mutate) it.
func get_vehicle_input() -> VehicleInput:
	return _current.copy()


## Merge the keyboard and touch raw intents into one before arbitration (plan §4.3):
## analog axes take the stronger request, steer sums (clamped), momentary bits OR
## together. Pure/static so it is unit-tested without the autoload. `lights` is not
## merged here — InputRouter owns the level and reads the merged `lights_cycle` edge.
static func merge_local(a: Dictionary, b: Dictionary) -> Dictionary:
	return {
		"accel": maxf(float(a.get("accel", 0.0)), float(b.get("accel", 0.0))),
		"brake_reverse": maxf(float(a.get("brake_reverse", 0.0)), float(b.get("brake_reverse", 0.0))),
		"steer": clampf(float(a.get("steer", 0.0)) + float(b.get("steer", 0.0)), -1.0, 1.0),
		"handbrake": maxf(float(a.get("handbrake", 0.0)), float(b.get("handbrake", 0.0))),
		"horn": bool(a.get("horn", false)) or bool(b.get("horn", false)),
		"lights_cycle": bool(a.get("lights_cycle", false)) or bool(b.get("lights_cycle", false)),
		"hitch_toggle": bool(a.get("hitch_toggle", false)) or bool(b.get("hitch_toggle", false)),
		"pto_toggle": bool(a.get("pto_toggle", false)) or bool(b.get("pto_toggle", false)),
	}


## Local (keyboard/gamepad) arbitration, pure for tests. Rules from plan §6:
## throttle only from accel; brake never throttle; full accel + full brake pass
## through (stopping is the brake > accel force hierarchy's job, in the spec);
## key gates throttle. Reverse UX: S brakes while moving, engages R near standstill;
## W in R brakes, then re-engages D1 near standstill.
static func arbitrate_local(raw: Dictionary, speed: float, gear_byte: int,
		key: int = KEY_IGNITION) -> VehicleInput:
	var out := VehicleInput.new()
	out.steer = clampf(float(raw.get("steer", 0.0)), -1.0, 1.0)
	out.handbrake = clampf(float(raw.get("handbrake", 0.0)), 0.0, 1.0)
	out.key = key  # local key is always Ignition until the bridge owns it (M3)
	out.gear_auto = true
	out.horn = bool(raw.get("horn", false))
	out.lights = int(raw.get("lights", 1))  # local headlight cycle (turn/warning bits stay off)
	# Implement request from the InputRouter-owned local toggles (tractor only; ignored elsewhere).
	out.hitch_request = clampf(float(raw.get("hitch_request", 1.0)), 0.0, 1.0)
	out.pto = bool(raw.get("pto", false))

	var accel := clampf(float(raw.get("accel", 0.0)), 0.0, 1.0)
	var brake_rev := clampf(float(raw.get("brake_reverse", 0.0)), 0.0, 1.0)
	var near_standstill := absf(speed) <= REVERSE_ENGAGE_SPEED

	if gear_byte == GEAR_R:
		if accel > 0.0 and near_standstill and brake_rev <= 0.0:
			out.gear_request = GEAR_D1
			out.throttle = accel
		else:
			out.gear_request = GEAR_R
			out.throttle = -brake_rev
			out.brake = accel
	else:
		if brake_rev > 0.0 and near_standstill and accel <= 0.0:
			out.gear_request = GEAR_R
			out.throttle = -brake_rev
		else:
			if gear_byte >= 1 and gear_byte <= 6:
				out.gear_request = gear_byte
			else:
				out.gear_request = GEAR_D1 if accel > 0.0 else GEAR_N
			out.throttle = accel
			out.brake = brake_rev

	if out.key != KEY_IGNITION:
		out.throttle = 0.0
	# Local rear STOP follows the foot brake; sloppyCAN owns it once the bridge is live.
	out.brake_lamp = out.brake > 0.0
	return out


## Bridge (sloppyCAN) arbitration, pure for tests. Rules from plan §6: while the bridge is
## active and not Neutral the gear OWNS direction — throttle is `accel` signed by the gear byte
## (+ in D1–D6, − in R, 0 in N), and local reverse UX is ignored (gear_auto = false, so the byte
## is used exactly). brake is never throttle; key gates throttle; steer/handbrake/lights/horn
## pass through. Values arrive already normalized to VehicleInput ranges from bridge_source.
static func arbitrate_bridge(vals: Dictionary) -> VehicleInput:
	var out := VehicleInput.new()
	out.steer = clampf(float(vals.get("steer", 0.0)), -1.0, 1.0)
	out.handbrake = clampf(float(vals.get("handbrake", 0.0)), 0.0, 1.0)
	out.brake = clampf(float(vals.get("brake", 0.0)), 0.0, 1.0)
	out.key = int(vals.get("key", KEY_IGNITION))
	out.lights = int(vals.get("lights", 1))
	out.horn = bool(vals.get("horn", false))
	# Lamp/warning bits mirrored verbatim (plan §6 — sloppyCAN is the sole authority;
	# any absent bit defaults off, e.g. the warning LEDs).
	out.turn_left = bool(vals.get("turnL", false))
	out.turn_right = bool(vals.get("turnR", false))
	out.brake_lamp = bool(vals.get("brakeLamp", false))
	out.check_engine = bool(vals.get("checkEngine", false))
	out.battery_warn = bool(vals.get("battery", false))
	# ISOBUS implement request mirrored from sloppyCAN (sole authority, plan §6). Absent →
	# raised/off, the §6 default-off convention. bridge_source clamps hitch_pos to 0..100.
	out.hitch_request = clampf(float(vals.get("hitch_pos", 100.0)) / 100.0, 0.0, 1.0)
	out.pto = bool(vals.get("pto", false))
	out.gear_auto = false  # bridge byte is exact and owns direction (plan §6)

	var gear := int(vals.get("gear", GEAR_N))
	out.gear_request = gear
	var accel := clampf(float(vals.get("accel", 0.0)), 0.0, 1.0)
	if gear == GEAR_R:
		out.throttle = -accel
	elif gear >= GEAR_D1 and gear <= 6:
		out.throttle = accel
	else:  # Neutral or unknown byte — no drive
		out.throttle = 0.0

	if out.key != KEY_IGNITION:
		out.throttle = 0.0
	return out
