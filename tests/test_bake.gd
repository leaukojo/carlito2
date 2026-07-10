# GdUnit generated TestSuite
extends GdUnitTestSuite
## Unit tests for the level baker's pure logic (plan §2 rule 8): chunk assignment,
## vertex welding, spawn validation, hashing/normalization, and the manifest
## round-trip. Scene-level bake behaviour is exercised end-to-end by the CI bake
## check (tools/check_bakes.gd), not here.

const Baker := preload("res://kit/bake/level_baker.gd")


# ---------------------------------------------------------------- chunk keys

func test_chunk_key_quadrants() -> void:
	assert_that(Baker.chunk_key(Vector3(0, 0, 0), 48.0)).is_equal(Vector2i(0, 0))
	assert_that(Baker.chunk_key(Vector3(47.9, 5, 47.9), 48.0)).is_equal(Vector2i(0, 0))
	assert_that(Baker.chunk_key(Vector3(48.0, 0, 0), 48.0)).is_equal(Vector2i(1, 0))
	# floor semantics, not truncation: -0.1 belongs to chunk -1
	assert_that(Baker.chunk_key(Vector3(-0.1, 0, -48.1), 48.0)).is_equal(Vector2i(-1, -2))


func test_chunk_origin_roundtrip() -> void:
	var key := Vector2i(-2, 3)
	var origin := Baker.chunk_origin(key, 32.0)
	assert_that(origin).is_equal(Vector3(-64, 0, 96))
	assert_that(Baker.chunk_key(origin + Vector3(1, 0, 1), 32.0)).is_equal(key)


# ------------------------------------------------------------------- welding

func _tri(a: Vector3, b: Vector3, c: Vector3) -> PackedVector3Array:
	return PackedVector3Array([a, b, c])


func test_weld_snaps_near_vertices_bit_identical() -> void:
	# Two triangles sharing an edge, but the second's shared verts are off by less
	# than the weld epsilon (the classic tile-border crack).
	var soup := PackedVector3Array()
	soup.append_array(_tri(Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)))
	soup.append_array(_tri(Vector3(1.0004, 0, 0.0003), Vector3(1, 0, 1), Vector3(-0.0002, 0, 1.0004)))
	var welded := Baker.weld_faces(soup)
	assert_int(welded.size()).is_equal(6)
	# shared corners are now bit-identical
	assert_that(welded[1]).is_equal(welded[3])   # (1,0,0)
	assert_that(welded[2]).is_equal(welded[5])   # (0,0,1)


func test_weld_drops_degenerate_triangles() -> void:
	# All three verts weld to the same point -> triangle vanishes.
	var soup := _tri(Vector3(0, 0, 0), Vector3(0.0002, 0, 0), Vector3(0, 0.0003, 0))
	assert_int(Baker.weld_faces(soup).size()).is_equal(0)


func test_weld_is_deterministic() -> void:
	var soup := PackedVector3Array()
	soup.append_array(_tri(Vector3(0.30017, 1.2, -4.7), Vector3(5, 0, 0), Vector3(0, 0, 5)))
	assert_that(Baker.weld_faces(soup)).is_equal(Baker.weld_faces(soup.duplicate()))


# ----------------------------------------------------------- spawn validation

func _spawn(types: Array, water := false) -> Dictionary:
	return {"types": PackedStringArray(types), "is_water": water}


func test_validate_spawns_happy_path() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(["car", "truck"]), "car",
			[_spawn([]), _spawn(["truck"])])
	assert_array(errors).is_empty()


func test_validate_spawns_no_markers() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(["car"]), "car", [])
	assert_int(errors.size()).is_equal(1)
	assert_str(errors[0]).contains("no VehicleSpawn")


func test_validate_spawns_default_not_allowed() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(["truck"]), "car", [_spawn([])])
	assert_bool("\n".join(errors).contains("not in allowed_vehicles")).is_true()


func test_validate_spawns_missing_type_coverage() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(["car", "tractor"]), "car",
			[_spawn(["car"])])
	assert_bool("\n".join(errors).contains("'tractor'")).is_true()


func test_validate_spawns_boat_needs_water() -> void:
	var land_only := Baker.validate_spawns(PackedStringArray(["boat"]), "boat", [_spawn([])])
	assert_bool("\n".join(land_only).contains("water")).is_true()
	var with_water := Baker.validate_spawns(PackedStringArray(["boat"]), "boat",
			[_spawn([], true)])
	assert_array(with_water).is_empty()


func test_validate_spawns_land_vehicle_rejects_water_only() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(["car"]), "car", [_spawn([], true)])
	assert_bool("\n".join(errors).contains("'car'")).is_true()


func test_validate_spawns_empty_allowed_checks_default_only() -> void:
	var errors := Baker.validate_spawns(PackedStringArray(), "car", [_spawn(["car"])])
	assert_array(errors).is_empty()


# ------------------------------------------------------------------- hashing

func test_normalize_text_line_endings() -> void:
	assert_str(Baker.normalize_text("a\r\nb\rc\nd")).is_equal("a\nb\nc\nd")


func test_hash_file_text_ignores_crlf() -> void:
	var lf := "user://bake_test_lf.tscn"
	var crlf := "user://bake_test_crlf.tscn"
	FileAccess.open(lf, FileAccess.WRITE).store_string("[node]\nkey = 1\n")
	FileAccess.open(crlf, FileAccess.WRITE).store_string("[node]\r\nkey = 1\r\n")
	assert_str(Baker.hash_file(lf)).is_equal(Baker.hash_file(crlf))


func test_hash_inputs_order_independent_and_content_sensitive() -> void:
	var a := "user://bake_test_a.tscn"
	var b := "user://bake_test_b.tscn"
	FileAccess.open(a, FileAccess.WRITE).store_string("alpha")
	FileAccess.open(b, FileAccess.WRITE).store_string("beta")
	var h1 := Baker.hash_inputs(PackedStringArray([a, b]))
	var h2 := Baker.hash_inputs(PackedStringArray([b, a]))
	assert_str(h1).is_equal(h2)
	FileAccess.open(b, FileAccess.WRITE).store_string("beta CHANGED")
	assert_str(Baker.hash_inputs(PackedStringArray([a, b]))).is_not_equal(h1)


func test_hash_extra_chunk_size_changes_hash() -> void:
	var a := "user://bake_test_a.tscn"
	FileAccess.open(a, FileAccess.WRITE).store_string("alpha")
	var paths := PackedStringArray([a])
	assert_str(Baker.hash_inputs(paths, Baker.hash_extra(48.0))) \
			.is_not_equal(Baker.hash_inputs(paths, Baker.hash_extra(32.0)))


func test_hash_missing_file_flagged_not_crashing() -> void:
	var h := Baker.hash_inputs(PackedStringArray(["user://bake_test_nope.tscn"]))
	assert_str(h).is_not_empty()


# ------------------------------------------------------------------ manifest

func test_manifest_roundtrip_and_paths() -> void:
	var level := "user://bake_test_level.tscn"
	assert_str(Baker.baked_scene_path(level)).is_equal("user://bake_test_level.baked.scn")
	assert_str(Baker.manifest_path(level)).is_equal("user://bake_test_level.bake.json")
	assert_that(Baker.write_manifest(level, "abc123", 48.0, {"chunks": 2})).is_equal(OK)
	var m := Baker.read_manifest(level)
	assert_int(int(m.get("baker_version", -1))).is_equal(Baker.BAKER_VERSION)
	assert_str(String(m.get("input_hash", ""))).is_equal("abc123")
	assert_float(float(m.get("chunk_size", 0.0))).is_equal_approx(48.0, 0.001)
	assert_int(int((m.get("stats", {}) as Dictionary).get("chunks", 0))).is_equal(2)


func test_manifest_is_timestamp_free_idempotent() -> void:
	var level := "user://bake_test_level2.tscn"
	Baker.write_manifest(level, "h", 32.0, {"chunks": 1})
	var first := FileAccess.get_file_as_string(Baker.manifest_path(level))
	Baker.write_manifest(level, "h", 32.0, {"chunks": 1})
	assert_str(FileAccess.get_file_as_string(Baker.manifest_path(level))).is_equal(first)


# ------------------------------------------------------------ material keys

func test_material_key_merges_equal_materials_across_instances() -> void:
	var m1 := StandardMaterial3D.new()
	var m2 := StandardMaterial3D.new()
	m1.albedo_color = Color.RED
	m2.albedo_color = Color.RED
	assert_str(Baker.material_key(m1)).is_equal(Baker.material_key(m2))
	m2.albedo_color = Color.BLUE
	assert_str(Baker.material_key(m1)).is_not_equal(Baker.material_key(m2))
	assert_str(Baker.material_key(null)).is_equal("null")


# ------------------------------------------------------- surface accumulator

func _quad_arrays() -> Array:
	# One unit quad (two indexed triangles) with normals up and UVs.
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([
		Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	return arrays


func test_accumulator_offsets_indices_and_transforms_positions() -> void:
	var acc := Baker.SurfaceAccumulator.new()
	acc.append(_quad_arrays(), Transform3D.IDENTITY)
	acc.append(_quad_arrays(), Transform3D(Basis.IDENTITY, Vector3(10, 0, 0)))
	assert_int(acc.positions.size()).is_equal(8)
	assert_int(acc.indices.size()).is_equal(12)
	assert_int(acc.indices[6]).is_equal(4)  # second quad's indices offset by base
	assert_that(acc.positions[4]).is_equal(Vector3(10, 0, 0))


func test_accumulator_renormalizes_normals_under_uniform_scale() -> void:
	var acc := Baker.SurfaceAccumulator.new()
	var scaled := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 10.0), Vector3.ZERO)
	acc.append(_quad_arrays(), scaled)
	assert_float(acc.normals[0].length()).is_equal_approx(1.0, 0.0001)
	assert_that(acc.positions[1]).is_equal(Vector3(10, 0, 0))


func test_accumulator_backfills_missing_uv_and_color() -> void:
	var no_uv := _quad_arrays()
	no_uv[Mesh.ARRAY_TEX_UV] = null
	var with_col := _quad_arrays()
	with_col[Mesh.ARRAY_COLOR] = PackedColorArray([
		Color.RED, Color.RED, Color.RED, Color.RED])
	var acc := Baker.SurfaceAccumulator.new()
	acc.append(no_uv, Transform3D.IDENTITY)      # no uv, no color yet
	acc.append(with_col, Transform3D.IDENTITY)   # uv + color appear late
	assert_bool(acc.has_uv).is_true()
	assert_bool(acc.has_color).is_true()
	assert_int(acc.uvs.size()).is_equal(8)       # first quad zero-backfilled
	assert_int(acc.colors.size()).is_equal(8)
	assert_that(acc.colors[0]).is_equal(Color.WHITE)  # backfill is white, not transparent
	assert_that(acc.colors[4]).is_equal(Color.RED)
	# commit produces a well-formed two-quad surface
	var mesh := ArrayMesh.new()
	acc.commit(mesh, StandardMaterial3D.new())
	assert_int(mesh.get_surface_count()).is_equal(1)


func test_accumulator_generates_sequential_indices_for_unindexed() -> void:
	var arrays := _quad_arrays()
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TEX_UV] = null
	arrays[Mesh.ARRAY_INDEX] = null
	var acc := Baker.SurfaceAccumulator.new()
	acc.append(arrays, Transform3D.IDENTITY)
	assert_that(acc.indices).is_equal(PackedInt32Array([0, 1, 2]))
