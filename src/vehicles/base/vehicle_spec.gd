class_name VehicleSpec
extends Resource
## All tuning for one vehicle: new vehicle = new spec + model scene.
##
## Data-only; consumed by BaseVehicle / RayWheel / Drivetrain. Curves are point
## arrays with linear interpolation (sample_curve) instead of Curve resources so
## tuning is deterministic and directly assertable in unit tests.
## Lamp PLACEMENT stays scene-authored: the spec only declares which scene
## nodes are which lamp (the *_paths below), never their transforms.

@export_group("Body")
@export var mass := 1200.0                         ## kg, applied to the RigidBody3D
@export var center_of_mass := Vector3(0, -0.3, 0)  ## body-space; low COM keeps the car flat

@export_group("Wheels")
## Hub anchors in body space, order FL, FR, RL, RR (front = -Z, right = +X).
@export var wheel_positions := PackedVector3Array([
	Vector3(-0.78, -0.1, -1.25), Vector3(0.78, -0.1, -1.25),
	Vector3(-0.78, -0.1, 1.25), Vector3(0.78, -0.1, 1.25),
])
@export var wheel_radius := 0.32
@export var wheel_inertia := 1.2   ## kg*m^2 around the axle
## Optional wheel visual scene, instanced under WheelFL..RR when the vehicle scene has no
## authored wheel mesh (the Kenney wheel wrapper). RayWheel drives its transform each tick;
## radius is still spec.wheel_radius (visual only). Absent = wheels come from the scene.
@export var wheel_scene: PackedScene
@export var driven_front := false
@export var driven_rear := true

@export_group("Suspension")
@export var rest_length := 0.25     ## m of free ray travel below the hub anchor
@export var spring_rate := 22000.0  ## N/m (~1.3 Hz natural frequency at 300 kg/corner — 60 Hz-safe)
@export var damper_bump := 1800.0   ## N*s/m
@export var damper_rebound := 2400.0
@export var max_suspension_force := 30000.0  ## N; clamp against deep-penetration catapults

@export_group("Tires")
## Slip -> grip factor, shared by both axes: x is slip ratio (longitudinal) or slip
## angle in radians (lateral) — both peak around 0.10-0.15 on that scale.
@export var grip_curve := PackedVector2Array([
	Vector2(0.0, 0.0), Vector2(0.12, 1.0), Vector2(0.4, 0.9), Vector2(1.0, 0.8),
])
@export var mu_long := 1.05
@export var mu_lat := 0.95
## Rear lateral grip multiplier while the handbrake is pulled (1 = no effect).
## The arcade drift knob: the §6 hierarchy caps handbrake_torque too low to lock the
## rears, so kicking the tail out is done by cutting rear side grip instead.
@export_range(0.0, 1.0) var handbrake_grip := 1.0

@export_group("Drivetrain")
## rpm -> engine Nm at full throttle.
@export var torque_curve := PackedVector2Array([
	Vector2(900, 95), Vector2(2000, 150), Vector2(3200, 180),
	Vector2(4800, 185), Vector2(6000, 165), Vector2(6800, 60),
])
@export var idle_rpm := 900.0
@export var redline_rpm := 6800.0
@export var gear_ratios := PackedFloat32Array([3.5, 2.2, 1.55, 1.18, 0.94, 0.78])
@export var reverse_ratio := 2.2  ## short enough that reverse wheel torque stays under sliding grip (no sustained burnout)
@export var final_drive := 3.9
@export var efficiency := 0.9
@export var shift_up_rpm := 5600.0
@export var shift_down_rpm := 2200.0

@export_group("Brakes")
## §6 hierarchy is encoded in these magnitudes (and asserted in tests):
## foot brake > max drive force > handbrake (holds only below ~30% throttle).
@export var brake_torque := 1300.0     ## Nm per wheel, all four
@export var handbrake_torque := 160.0  ## Nm per rear wheel

@export_group("Steering")
@export var max_steer_deg := 32.0
@export var steer_speed := 2.5  ## normalized steer units/s slewed toward input

@export_group("Lamps")
## NodePaths (relative to the vehicle root) naming the scene-authored lamp nodes
## LampSet drives. Headlights are SpotLight3D nodes (energy/range per
## level); the rest are MeshInstance3D lenses given a private emissive material.
@export var headlight_paths: Array[NodePath] = []
@export var brake_lamp_paths: Array[NodePath] = []
@export var turn_left_paths: Array[NodePath] = []
@export var turn_right_paths: Array[NodePath] = []


## Piecewise-linear sample of a (x, y) point array sorted by x; clamps at both ends.
static func sample_curve(points: PackedVector2Array, x: float) -> float:
	if points.is_empty():
		return 0.0
	if x <= points[0].x:
		return points[0].y
	for i in range(1, points.size()):
		if x <= points[i].x:
			var t := (x - points[i - 1].x) / (points[i].x - points[i - 1].x)
			return lerpf(points[i - 1].y, points[i].y, t)
	return points[points.size() - 1].y
