class_name PlaneVehicle
extends BaseVehicle
## Light aircraft (CANaerospace flavor). A real BaseVehicle subclass (like the boat and
## drone) because it owns the prop/lift/control-surface locomotion module the wheeled
## base has no concept of. It never forks _physics_process — it plugs into the two base
## seams (_make_telemetry, _tick_extras). The three RayWheels (steered nose wheel, two
## mains) come straight from the spec, so ground roll, runway takeoff and wheel braking
## are the base's own physics; the wheels are UNDRIVEN — all propulsion is prop thrust.
##
## Locomotion (arcade): prop thrust from a modeled prop rpm that chases throttle (spool
## lag; the published rpm IS the number the thrust is computed from — rule 3); speed-
## squared lift along body up that fades below stall speed (simplified stall: lift dies,
## the nose drops — no spin model); air drag; control torques whose authority scales
## with airspeed (no authority at standstill, the boat's rudder rule). Steer is a
## coordinated roll+yaw blend: it commands a bank angle the roll spring chases (wings
## self-level on release) plus a yaw rate. R/F = elevator, B toggles flaps.
##
## Every force term is a pure static fn carrying the RayWheel/boat one-tick clamp
## discipline (60 Hz locked tick): a damper may at most zero the velocity it opposes in
## one tick (never reverse it), and totals are hard-capped. Unit-tested in
## tests/test_plane.gd. DO NOT remove or weaken any clamp; DO NOT raise the tick.
##
## Flight tuning lives here as node knobs (boat/drone precedent); body tuning (mass,
## wheels, brakes, the rpm band the prop model runs in) is plane_spec.tres.
## Wheel visuals bind by SPEC ORDER to WHEEL_VISUAL_NAMES: index 0 = nose = "WheelFL",
## 1 = left main = "WheelFR", 2 = right main = "WheelRL" (the base's car naming, reused).

@export_group("Propulsion")
@export var max_thrust := 9000.0        ## N at redline prop rpm (hard cap by construction)
@export var reverse_thrust_frac := 0.25 ## reverse (beta) thrust fraction for taxiing back
@export var prop_spool_rate := 3500.0   ## rpm/s the prop chases the throttle target (spool lag)

@export_group("Aero")
@export var lift_coeff := 13.0          ## N per (m/s)^2 of forward airspeed, flaps retracted
@export var lift_cap := 16000.0         ## N hard cap on total lift (~2 g)
@export var stall_speed := 13.0         ## m/s below which lift is fully gone
@export var full_lift_speed := 20.0     ## m/s at which the lift fraction reaches 1
@export var drag_coeff := 200.0         ## N per m/s of speed (sets top speed vs thrust)
@export var flap_lift_bonus := 4.0      ## extra lift_coeff at full flaps
@export var flap_drag_bonus := 40.0     ## extra drag_coeff at full flaps
@export var flap_slew_rate := 0.4       ## flap travel fraction per second (contract flaps_actual)

@export_group("Control")
@export var authority_speed_ref := 15.0 ## m/s of airflow that gives full control authority
@export var pitch_gain := 12000.0       ## N*m at full elevator + full authority
@export var pitch_damping := 9000.0     ## N*m per rad/s of pitch rate (gain/damping = max pitch rate)
@export var max_pitch_torque := 12000.0 ## N*m cap on the total pitch torque
@export var max_bank_deg := 45.0        ## bank angle commanded at full steer
@export var roll_stiffness := 9000.0    ## N*m per rad of bank error
@export var roll_damping := 3000.0      ## N*m per rad/s of roll rate
@export var max_roll_torque := 9000.0   ## N*m cap on the total roll torque
@export var max_yaw_rate := 0.9         ## rad/s commanded at full steer + full authority
@export var yaw_gain := 6000.0          ## N*m per rad/s of yaw-rate error
@export var max_yaw_torque := 7000.0    ## N*m cap on the yaw torque
@export var stall_pitch_gain := 6000.0  ## N*m of nose-down torque at full stall (airborne)

## Body footprint (m), used only to derive the representative moment of inertia the
## one-tick torque clamps need — the drone's clamp basis, the boat's probe-span role.
@export var body_extents := Vector3(7.0, 1.5, 5.5)

## Visual prop spin: shaft rad/s per prop rpm — a cosmetic ratio far below the real rev
## rate (which would alias to a shimmer at 60 fps); the honest number stays the published
## rpm, the spinning blade is just its readable stand-in (the Implement rotor precedent).
const PROP_VISUAL_SPIN := 0.012

var _prop_rpm := 0.0   ## modeled prop rpm the thrust is computed from (published as rpm)
var _flap_pos := 0.0   ## 0..1 actual flap extension, slewed toward the request
var _inertia := 5000.0 ## representative moment (kg*m^2) for the one-tick torque clamps

@onready var _prop: Node3D = $Prop


## Cosmetic only: spin the prop blade from the modeled rpm (visuals in _process, physics
## untouched — the tractor Implement's rotor pattern).
func _process(delta: float) -> void:
	_prop.rotate_z(_prop_rpm * PROP_VISUAL_SPIN * delta)


func _make_telemetry() -> VehicleTelemetry:
	return PlaneTelemetry.new()


func _ready() -> void:
	super._ready()
	_prop_rpm = 0.0
	_inertia = inertia_of(spec.mass, body_extents.x, body_extents.z)


func _tick_extras(input: InputRouter.VehicleInput, delta: float) -> void:
	var t := telemetry as PlaneTelemetry
	var body := global_transform.basis
	var fwd := -body.z
	var right := body.x
	var up := body.y

	# Prop: rpm chases the throttle target (0 with the key off — engine stopped), thrust
	# derives FROM that rpm so the published number is the one that produced the motion.
	var running := input.key == InputRouter.KEY_IGNITION
	var target_rpm := 0.0
	if running:
		target_rpm = lerpf(spec.idle_rpm, spec.redline_rpm, clampf(absf(input.throttle), 0.0, 1.0))
	_prop_rpm = prop_rpm_step(_prop_rpm, target_rpm, prop_spool_rate, delta)
	var thrust := prop_thrust(_prop_rpm, spec.idle_rpm, spec.redline_rpm, max_thrust,
			drivetrain.gear_byte, reverse_thrust_frac)
	apply_central_force(fwd * thrust)

	# Flaps: actual position slews toward the request (contract flaps_actual).
	_flap_pos = flap_slew(_flap_pos, clampf(input.flaps, 0.0, 1.0), flap_slew_rate, delta)

	# Lift + drag. Lift rides forward airspeed only (a flat fall generates none) and
	# fades to zero below stall speed; drag opposes the whole velocity, one-tick clamped.
	var v_fwd := linear_velocity.dot(fwd)
	var frac := lift_frac(v_fwd, stall_speed, full_lift_speed)
	apply_central_force(up * lift_force(v_fwd, lift_coeff + flap_lift_bonus * _flap_pos,
			lift_cap, frac))
	apply_central_force(clamped_damper(linear_velocity,
			drag_coeff + flap_drag_bonus * _flap_pos, spec.mass, delta))

	# Control surfaces: authority scales with airflow (none at standstill).
	var auth := control_authority(v_fwd, authority_speed_ref)
	# Elevator: + = nose up = +torque about body right. Damper on the pitch rate.
	apply_torque(right * pitch_torque(clampf(input.elevator, -1.0, 1.0), pitch_gain, auth,
			angular_velocity.dot(right), pitch_damping, _inertia, delta, max_pitch_torque))
	# Steer -> coordinated bank + yaw. steer + = right; roll + = right side down and
	# +torque about body FORWARD rolls right-side-down, so the spring needs no sign flip.
	# The spring always acts (authority scales it), so wings self-level on release.
	apply_torque(fwd * roll_torque(_steer * max_bank_deg, roll_deg(body), roll_stiffness,
			auth, angular_velocity.dot(fwd), roll_damping, _inertia, delta, max_roll_torque))
	# Yaw rate toward the commanded rate about body up. steer negative = left; +Y torque
	# yaws left, so the sign flips (the boat's rudder convention).
	apply_torque(up * yaw_torque(-_steer * max_yaw_rate * auth, angular_velocity.dot(up),
			yaw_gain, _inertia, delta, max_yaw_torque))

	# Simplified stall, airborne only: as lift fades the nose is pushed down, so losing
	# speed reads as the nose dropping (recover by diving), never a spin.
	if _airborne():
		apply_torque(right * stall_torque(frac, stall_pitch_gain))

	# Telemetry: attitude/altitude/vspeed straight from the sim; rpm is the prop model
	# (honest-model latitude, labelled — see PlaneTelemetry); flaps as applied.
	t.rpm = _prop_rpm
	t.pitch = pitch_deg(body)
	t.roll = roll_deg(body)
	t.altitude = global_position.y
	t.vspeed = linear_velocity.y
	t.flaps_actual = roundi(_flap_pos * 100.0)


func respawn() -> void:
	super.respawn()
	_prop_rpm = 0.0
	_flap_pos = 0.0


## True when no wheel touches the ground (the stall nose-drop only acts in the air).
func _airborne() -> bool:
	for w in wheels:
		if w.in_contact:
			return false
	return true


# --- pure flight math (unit-tested, one-tick clamped like RayWheel/boat) -------

## Prop rpm chasing its target at a fixed spool rate (rpm/s) — the boat trim_step
## pattern. The caller picks the target (idle..redline from throttle; 0 with the key off).
static func prop_rpm_step(current: float, target: float, rate: float, delta: float) -> float:
	return move_toward(current, target, rate * delta)


## 0..1 thrust fraction of the prop rpm within the engine band: idle = 0 (no residual
## creep thrust), redline = 1.
static func thrust_frac(rpm: float, idle_rpm: float, redline_rpm: float) -> float:
	return clampf((rpm - idle_rpm) / maxf(1.0, redline_rpm - idle_rpm), 0.0, 1.0)


## Signed prop thrust (N) along body forward. Magnitude comes FROM the modeled rpm
## (rule 3: the published rpm is the number that produced the motion), capped at
## thrust_cap by construction; the gear byte owns direction (D forward, R a weak
## reverse/beta fraction for taxiing, N none — the boat's gear-owns-direction rule).
static func prop_thrust(rpm: float, idle_rpm: float, redline_rpm: float, thrust_cap: float,
		gear_byte: int, reverse_frac: float) -> float:
	var mag := thrust_frac(rpm, idle_rpm, redline_rpm) * thrust_cap
	if Drivetrain.is_drive(gear_byte):
		return mag
	if Drivetrain.is_reverse(gear_byte):
		return -mag * reverse_frac
	return 0.0


## Flap position slewing toward the request at a fixed travel rate (fraction/s).
static func flap_slew(current: float, target: float, rate: float, delta: float) -> float:
	return move_toward(current, clampf(target, 0.0, 1.0), rate * delta)


## 0..1 lift fraction vs forward airspeed: 0 at/below stall speed, 1 at/above
## full_lift_speed, smoothstep between — the simplified stall curve.
static func lift_frac(airspeed: float, stall: float, full_speed: float) -> float:
	var t := clampf((airspeed - stall) / maxf(0.1, full_speed - stall), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## Lift (N) along body up: speed-squared on FORWARD airspeed (never backward flight),
## scaled by the stall fraction and hard-capped (the max_suspension_force analogue).
static func lift_force(airspeed: float, coeff: float, cap: float, fraction: float) -> float:
	var v := maxf(airspeed, 0.0)
	return minf(coeff * v * v, cap) * clampf(fraction, 0.0, 1.0)


## Control authority 0..1: no airflow over the surfaces = no control (the boat's
## rudder_authority rule, without prop wash — the tail sits outside the prop stream).
static func control_authority(airspeed: float, speed_ref: float) -> float:
	return clampf(absf(airspeed) / maxf(0.1, speed_ref), 0.0, 1.0)


## Damper opposing `vel_vec`, magnitude-clamped so one tick can at most ZERO it, never
## reverse it (RayWheel/boat discipline). `moment` is the mass or inertia acted on.
static func clamped_damper(vel_vec: Vector3, coeff: float, moment: float, delta: float) -> Vector3:
	var speed := vel_vec.length()
	if speed < 1e-6:
		return Vector3.ZERO
	var mag := minf(coeff * speed, moment * speed / delta)
	return -vel_vec / speed * mag


## Linear damping torque against `rate`, clamped so one tick can at most ZERO the rate
## it opposes, never reverse it (the boat's damped_force, torque flavor).
static func damped_torque(rate: float, coeff: float, moment: float, delta: float) -> float:
	var tick_cap := moment * absf(rate) / delta
	return clampf(-coeff * rate, -tick_cap, tick_cap)


## Pitch torque: elevator command scaled by authority plus a one-tick-clamped damper on
## the pitch rate; the total is hard-capped. + = nose up (about body right).
static func pitch_torque(elevator: float, gain: float, authority: float, pitch_rate: float,
		damping: float, moment: float, delta: float, max_torque: float) -> float:
	var torque := elevator * gain * clampf(authority, 0.0, 1.0) \
			+ damped_torque(pitch_rate, damping, moment, delta)
	return clampf(torque, -max_torque, max_torque)


## Roll torque: spring toward the commanded bank angle (degrees, + = right side down)
## scaled by authority, plus a one-tick-clamped damper on the roll rate; hard-capped.
## Applied about body FORWARD, where + rolls the right side down — spring sign matches.
static func roll_torque(target_deg: float, current_deg: float, stiffness: float,
		authority: float, roll_rate: float, damping: float, moment: float, delta: float,
		max_torque: float) -> float:
	var torque := deg_to_rad(target_deg - current_deg) * stiffness * clampf(authority, 0.0, 1.0) \
			+ damped_torque(roll_rate, damping, moment, delta)
	return clampf(torque, -max_torque, max_torque)


## Yaw torque driving the yaw rate toward `target_rate`, one-tick clamped (the impulse
## can't overshoot the target rate within a tick) and hard-capped (the drone's rule).
static func yaw_torque(target_rate: float, current_rate: float, gain: float,
		moment: float, delta: float, max_torque: float) -> float:
	var err := target_rate - current_rate
	var tick_cap := moment * absf(err) / delta
	return clampf(clampf(gain * err, -tick_cap, tick_cap), -max_torque, max_torque)


## Nose-down stall torque (N*m, about body right — negative = nose down): zero with
## full lift, full gain with none. The hard cap is the gain itself by construction.
static func stall_torque(lift_fraction: float, gain: float) -> float:
	return -(1.0 - clampf(lift_fraction, 0.0, 1.0)) * gain


## Representative moment of inertia (kg*m^2) of a box footprint — the clamp basis for
## the torque dampers (m (w^2 + d^2) / 12), the boat/drone formula.
static func inertia_of(body_mass: float, width: float, depth: float) -> float:
	return body_mass * (width * width + depth * depth) / 12.0


## Body pitch in degrees, + = nose up. Read straight from the basis (boat convention).
static func pitch_deg(b: Basis) -> float:
	return rad_to_deg(asin(clampf((-b.z).y, -1.0, 1.0)))


## Body roll in degrees, + = starboard/right side down; atan2 stays stable through a
## full roll (contract range -180..180). Boat convention.
static func roll_deg(b: Basis) -> float:
	return rad_to_deg(atan2(-b.x.y, b.y.y))
