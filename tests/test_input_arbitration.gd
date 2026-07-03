extends GdUnitTestSuite
## InputRouter arbitration rules that exist at M1 (plan §5.2, §6): key gating,
## brake-never-throttle, and the local S = brake-then-reverse scheme.
## Exercises the pure static arbitrate_local — no autoload lifecycle needed.

const RouterScript := preload("res://src/input/input_router.gd")

const GEAR_N := 0x00
const GEAR_D1 := 0x01
const GEAR_R := 0xFF


func _raw(accel := 0.0, brake_reverse := 0.0, steer := 0.0, handbrake := 0.0) -> Dictionary:
	return {
		"accel": accel, "brake_reverse": brake_reverse,
		"steer": steer, "handbrake": handbrake,
	}


func test_throttle_zero_unless_key_ignition() -> void:
	for key in [RouterScript.KEY_LOCK, RouterScript.KEY_ON]:
		var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(
				_raw(1.0), 0.0, GEAR_D1, key)
		assert_float(out.throttle).is_equal(0.0)
	var ignition: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(1.0), 0.0, GEAR_D1, RouterScript.KEY_IGNITION)
	assert_float(ignition.throttle).is_equal(1.0)


func test_brake_never_produces_throttle_while_moving() -> void:
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(0.0, 1.0), 15.0, GEAR_D1)
	assert_float(out.throttle).is_equal(0.0)
	assert_float(out.brake).is_equal(1.0)
	assert_int(out.gear_request).is_equal(GEAR_D1)


func test_full_accel_plus_full_brake_pass_through() -> void:
	# §6: stopping is the brake > accel force hierarchy's job (in the spec), not
	# the router's — both pedals pass through untouched.
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(1.0, 1.0), 15.0, GEAR_D1)
	assert_float(out.throttle).is_equal(1.0)
	assert_float(out.brake).is_equal(1.0)


func test_reverse_engages_at_standstill_only() -> void:
	# Rolling: S is brake.
	var rolling: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(0.0, 1.0), 10.0, GEAR_D1)
	assert_int(rolling.gear_request).is_equal(GEAR_D1)
	assert_float(rolling.throttle).is_equal(0.0)
	# Near standstill: S engages R and becomes reverse throttle (signed by gear).
	for gear in [GEAR_N, GEAR_D1]:
		var stopped: RouterScript.VehicleInput = RouterScript.arbitrate_local(
				_raw(0.0, 1.0), 0.1, gear)
		assert_int(stopped.gear_request).is_equal(GEAR_R)
		assert_float(stopped.throttle).is_equal(-1.0)
		assert_float(stopped.brake).is_equal(0.0)


func test_accel_while_reversing_brakes_then_reengages_drive() -> void:
	# Rolling backwards: W is brake, gear stays R.
	var rolling: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(1.0, 0.0), -3.0, GEAR_R)
	assert_int(rolling.gear_request).is_equal(GEAR_R)
	assert_float(rolling.throttle).is_equal(0.0)
	assert_float(rolling.brake).is_equal(1.0)
	# Stopped: W re-engages D1 with forward throttle.
	var stopped: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(1.0, 0.0), -0.1, GEAR_R)
	assert_int(stopped.gear_request).is_equal(GEAR_D1)
	assert_float(stopped.throttle).is_equal(1.0)
	assert_float(stopped.brake).is_equal(0.0)


func test_idle_in_reverse_stays_in_reverse() -> void:
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(), 0.0, GEAR_R)
	assert_int(out.gear_request).is_equal(GEAR_R)
	assert_float(out.throttle).is_equal(0.0)


func test_no_input_in_neutral_requests_neutral() -> void:
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(), 0.0, GEAR_N)
	assert_int(out.gear_request).is_equal(GEAR_N)
	assert_bool(out.gear_auto).is_true()


func test_steer_and_handbrake_pass_through_clamped() -> void:
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(
			_raw(0.0, 0.0, -1.5, 2.0), 0.0, GEAR_D1)
	assert_float(out.steer).is_equal(-1.0)
	assert_float(out.handbrake).is_equal(1.0)
