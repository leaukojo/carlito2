class_name LampSet
extends RefCounted
## Applies §6 lamp state to the scene-authored lamp nodes a VehicleSpec names.
##
## Placement is scene-authored: the spec only DECLARES which nodes are
## the head / brake / turn lamps (by NodePath, relative to the vehicle root); their
## transforms live in the model scene. sloppyCAN is the sole authority on lamp state
##: the brake tier, the turn bits and the headlight level are mirrored
## VERBATIM here — there is no local blink timer; turn lamps blink because the source
## toggles the bit.
##
## The decision (rear_tier) is a pure static fn, unit-tested in tests/test_lamps.gd;
## apply() is the thin scene-touching part (Light3D energy + emissive materials).

## Rear tri-state: STOP (brake) > TAIL (headlights on) > OFF (dim housing,
## never invisible).
enum Rear { OFF, TAIL, STOP }

## Headlight levels — mirror the contract 'lights' enum values exactly.
const HL_OFF := 1
const HL_CLEARANCE := 2
const HL_LOW := 3
const HL_HIGH := 4

## Emissive energy per rear tier; OFF keeps a dim housing glow so the lens is always
## visible.
const REAR_ENERGY := { Rear.OFF: 0.15, Rear.TAIL: 0.7, Rear.STOP: 3.5 }
const REAR_COLOR := Color(0.95, 0.06, 0.03)

## Turn lens: dark amber when off (still visible), bright amber when lit.
const TURN_OFF_ENERGY := 0.12
const TURN_ON_ENERGY := 3.5
const TURN_COLOR := Color(1.0, 0.5, 0.0)

## Headlight SpotLight3D energy + range per level (distinct per state).
const HEAD_ENERGY := { HL_OFF: 0.0, HL_CLEARANCE: 1.2, HL_LOW: 7.5, HL_HIGH: 14.0 }
const HEAD_RANGE := { HL_OFF: 0.0, HL_CLEARANCE: 8.0, HL_LOW: 32.0, HL_HIGH: 90.0 }

## Beam SHAPE per level. The Compatibility renderer has no light projectors, so the beam
## pattern is what the cone itself can express: a wide, short, downward-aimed spread for
## low beam (light on the road just ahead), a narrow, near-level, long throw for high
## beam. Without the downward pitch every level renders the same disc on whatever wall is
## in front — which is the artifact these three tables exist to remove.
##
## HEAD_ANGLE is the HALF-angle in degrees (Godot's spot_angle), HEAD_PITCH the downward
## aim in degrees applied to the scene-authored basis, HEAD_FALLOFF the cone-edge exponent
## (higher = more light concentrated on the axis, i.e. a hotspot rather than a flat disc).
const HEAD_ANGLE := { HL_OFF: 38.0, HL_CLEARANCE: 36.0, HL_LOW: 44.0, HL_HIGH: 38.0 }
const HEAD_PITCH := { HL_OFF: 0.0, HL_CLEARANCE: 12.0, HL_LOW: 11.0, HL_HIGH: 1.5 }
const HEAD_FALLOFF := { HL_OFF: 1.0, HL_CLEARANCE: 1.0, HL_LOW: 1.4, HL_HIGH: 0.7 }

## Real low beams are asymmetric: the kerb-side lamp is kicked up/out to light the verge,
## the oncoming side is aimed lower so it doesn't dazzle. Left lamps take this much EXTRA
## downward pitch at low beam (and a matching outward yaw so the pair covers the full lane
## width instead of two stacked discs). High beam is symmetric — both lamps aim long.
const LOW_LEFT_EXTRA_PITCH := 4.0
const LOW_OUTWARD_YAW := 7.0

var _heads: Array[SpotLight3D] = []
## Authored basis per head, captured at setup — the pitch is applied relative to it so a
## scene that aims a lamp off-axis keeps its aim.
var _head_rest: Array[Basis] = []
## -1.0 left / +1.0 right / 0.0 centred lamp (from its authored local X).
var _head_side: Array[float] = []
var _rear_mat: StandardMaterial3D
var _turn_l_mat: StandardMaterial3D
var _turn_r_mat: StandardMaterial3D


# --- pure decision (unit-tested) --------------------------------------------

## Rear tri-state: STOP from the brake bit (sloppyCAN's 0x1BB brake bit locally the
## foot brake), else TAIL when the headlights are at clearance or brighter, else OFF.
static func rear_tier(brake_on: bool, headlights: int) -> Rear:
	if brake_on:
		return Rear.STOP
	if headlights >= HL_CLEARANCE:
		return Rear.TAIL
	return Rear.OFF


# --- setup + application (scene) --------------------------------------------

## Resolve the spec's lamp NodePaths against the vehicle and give the mesh lamps a
## private emissive material so runtime energy changes never touch a shared resource.
func setup(vehicle: Node, spec: VehicleSpec) -> void:
	for p in spec.headlight_paths:
		var n := vehicle.get_node_or_null(p)
		if n is SpotLight3D:
			_heads.append(n)
			_head_rest.append((n as SpotLight3D).transform.basis)
			# -1 left / +1 right / 0 centred (a lone centre lamp must not splay sideways).
			var head_x := (n as SpotLight3D).position.x
			_head_side.append(0.0 if absf(head_x) < 0.01 else signf(head_x))
	_rear_mat = _bind(vehicle, spec.brake_lamp_paths, REAR_COLOR, REAR_ENERGY[Rear.OFF])
	_turn_l_mat = _bind(vehicle, spec.turn_left_paths, TURN_COLOR, TURN_OFF_ENERGY)
	_turn_r_mat = _bind(vehicle, spec.turn_right_paths, TURN_COLOR, TURN_OFF_ENERGY)


## One shared emissive material assigned as material_override to every mesh in `paths`
## (they always light together). Returns it so apply() can mutate its energy; null if
## no mesh resolved.
func _bind(vehicle: Node, paths: Array[NodePath], color: Color, energy: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = null
	for p in paths:
		var n := vehicle.get_node_or_null(p)
		if n is MeshInstance3D:
			if mat == null:
				mat = StandardMaterial3D.new()
				mat.albedo_color = color.darkened(0.6)
				mat.emission_enabled = true
				mat.emission = color
				mat.emission_energy_multiplier = energy
			(n as MeshInstance3D).material_override = mat
	return mat


## Mirror the current lamp state to the scene. brake_on / turn bits come straight from
## VehicleInput (sloppyCAN authoritative when the bridge is live); no timers here.
func apply(brake_on: bool, headlights: int, turn_left: bool, turn_right: bool) -> void:
	if _rear_mat != null:
		_rear_mat.emission_energy_multiplier = REAR_ENERGY[rear_tier(brake_on, headlights)]
	if _turn_l_mat != null:
		_turn_l_mat.emission_energy_multiplier = TURN_ON_ENERGY if turn_left else TURN_OFF_ENERGY
	if _turn_r_mat != null:
		_turn_r_mat.emission_energy_multiplier = TURN_ON_ENERGY if turn_right else TURN_OFF_ENERGY

	var energy: float = HEAD_ENERGY.get(headlights, 0.0)
	var angle: float = HEAD_ANGLE.get(headlights, 38.0)
	var falloff: float = HEAD_FALLOFF.get(headlights, 1.0)
	# Pitch is a rotation about the lamp's own X (down = negative), applied to the rest
	# basis so repeated calls never accumulate.
	var pitch := -float(HEAD_PITCH.get(headlights, 0.0))
	var low := headlights == HL_LOW
	for i in _heads.size():
		var h := _heads[i]
		var side := _head_side[i]
		# Left lamp dips further at low beam; both splay outward so the pair reads as one
		# wide lane-width spread. Yaw is about local Y (+ = left, hence the -side).
		var p := pitch - (LOW_LEFT_EXTRA_PITCH if low and side < 0.0 else 0.0)
		var yaw := deg_to_rad(-side * LOW_OUTWARD_YAW) if low else 0.0
		h.visible = energy > 0.0
		h.light_energy = energy
		h.spot_range = HEAD_RANGE.get(headlights, 0.0)
		h.spot_angle = angle
		h.spot_angle_attenuation = falloff
		h.transform.basis = _head_rest[i] * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, deg_to_rad(p))
