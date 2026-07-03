extends Node
## InputRouter autoload — merges input sources into one normalized VehicleInput.
##
## Plan §4.3: three InputSources (keyboard/gamepad, touch, bridge) merge into a
## single VehicleInput. ALL arbitration lives here and nowhere else (plan §2 rule 5):
## throttle only ever comes from the accelerator (brake is never throttle); key must
## be Ignition for throttle; locally S brakes and engages R near standstill; when the
## bridge is active and not Neutral the gear owns direction (plan §6 — lands with the
## bridge source in M3). Vehicles never know which source is active.
##
## Arbitration is static/pure (like contract.gd's parser) so tests exercise it
## without the autoload lifecycle. Local source: P1a (this). Touch: M4. Bridge: M3.

const KEY_LOCK := 1
const KEY_ON := 2
const KEY_IGNITION := 3

const GEAR_N := 0x00
const GEAR_D1 := 0x01
const GEAR_R := 0xFF

## m/s below which S (held with no accel) swaps D->R and W swaps R->D.
const REVERSE_ENGAGE_SPEED := 0.5

const LocalSource := preload("res://src/input/sources/local_source.gd")


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
		return c


var _local_source := LocalSource.new()
var _vehicle: Node3D = null
var _current := VehicleInput.new()


## Vehicles register on _ready so arbitration can read speed/gear (local reverse
## needs them); they never expose anything else to the router.
func register_vehicle(vehicle: Node3D) -> void:
	_vehicle = vehicle


func unregister_vehicle(vehicle: Node3D) -> void:
	if _vehicle == vehicle:
		_vehicle = null


func _physics_process(delta: float) -> void:
	# Autoloads tick before scene nodes, so this runs ahead of every vehicle's frame.
	var raw := _local_source.poll(delta)
	var speed := 0.0
	var gear := GEAR_N
	if _vehicle != null:
		speed = _vehicle.get_speed()
		gear = _vehicle.get_gear_byte()
	# Bridge source + gear-owns-direction arbitration slot in here at M3.
	_current = arbitrate_local(raw, speed, gear)


## Current merged input. Returns a fresh copy — callers own (and may mutate) it.
func get_vehicle_input() -> VehicleInput:
	return _current.copy()


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
	return out
