class_name LampSet
extends RefCounted
## Applies §6 lamp state to the scene-authored lamp nodes a VehicleSpec names.
##
## Placement is scene-authored (plan §4.4): the spec only DECLARES which nodes are
## the head / brake / turn lamps (by NodePath, relative to the vehicle root); their
## transforms live in the model scene. sloppyCAN is the sole authority on lamp state
## (plan §6): the brake tier, the turn bits and the headlight level are mirrored
## VERBATIM here — there is no local blink timer; turn lamps blink because the source
## toggles the bit.
##
## The decision (rear_tier) is a pure static fn, unit-tested in tests/test_lamps.gd;
## apply() is the thin scene-touching part (Light3D energy + emissive materials).

## Rear tri-state (plan §6): STOP (brake) > TAIL (headlights on) > OFF (dim housing,
## never invisible).
enum Rear { OFF, TAIL, STOP }

## Headlight levels — mirror the contract 'lights' enum values exactly.
const HL_OFF := 1
const HL_CLEARANCE := 2
const HL_LOW := 3
const HL_HIGH := 4

## Emissive energy per rear tier; OFF keeps a dim housing glow so the lens is always
## visible (plan §6).
const REAR_ENERGY := { Rear.OFF: 0.15, Rear.TAIL: 0.7, Rear.STOP: 3.5 }
const REAR_COLOR := Color(0.95, 0.06, 0.03)

## Turn lens: dark amber when off (still visible), bright amber when lit.
const TURN_OFF_ENERGY := 0.12
const TURN_ON_ENERGY := 3.5
const TURN_COLOR := Color(1.0, 0.5, 0.0)

## Headlight SpotLight3D energy + range per level (distinct per state, plan §6).
const HEAD_ENERGY := { HL_OFF: 0.0, HL_CLEARANCE: 0.6, HL_LOW: 4.0, HL_HIGH: 8.0 }
const HEAD_RANGE := { HL_OFF: 0.0, HL_CLEARANCE: 8.0, HL_LOW: 28.0, HL_HIGH: 50.0 }

var _heads: Array[SpotLight3D] = []
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
	for h in _heads:
		h.visible = energy > 0.0
		h.light_energy = energy
		h.spot_range = HEAD_RANGE.get(headlights, 0.0)
