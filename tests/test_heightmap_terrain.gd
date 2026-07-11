extends GdUnitTestSuite
## HeightmapTerrain world-space height query (LK2): the ground-sample fallback the palette
## dock uses when a placement raycast misses. Pure image math — built inline with round
## numbers so every expected value is hand-checkable.

const TerrainScript := preload("res://src/levels/base/heightmap_terrain.gd")


func _tex(img: Image) -> ImageTexture:
	return ImageTexture.create_from_image(img)


# Float format so fractional red values are exact (RGB8 would quantize 0.5 -> 0.498).
func _flat(red: float) -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBF)
	img.fill(Color(red, red, red))
	return _tex(img)


# A 2x1 image: red ramps 0 -> 1 across X (left -> right).
func _ramp_x() -> ImageTexture:
	var img := Image.create(2, 1, false, Image.FORMAT_RGBF)
	img.set_pixel(0, 0, Color(0, 0, 0))
	img.set_pixel(1, 0, Color(1, 1, 1))
	return _tex(img)


# In-tree so global_position resolves (height_at returns world-space Y).
func _terrain(size: Vector2, height: float, pos := Vector3.ZERO) -> HeightmapTerrain:
	var t: HeightmapTerrain = auto_free(TerrainScript.new())
	t.terrain_size = size
	t.height = height
	t.position = pos
	add_child(t)
	return t


func test_flat_height_is_uniform() -> void:
	var t := _terrain(Vector2(4, 4), 10.0)
	t.heightmap = _flat(0.5)
	assert_float(t.height_at(Vector3(0, 99, 0))).is_equal_approx(5.0, 0.001)
	assert_float(t.height_at(Vector3(1.5, 0, -1.5))).is_equal_approx(5.0, 0.001)


func test_null_heightmap_flat_at_node_y() -> void:
	var t := _terrain(Vector2(4, 4), 8.0, Vector3(0, 3, 0))
	assert_float(t.height_at(Vector3(5, 0, 5))).is_equal_approx(3.0, 0.001)


func test_ramp_interpolates_across_x() -> void:
	var t := _terrain(Vector2(2, 2), 10.0)   # extent +/-1 on X and Z
	t.heightmap = _ramp_x()
	assert_float(t.height_at(Vector3(-1, 0, 0))).is_equal_approx(0.0, 0.001)
	assert_float(t.height_at(Vector3(0, 0, 0))).is_equal_approx(5.0, 0.001)
	assert_float(t.height_at(Vector3(1, 0, 0))).is_equal_approx(10.0, 0.001)


func test_height_adds_node_offset() -> void:
	var t := _terrain(Vector2(4, 4), 8.0, Vector3(10, 2, -5))   # translated terrain
	t.heightmap = _flat(1.0)
	# query at world (10, _, -5) maps to local origin -> full height, plus node Y.
	assert_float(t.height_at(Vector3(10, 0, -5))).is_equal_approx(10.0, 0.001)


func test_chunked_mesh_builds_per_tile_and_height_matches_across_borders() -> void:
	# LK3: 4x4 cells at chunk_cells 2 -> 2x2 tiles, one MeshInstance3D each; the height
	# query is image-based, so values across a chunk border are unchanged.
	var t := _terrain(Vector2(4, 4), 10.0)
	t.chunk_cells = 2
	t.heightmap = _flat(0.5)
	var chunks := t.get_node("Chunks")
	assert_int(chunks.get_child_count()).is_equal(4)
	for chunk in chunks.get_children():
		assert_object((chunk as MeshInstance3D).mesh).is_not_null()
	assert_float(t.height_at(Vector3(0, 0, 0))).is_equal_approx(5.0, 0.001)   # tile seam
	assert_float(t.height_at(Vector3(1.5, 0, 1.5))).is_equal_approx(5.0, 0.001)


func test_contains_xz_extent() -> void:
	var t := _terrain(Vector2(4, 4), 8.0, Vector3(10, 0, 0))   # extent +/-2 around x=10
	assert_bool(t.contains_xz(Vector3(11.9, 0, 1.9))).is_true()
	assert_bool(t.contains_xz(Vector3(12.5, 0, 0))).is_false()
	assert_bool(t.contains_xz(Vector3(10, 0, -2.5))).is_false()
