extends Level
## Garage showroom. The spawned vehicle is physics-frozen and hovers above the floor so
## the orbit camera can inspect it from any angle, including underneath. Freezing is
## KINEMATIC, so _physics_process still runs — wheels steer/spin, the engine revs, lamps
## toggle — the body just never moves. A wall screen shows the active vehicle's spec.
## Input, lamps, dashboard and bridge all flow through Level unchanged.

@onready var _stats_left: Label3D = $Screen/StatsLeft
@onready var _stats_right: Label3D = $Screen/StatsRight


func _ready() -> void:
	# Connect before super._ready() so the load-time spawn's vehicle_changed is handled.
	vehicle_changed.connect(_on_vehicle_changed)
	super._ready()


## Runs on every (re)spawn/swap: pin the new body in place and refresh the wall stats.
func _on_vehicle_changed(_family: String) -> void:
	if vehicle == null:
		return
	vehicle.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	vehicle.freeze = true
	_refresh_stats()


## Two columns so the text fits the wall screen.
func _refresh_stats() -> void:
	var spec: VehicleSpec = vehicle.spec
	if spec == null:
		_stats_left.text = "No spec"
		_stats_right.text = ""
		return
	_stats_left.text = "\n".join([
		"VEHICLE: %s" % _game_state().current_variant,
		"Family: %s" % _game_state().current_vehicle,
		"Mass: %d kg" % roundi(spec.mass),
		"Drive: %s" % _drive_text(spec),
	])
	_stats_right.text = "\n".join([
		"Gears: %d" % spec.gear_ratios.size(),
		"Redline: %d rpm" % roundi(spec.redline_rpm),
		"Peak torque: %d Nm" % roundi(_peak_torque(spec)),
		"Max steer: %.0f deg" % spec.max_steer_deg,
		"Brake: %d Nm" % roundi(spec.brake_torque),
	])


func _drive_text(spec: VehicleSpec) -> String:
	if spec.driven_front and spec.driven_rear:
		return "AWD"
	if spec.driven_front:
		return "FWD"
	if spec.driven_rear:
		return "RWD"
	return "none"


func _peak_torque(spec: VehicleSpec) -> float:
	var peak := 0.0
	for p in spec.torque_curve:
		peak = maxf(peak, p.y)
	return peak
