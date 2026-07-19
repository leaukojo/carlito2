extends GdUnitTestSuite
## VehicleCatalog pure helpers + a §6 force-hierarchy guard over every generated Kenney
## spec (brake > peak drive per wheel > handbrake, handbrake capped low). The generator
## derives brake/handbrake from the drivetrain, so a regression here means the derivation
## broke — fix the generator's numbers, never this test (same rule as test_drivetrain).

const DrivetrainScript := preload("res://src/vehicles/base/drivetrain.gd")
const VehicleSpecScript := preload("res://src/vehicles/base/vehicle_spec.gd")


# --- catalog structure --------------------------------------------------------

func test_family_of_and_scene_of() -> void:
	assert_str(VehicleCatalog.family_of("sedan")).is_equal("car")
	assert_str(VehicleCatalog.family_of("firetruck")).is_equal("truck")
	assert_str(VehicleCatalog.family_of("tractor-shovel")).is_equal("tractor")
	assert_str(VehicleCatalog.family_of("boat")).is_equal("boat")
	assert_str(VehicleCatalog.family_of("nope")).is_equal("")
	assert_str(VehicleCatalog.scene_of("sedan")).is_equal("res://src/vehicles/kenney/sedan.tscn")
	assert_str(VehicleCatalog.scene_of("nope")).is_equal("")


func test_legacy_variant_is_first_in_its_family() -> void:
	# The garage spawns first_in_family; it must be the hand-built legacy body.
	assert_str(VehicleCatalog.first_in_family("car")).is_equal("car")
	assert_str(VehicleCatalog.first_in_family("truck")).is_equal("truck")
	assert_str(VehicleCatalog.first_in_family("tractor")).is_equal("tractor")
	assert_str(VehicleCatalog.first_in_family("boat")).is_equal("boat")


func test_variants_in_family_grouping() -> void:
	var car := VehicleCatalog.variants_in_family("car")
	assert_int(car.size()).is_equal(13)   # legacy car + 12 Kenney
	assert_bool(car.has("sedan")).is_true()
	assert_bool(car.has("firetruck")).is_false()
	assert_int(VehicleCatalog.variants_in_family("truck").size()).is_equal(6)
	assert_int(VehicleCatalog.variants_in_family("tractor").size()).is_equal(4)
	assert_int(VehicleCatalog.variants_in_family("boat").size()).is_equal(1)


func test_next_in_family_wraps() -> void:
	var car := VehicleCatalog.variants_in_family("car")
	# cycling from the last variant returns to the first (the legacy body).
	assert_str(VehicleCatalog.next_in_family(car[car.size() - 1])).is_equal(car[0])
	assert_str(VehicleCatalog.next_in_family("car")).is_equal(car[1])
	# a lone family is a no-op; unknown is returned unchanged.
	assert_str(VehicleCatalog.next_in_family("boat")).is_equal("boat")
	assert_str(VehicleCatalog.next_in_family("nope")).is_equal("nope")


func test_every_variant_scene_exists() -> void:
	for variant in VehicleCatalog.VARIANTS:
		assert_bool(ResourceLoader.exists(VehicleCatalog.scene_of(variant))) \
				.override_failure_message("missing scene for variant '%s'" % variant).is_true()


# --- §6 force hierarchy over every generated Kenney spec ----------------------

func test_kenney_specs_keep_force_hierarchy() -> void:
	for variant in VehicleCatalog.VARIANTS:
		var scene := VehicleCatalog.scene_of(variant)
		if not scene.begins_with("res://src/vehicles/kenney/"):
			continue  # hand-built legacy specs are covered elsewhere
		var spec_path := scene.trim_suffix(".tscn") + "_spec.tres"
		var spec: VehicleSpecScript = load(spec_path)
		assert_object(spec).override_failure_message("no spec for " + variant).is_not_null()

		var peak_engine := 0.0
		for p in spec.torque_curve:
			peak_engine = maxf(peak_engine, p.y)
		var max_drive: float = peak_engine * spec.gear_ratios[0] * spec.final_drive * spec.efficiency
		var total_brake: float = spec.brake_torque * spec.wheel_positions.size()
		var total_handbrake: float = spec.handbrake_torque * 2.0
		# brake beats peak drive torque so full accel + full brake stops.
		assert_float(total_brake).override_failure_message(
				"%s: brake %.0f <= drive %.0f" % [variant, total_brake, max_drive]).is_greater(max_drive)
		# handbrake holds only below ~25% throttle: between the 25% and 50% launch brackets.
		var drive_25: float = absf(DrivetrainScript.wheel_torque(spec, spec.idle_rpm, 0.25, 1))
		var drive_50: float = absf(DrivetrainScript.wheel_torque(spec, spec.idle_rpm, 0.5, 1))
		assert_float(total_handbrake).override_failure_message(
				"%s: handbrake %.0f <= drive_25 %.0f" % [variant, total_handbrake, drive_25]).is_greater(drive_25)
		assert_float(total_handbrake).override_failure_message(
				"%s: handbrake %.0f >= drive_50 %.0f" % [variant, total_handbrake, drive_50]).is_less(drive_50)
