class_name TractorVehicle
extends BaseVehicle
## Tractor (plan §1 Machinery, §4.4). A real BaseVehicle subclass because it owns per-tick
## subsystem state the base has no concept of: the rear hitch position and the PTO. It never
## forks _physics_process — it plugs into the two base seams (_make_telemetry, _tick_extras).
##
## Implement geometry is scene-authored on the Implement (like lamp placement, plan §4.4);
## drive tuning lives in tractor_spec.tres. Only the three implement behaviour knobs are
## @export here (node behaviour, not wheel/engine tuning — a 3-number TractorSpec would be
## over-engineering, CLAUDE.md rule 2).

const SPAWN_HITCH := 1.0                ## spawn default: raised (transport), PTO off (plan §3)

@export var hitch_travel_time := 1.5   ## s for a full raise or lower
@export var pto_ratio := 0.45          ## engine rpm -> PTO shaft rpm (redline*ratio must be <= 1200)
@export var pto_load := 0.35           ## engine_load added while PTO engaged
@export var implement_path: NodePath = ^"HitchSocket/Implement"

var _hitch_actual := SPAWN_HITCH       ## 0..1, chases input.hitch_request
var _implement: Implement


func _make_telemetry() -> VehicleTelemetry:
	return TractorTelemetry.new()


func _ready() -> void:
	super._ready()
	_implement = get_node_or_null(implement_path) as Implement


func _tick_extras(input: InputRouter.VehicleInput, delta: float) -> void:
	var t := telemetry as TractorTelemetry
	var running := input.key == InputRouter.KEY_IGNITION
	_hitch_actual = move_toward(_hitch_actual, input.hitch_request, delta / hitch_travel_time)
	var pto_on := input.pto and running
	t.hitch_pos_actual = roundi(_hitch_actual * 100.0)
	t.pto_state = pto_on
	t.pto_rpm = int(clampf(drivetrain.rpm * pto_ratio, 0.0, TractorTelemetry.PTO_RPM_MAX)) if pto_on else 0
	t.engine_load = roundi(TractorTelemetry.engine_load_pct(input.throttle, pto_on, pto_load))
	if _implement != null:
		_implement.set_hitch(_hitch_actual)
		_implement.set_pto(pto_on, t.pto_rpm)


## Re-raise the implement on respawn so a reset returns to the spawn default (raised).
func respawn() -> void:
	super.respawn()
	_hitch_actual = SPAWN_HITCH
