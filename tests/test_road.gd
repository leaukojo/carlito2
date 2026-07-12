extends GdUnitTestSuite
## RoadBuilder / RoadProfile pure fns + the baker's road integration (level_kit_plan.md
## §4 LK7): curvature-adaptive sampling, ribbon extrusion (winding must stay up-facing
## for BOTH curve directions — a flipped ribbon is drive-through), banking from tilt,
## the conform flatten mask (floor-quantized so the 8-bit PNG never sits above the
## road), and split_arrays_by_chunk. Hand-checkable numbers throughout, same discipline
## as Drivetrain. Curve3D and Image are headless-constructible, so everything runs in CI.

const Builder := preload("res://kit/helpers/road_builder.gd")
const Profile := preload("res://kit/helpers/road_profile.gd")
const Baker := preload("res://kit/bake/level_baker.gd")
const RoadPathScript := preload("res://kit/helpers/road_path.gd")


func _straight(a: Vector3, b: Vector3) -> Curve3D:
	var c := Curve3D.new()
	c.add_point(a)
	c.add_point(b)
	return c


## Quarter arc of radius 20 in the XZ plane (bezier circle approximation, handle
## length r * 0.5523).
func _quarter_arc() -> Curve3D:
	var c := Curve3D.new()
	var h := 20.0 * 0.5523
	c.add_point(Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, h))
	c.add_point(Vector3(20, 0, 20), Vector3(-h, 0, 0), Vector3.ZERO)
	return c


# --------------------------------------------------------------- adaptive sampling


func test_adaptive_straight_is_uniform_coarse() -> void:
	var offsets := Builder.adaptive_offsets(_straight(Vector3.ZERO, Vector3(0, 0, 100)), 6.0, 6.0)
	# ceil(100/6) = 17 segments -> 18 offsets, no curvature subdivision
	assert_int(offsets.size()).is_equal(18)
	assert_float(offsets[0]).is_equal(0.0)
	assert_float(offsets[17]).is_equal_approx(100.0, 0.01)
	var step := offsets[1] - offsets[0]
	for i in range(1, offsets.size()):
		assert_bool(offsets[i] > offsets[i - 1]).is_true()
		assert_float(offsets[i] - offsets[i - 1]).is_equal_approx(step, 0.001)


func test_adaptive_arc_subdivides_and_bounds_angle() -> void:
	var arc := _quarter_arc()
	var arc_offsets := Builder.adaptive_offsets(arc, 6.0, 6.0)
	var length := arc.get_baked_length()
	var straight_offsets := Builder.adaptive_offsets(
			_straight(Vector3.ZERO, Vector3(0, 0, length)), 6.0, 6.0)
	assert_bool(arc_offsets.size() > straight_offsets.size()).is_true()
	# every final segment's end tangents agree within the budget (or hit the MIN_SEG floor)
	for i in range(1, arc_offsets.size()):
		var a := arc_offsets[i - 1]
		var b := arc_offsets[i]
		var angle := Builder.tangent_at(arc, a, length).angle_to(
				Builder.tangent_at(arc, b, length))
		assert_bool(angle <= deg_to_rad(6.0) + 0.02 or b - a <= Builder.MIN_SEG + 0.001).is_true()


func test_adaptive_is_deterministic() -> void:
	var arc := _quarter_arc()
	assert_that(Builder.adaptive_offsets(arc, 6.0, 6.0)) \
			.is_equal(Builder.adaptive_offsets(arc, 6.0, 6.0))


## Zero-handle corner: an offset must land exactly on the interior control point (the
## miter ring — its central-difference tangent is the corner's angle bisector), and
## the list stays strictly increasing.
func test_adaptive_offsets_anchor_interior_control_points() -> void:
	var c := Curve3D.new()
	c.add_point(Vector3.ZERO)
	c.add_point(Vector3(20, 0, 0))
	c.add_point(Vector3(20, 0, 20))
	var length := c.get_baked_length()
	var corner := c.get_closest_offset(Vector3(20, 0, 0))
	var offsets := Builder.adaptive_offsets(c, 6.0, 6.0)
	var best := INF
	for i in range(1, offsets.size()):
		assert_bool(offsets[i] > offsets[i - 1]).is_true()
		best = minf(best, absf(offsets[i] - corner))
	assert_float(best).is_equal_approx(0.0, 0.01)
	# the ring AT the corner frames along the bisector of the two segment directions
	var t := Builder.tangent_at(c, corner, length)
	assert_float(t.dot(Vector3(1, 0, 1).normalized())).is_equal_approx(1.0, 0.01)


func test_smooth_handles_catmull_rom() -> void:
	var h: Dictionary = Builder.smooth_handles(
			Vector3.ZERO, Vector3(10, 0, 0), Vector3(10, 0, 10))
	var dir := Vector3(10, 0, 10).normalized()
	assert_vector(h["in"]).is_equal_approx(-dir * (10.0 / 3.0), Vector3.ONE * 0.001)
	assert_vector(h["out"]).is_equal_approx(dir * (10.0 / 3.0), Vector3.ONE * 0.001)
	# coincident neighbours degenerate to zero handles
	var d: Dictionary = Builder.smooth_handles(Vector3.ONE, Vector3(5, 0, 0), Vector3.ONE)
	assert_vector(d["in"]).is_equal(Vector3.ZERO)
	assert_vector(d["out"]).is_equal(Vector3.ZERO)


func test_adaptive_degenerate_curves_are_empty() -> void:
	assert_int(Builder.adaptive_offsets(null, 6.0, 6.0).size()).is_equal(0)
	assert_int(Builder.adaptive_offsets(Curve3D.new(), 6.0, 6.0).size()).is_equal(0)
	var one := Curve3D.new()
	one.add_point(Vector3(3, 0, 0))
	assert_int(Builder.adaptive_offsets(one, 6.0, 6.0).size()).is_equal(0)
	assert_int(Builder.adaptive_offsets(
			_straight(Vector3(3, 0, 0), Vector3(3, 0, 0)), 6.0, 6.0).size()).is_equal(0)


# ------------------------------------------------------------------ cross-section


func test_asphalt_cross_section() -> void:
	var p: Resource = Profile.new()   # defaults: 3.5 / 0.6 / 0.15 / 0.3 / 0.5
	var cs: Dictionary = p.call("cross_section")
	var points: PackedVector2Array = cs.points
	var mats: PackedInt32Array = cs.mats
	assert_int(points.size()).is_equal(8)
	assert_that(mats).is_equal(PackedInt32Array([2, 2, 1, 0, 1, 2, 2]))
	# mirror-symmetric laterals from the width exports
	var expect := PackedFloat32Array([-4.75, -4.25, -3.65, -3.5, 3.5, 3.65, 4.25, 4.75])
	for i in points.size():
		assert_float(points[i].x).is_equal_approx(expect[i], 0.0001)
	assert_float(points[0].y).is_equal_approx(-0.3, 0.0001)   # drop skirt ends
	assert_float(points[7].y).is_equal_approx(-0.3, 0.0001)
	assert_float(points[3].y).is_equal(0.0)
	assert_float(float(p.call("paved_half_width"))).is_equal_approx(4.25, 0.0001)
	assert_float(float(p.call("full_half_width"))).is_equal_approx(4.75, 0.0001)


func test_gravel_cross_section_drops_zero_width_strips() -> void:
	var p: Resource = Profile.new()
	p.set("edge_line_width", 0.0)
	var cs: Dictionary = p.call("cross_section")
	assert_int((cs.points as PackedVector2Array).size()).is_equal(6)
	assert_that(cs.mats).is_equal(PackedInt32Array([2, 2, 0, 2, 2]))


# ---------------------------------------------------------------------- extrusion


func _extrude_straight(banked := false, a := Vector3.ZERO, b := Vector3(0, 0, 12),
		tilt := 0.0) -> Dictionary:
	var curve := _straight(a, b)
	if tilt != 0.0:
		curve.set_point_tilt(0, tilt)
		curve.set_point_tilt(1, tilt)
	var p: Resource = Profile.new()
	var cs: Dictionary = p.call("cross_section")
	var offsets := Builder.adaptive_offsets(curve, 6.0, 6.0)   # [0, 6, 12]
	return Builder.extrude(curve, cs.points, cs.mats, offsets, banked)


func test_extrude_vertex_counts_per_slot() -> void:
	var surfaces := _extrude_straight()
	# 3 rings x 2 verts x strips-per-slot: surface 1 strip, line 2, shoulder 4
	assert_int((surfaces[0][Mesh.ARRAY_VERTEX] as PackedVector3Array).size()).is_equal(6)
	assert_int((surfaces[1][Mesh.ARRAY_VERTEX] as PackedVector3Array).size()).is_equal(12)
	assert_int((surfaces[2][Mesh.ARRAY_VERTEX] as PackedVector3Array).size()).is_equal(24)
	# 2 quads per strip -> 4 triangles -> 12 indices per strip
	assert_int((surfaces[0][Mesh.ARRAY_INDEX] as PackedInt32Array).size()).is_equal(12)
	assert_int((surfaces[2][Mesh.ARRAY_INDEX] as PackedInt32Array).size()).is_equal(48)


func test_extrude_positions_honor_profile_widths() -> void:
	var surfaces := _extrude_straight()
	for v: Vector3 in (surfaces[0][Mesh.ARRAY_VERTEX] as PackedVector3Array):
		assert_float(absf(v.x)).is_equal_approx(3.5, 0.0001)   # lane edges
		assert_float(v.y).is_equal(0.0)
		assert_bool([0.0, 6.0, 12.0].any(func(z: float) -> bool:
				return absf(v.z - z) < 0.01)).is_true()


func test_extrude_flat_normals_up_and_drop_tilts_outward() -> void:
	var surfaces := _extrude_straight()
	for n: Vector3 in (surfaces[0][Mesh.ARRAY_NORMAL] as PackedVector3Array):
		assert_bool(n.is_equal_approx(Vector3.UP)).is_true()
	# shoulder slot holds the drop skirts: some normals lean sideways, all stay upward
	var leaned := false
	for n: Vector3 in (surfaces[2][Mesh.ARRAY_NORMAL] as PackedVector3Array):
		assert_bool(n.y > 0.0).is_true()
		if absf(n.x) > 0.1:
			leaned = true
	assert_bool(leaned).is_true()


func test_extrude_uvs_are_lateral_and_arc_length() -> void:
	var surfaces := _extrude_straight()
	var uvs: PackedVector2Array = surfaces[0][Mesh.ARRAY_TEX_UV]
	var pos: PackedVector3Array = surfaces[0][Mesh.ARRAY_VERTEX]
	for i in uvs.size():
		assert_float(absf(uvs[i].x)).is_equal_approx(3.5, 0.0001)   # u = lateral meters
		assert_float(uvs[i].y).is_equal_approx(pos[i].z, 0.01)      # v = arc meters


func _assert_up_facing(surfaces: Dictionary) -> void:
	for slot in surfaces:
		var pos: PackedVector3Array = surfaces[slot][Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = surfaces[slot][Mesh.ARRAY_INDEX]
		for i in range(0, idx.size(), 3):
			var cross := (pos[idx[i + 1]] - pos[idx[i]]).cross(pos[idx[i + 2]] - pos[idx[i]])
			# CW seen from above = Godot front face up = geometric cross points DOWN
			assert_bool(cross.y < -1e-6).is_true()


func test_extrude_winding_up_facing_both_directions() -> void:
	_assert_up_facing(_extrude_straight(false, Vector3.ZERO, Vector3(0, 0, 12)))
	_assert_up_facing(_extrude_straight(false, Vector3(0, 0, 12), Vector3.ZERO))


func test_extrude_banking_rotates_about_tangent() -> void:
	var banked := _extrude_straight(true, Vector3.ZERO, Vector3(0, 0, 12), 0.3)
	# T = +Z, so tilt 0.3 rotates UP about +Z: (-sin 0.3, cos 0.3, 0)
	var expect := Vector3(-sin(0.3), cos(0.3), 0)
	for n: Vector3 in (banked[0][Mesh.ARRAY_NORMAL] as PackedVector3Array):
		assert_bool(n.is_equal_approx(expect)).is_true()
	# banked=false ignores the authored tilt entirely
	var flat := _extrude_straight(false, Vector3.ZERO, Vector3(0, 0, 12), 0.3)
	for n: Vector3 in (flat[0][Mesh.ARRAY_NORMAL] as PackedVector3Array):
		assert_bool(n.is_equal_approx(Vector3.UP)).is_true()


func test_faces_from_surfaces_flattens_all_triangles() -> void:
	var surfaces := _extrude_straight()
	var faces := Builder.faces_from_surfaces(surfaces)
	assert_int(faces.size()).is_equal(12 + 24 + 48)   # every index becomes a soup vert
	# soup verts come from the surface verts (spot-check containment)
	var pos: PackedVector3Array = surfaces[0][Mesh.ARRAY_VERTEX]
	assert_bool(Array(faces).has(pos[0])).is_true()


func test_extrude_climbing_straight_has_no_roll() -> void:
	# a road up a slope: the right vector stays horizontal, so each cross-section
	# vertex pair of the flat surface strip shares one world Y
	var surfaces := _extrude_straight(false, Vector3.ZERO, Vector3(0, 5, 50))
	var pos: PackedVector3Array = surfaces[0][Mesh.ARRAY_VERTEX]
	for i in range(0, pos.size(), 2):
		assert_float(pos[i].y).is_equal_approx(pos[i + 1].y, 0.0001)


# ------------------------------------------------------------------- conform math


func test_flatten_weight_shape() -> void:
	assert_float(Builder.flatten_weight(0.0, 2.0, 3.0)).is_equal(1.0)
	assert_float(Builder.flatten_weight(2.0, 2.0, 3.0)).is_equal(1.0)
	assert_float(Builder.flatten_weight(3.5, 2.0, 3.0)).is_equal_approx(0.5, 0.001)
	assert_float(Builder.flatten_weight(5.0, 2.0, 3.0)).is_equal(0.0)
	assert_float(Builder.flatten_weight(99.0, 2.0, 3.0)).is_equal(0.0)
	# monotone non-increasing across the falloff band
	assert_bool(Builder.flatten_weight(2.5, 2.0, 3.0) >= Builder.flatten_weight(3.0, 2.0, 3.0)).is_true()
	assert_bool(Builder.flatten_weight(3.0, 2.0, 3.0) >= Builder.flatten_weight(4.0, 2.0, 3.0)).is_true()


## Centerline row of samples across a 16x16 image (span 15 m -> 1 px = 1 m). The line
## sits on pixel row 7 (lz = -0.5); samples every 0.5 m cover every column.
func _conform_test_image() -> Dictionary:
	var img := Image.create(16, 16, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	var samples := PackedVector3Array()
	var lx := -7.5
	while lx <= 7.51:
		samples.append(Vector3(lx, -0.5, 0.25))
		lx += 0.5
	return {"img": img, "samples": samples}


func test_conform_heights_flattens_inner_and_blends_falloff() -> void:
	var setup := _conform_test_image()
	var img: Image = setup.img
	var before := img.get_pixel(0, 0).r
	var dirty := Builder.conform_heights(img, setup.samples, 2.5, 3.0, 15.0, 15.0)
	# inner band (rows 5..9, dist <= 2.5): the floor-quantized target, never above it
	for row in [5, 6, 7, 8, 9]:
		var r := img.get_pixel(8, row).r
		assert_float(r * 255.0).is_equal_approx(63.0, 1.0)   # floor(0.25*255) = 63
		assert_bool(r <= 0.25 + 1e-6).is_true()
	# mid-falloff (row 4, dist 3): strictly between target and original
	var mid := img.get_pixel(8, 4).r
	assert_bool(mid > img.get_pixel(8, 7).r and mid < before).is_true()
	# beyond half_width + falloff (dist >= 5.5): untouched
	assert_float(img.get_pixel(8, 13).r).is_equal(before)
	assert_float(img.get_pixel(0, 0).r).is_equal(before)
	# tight dirty rect: rows 2..12 change (dist 5 still blends), all 16 columns
	assert_that(dirty).is_equal(Rect2i(0, 2, 16, 11))


func test_conform_heights_is_deterministic() -> void:
	var a := _conform_test_image()
	var b := _conform_test_image()
	Builder.conform_heights(a.img, a.samples, 2.5, 3.0, 15.0, 15.0)
	Builder.conform_heights(b.img, b.samples, 2.5, 3.0, 15.0, 15.0)
	assert_that((a.img as Image).get_data()).is_equal((b.img as Image).get_data())


func test_conform_heights_empty_inputs() -> void:
	var img := Image.create(8, 8, false, Image.FORMAT_L8)
	assert_that(Builder.conform_heights(img, PackedVector3Array(), 2.0, 2.0, 7.0, 7.0)) \
			.is_equal(Rect2i())


## The target is lerped at the pixel's projection onto the centerline SEGMENT, never
## snapped to the nearest point sample: two samples 15 m apart still flatten the span
## between them, and a mid-span pixel gets the interpolated height.
func test_conform_heights_lerps_target_along_segment() -> void:
	var img := Image.create(16, 16, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	var samples := PackedVector3Array([
		Vector3(-7.5, -0.5, 0.1), Vector3(7.5, -0.5, 0.3)])
	Builder.conform_heights(img, samples, 2.5, 3.0, 15.0, 15.0)
	# pixel (8, 7): on the line at lx = 0.5 -> t = 8/15, target = 0.1 + 0.2 * 8/15,
	# stored = floor(target * 255) = 52
	assert_float(img.get_pixel(8, 7).r * 255.0).is_equal_approx(52.0, 0.5)
	# endpoints keep their own targets: floor(0.1*255) = 25, floor(0.3*255) = 76
	assert_float(img.get_pixel(0, 7).r * 255.0).is_equal_approx(25.0, 0.5)
	assert_float(img.get_pixel(15, 7).r * 255.0).is_equal_approx(76.0, 0.5)


## The seam invariant (LK7 seam pass): on a steep road, every plateau pixel stays
## within (target - one 8-bit step, target] of the analytic road height at its own
## projection. The nearest-point-sample flatten violated this on any grade over ~20%
## (a point target is off by up to half the sample spacing x the grade).
func test_conform_heights_sloped_road_stays_below_ribbon() -> void:
	var img := Image.create(16, 16, false, Image.FORMAT_L8)
	img.fill(Color(0.5, 0.5, 0.5))
	# straight line along x at lz = -0.5, target climbing 0.05 -> 0.95; samples every
	# 0.8 m (deliberately NOT aligned with the 1 m pixel grid) + the exact endpoint,
	# the _conform_terrain convention
	var samples := PackedVector3Array()
	var x := -7.5
	while x < 7.5:
		samples.append(Vector3(x, -0.5, 0.05 + (x + 7.5) / 15.0 * 0.9))
		x += 0.8
	samples.append(Vector3(7.5, -0.5, 0.95))
	Builder.conform_heights(img, samples, 2.5, 3.0, 15.0, 15.0)
	var step := 1.0 / 255.0
	for pz in [5, 6, 7, 8, 9]:           # rows within the 2.5 m plateau of the line
		for px in 16:
			var lx := float(px) - 7.5
			var t_proj := 0.05 + (lx + 7.5) / 15.0 * 0.9
			var stored := img.get_pixel(px, pz).r
			assert_bool(stored <= t_proj + 1e-4).is_true()
			assert_bool(stored >= t_proj - step - 1e-4).is_true()


# --------------------------------------------------------- baker: chunk bucketing


func _two_quad_arrays() -> Array:
	# two up-facing quads either side of x = 48 (chunk border at chunk_size 48)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(40, 0, 0), Vector3(46, 0, 0), Vector3(40, 0, 2), Vector3(46, 0, 2),
		Vector3(50, 0, 0), Vector3(56, 0, 0), Vector3(50, 0, 2), Vector3(56, 0, 2)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP,
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1),
		Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1, 1, 2, 3, 4, 6, 5, 5, 6, 7])
	return arrays


func test_split_arrays_by_chunk_buckets_by_world_centroid() -> void:
	var out: Dictionary = Baker.split_arrays_by_chunk(_two_quad_arrays(),
			Transform3D.IDENTITY, 48.0)
	assert_int(out.size()).is_equal(2)
	assert_bool(out.has(Vector2i(0, 0)) and out.has(Vector2i(1, 0))).is_true()
	var tri_total := 0
	for key: Vector2i in out:
		var arrays: Array = out[key]
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		assert_int(pos.size()).is_equal(4)   # per-chunk dedup
		tri_total += idx.size() / 3
		for i in idx:
			assert_bool(i >= 0 and i < pos.size()).is_true()
	assert_int(tri_total).is_equal(4)   # triangle count conserved
	# vertex positions preserved (source-space, not shifted by the keying transform)
	assert_bool(Array((out[Vector2i(0, 0)] as Array)[Mesh.ARRAY_VERTEX] as PackedVector3Array)
			.has(Vector3(40, 0, 0))).is_true()


func test_split_arrays_by_chunk_transform_keys_only() -> void:
	var shifted: Dictionary = Baker.split_arrays_by_chunk(_two_quad_arrays(),
			Transform3D(Basis.IDENTITY, Vector3(48, 0, 0)), 48.0)
	assert_bool(shifted.has(Vector2i(1, 0)) and shifted.has(Vector2i(2, 0))).is_true()
	# output verts stay in source space
	assert_bool(Array((shifted[Vector2i(1, 0)] as Array)[Mesh.ARRAY_VERTEX] as PackedVector3Array)
			.has(Vector3(40, 0, 0))).is_true()


# ------------------------------------------------------------ baker: road collect


## Minimal bakeable level with one RoadPath (never enters the tree, so no _ready side
## effects — the baker's own operating mode).
func _road_level(with_profile: bool) -> Dictionary:
	var root := Node3D.new()
	root.name = "L"
	var spawn := Marker3D.new()
	spawn.name = "Spawn"
	spawn.set_script(load("res://src/levels/base/vehicle_spawn.gd"))
	root.add_child(spawn)
	var authoring := Node3D.new()
	authoring.name = "Authoring"
	authoring.set_script(preload("res://kit/helpers/authoring_root.gd"))
	root.add_child(authoring)
	var road := Node3D.new()
	road.name = "Road"
	road.set_script(RoadPathScript)
	if with_profile:
		road.set("profile", load("res://kit/roads/asphalt_profile.tres"))
	authoring.add_child(road)
	var path := Path3D.new()
	path.name = "Path"
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(0, 0.05, 60))
	path.curve = curve
	road.add_child(path)
	return {"root": root, "road": road}


func test_bake_collects_road_into_weld_and_chunks() -> void:
	var level := _road_level(true)
	var result: Dictionary = Baker.bake(level.root)
	assert_bool(result.ok).is_true()
	var stats: Dictionary = result.stats
	assert_int(int(stats.roads)).is_equal(1)
	assert_bool(int(stats.drivable_triangles) > 0).is_true()
	# a 60 m ribbon along z straddling x = 0 buckets into 4 chunks at chunk_size 48:
	# x chunks -1/0 (triangle centroids either side of the centerline), z chunks 0/1
	assert_int(int(stats.chunks)).is_equal(4)
	var baked: Node3D = result.root
	assert_object(baked.get_node_or_null("Drivable")).is_not_null()
	baked.free()
	level.root.free()


func test_bake_road_without_profile_is_an_error() -> void:
	var level := _road_level(false)
	var result: Dictionary = Baker.bake(level.root)
	assert_bool(result.ok).is_false()
	assert_bool("\n".join(result.errors as PackedStringArray).contains("profile")).is_true()
	level.root.free()


func test_bake_road_with_degenerate_curve_is_an_error() -> void:
	var level := _road_level(true)
	((level.road as Node).get_node("Path") as Path3D).curve = Curve3D.new()
	var result: Dictionary = Baker.bake(level.root)
	assert_bool(result.ok).is_false()
	assert_bool("\n".join(result.errors as PackedStringArray).contains("curve")).is_true()
	level.root.free()
