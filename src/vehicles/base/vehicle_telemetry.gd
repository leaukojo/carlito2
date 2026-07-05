class_name VehicleTelemetry
extends RefCounted
## Per-tick telemetry published by BaseVehicle (plan §4.4, §3). Covers every contract
## "out" signal for ground vehicles (car/truck/tractor).
##
## Motion values (speed, rpm, gear, slip, accel, yaw, heading, position) are read out
## of the sim that produced the motion — never derived fictions (plan §2 rule 3). The
## auxiliary systems (fuel, coolant, battery) are simple *honest models* (v1 parity,
## plan §1) clearly labelled as modeled, not measured.
##
## Every non-trivial derivation is a static pure function down below and is unit-tested
## in tests/test_telemetry.gd, exactly like Drivetrain's math — BaseVehicle only holds
## the per-tick state (previous velocity, accumulators) and calls these.

# --- GPS mapping (plan §6: world XZ -> lat/lon around the Paris origin) ---
const GPS_ORIGIN_LAT := 48.8566
const GPS_ORIGIN_LON := 2.3522
const METERS_PER_DEG_LAT := 111320.0  ## mean meters per degree of latitude

# --- auxiliary-system model constants ---
const FUEL_IDLE_BURN := 0.02   ## %/s burned at idle while running
const FUEL_LOAD_BURN := 0.18   ## extra %/s at full throttle
const COOLANT_AMBIENT := 20.0    ## degC cold-start / engine-off resting temp
const COOLANT_OPERATING := 90.0  ## degC steady running temp at no load
const COOLANT_HOT := 108.0       ## degC steady running temp at full load
const BATTERY_RESTING := 12.6    ## V engine off
const BATTERY_CHARGING := 14.2   ## V engine running (alternator), before load droop

# --- status bitfield (contract 'status', u16) ---
## Provisional layout: the final bit assignment is fixed at P3 with sloppyCAN
## (contract note). Kept here as named bits so nothing hand-codes magic numbers.
const ST_IGNITION := 1 << 0    ## engine running (key in Ignition)
const ST_GROUND := 1 << 1      ## all wheels on the ground
const ST_MOVING := 1 << 2      ## |speed| above the standstill epsilon
const ST_REVERSE := 1 << 3     ## engaged gear is R
const ST_NEUTRAL := 1 << 4     ## engaged gear is N
const ST_HANDBRAKE := 1 << 5   ## parking brake engaged
const ST_HEADLIGHTS := 1 << 6  ## headlights at LOW or brighter

# --- motion (measured from the sim) ---
var speed := 0.0        ## signed longitudinal m/s (contract 'speed')
var kmh := 0.0          ## absolute km/h (contract 'kmh')
var rpm := 0.0          ## real engine RPM out of the drivetrain (contract 'rpm')
var gear_byte := 0      ## RAMN byte: 0=N, 1..6=D1-D6, 255=R (contract 'gear')
var throttle := 0.0     ## -1..1 as applied, signed by direction (contract 'throttle')
var steer := 0.0        ## -1..1 as applied (contract 'steer')
var yaw := 0.0          ## yaw rate rad/s about the body up axis (contract 'yaw')
var acc_long := 0.0     ## longitudinal accel m/s^2, smoothed (contract 'accLong')
var acc_lat := 0.0      ## lateral accel m/s^2, smoothed (contract 'accLat')
var slip_front := 0.0   ## mean |slip ratio| per axle (contract 'slip'; per-axle split is P2)
var slip_rear := 0.0
var ground := false     ## all wheels in contact (contract 'ground')
var impact := 0.0       ## impact event magnitude m/s^2, peak-held (contract 'impact')

# --- navigation ---
var pos_x := 0.0        ## world X (contract 'posX')
var pos_z := 0.0        ## world Z (contract 'posZ')
var heading := 0.0      ## compass heading deg, [0,360) (contract 'heading')
var lat := GPS_ORIGIN_LAT   ## GPS latitude, Paris origin (contract 'lat')
var lon := GPS_ORIGIN_LON   ## GPS longitude, Paris origin (contract 'lon')
var odo := 0.0          ## odometer km, persists across respawn (contract 'odo')

# --- auxiliary systems (modeled, not measured) ---
var fuel := 100.0                ## % remaining (contract 'fuel')
var coolant := COOLANT_AMBIENT   ## degC (contract 'coolant')
var battery := BATTERY_RESTING   ## V (contract 'battery' out; distinct from the 'in' warning LED)
var status := 0                  ## u16 bitfield (contract 'status')


# --- pure derivations (unit-tested) -----------------------------------------

## Latitude for a world Z, mapping -Z to north around the Paris origin. GDScript
## floats are 64-bit so the small-offset precision the contract's f64 lat/lon want
## survives (returning a Vector2 would truncate it to 32-bit).
static func gps_lat(world_z: float) -> float:
	return GPS_ORIGIN_LAT + (-world_z) / METERS_PER_DEG_LAT


## Longitude for a world X (+X = east), meters-per-degree shrunk by the origin latitude.
static func gps_lon(world_x: float) -> float:
	return GPS_ORIGIN_LON + world_x / (METERS_PER_DEG_LAT * cos(deg_to_rad(GPS_ORIGIN_LAT)))


## Compass heading in degrees [0,360) from a forward vector. 0 = north (-Z),
## 90 = east (+X); matches the GPS axis convention above.
static func heading_from_forward(forward: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)


## Odometer step: accumulate absolute distance travelled, in km.
static func odo_step(prev_km: float, speed_ms: float, delta: float) -> float:
	return prev_km + absf(speed_ms) * delta / 1000.0


## Body-frame acceleration (long, lat) in m/s^2 from the velocity change over the
## tick, projected onto the given forward/right axes. Kinematic (no gravity term):
## it reports the g felt from actual changes in motion. Caller smooths it.
static func body_accel(v_now: Vector3, v_prev: Vector3, delta: float,
		forward: Vector3, right: Vector3) -> Vector2:
	if delta <= 0.0:
		return Vector2.ZERO
	var a := (v_now - v_prev) / delta
	return Vector2(a.dot(forward), a.dot(right))


## Impact magnitude gate: the acceleration spike is only an "event" once it clears
## the threshold, otherwise 0 (caller peak-holds it so a one-tick spike stays visible).
static func impact_gate(accel_mag: float, threshold: float) -> float:
	return accel_mag if accel_mag >= threshold else 0.0


## Fuel burn step (%). Only burns while running; idle burn plus a load term.
static func fuel_step(prev_pct: float, load: float, running: bool, delta: float) -> float:
	if not running:
		return prev_pct
	var burn := (FUEL_IDLE_BURN + FUEL_LOAD_BURN * clampf(load, 0.0, 1.0)) * delta
	return clampf(prev_pct - burn, 0.0, 100.0)


## Steady-state coolant target: ambient when off, warming toward the hot end with load.
static func coolant_target(running: bool, load: float) -> float:
	if not running:
		return COOLANT_AMBIENT
	return lerpf(COOLANT_OPERATING, COOLANT_HOT, clampf(load, 0.0, 1.0))


## First-order lag toward the coolant target; never overshoots.
static func coolant_step(prev_c: float, target_c: float, rate: float, delta: float) -> float:
	return move_toward(prev_c, target_c, rate * delta)


## Battery terminal voltage: resting when off, alternator-charged (drooping under
## load) when running.
static func battery_volts(running: bool, load: float) -> float:
	if not running:
		return BATTERY_RESTING
	return BATTERY_CHARGING - 0.6 * clampf(load, 0.0, 1.0)


## Pack the status bitfield from current vehicle state.
static func pack_status(ignition: bool, ground_contact: bool, moving: bool,
		gear_byte_: int, handbrake: bool, headlights: bool) -> int:
	var s := 0
	if ignition:
		s |= ST_IGNITION
	if ground_contact:
		s |= ST_GROUND
	if moving:
		s |= ST_MOVING
	if gear_byte_ == Drivetrain.GEAR_R:
		s |= ST_REVERSE
	if gear_byte_ == Drivetrain.GEAR_N:
		s |= ST_NEUTRAL
	if handbrake:
		s |= ST_HANDBRAKE
	if headlights:
		s |= ST_HEADLIGHTS
	return s


# --- bridge marshaling -------------------------------------------------------

## Every non-todo ground "out" signal keyed by its contract name, in the units the
## contract declares (plan §3). The Bridge walks Contract.signals_out() and pulls
## each name from here, so the field-name list lives once, in the contract — the
## bridge never hand-writes it (plan §2 rule 4). throttle/steer are reported as
## percent (contract i8 %) and slip as the mean per-axle ratio; the fixed-point CAN
## byte scaling is the sloppyCAN side's job, not ours.
func to_bridge_dict() -> Dictionary:
	return {
		"speed": speed,
		"kmh": kmh,
		"rpm": roundi(rpm),
		"gear": gear_byte,
		"throttle": roundi(throttle * 100.0),
		"steer": roundi(steer * 100.0),
		"yaw": yaw,
		"accLong": acc_long,
		"accLat": acc_lat,
		"slip": (slip_front + slip_rear) * 0.5,
		"ground": ground,
		"posX": pos_x,
		"posZ": pos_z,
		"heading": heading,
		"lat": lat,
		"lon": lon,
		"odo": odo,
		"status": status,
		"impact": impact,
		"fuel": roundi(fuel),
		"coolant": roundi(coolant),
		"battery": battery,
	}
