extends GdUnitTestSuite
## §6 lamp decision logic + the procedural horn stream. The scene-touching parts of
## LampSet (Light3D energy, material overrides) need a tree and are not tested here;
## the pure tri-state rule and the horn synthesis are.

const LampSet := preload("res://src/vehicles/base/lamp_set.gd")
const Horn := preload("res://src/vehicles/base/horn.gd")


# --- rear tri-state (plan §6: STOP > TAIL > OFF) -----------------------------

func test_brake_bit_gives_stop_regardless_of_headlights() -> void:
	for lights in [LampSet.HL_OFF, LampSet.HL_CLEARANCE, LampSet.HL_LOW, LampSet.HL_HIGH]:
		assert_int(LampSet.rear_tier(true, lights)).is_equal(LampSet.Rear.STOP)


func test_tail_only_when_headlights_at_clearance_or_brighter() -> void:
	assert_int(LampSet.rear_tier(false, LampSet.HL_OFF)).is_equal(LampSet.Rear.OFF)
	assert_int(LampSet.rear_tier(false, LampSet.HL_CLEARANCE)).is_equal(LampSet.Rear.TAIL)
	assert_int(LampSet.rear_tier(false, LampSet.HL_LOW)).is_equal(LampSet.Rear.TAIL)
	assert_int(LampSet.rear_tier(false, LampSet.HL_HIGH)).is_equal(LampSet.Rear.TAIL)


func test_off_tier_is_never_dark() -> void:
	# OFF keeps a dim housing glow so the lens is always visible (plan §6).
	assert_float(LampSet.REAR_ENERGY[LampSet.Rear.OFF]).is_greater(0.0)


func test_headlight_levels_have_distinct_increasing_energy_and_range() -> void:
	# off/clearance/low/high with distinct energy/range (plan §6).
	assert_float(LampSet.HEAD_ENERGY[LampSet.HL_OFF]).is_equal(0.0)
	assert_float(LampSet.HEAD_ENERGY[LampSet.HL_CLEARANCE]).is_less(LampSet.HEAD_ENERGY[LampSet.HL_LOW])
	assert_float(LampSet.HEAD_ENERGY[LampSet.HL_LOW]).is_less(LampSet.HEAD_ENERGY[LampSet.HL_HIGH])
	assert_float(LampSet.HEAD_RANGE[LampSet.HL_CLEARANCE]).is_less(LampSet.HEAD_RANGE[LampSet.HL_HIGH])


# --- procedural horn ---------------------------------------------------------

func test_horn_stream_is_non_empty_and_loops() -> void:
	var wav := Horn.make_stream()
	assert_int(wav.data.size()).is_greater(0)
	assert_int(wav.loop_mode).is_equal(AudioStreamWAV.LOOP_FORWARD)
	assert_int(wav.loop_end).is_greater(0)
