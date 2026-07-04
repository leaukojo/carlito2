class_name BaseVehicle
extends RigidBody3D
## Vehicle base (plan §4.4): consumes one normalized VehicleInput from InputRouter
## (never reads input sources itself — plan §2 rule 5), runs the raycast wheels and
## drivetrain, and publishes VehicleTelemetry each physics tick. Spawn/respawn and
## the camera target are part of this base contract. All tuning lives in `spec`.

signal respawned

const WHEEL_VISUAL_NAMES: PackedStringArray = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
const FALL_RESPAWN_Y := -20.0

## Telemetry derivation tuning (plan §3): kept out of VehicleSpec — these are the
## same for every vehicle, not feel knobs.
const ACCEL_SMOOTH := 10.0      ## 1/s exp rate the reported long/lat accel tracks raw
const COOLANT_RATE := 2.0       ## degC/s the coolant chases its steady-state target
const IMPACT_THRESHOLD := 25.0  ## m/s^2 acceleration spike that counts as an impact
const IMPACT_DECAY := 40.0      ## m/s^2 per s the held impact value bleeds off
const MOVING_SPEED := 0.3       ## m/s standstill epsilon for the status 'moving' bit

@export var spec: VehicleSpec

var drivetrain: Drivetrain
var wheels: Array[RayWheel] = []
var telemetry := VehicleTelemetry.new()
var spawn_transform: Transform3D

var _steer := 0.0
var _prev_velocity := Vector3.ZERO  ## last tick's linear_velocity, for accel/impact
var _impact_hold := 0.0             ## decaying peak of the impact magnitude


func _ready() -> void:
	mass = spec.mass
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = spec.center_of_mass
	can_sleep = false
	drivetrain = Drivetrain.new(spec)
	for i in spec.wheel_positions.size():
		var pos := spec.wheel_positions[i]
		var front := pos.z < 0.0
		var driven := (front and spec.driven_front) or (not front and spec.driven_rear)
		var visual: Node3D = null
		if i < WHEEL_VISUAL_NAMES.size():
			visual = get_node_or_null(NodePath(WHEEL_VISUAL_NAMES[i]))
		wheels.append(RayWheel.new(pos, front, driven, visual))
	spawn_transform = global_transform
	_prev_velocity = linear_velocity
	InputRouter.register_vehicle(self)


func _exit_tree() -> void:
	InputRouter.unregister_vehicle(self)


func _physics_process(delta: float) -> void:
	var input := InputRouter.get_vehicle_input()
	_steer = move_toward(_steer, input.steer, spec.steer_speed * delta)

	var driven_count := 0
	var drive_omega := 0.0
	for w in wheels:
		if w.driven:
			driven_count += 1
			drive_omega += w.omega
	drive_omega /= maxf(1.0, driven_count)

	var axle_torque := drivetrain.process(
			delta, absf(input.throttle), drive_omega, input.gear_request, input.gear_auto)

	var space := get_world_3d().direct_space_state
	for w in wheels:
		w.steer_angle = -_steer * deg_to_rad(spec.max_steer_deg) if w.steered else 0.0
		var drive_t := axle_torque / driven_count if w.driven else 0.0
		var brake_t := input.brake * spec.brake_torque
		if w.is_rear:
			brake_t += input.handbrake * spec.handbrake_torque
		w.tick(self, spec, space, drive_t, brake_t, delta)

	_update_telemetry(input, delta)
	if global_position.y < FALL_RESPAWN_Y:
		respawn()


func _update_telemetry(input: InputRouter.VehicleInput, delta: float) -> void:
	var xform := global_transform
	var forward := -xform.basis.z
	var up := xform.basis.y

	# Motion read straight out of the sim (plan §2 rule 3).
	telemetry.speed = linear_velocity.dot(forward)
	telemetry.kmh = absf(telemetry.speed) * 3.6
	telemetry.rpm = drivetrain.rpm
	telemetry.gear_byte = drivetrain.gear_byte
	telemetry.throttle = input.throttle
	telemetry.steer = _steer
	telemetry.yaw = angular_velocity.dot(up)

	var accel := VehicleTelemetry.body_accel(
			linear_velocity, _prev_velocity, delta, forward, xform.basis.x)
	var s := 1.0 - exp(-ACCEL_SMOOTH * delta)
	telemetry.acc_long = lerpf(telemetry.acc_long, accel.x, s)
	telemetry.acc_lat = lerpf(telemetry.acc_lat, accel.y, s)

	telemetry.ground = true
	var slip_sum := [0.0, 0.0]
	var count := [0, 0]
	for w in wheels:
		var axle := 1 if w.is_rear else 0
		slip_sum[axle] += w.slip
		count[axle] += 1
		if not w.in_contact:
			telemetry.ground = false
	telemetry.slip_front = slip_sum[0] / maxi(1, count[0])
	telemetry.slip_rear = slip_sum[1] / maxi(1, count[1])

	# Navigation: raw position, GPS mapping, compass heading, odometer.
	telemetry.pos_x = global_position.x
	telemetry.pos_z = global_position.z
	telemetry.lat = VehicleTelemetry.gps_lat(global_position.z)
	telemetry.lon = VehicleTelemetry.gps_lon(global_position.x)
	telemetry.heading = VehicleTelemetry.heading_from_forward(forward)
	telemetry.odo = VehicleTelemetry.odo_step(telemetry.odo, telemetry.speed, delta)

	# Auxiliary systems (modeled): fuel/coolant/battery keyed off ignition + load.
	var running := input.key == InputRouter.KEY_IGNITION
	var load := clampf(absf(input.throttle), 0.0, 1.0)
	telemetry.fuel = VehicleTelemetry.fuel_step(telemetry.fuel, load, running, delta)
	telemetry.coolant = VehicleTelemetry.coolant_step(
			telemetry.coolant, VehicleTelemetry.coolant_target(running, load), COOLANT_RATE, delta)
	telemetry.battery = VehicleTelemetry.battery_volts(running, load)

	# Impact: gate the raw acceleration spike, then peak-hold with decay so a
	# one-tick collision stays readable on the dash / bridge.
	var accel_mag := ((linear_velocity - _prev_velocity) / maxf(delta, 1e-5)).length()
	_impact_hold = maxf(
			VehicleTelemetry.impact_gate(accel_mag, IMPACT_THRESHOLD),
			move_toward(_impact_hold, 0.0, IMPACT_DECAY * delta))
	telemetry.impact = _impact_hold

	telemetry.status = VehicleTelemetry.pack_status(
			running, telemetry.ground, absf(telemetry.speed) > MOVING_SPEED,
			telemetry.gear_byte, input.handbrake > 0.0, input.lights >= 3)

	_prev_velocity = linear_velocity


## Reset to the last spawn transform with zeroed motion. Also fired automatically
## when the vehicle falls off the world.
func respawn() -> void:
	global_transform = spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_steer = 0.0
	# Zero the accel/impact history so the teleport isn't read as a huge Δv spike.
	_prev_velocity = Vector3.ZERO
	_impact_hold = 0.0
	telemetry.acc_long = 0.0
	telemetry.acc_lat = 0.0
	for w in wheels:
		w.reset()
	reset_physics_interpolation()
	respawned.emit()


func get_camera_target() -> Node3D:
	return self


## Read by InputRouter for arbitration (local brake-vs-reverse); vehicles otherwise
## never talk to the router beyond register/consume.
func get_speed() -> float:
	return telemetry.speed


func get_gear_byte() -> int:
	return drivetrain.gear_byte if drivetrain != null else Drivetrain.GEAR_N
