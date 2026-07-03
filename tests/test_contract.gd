extends GdUnitTestSuite
## Contract loader tests (plan §5.2 "contract loading/validation").
## Exercises the pure-logic ContractData parser directly — no autoload lifecycle needed.

const ContractScript := preload("res://src/bridge/contract.gd")

## Every v1 bridge signal, from plan §6 / the v1 reference spec. The contract must
## cover all of them (M0 requirement: "every v1 signal plus rpm as a real signal").
const V1_IN_SIGNALS: PackedStringArray = [
	"accel", "brake", "steer", "handbrake", "key", "lights", "gear",
	"turnL", "turnR", "horn", "checkEngine", "battery", "brakeLamp",
]
const V1_OUT_SIGNALS: PackedStringArray = [
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


func test_real_contract_is_valid_v2() -> void:
	var data := _real_contract()
	assert_array(data.errors).is_empty()
	assert_int(data.version).is_equal(2)


func _assert_v1_signals_present(names: PackedStringArray, dir: String) -> void:
	var data := _real_contract()
	for name in names:
		assert_bool(data.has_signal_def(name, dir)) \
			.override_failure_message("missing v1 '%s' signal: %s" % [dir, name]).is_true()
		assert_bool(data.is_todo(name, dir)) \
			.override_failure_message("v1 '%s' signal must not be todo: %s" % [dir, name]).is_false()


func test_every_v1_in_signal_present() -> void:
	_assert_v1_signals_present(V1_IN_SIGNALS, "in")


func test_every_v1_out_signal_present() -> void:
	_assert_v1_signals_present(V1_OUT_SIGNALS, "out")


func test_rpm_is_a_real_out_signal() -> void:
	var rpm := _real_contract().get_signal_def("rpm", "out")
	assert_object(rpm).is_not_null()
	assert_str(rpm.type).is_equal("u16")
	assert_array(rpm.range).is_equal([0.0, 8000.0])


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


func test_todo_entries_load_and_report_todo() -> void:
	var data := _real_contract()
	assert_bool(data.is_todo("hitch_pos", "in")).is_true()
	assert_bool(data.is_todo("pitch", "out")).is_true()
	var hitch := data.get_signal_def("hitch_pos", "in")
	assert_str(hitch.flavor).is_equal("isobus")


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
