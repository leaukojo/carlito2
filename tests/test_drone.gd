extends GdUnitTestSuite
## Drone flight math. Pure static fns exercised without the physics body — the same
## testing discipline as the boat/RayWheel. What matters most are the 60 Hz one-tick
## clamps (a damper may at most zero the velocity it opposes in one tick, never reverse
## it; totals are hard-capped) plus the arcade guarantees: hover equilibrium, self-levelling
## torque direction, arm gating, and the modeled rotor-rpm.

const D := preload("res://src/vehicles/drone/drone.gd")
const DroneT := preload("res://src/vehicles/drone/drone_telemetry.gd")

const DELTA := 1.0 / 60.0

# Round numbers so expected values are hand-checkable: a 5 kg drone at g = 10.
const MASS := 5.0
const G := 10.0
const CLIMB_FORCE := 30.0
const MAX_THRUST := 150.0


# --- lift_thrust: hover equilibrium + clamps ----------------------------------

func test_lift_thrust_hovers_against_gravity() -> void:
	# Climb neutral: thrust exactly cancels weight, so a level drone holds altitude.
	assert_float(D.lift_thrust(MASS, G, 0.0, CLIMB_FORCE, MAX_THRUST)).is_equal_approx(MASS * G, 1e-6)


func test_lift_thrust_climb_stick_adds_and_removes_lift() -> void:
	assert_float(D.lift_thrust(MASS, G, 1.0, CLIMB_FORCE, MAX_THRUST)) \
			.is_equal_approx(MASS * G + CLIMB_FORCE, 1e-6)
	assert_float(D.lift_thrust(MASS, G, -1.0, CLIMB_FORCE, MAX_THRUST)) \
			.is_equal_approx(MASS * G - CLIMB_FORCE, 1e-6)


func test_lift_thrust_never_negative_and_hard_capped() -> void:
	# Full-down with a climb force larger than weight still can't suck the drone down.
	assert_float(D.lift_thrust(MASS, G, -1.0, 200.0, MAX_THRUST)).is_equal(0.0)
	# Runaway demand is capped at max_thrust (the max_suspension_force analogue).
	assert_float(D.lift_thrust(MASS, G, 1.0, 1e6, MAX_THRUST)).is_equal(MAX_THRUST)


# --- clamped_damper: 60 Hz one-tick discipline --------------------------------

func test_clamped_damper_opposes_velocity() -> void:
	var f := D.clamped_damper(Vector3(2.0, 0.0, 0.0), 3.0, MASS, DELTA)
	assert_vector(f).is_equal_approx(Vector3(-6.0, 0.0, 0.0), Vector3.ONE * 1e-4)


func test_clamped_damper_clamped_to_one_tick_zeroing() -> void:
	# An absurd coefficient may at most ZERO the velocity in one tick, never reverse it.
	var v := Vector3(0.0, 0.0, 1.5)
	var tick_cap := MASS * v.length() / DELTA
	var f := D.clamped_damper(v, 1e12, MASS, DELTA)
	assert_float(f.length()).is_equal_approx(tick_cap, 1e-2)
	# Direction is exactly opposite the velocity (no reversal).
	assert_float(f.normalized().dot(v.normalized())).is_equal_approx(-1.0, 1e-5)


func test_clamped_damper_zero_velocity_is_zero() -> void:
	assert_vector(D.clamped_damper(Vector3.ZERO, 5.0, MASS, DELTA)).is_equal(Vector3.ZERO)


# --- level_target_up: attitude target ------------------------------------------

func test_level_target_up_level_is_straight_up() -> void:
	assert_vector(D.level_target_up(Basis.IDENTITY, 0.0)).is_equal_approx(Vector3.UP, Vector3.ONE * 1e-5)


func test_level_target_up_positive_tilt_leans_the_up_vector_back() -> void:
	# Facing -Z (north). POSITIVE tilt tips the up-vector backward (+Z) — the nose-up /
	# backward-flight lean (the caller negates throttle, so W maps to negative tilt).
	var up := D.level_target_up(Basis.IDENTITY, deg_to_rad(20.0))
	assert_float(up.z).is_greater(0.0)      # leaned toward +Z (backward)
	assert_float(up.x).is_equal_approx(0.0, 1e-5)  # no roll introduced
	assert_float(up.y).is_equal_approx(cos(deg_to_rad(20.0)), 1e-5)


# --- align_torque: self-levelling direction is correct by construction ---------

func test_align_torque_rotates_body_up_toward_target() -> void:
	# Body rolled so its up leans to +X; target is world up. The torque must rotate the
	# up-vector back toward vertical (a positive rotation about +Z reduces a +X lean).
	var s := sin(deg_to_rad(15.0))
	var c := cos(deg_to_rad(15.0))
	var body_up := Vector3(s, c, 0.0)
	var tau := D.align_torque(body_up, Vector3.UP, 4.0)
	assert_vector(tau).is_equal_approx(Vector3(0.0, 0.0, s * 4.0), Vector3.ONE * 1e-4)
	# Already level: no corrective torque.
	assert_vector(D.align_torque(Vector3.UP, Vector3.UP, 4.0)).is_equal_approx(Vector3.ZERO, Vector3.ONE * 1e-6)


# --- yaw_torque: drives the yaw rate toward target, clamped --------------------

func test_yaw_torque_pushes_toward_target_rate() -> void:
	# Below target: positive torque; above target: negative.
	assert_float(D.yaw_torque(2.0, 0.0, 4.0, 0.6, DELTA, 6.0)).is_greater(0.0)
	assert_float(D.yaw_torque(0.0, 2.0, 4.0, 0.6, DELTA, 6.0)).is_less(0.0)
	# At the target: no torque.
	assert_float(D.yaw_torque(1.5, 1.5, 4.0, 0.6, DELTA, 6.0)).is_equal(0.0)


func test_yaw_torque_capped_and_one_tick_clamped() -> void:
	# A huge gain is capped at max_torque.
	assert_float(D.yaw_torque(5.0, 0.0, 1e6, 0.6, DELTA, 6.0)).is_equal(6.0)
	# With a tiny error the one-tick cap (inertia*err/delta) binds below max_torque.
	var err := 0.001
	var tick_cap := 0.6 * err / DELTA
	assert_float(D.yaw_torque(err, 0.0, 1e6, 0.6, DELTA, 6.0)).is_equal_approx(tick_cap, 1e-4)


# --- rotor_rpm: honest model + arm gating --------------------------------------

func test_rotor_rpm_zero_when_disarmed() -> void:
	assert_int(D.rotor_rpm(MASS * G, MAX_THRUST, 2600, 12000, false)).is_equal(0)


func test_rotor_rpm_scales_with_thrust_fraction() -> void:
	# Disarmed floor aside, armed rpm interpolates spin_min..spin_max by thrust/max.
	assert_int(D.rotor_rpm(0.0, MAX_THRUST, 2600, 12000, true)).is_equal(2600)
	assert_int(D.rotor_rpm(MAX_THRUST, MAX_THRUST, 2600, 12000, true)).is_equal(12000)
	# Hover thrust (50 of 150 = 1/3) sits a third of the way up.
	assert_int(D.rotor_rpm(50.0, 150.0, 0, 12000, true)).is_equal(4000)


# --- inertia + attitude extraction ---------------------------------------------

func test_inertia_of_box_footprint() -> void:
	# m (w^2 + d^2) / 12 with round numbers: 12 * (4 + 2) / 12 = 6.
	assert_float(D.inertia_of(12.0, 2.0, sqrt(2.0))).is_equal_approx(6.0, 1e-5)


func test_pitch_and_roll_extraction() -> void:
	assert_float(D.pitch_deg(Basis.IDENTITY)).is_equal_approx(0.0, 1e-4)
	# +X rotation lifts the nose (boat convention).
	assert_float(D.pitch_deg(Basis(Vector3.RIGHT, deg_to_rad(20.0)))).is_equal_approx(20.0, 1e-4)
	assert_float(D.roll_deg(Basis.IDENTITY)).is_equal_approx(0.0, 1e-4)
	assert_float(D.roll_deg(Basis(Vector3(0, 0, -1), deg_to_rad(30.0)))).is_equal_approx(30.0, 1e-4)


# --- telemetry bridge coverage -------------------------------------------------

func test_drone_telemetry_bridge_dict_adds_flight_fields() -> void:
	var t := DroneT.new()
	t.altitude = 42.0
	t.vspeed = -1.5
	t.rotor_rpm = 8000
	t.armed = true
	t.pitch = 6.0
	t.roll = -3.0
	var d := t.to_bridge_dict()
	assert_float(d["altitude"]).is_equal(42.0)
	assert_float(d["vspeed"]).is_equal(-1.5)
	assert_int(d["rotor_rpm"]).is_equal(8000)
	assert_bool(d["armed"]).is_true()
	assert_float(d["pitch"]).is_equal(6.0)
	assert_float(d["roll"]).is_equal(-3.0)
	# Base fields still ride along (super() first, tractor/boat pattern).
	assert_bool(d.has("speed")).is_true()
	assert_bool(d.has("status")).is_true()
