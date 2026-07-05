class_name Implement
extends Node3D
## Cosmetic rear implement (plan §1 "visuals minimal", §4.4, §8 scope guard). It rides the
## tractor body under a HitchSocket Marker3D — NO CollisionShape, NO joint. It only animates:
## a LiftArm pivot that raises/lowers with the hitch, and a Rotor the PTO visibly spins.
## Being a separate instanced scene makes "one attachable implement" a real attach point
## (swap the instance to swap implements) without dragging in constraint physics.

## Arm pitch (deg about local X) at the extremes; hitch 1.0 = raised, 0.0 = lowered.
@export var raised_angle_deg := 0.0
@export var lowered_angle_deg := 55.0
## Multiplies the visual PTO spin (cosmetic only, no physical meaning).
@export var pto_spin_scale := 1.0

@onready var _lift_arm: Node3D = $LiftArm
@onready var _rotor: Node3D = $Rotor

var _pto_on := false
var _pto_rpm := 0


## pos01 in [0,1]: 1 = fully raised (transport), 0 = fully lowered (working).
func set_hitch(pos01: float) -> void:
	if _lift_arm == null:
		return
	_lift_arm.rotation.x = deg_to_rad(lerpf(lowered_angle_deg, raised_angle_deg, clampf(pos01, 0.0, 1.0)))


## Store the PTO state; the visible spin happens in _process. rpm is the shaft speed.
func set_pto(on: bool, rpm: int) -> void:
	_pto_on = on
	_pto_rpm = rpm


func _process(delta: float) -> void:
	if _pto_on and _rotor != null:
		_rotor.rotate_y(float(_pto_rpm) / 60.0 * TAU * pto_spin_scale * delta)
