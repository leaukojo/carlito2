class_name BaseVehicle
extends RigidBody3D
## Vehicle base (plan §4.4): consumes one normalized VehicleInput from InputRouter
## (never reads input sources itself — plan §2 rule 5), runs the raycast wheels and
## drivetrain, and publishes VehicleTelemetry each physics tick. Spawn/respawn and
## the camera target are part of this base contract. All tuning lives in `spec`.

signal respawned

const WHEEL_VISUAL_NAMES: PackedStringArray = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]
const FALL_RESPAWN_Y := -20.0

@export var spec: VehicleSpec

var drivetrain: Drivetrain
var wheels: Array[RayWheel] = []
var telemetry := VehicleTelemetry.new()
var spawn_transform: Transform3D

var _steer := 0.0


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

	_update_telemetry(input)
	if global_position.y < FALL_RESPAWN_Y:
		respawn()


func _update_telemetry(input: InputRouter.VehicleInput) -> void:
	telemetry.speed = linear_velocity.dot(-global_transform.basis.z)
	telemetry.kmh = absf(telemetry.speed) * 3.6
	telemetry.rpm = drivetrain.rpm
	telemetry.gear_byte = drivetrain.gear_byte
	telemetry.throttle = input.throttle
	telemetry.steer = _steer
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


## Reset to the last spawn transform with zeroed motion. Also fired automatically
## when the vehicle falls off the world.
func respawn() -> void:
	global_transform = spawn_transform
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_steer = 0.0
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
