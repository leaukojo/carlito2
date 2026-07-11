extends GdUnitTestSuite
## BrushOps pure fns (level_kit_plan.md LK4): the radial weight curve, the four sculpt ops,
## and the height/splat image stamps. Editor-free Image arithmetic, so it gets the same test
## discipline as TerrainGen — hand-checkable numbers throughout. Float image formats (RF /
## RGBAF) keep expected values exact (RGB8 would quantize).

const BrushOps := preload("res://kit/helpers/brush_ops.gd")


# --- weight curve ---


func test_weight_endpoints() -> void:
	assert_float(BrushOps.weight(0.0, 0.5)).is_equal(1.0)
	assert_float(BrushOps.weight(1.0, 0.5)).is_equal(0.0)
	assert_float(BrushOps.weight(1.5, 0.5)).is_equal(0.0)


func test_weight_hard_edge_is_solid_disk() -> void:
	# falloff 0 -> inner radius 1 -> full weight everywhere inside the rim.
	assert_float(BrushOps.weight(0.5, 0.0)).is_equal(1.0)
	assert_float(BrushOps.weight(0.99, 0.0)).is_equal(1.0)


func test_weight_full_falloff_is_dome() -> void:
	# falloff 1 -> inner radius 0 -> smoothstep down; midpoint = 1 - smoothstep(0.5) = 0.5.
	assert_float(BrushOps.weight(0.5, 1.0)).is_equal_approx(0.5, 0.001)


# --- sculpt ops ---


func test_sculpt_raise_and_lower() -> void:
	assert_float(BrushOps.sculpt_value(BrushOps.RAISE, 0.5, 0.0, 0.0, 1.0)) \
			.is_equal_approx(0.5 + BrushOps.RATE, 0.0001)
	assert_float(BrushOps.sculpt_value(BrushOps.LOWER, 0.5, 0.0, 0.0, 1.0)) \
			.is_equal_approx(0.5 - BrushOps.RATE, 0.0001)


func test_sculpt_clamps_to_unit_range() -> void:
	assert_float(BrushOps.sculpt_value(BrushOps.RAISE, 0.99, 0.0, 0.0, 1.0)).is_equal(1.0)
	assert_float(BrushOps.sculpt_value(BrushOps.LOWER, 0.01, 0.0, 0.0, 1.0)).is_equal(0.0)


func test_sculpt_smooth_moves_toward_average() -> void:
	# amount 0.5 -> halfway to the neighbourhood average.
	assert_float(BrushOps.sculpt_value(BrushOps.SMOOTH, 0.2, 0.6, 0.0, 0.5)) \
			.is_equal_approx(0.4, 0.0001)


func test_sculpt_flatten_moves_toward_target() -> void:
	assert_float(BrushOps.sculpt_value(BrushOps.FLATTEN, 0.2, 0.0, 0.8, 0.5)) \
			.is_equal_approx(0.5, 0.0001)


# --- height stamp ---


func _flat_rf(n: int, value: float) -> Image:
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	img.fill(Color(value, 0, 0))
	return img


func test_stamp_height_raises_center_only_inside_radius() -> void:
	var img := _flat_rf(9, 0.5)
	var dirty := BrushOps.stamp_height(img, 4, 4, 2.0, 2.0, BrushOps.RAISE, 1.0, 0.0, 0.0)
	# Centre is inside the solid disk (falloff 0) -> full raise.
	assert_float(img.get_pixel(4, 4).r).is_equal_approx(0.55, 0.0001)
	# A corner is ~2.8 radii out -> untouched.
	assert_float(img.get_pixel(0, 0).r).is_equal(0.5)
	# Dirty rect is non-empty and stays within the image.
	assert_bool(dirty.size == Vector2i.ZERO).is_false()
	assert_bool(Rect2i(0, 0, 9, 9).encloses(dirty)).is_true()


func test_stamp_height_flatten_pulls_toward_target() -> void:
	var img := _flat_rf(7, 0.2)
	BrushOps.stamp_height(img, 3, 3, 2.0, 2.0, BrushOps.FLATTEN, 1.0, 0.0, 0.8)
	assert_float(img.get_pixel(3, 3).r).is_equal_approx(0.8, 0.0001)  # amount 1 -> reaches target


func test_stamp_height_empty_when_out_of_bounds() -> void:
	var img := _flat_rf(5, 0.5)
	# Centre far off the image, radius too small to reach any pixel -> no edit.
	var dirty := BrushOps.stamp_height(img, 50, 50, 1.0, 1.0, BrushOps.RAISE, 1.0, 0.0, 0.0)
	assert_bool(dirty.size == Vector2i.ZERO).is_true()
	assert_float(img.get_pixel(4, 4).r).is_equal(0.5)


# --- splat stamp ---


func test_stamp_splat_paints_channel_toward_pure() -> void:
	var img := Image.create(9, 9, false, Image.FORMAT_RGBAF)
	img.fill(Color(0.25, 0.25, 0.25, 0.25))
	BrushOps.stamp_splat(img, 4, 4, 2.0, 2.0, 0, 1.0, 0.0)  # channel 0 = grass (R)
	var c := img.get_pixel(4, 4)
	assert_float(c.r).is_equal_approx(1.0, 0.0001)
	assert_float(c.g).is_equal_approx(0.0, 0.0001)
	assert_float(c.b).is_equal_approx(0.0, 0.0001)
	# Outside the radius the weights are untouched.
	assert_float(img.get_pixel(0, 0).r).is_equal_approx(0.25, 0.0001)
