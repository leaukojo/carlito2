extends GdUnitTestSuite
## Contract loader tests.
## Exercises the pure-logic ContractData parser directly — no autoload lifecycle needed.

const ContractScript := preload("res://src/bridge/contract.gd")

## Every core bridge signal (the original parity set). The contract must
## cover all of them.
const CORE_IN_SIGNALS: PackedStringArray = [
	"accel", "brake", "steer", "handbrake", "key", "lights", "gear",
	"turnL", "turnR", "horn", "checkEngine", "battery", "brakeLamp",
]
const CORE_OUT_SIGNALS: PackedStringArray = [
	"speed", "kmh", "rpm", "gear", "throttle", "yaw", "accLong", "accLat",
	"steer", "slip", "ground", "posX", "posZ", "heading", "lat", "lon",
	"odo", "status", "impact", "fuel", "coolant", "battery",
]


func _parse_file(path: String) -> ContractScript.ContractData:
	var file := FileAccess.open(path, FileAccess.READ)
	assert_object(file).is_not_null()
	return ContractScript.ContractData.parse(file.get_as_text())


func _real_contract() -> ContractScript.ContractData:
	return _parse_file(ContractScript.CONTRACT_PATH)


func test_real_contract_is_valid_v9() -> void:
	var data := _real_contract()
	assert_array(data.errors).is_empty()
	assert_int(data.version).is_equal(9)


func _assert_core_signals_present(names: PackedStringArray, dir: String) -> void:
	var data := _real_contract()
	for sig_name in names:
		assert_bool(data.has_signal_def(sig_name, dir)) \
			.override_failure_message("missing core '%s' signal: %s" % [dir, sig_name]).is_true()
		assert_bool(data.is_todo(sig_name, dir)) \
			.override_failure_message("core '%s' signal must not be todo: %s" % [dir, sig_name]).is_false()


func test_every_v1_in_signal_present() -> void:
	_assert_core_signals_present(CORE_IN_SIGNALS, "in")


func test_every_v1_out_signal_present() -> void:
	_assert_core_signals_present(CORE_OUT_SIGNALS, "out")


func test_rpm_is_a_real_out_signal() -> void:
	var rpm := _real_contract().get_signal_def("rpm", "out")
	assert_object(rpm).is_not_null()
	assert_str(rpm.type).is_equal("u16")
	assert_array(rpm.range).is_equal([0.0, 8000.0])


func test_warn_thresholds_parse_and_classify() -> void:
	var data := _real_contract()
	# rpm redline: high-side warn near the top of [0, 8000].
	var rpm := data.get_signal_def("rpm", "out")
	assert_bool(rpm.has_warn()).is_true()
	assert_float(rpm.warn).is_equal_approx(6800.0, 0.001)
	assert_bool(rpm.warn_is_low()).is_false()
	# fuel: low-side warn near the bottom of [0, 100].
	var fuel := data.get_signal_def("fuel", "out")
	assert_bool(fuel.has_warn()).is_true()
	assert_bool(fuel.warn_is_low()).is_true()
	# coolant: high-side overheat warn.
	assert_bool(data.get_signal_def("coolant", "out").warn_is_low()).is_false()
	# a signal without 'warn' reports none.
	assert_bool(data.get_signal_def("kmh", "out").has_warn()).is_false()


func test_fixture_bad_warn_fails() -> void:
	var data := _parse_file("res://tests/fixtures/bad_warn.json")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("'warn'")


func test_gear_enum_decodes_ramn_byte_semantics() -> void:
	var gear := _real_contract().get_signal_def("gear", "in")
	assert_object(gear).is_not_null()
	assert_str(gear.enum_label(0)).is_equal("N")
	assert_str(gear.enum_label(1)).is_equal("D1")
	assert_str(gear.enum_label(3)).is_equal("D3")
	assert_str(gear.enum_label(6)).is_equal("D6")
	assert_str(gear.enum_label(255)).is_equal("R")
	assert_str(gear.enum_label(7)).is_equal("")


func test_lights_and_key_enums_decode() -> void:
	var data := _real_contract()
	var lights := data.get_signal_def("lights", "in")
	assert_str(lights.enum_label(1)).is_equal("OFF")
	assert_str(lights.enum_label(4)).is_equal("HIGH")
	var key := data.get_signal_def("key", "in")
	assert_str(key.enum_label(3)).is_equal("Ignition")


func test_battery_resolves_distinctly_per_dir() -> void:
	var data := _real_contract()
	var led := data.get_signal_def("battery", "in")
	var volts := data.get_signal_def("battery", "out")
	assert_object(led).is_not_null()
	assert_object(volts).is_not_null()
	assert_str(led.type).is_equal("bool")
	assert_str(volts.type).is_equal("f32")


func test_contract_is_fully_implemented() -> void:
	var data := _real_contract()
	# Tractor ISOBUS signals: implemented (not todo), flavored isobus.
	assert_bool(data.is_todo("hitch_pos", "in")).is_false()
	var hitch := data.get_signal_def("hitch_pos", "in")
	assert_str(hitch.flavor).is_equal("isobus")
	# Boat signals: implemented — as of v5 NO signal is todo anymore.
	assert_bool(data.is_todo("pitch", "out")).is_false()
	for sig in data.signals:
		assert_bool(sig.todo) \
			.override_failure_message("signal still marked todo: %s/%s" % [sig.dir, sig.name]) \
			.is_false()


func test_flying_signals_present_and_flavored() -> void:
	var data := _real_contract()
	# New flavored in signals.
	var elevator := data.get_signal_def("elevator", "in")
	assert_object(elevator).is_not_null()
	assert_str(elevator.flavor).is_equal("canaerospace")
	assert_str(elevator.type).is_equal("i8")
	assert_str(data.get_signal_def("flaps", "in").flavor).is_equal("canaerospace")
	assert_str(data.get_signal_def("climb", "in").flavor).is_equal("dronecan")
	var arm := data.get_signal_def("arm", "in")
	assert_object(arm).is_not_null()
	assert_str(arm.flavor).is_equal("dronecan")
	assert_str(arm.type).is_equal("bool")
	# New out signals: altitude/vspeed are cross-family instruments (bars via range).
	var altitude := data.get_signal_def("altitude", "out")
	assert_array(altitude.range).is_equal([0.0, 500.0])
	assert_array(data.get_signal_def("vspeed", "out").range).is_equal([-20.0, 20.0])
	assert_str(data.get_signal_def("rotor_rpm", "out").flavor).is_equal("dronecan")
	assert_str(data.get_signal_def("armed", "out").type).is_equal("bool")


func test_plane_and_drone_wired_into_shared_signals() -> void:
	var data := _real_contract()
	# Plane: engine + wheels — joins rpm/gear/fuel/coolant/ground plus the shared set.
	var plane_out := data.signals_for_vehicle("plane", "out").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(plane_out).contains(["kmh", "rpm", "gear", "ground", "fuel", "altitude", "vspeed", "pitch", "roll"])
	var plane_in := data.signals_for_vehicle("plane", "in").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(plane_in).contains(["accel", "brake", "elevator", "flaps", "gear"])
	assert_array(plane_in).not_contains(["climb", "arm", "rudder"])
	# Drone: battery-electric — no rpm/gear/fuel/coolant/ground, but altitude/vspeed/climb/arm.
	var drone_out := data.signals_for_vehicle("drone", "out").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(drone_out).contains(["kmh", "altitude", "vspeed", "rotor_rpm", "armed", "pitch", "roll"])
	assert_array(drone_out).not_contains(["rpm", "gear", "ground", "fuel", "coolant"])
	var drone_in := data.signals_for_vehicle("drone", "in").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(drone_in).contains(["accel", "brake", "steer", "climb", "arm"])
	assert_array(drone_in).not_contains(["elevator", "flaps", "gear", "handbrake"])


func test_signals_for_vehicle_filters() -> void:
	var data := _real_contract()
	var boat_in := data.signals_for_vehicle("boat", "in")
	var names := boat_in.map(func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(names).contains(["accel", "steer", "horn"])
	assert_array(names).not_contains(["gear", "brakeLamp"])


func test_fixture_duplicate_signal_fails() -> void:
	var data := _parse_file("res://tests/fixtures/dup_signal.json")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("duplicate")


func test_fixture_unknown_type_fails() -> void:
	var data := _parse_file("res://tests/fixtures/unknown_type.json")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("'type'")


func test_fixture_bad_range_fails() -> void:
	var data := _parse_file("res://tests/fixtures/bad_range.json")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("'range'")


func test_fixture_bad_version_fails() -> void:
	var data := _parse_file("res://tests/fixtures/bad_version.json")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("'version'")


func test_not_json_fails() -> void:
	var data := ContractScript.ContractData.parse("this is not json {")
	assert_bool(data.is_valid()).is_false()
	assert_str("\n".join(data.errors)).contains("invalid JSON")


# --- train family (flavor "train": rail practice, not a real train CAN standard) ---

func test_train_wired_into_shared_signals_and_flavored_rail_signals() -> void:
	var data := _real_contract()
	assert_bool(data.is_valid()).is_true()
	var train_in := data.signals_for_vehicle("train", "in").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(train_in).contains(["accel", "brake", "key", "gear", "handbrake",
			"pantograph", "doors"])
	# Rail-guided: no steering; no rear-lamp / turn-signal equivalent.
	assert_array(train_in).not_contains(["steer", "turnL", "turnR", "brakeLamp"])

	var train_out := data.signals_for_vehicle("train", "out").map(
			func(s: ContractScript.SignalDef) -> String: return s.name)
	assert_array(train_out).contains(["kmh", "speed", "gear", "odo", "status",
			"pantograph_state", "doors_state", "catenary_volts", "motor_current",
			"brake_pipe", "grade", "coupler_force"])
	# Electric traction: no engine RPM, fuel or coolant; no wheel slip/ground.
	assert_array(train_out).not_contains(["rpm", "fuel", "coolant", "slip", "ground", "steer"])

	assert_str(data.get_signal_def("pantograph", "in").flavor).is_equal("train")
	assert_str(data.get_signal_def("coupler_force", "out").flavor).is_equal("train")
	# catenary_volts / brake_pipe warn on the LOW side; motor_current on the high side.
	assert_bool(data.get_signal_def("catenary_volts", "out").warn_is_low()).is_true()
	assert_bool(data.get_signal_def("brake_pipe", "out").warn_is_low()).is_true()
	assert_bool(data.get_signal_def("motor_current", "out").warn_is_low()).is_false()
