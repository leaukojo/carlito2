@tool
extends RefCounted
## "Conform terrain under tiles" (palette toolbar button): flattens every overlapping
## HeightmapTerrain to the painted GridMap cells' BASE plane — the tiles' resting
## height — so a tile city sits on terrain without hand-stroking 12 m flatten pads.
## The RoadPath Conform discipline throughout: destructive-by-button, the pure pixel
## work is RoadBuilder.conform_rects (tested), one undoable _commit_generated action
## per terrain. Targets ROUND-quantize to the 8-bit grid (closest meet either side of
## the base; the tiles' deck height hides the residual — see conform_rects' doc).
## Editor-only (addons/), so editor API types are fine here.

## Flatten fade-out (m) beyond the tile footprint union — the RoadPath default.
const FALLOFF := 4.0


## Per painted cell (sorted — deterministic first-wins rect order downstream):
## world-space XZ footprint rect + base-plane world height, as
## {rects: Array[Rect2], base_ys: PackedFloat32Array}. The footprint is the item
## mesh's AABB in the painted orientation — multi-cell tiles like the 2x2 road-curve
## / 3x3 roundabout overhang their anchor cell, so occupancy alone would leave their
## overhung cells unconformed — cached per (item, orientation). No editor APIs
## (tested in tests/test_road.gd against the real roads meshlib).
static func footprint_rects(grid: GridMap) -> Dictionary:
	var rects: Array[Rect2] = []
	var base_ys := PackedFloat32Array()
	var lib := grid.mesh_library
	if lib == null:
		return {"rects": rects, "base_ys": base_ys}
	var xf := grid.global_transform if grid.is_inside_tree() else grid.transform
	var cells := grid.get_used_cells()
	cells.sort()
	var footprints := {}   # Vector2i(item, orientation) -> Rect2 (grid-relative XZ)
	for cell: Vector3i in cells:
		var item := grid.get_cell_item(cell)
		var orient := grid.get_cell_item_orientation(cell)
		var key := Vector2i(item, orient)
		if not footprints.has(key):
			var mesh := lib.get_item_mesh(item)
			if mesh == null:
				footprints[key] = Rect2()
			else:
				# full mesh transform (its origin carries palette alignment offsets),
				# then the painted orientation, then the grid's world basis
				var mt := lib.get_item_mesh_transform(item)
				var cell_basis := grid.get_basis_with_orthogonal_index(orient)
				var aabb := mesh.get_aabb()
				var fp := Rect2()
				for ci in 8:
					var c := xf.basis * (cell_basis * (mt * aabb.get_endpoint(ci)))
					var p := Vector2(c.x, c.z)
					fp = Rect2(p, Vector2.ZERO) if ci == 0 else fp.expand(p)
				footprints[key] = fp
		var fp2: Rect2 = footprints[key]
		if not fp2.has_area():
			continue
		var origin := xf * grid.map_to_local(cell)
		rects.append(Rect2(fp2.position + Vector2(origin.x, origin.z), fp2.size))
		base_ys.append(origin.y)
	return {"rects": rects, "base_ys": base_ys}


static func conform(grid: GridMap, scene_root: Node) -> void:
	if grid == null or scene_root == null:
		push_warning("Kit: no roads GridMap in the scene to conform under.")
		return
	var lib := grid.mesh_library
	var cells := grid.get_used_cells()
	if lib == null or cells.is_empty():
		push_warning("Kit: '%s' has no painted cells to conform under." % grid.name)
		return
	var fps := footprint_rects(grid)
	var rects: Array[Rect2] = fps["rects"]
	var base_ys: PackedFloat32Array = fps["base_ys"]
	if rects.is_empty():
		push_warning("Kit: '%s' has no tile meshes to conform under." % grid.name)
		return

	var terrains: Array[Node] = []
	ScatterBase.find_terrains_under(scene_root, terrains)
	var touched := 0
	for t in terrains:
		var t3d := t as Node3D
		var half: Vector2 = t.get("terrain_size") * 0.5
		var t_rect := Rect2(t3d.global_position.x - half.x,
				t3d.global_position.z - half.y, half.x * 2.0, half.y * 2.0) \
				.grow(FALLOFF)
		var local_rects: Array[Rect2] = []
		var targets := PackedFloat32Array()
		var amp := maxf(float(t.get("height")), 0.001)
		var clamped := false
		for i in rects.size():
			if not t_rect.intersects(rects[i]):
				continue
			local_rects.append(Rect2(rects[i].position
					- Vector2(t3d.global_position.x, t3d.global_position.z),
					rects[i].size))
			var tn := (base_ys[i] - t3d.global_position.y) / amp
			if tn < 0.0 or tn > 1.0:
				clamped = true
			targets.append(clampf(tn, 0.0, 1.0))
		if local_rects.is_empty():
			continue
		if clamped:
			push_warning("Kit: tiles of '%s' sit outside terrain '%s's height range — the flatten clamps there." % [grid.name, t.name])
		var img: Image = t._read_image()
		if img == null:
			push_warning("Kit: terrain '%s' has no heightmap to conform." % t.name)
			continue
		var dims: Vector2i = t._grid_dims()
		var dirty := RoadBuilder.conform_rects(img, local_rects, targets, FALLOFF,
				float(dims.x - 1), float(dims.y - 1))
		if not dirty.has_area():
			continue
		t._commit_generated("Conform terrain under tiles '%s'" % grid.name,
				[[&"heightmap", t.png_path_for("height"), img]], {})
		touched += 1
	if touched == 0:
		push_warning("Kit: no HeightmapTerrain under '%s's tiles — nothing conformed." % grid.name)
	else:
		print("Kit: conformed %d terrain(s) under '%s'." % [touched, grid.name])
