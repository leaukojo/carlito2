class_name Drivetrain
extends RefCounted
## Simplified clutch-less, diff-less drivetrain: engine torque curve ->
## gearbox (RAMN gear byte semantics) -> drive axle. RPM follows wheel speed through
## the ratio with idle/redline clamps — the *real* RPM signal.
##
## All math lives in static pure functions (unit-tested); the instance only holds
## current gear + smoothed RPM. Approach informed by Dechode/Godot-Advanced-Vehicle
## and Tobalation/GDCustomRaycastVehicle (both MIT, credited in README); no code copied.

## RAMN gear byte: 0x00 = N, 0x01..0x06 = D1-D6, 0xFF = R.
const GEAR_N := 0x00
const GEAR_R := 0xFF

const RADS_TO_RPM := 60.0 / TAU
const RPM_SMOOTH := 8.0  ## 1/s exponential rate the displayed/torque RPM tracks the target

var spec: VehicleSpec
var gear_byte := GEAR_N
var rpm: float


func _init(p_spec: VehicleSpec) -> void:
	spec = p_spec
	rpm = spec.idle_rpm


static func is_drive(byte: int) -> bool:
	return byte >= 1 and byte <= 6


static func is_reverse(byte: int) -> bool:
	return byte == GEAR_R


## Any byte outside the RAMN semantics is treated as Neutral (safe).
static func normalize_byte(byte: int) -> int:
	if is_drive(byte) or is_reverse(byte):
		return byte
	return GEAR_N


## Total engine->wheel ratio, signed by direction (forward +, reverse -), 0 in N.
static func ratio_for_byte(p_spec: VehicleSpec, byte: int) -> float:
	if is_drive(byte):
		return p_spec.gear_ratios[byte - 1] * p_spec.final_drive
	if is_reverse(byte):
		return -p_spec.reverse_ratio * p_spec.final_drive
	return 0.0


## Full-throttle engine torque at rpm; 0 at/above redline (soft limiter).
static func engine_torque(p_spec: VehicleSpec, at_rpm: float) -> float:
	if at_rpm >= p_spec.redline_rpm:
		return 0.0
	return VehicleSpec.sample_curve(p_spec.torque_curve, at_rpm)


## RPM implied by wheel speed through the ratio, clamped [idle, redline]; idle in N.
static func rpm_from_wheel(p_spec: VehicleSpec, wheel_omega: float, byte: int) -> float:
	var ratio := ratio_for_byte(p_spec, byte)
	if ratio == 0.0:
		return p_spec.idle_rpm
	return clampf(absf(wheel_omega * ratio) * RADS_TO_RPM, p_spec.idle_rpm, p_spec.redline_rpm)


## Torque delivered to the drive axle, signed by the gear ratio (throttle is a 0..1
## magnitude — direction always comes from the gear).
static func wheel_torque(p_spec: VehicleSpec, at_rpm: float, throttle: float, byte: int) -> float:
	return engine_torque(p_spec, at_rpm) * clampf(throttle, 0.0, 1.0) \
			* ratio_for_byte(p_spec, byte) * p_spec.efficiency


## One clutch-less shift step within D1-D6 on rpm thresholds; N/R never auto-shift.
static func auto_shift(p_spec: VehicleSpec, byte: int, at_rpm: float) -> int:
	if not is_drive(byte):
		return normalize_byte(byte)
	if at_rpm >= p_spec.shift_up_rpm and byte < 6:
		return byte + 1
	if at_rpm <= p_spec.shift_down_rpm and byte > 1:
		return byte - 1
	return byte


## Per-tick update: adopt the gear request, update RPM, return drive-axle torque (Nm).
## auto=true (local input): the request is a direction (N / enter-D / R) and the box
## auto-shifts within D1-D6. auto=false (bridge): the byte is exact — the bridge
## gear owns direction and auto-shift is bypassed.
## `ground_speed` is the body's forward road speed (m/s); auto-shift decides on it, not
## on `drive_wheel_omega`, so wheelspin can't fake a high rpm and make the box hunt.
func process(delta: float, throttle: float, drive_wheel_omega: float,
		ground_speed: float, requested_byte: int, auto: bool) -> float:
	var req := normalize_byte(requested_byte)
	if auto:
		if req == GEAR_R or req == GEAR_N:
			gear_byte = req
		elif not is_drive(gear_byte):
			gear_byte = req
		if is_drive(gear_byte):
			# Shift on ROAD speed, not the spinning drive wheel: under wheelspin the
			# wheel over-reads rpm, upshifting early; the taller gear then bogs below the
			# downshift point and drops back -> hunting. The real (spinning) rpm still
			# drives the engine target below and the tach.
			var road_omega := ground_speed / spec.wheel_radius
			gear_byte = auto_shift(spec, gear_byte, rpm_from_wheel(spec, road_omega, gear_byte))
	else:
		gear_byte = req

	var target_rpm: float
	if gear_byte == GEAR_N:
		target_rpm = lerpf(spec.idle_rpm, spec.redline_rpm, clampf(throttle, 0.0, 1.0))
	else:
		target_rpm = rpm_from_wheel(spec, drive_wheel_omega, gear_byte)
	rpm = lerpf(rpm, target_rpm, 1.0 - exp(-RPM_SMOOTH * delta))

	return wheel_torque(spec, rpm, throttle, gear_byte)
