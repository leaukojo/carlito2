class_name ChaseCamera
extends Camera3D
## Chase camera on the BaseVehicle camera-target contract (plan §4.4).
##
## Follows in _process using get_global_transform_interpolated(): physics runs at
## the locked 60 Hz with interpolation (plan §1), so reading global_transform here
## would sample the raw tick and stutter. Yaw-only follow (ignores body pitch/roll).

@export var target: Node3D
@export var distance := 6.0
@export var height := 2.5
@export var look_height := 1.2
@export var smoothing := 5.0  ## 1/s exponential position catch-up rate


func _ready() -> void:
	# This node moves per rendered frame, not per physics tick — interpolating it
	# against stale physics snapshots would fight _process and judder.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func _process(delta: float) -> void:
	if target == null:
		return
	global_position = global_position.lerp(
			_desired_position(), 1.0 - exp(-smoothing * delta))
	look_at(target.get_global_transform_interpolated().origin + Vector3.UP * look_height)


## Jump straight to the follow position (spawn/respawn).
func snap() -> void:
	if target == null:
		return
	global_position = _desired_position()
	look_at(target.get_global_transform_interpolated().origin + Vector3.UP * look_height)


func _desired_position() -> Vector3:
	var tt := target.get_global_transform_interpolated()
	var back := tt.basis.z
	back.y = 0.0
	back = back.normalized() if back.length_squared() > 0.001 else Vector3.BACK
	return tt.origin + back * distance + Vector3.UP * height
