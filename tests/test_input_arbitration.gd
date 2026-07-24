extends GdUnitTestSuite
## InputRouter local arbitration rules: key gating,
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


# --- bridge arbitration (gear owns direction while active) --------------------
## Values reach arbitrate_bridge already normalized (bridge_source did the /100).

func _bridge(accel := 0.0, brake := 0.0, steer := 0.0, handbrake := 0.0,
		gear := GEAR_N, key := RouterScript.KEY_IGNITION) -> Dictionary:
	return {
		"active": true, "accel": accel, "brake": brake, "steer": steer,
		"handbrake": handbrake, "gear": gear, "key": key, "lights": 1, "horn": false,
	}


func test_bridge_gear_owns_direction() -> void:
	# D1: forward throttle, exact byte (gear_auto false).
	var d1: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 0.0, 0.0, 0.0, GEAR_D1))
	assert_int(d1.gear_request).is_equal(GEAR_D1)
	assert_float(d1.throttle).is_equal(1.0)
	assert_bool(d1.gear_auto).is_false()
	# R: same accel, negative throttle.
	var rev: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 0.0, 0.0, 0.0, GEAR_R))
	assert_int(rev.gear_request).is_equal(GEAR_R)
	assert_float(rev.throttle).is_equal(-1.0)
	# N: no drive.
	var neu: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 0.0, 0.0, 0.0, GEAR_N))
	assert_int(neu.gear_request).is_equal(GEAR_N)
	assert_float(neu.throttle).is_equal(0.0)


func test_bridge_all_forward_gears_drive_forward() -> void:
	for g in [2, 3, 4, 5, 6]:
		var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.5, 0.0, 0.0, 0.0, g))
		assert_int(out.gear_request).is_equal(g)
		assert_float(out.throttle).is_equal(0.5)


func test_bridge_key_gates_throttle() -> void:
	for key in [RouterScript.KEY_LOCK, RouterScript.KEY_ON]:
		var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 0.0, 0.0, 0.0, GEAR_D1, key))
		assert_float(out.throttle).is_equal(0.0)
	var ign: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 0.0, 0.0, 0.0, GEAR_D1, RouterScript.KEY_IGNITION))
	assert_float(ign.throttle).is_equal(1.0)


func test_bridge_brake_never_throttle() -> void:
	# Brake alone: no throttle, brake passes.
	var braked: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 1.0, 0.0, 0.0, GEAR_D1))
	assert_float(braked.throttle).is_equal(0.0)
	assert_float(braked.brake).is_equal(1.0)
	# Full accel + full brake: throttle from accel (signed by gear), brake still passes.
	var both: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(1.0, 1.0, 0.0, 0.0, GEAR_D1))
	assert_float(both.throttle).is_equal(1.0)
	assert_float(both.brake).is_equal(1.0)


func test_bridge_steer_and_handbrake_pass_through() -> void:
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 0.0, -0.5, 1.0, GEAR_D1))
	assert_float(out.steer).is_equal(-0.5)
	assert_float(out.handbrake).is_equal(1.0)


# --- lamp/warning bits --------------------------------------------

func test_local_lamp_bits_default_off_and_brake_lamp_follows_brake() -> void:
	# Rolling in D1 with S held: foot brake on -> STOP; turn/warning LEDs off (no local
	# source, no blink timer).
	var braking: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(0.0, 1.0), 10.0, GEAR_D1)
	assert_bool(braking.brake_lamp).is_true()
	assert_bool(braking.turn_left).is_false()
	assert_bool(braking.turn_right).is_false()
	assert_bool(braking.check_engine).is_false()
	assert_bool(braking.battery_warn).is_false()
	# Coasting: no brake -> no STOP.
	var coasting: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(1.0, 0.0), 10.0, GEAR_D1)
	assert_bool(coasting.brake_lamp).is_false()


func test_merge_local_combines_keyboard_and_touch() -> void:
	# Analog axes take the stronger request; steer sums (clamped); bits OR.
	var kbd := {"accel": 0.3, "brake_reverse": 0.0, "steer": 0.5, "handbrake": 0.0,
			"horn": false, "lights_cycle": false}
	var touch := {"accel": 1.0, "brake_reverse": 0.4, "steer": 0.8, "handbrake": 1.0,
			"horn": true, "lights_cycle": false}
	var m := RouterScript.merge_local(kbd, touch)
	assert_float(m["accel"]).is_equal(1.0)
	assert_float(m["brake_reverse"]).is_equal(0.4)
	assert_float(m["steer"]).is_equal(1.0)  # 0.5 + 0.8 clamped
	assert_float(m["handbrake"]).is_equal(1.0)
	assert_bool(m["horn"]).is_true()
	assert_bool(m["lights_cycle"]).is_false()


# --- ISOBUS implement (tractor) -----------------------------------------------

func test_bridge_maps_hitch_percent_and_mirrors_pto() -> void:
	# hitch_pos arrives 0..100 (bridge_source keeps contract units); arbitrate_bridge /100.
	var vals := _bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1)
	vals["hitch_pos"] = 40.0
	vals["pto"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_float(out.hitch_request).is_equal_approx(0.4, 1e-4)
	assert_bool(out.pto).is_true()
	# Absent → raised (1.0) / off, the §6 default-off convention.
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1))
	assert_float(bare.hitch_request).is_equal(1.0)
	assert_bool(bare.pto).is_false()


func test_local_passes_hitch_and_pto_through() -> void:
	var raw := _raw()
	raw["hitch_request"] = 0.0
	raw["pto"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(raw, 0.0, GEAR_D1)
	assert_float(out.hitch_request).is_equal(0.0)
	assert_bool(out.pto).is_true()
	# Defaults when the keys are absent: raised / off.
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(), 0.0, GEAR_D1)
	assert_float(bare.hitch_request).is_equal(1.0)
	assert_bool(bare.pto).is_false()


func test_merge_local_ors_implement_toggle_edges() -> void:
	var kbd := {"hitch_toggle": true, "pto_toggle": false}
	var touch := {"hitch_toggle": false, "pto_toggle": true}
	var m := RouterScript.merge_local(kbd, touch)
	assert_bool(m["hitch_toggle"]).is_true()
	assert_bool(m["pto_toggle"]).is_true()
	# Neither pressed → both false.
	var none := RouterScript.merge_local({}, {})
	assert_bool(none["hitch_toggle"]).is_false()
	assert_bool(none["pto_toggle"]).is_false()


# --- boat rudder (contract v5) -------------------------------------------------

func test_bridge_rudder_overrides_steer_when_present() -> void:
	# sloppyCAN driving a boat sends 'rudder' (bridge_source only includes the key
	# when sent): it becomes the steer channel, whatever 'steer' says.
	var vals := _bridge(0.0, 0.0, 0.9, 0.0, GEAR_D1)
	vals["rudder"] = -0.6
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_float(out.steer).is_equal_approx(-0.6, 1e-6)
	# Clamped like steer.
	vals["rudder"] = -1.7
	assert_float(RouterScript.arbitrate_bridge(vals).steer).is_equal(-1.0)


func test_bridge_steer_unchanged_without_rudder() -> void:
	# Cars/trucks never send 'rudder' — steer passes through exactly as before.
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 0.0, 0.9, 0.0, GEAR_D1))
	assert_float(out.steer).is_equal_approx(0.9, 1e-6)


# --- flight controls (plane elevator + flaps / drone climb + arm) -------------

func test_local_flight_axes_pass_through_clamped() -> void:
	var raw := _raw()
	raw["elevator"] = 0.7
	raw["climb"] = -1.4  # out of range on purpose
	raw["arm"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(raw, 0.0, GEAR_D1)
	assert_float(out.elevator).is_equal_approx(0.7, 1e-6)
	assert_float(out.climb).is_equal(-1.0)  # clamped
	assert_bool(out.arm).is_true()
	# Defaults when absent: neutral axes, disarmed.
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(), 0.0, GEAR_D1)
	assert_float(bare.elevator).is_equal(0.0)
	assert_float(bare.climb).is_equal(0.0)
	assert_bool(bare.arm).is_false()


func test_bridge_normalizes_flight_axes_and_mirrors_arm() -> void:
	var vals := _bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1)
	vals["elevator"] = 0.5   # already %→unit normalized by bridge_source
	vals["climb"] = 1.6      # out of range on purpose
	vals["arm"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_float(out.elevator).is_equal_approx(0.5, 1e-6)
	assert_float(out.climb).is_equal(1.0)  # clamped
	assert_bool(out.arm).is_true()
	# Absent → neutral / disarmed (arm is authoritative from the bridge, no local toggle).
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1))
	assert_float(bare.elevator).is_equal(0.0)
	assert_float(bare.climb).is_equal(0.0)
	assert_bool(bare.arm).is_false()


func test_merge_local_combines_flight_axes_and_arm_edge() -> void:
	var kbd := {"elevator": 0.5, "climb": 0.0, "arm_toggle": false}
	var touch := {"elevator": 0.8, "climb": -0.3, "arm_toggle": true}
	var m := RouterScript.merge_local(kbd, touch)
	assert_float(m["elevator"]).is_equal(1.0)  # 0.5 + 0.8 clamped
	assert_float(m["climb"]).is_equal_approx(-0.3, 1e-6)
	assert_bool(m["arm_toggle"]).is_true()
	# Neither pressed → axes 0, edge false.
	var none := RouterScript.merge_local({}, {})
	assert_float(none["elevator"]).is_equal(0.0)
	assert_bool(none["arm_toggle"]).is_false()


func test_local_flaps_pass_through_clamped() -> void:
	# InputRouter owns the local _flaps_down toggle and injects "flaps" as 0/1; the
	# arbitration just clamps and passes it through (the hitch_request pattern).
	var raw := _raw()
	raw["flaps"] = 1.0
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(raw, 0.0, GEAR_D1)
	assert_float(out.flaps).is_equal(1.0)
	raw["flaps"] = 3.0  # out of range on purpose
	out = RouterScript.arbitrate_local(raw, 0.0, GEAR_D1)
	assert_float(out.flaps).is_equal(1.0)  # clamped
	# Absent → retracted.
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(), 0.0, GEAR_D1)
	assert_float(bare.flaps).is_equal(0.0)


func test_bridge_flaps_mirrored_clamped() -> void:
	# Already %→unit normalized by bridge_source; the bridge value is authoritative
	# (no local toggle on that path), absent → retracted.
	var vals := _bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1)
	vals["flaps"] = 0.4
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_float(out.flaps).is_equal_approx(0.4, 1e-6)
	vals["flaps"] = 1.7  # out of range on purpose
	out = RouterScript.arbitrate_bridge(vals)
	assert_float(out.flaps).is_equal(1.0)  # clamped
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(_bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1))
	assert_float(bare.flaps).is_equal(0.0)


func test_merge_local_combines_flaps_edge() -> void:
	var m := RouterScript.merge_local({"flaps_toggle": false}, {"flaps_toggle": true})
	assert_bool(m["flaps_toggle"]).is_true()
	assert_bool(RouterScript.merge_local({}, {})["flaps_toggle"]).is_false()


func test_bridge_mirrors_lamp_bits_verbatim() -> void:
	var vals := _bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1)
	vals["turnL"] = true
	vals["brakeLamp"] = true
	vals["checkEngine"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_bool(out.turn_left).is_true()
	assert_bool(out.turn_right).is_false()   # absent bit stays off
	assert_bool(out.brake_lamp).is_true()
	assert_bool(out.check_engine).is_true()
	assert_bool(out.battery_warn).is_false() # warning LED defaults off when not sent


# --- train controls (pantograph + doors) --------------------------------------

func test_local_train_toggles_pass_through() -> void:
	# InputRouter owns the local _pantograph / _doors toggles and injects them as bools;
	# the arbitration just passes them through (the pto pattern).
	var raw := _raw()
	raw["pantograph"] = true
	raw["doors"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_local(raw, 0.0, GEAR_D1)
	assert_bool(out.pantograph).is_true()
	assert_bool(out.doors).is_true()
	# Absent → lowered / shut.
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_local(_raw(), 0.0, GEAR_D1)
	assert_bool(bare.pantograph).is_false()
	assert_bool(bare.doors).is_false()


func test_bridge_mirrors_train_bits_verbatim() -> void:
	var vals := _bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1)
	vals["pantograph"] = true
	var out: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(vals)
	assert_bool(out.pantograph).is_true()
	assert_bool(out.doors).is_false()  # absent bit stays off
	var bare: RouterScript.VehicleInput = RouterScript.arbitrate_bridge(
			_bridge(0.0, 0.0, 0.0, 0.0, GEAR_D1))
	assert_bool(bare.pantograph).is_false()
	assert_bool(bare.doors).is_false()


func test_merge_local_ors_train_toggle_edges() -> void:
	var m := RouterScript.merge_local(
			{"pantograph_toggle": true, "doors_toggle": false},
			{"pantograph_toggle": false, "doors_toggle": true})
	assert_bool(m["pantograph_toggle"]).is_true()
	assert_bool(m["doors_toggle"]).is_true()
	var none := RouterScript.merge_local({}, {})
	assert_bool(none["pantograph_toggle"]).is_false()
	assert_bool(none["doors_toggle"]).is_false()


func test_vehicle_input_copy_carries_train_fields() -> void:
	var vi := RouterScript.VehicleInput.new()
	vi.pantograph = true
	vi.doors = true
	var c: RouterScript.VehicleInput = vi.copy()
	assert_bool(c.pantograph).is_true()
	assert_bool(c.doors).is_true()
