extends GdUnitTestSuite
## BrushOps pure fns: the radial weight curve, the four sculpt ops,
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
	BrushOps.stamp_splat(img, 4, 4, 2.0, 2.0, BrushOps.unit_slice(0, 0), 1.0, 0.0)  # grass (R)
	var c := img.get_pixel(4, 4)
	assert_float(c.r).is_equal_approx(1.0, 0.0001)
	assert_float(c.g).is_equal_approx(0.0, 0.0001)
	assert_float(c.b).is_equal_approx(0.0, 0.0001)
	# Outside the radius the weights are untouched.
	assert_float(img.get_pixel(0, 0).r).is_equal_approx(0.25, 0.0001)


# --- 8 channels across two splat images ---


## Weights of channel 0..7 at a pixel, read out of the two images as one 8-vector.
func _weights(img: Image, img2: Image, x: int, y: int) -> PackedFloat32Array:
	var a := img.get_pixel(x, y)
	var b := img2.get_pixel(x, y)
	return PackedFloat32Array([a.r, a.g, a.b, a.a, b.r, b.g, b.b, b.a])


func _total(w: PackedFloat32Array) -> float:
	var sum := 0.0
	for v in w:
		sum += v
	return sum


func test_unit_slice_places_channel_in_its_own_image() -> void:
	# Channel 1 (dirt) lives in image 0; image 1 sees an all-zero slice, so stamping it
	# fades channels 4..7 instead of raising one.
	assert_float(BrushOps.unit_slice(1, 0).g).is_equal(1.0)
	assert_bool(BrushOps.unit_slice(1, 1) == Color(0, 0, 0, 0)).is_true()
	# Channel 5 (mud) is image 1's G.
	assert_float(BrushOps.unit_slice(5, 1).g).is_equal(1.0)
	assert_float(BrushOps.unit_slice(5, 0).a).is_equal(0.0)


## One paint sample as the brush does it: the same kernel stamped into both weight images
## with that image's slice of the unit vector. Returns both dirty rects.
func _paint(img: Image, img2: Image, channel: int, strength: float) -> Array[Rect2i]:
	var rects: Array[Rect2i] = []
	rects.append(BrushOps.stamp_splat(img, 4, 4, 2.0, 2.0, BrushOps.unit_slice(channel, 0),
			strength, 0.0))
	rects.append(BrushOps.stamp_splat(img2, 4, 4, 2.0, 2.0, BrushOps.unit_slice(channel, 1),
			strength, 0.0))
	return rects


func _rgbaf(n: int, fill: Color) -> Image:
	var img := Image.create(n, n, false, Image.FORMAT_RGBAF)
	img.fill(fill)
	return img


func test_paint_high_channel_becomes_dominant_and_total_stays_normalized() -> void:
	var img := _rgbaf(9, Color(0.25, 0.25, 0.25, 0.25))
	var img2 := _rgbaf(9, Color(0, 0, 0, 0))
	_paint(img, img2, 5, 1.0)  # channel 5 = image 1's G, at full strength
	var w := _weights(img, img2, 4, 4)
	assert_float(w[5]).is_equal_approx(1.0, 0.0001)
	assert_float(_total(w)).is_equal_approx(1.0, 0.0001)  # the base four faded to zero
	# Untouched pixels keep the original 4-channel weights and no extra weight.
	var far := _weights(img, img2, 0, 0)
	assert_float(far[0]).is_equal_approx(0.25, 0.0001)
	assert_float(far[5]).is_equal(0.0)


func test_paint_base_channel_fades_a_high_channel() -> void:
	var img := _rgbaf(9, Color(0, 0, 0, 0))
	var img2 := _rgbaf(9, Color(0, 1.0, 0, 0))  # everything is channel 5
	_paint(img, img2, 0, 0.5)  # half a stroke of grass
	var w := _weights(img, img2, 4, 4)
	assert_float(w[0]).is_equal_approx(0.5, 0.0001)
	assert_float(w[5]).is_equal_approx(0.5, 0.0001)  # faded, not left at full
	assert_float(_total(w)).is_equal_approx(1.0, 0.0001)


func test_paint_with_zero_splat2_matches_four_channel_behavior() -> void:
	# A terrain that has never seen a high channel: painting a base channel must leave the
	# splatmap exactly as the old 4-channel stamp did, and splat2 all-zero.
	var img := _rgbaf(9, Color(0.25, 0.25, 0.25, 0.25))
	var img2 := _rgbaf(9, Color(0, 0, 0, 0))
	_paint(img, img2, 2, 1.0)  # channel 2 = sand (B)
	var c := img.get_pixel(4, 4)
	assert_float(c.b).is_equal_approx(1.0, 0.0001)
	assert_float(c.r).is_equal_approx(0.0, 0.0001)
	var c2 := img2.get_pixel(4, 4)
	assert_float(c2.g).is_equal(0.0)
	assert_float(c2.a).is_equal(0.0)


func test_both_splat_stamps_report_the_same_dirty_rect() -> void:
	# The brush unions ONE dirty rect for both images' undo regions — same kernel, so the
	# two stamps must always agree.
	var img := _rgbaf(9, Color(0.25, 0.25, 0.25, 0.25))
	var img2 := _rgbaf(9, Color(0, 0, 0, 0))
	var rects := _paint(img, img2, 6, 0.75)
	assert_bool(rects[0] == rects[1]).is_true()
	assert_bool(rects[0].size == Vector2i.ZERO).is_false()
