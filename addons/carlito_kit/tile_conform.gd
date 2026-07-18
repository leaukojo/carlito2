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

const Recipe := preload("res://kit/helpers/kit_recipe.gd")
const RECIPE_DIR := "res://kit/import"

## Flatten fade-out (m) beyond the tile footprint union — the RoadPath default.
const FALLOFF := 4.0

## Prefab families whose placed pieces flatten a terrain pad under themselves on Conform.
## Add/remove family names (from kit/import/*.json) to change behavior.
const CONFORM_PREFAB_FAMILIES: Array[String] = [
	"commercial-buildings", "industrial-buildings", "suburban-buildings",
	"racing-grandstands", "racing-pits", "racing-tents",
]
## Tile GridMaps excluded from Conform, by meshlib basename (all conform by default).
const CONFORM_EXCLUDE_MESHLIBS: Array[String] = []


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


## Conform every terrain under ALL painted tile GridMaps (any meshlib not excluded) plus
## every placed prefab building whose family is in CONFORM_PREFAB_FAMILIES, in one pass.
## Entry point for the palette dock's Conform button.
static func conform_all(scene_root: Node) -> void:
	if scene_root == null:
		push_warning("Kit: no scene open to conform.")
		return
	var authoring := _find_authoring(scene_root)
	if authoring == null:
		push_warning("Kit: no AuthoringRoot in the scene to conform under.")
		return

	var rects: Array[Rect2] = []
	var base_ys := PackedFloat32Array()

	# Every painted tile GridMap (skip excluded meshlibs); reuse footprint_rects verbatim.
	for node in authoring.find_children("*", "GridMap", true, false):
		var grid := node as GridMap
		if _meshlib_excluded(grid):
			continue
		var fps := footprint_rects(grid)
		var g_rects: Array[Rect2] = fps["rects"]
		var g_base: PackedFloat32Array = fps["base_ys"]
		for i in g_rects.size():
			rects.append(g_rects[i])
			base_ys.append(g_base[i])

	# Every placed KitPiece (duck-typed) whose family is listed: footprint = merged
	# world-space AABB of its mesh descendants, target = the piece's world origin Y.
	var recipe_cache := {}
	for node in authoring.find_children("*", "Node3D", true, false):
		if not node.has_method("is_carlito_kit_piece"):
			continue
		if not CONFORM_PREFAB_FAMILIES.has(piece_family(node, recipe_cache)):
			continue
		var fp := _piece_footprint(node as Node3D)
		if not fp.has_area():
			continue
		rects.append(fp)
		base_ys.append((node as Node3D).global_position.y)

	if rects.is_empty():
		push_warning("Kit: no painted tiles or listed prefab buildings to conform under.")
		return
	_conform_terrains(scene_root, rects, base_ys)


## Flatten every overlapping terrain to the given world-space XZ footprint rects + target
## base-plane world heights (paired arrays). One undoable _commit_generated per terrain.
static func _conform_terrains(scene_root: Node, rects: Array[Rect2],
		base_ys: PackedFloat32Array) -> void:
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
			push_warning("Kit: some footprints sit outside terrain '%s's height range — the flatten clamps there." % t.name)
		var img: Image = t._read_image()
		if img == null:
			push_warning("Kit: terrain '%s' has no heightmap to conform." % t.name)
			continue
		var dims: Vector2i = t._grid_dims()
		var dirty := RoadBuilder.conform_rects(img, local_rects, targets, FALLOFF,
				float(dims.x - 1), float(dims.y - 1))
		if not dirty.has_area():
			continue
		t._commit_generated("Conform terrain under tiles & buildings",
				[[&"heightmap", t.png_path_for("height"), img]], {})
		touched += 1
	if touched == 0:
		push_warning("Kit: no HeightmapTerrain overlaps the footprints — nothing conformed.")
	else:
		print("Kit: conformed %d terrain(s) under tiles & buildings." % touched)


## Whether a GridMap's meshlib basename is in CONFORM_EXCLUDE_MESHLIBS (or it has no lib).
static func _meshlib_excluded(grid: GridMap) -> bool:
	if grid.mesh_library == null:
		return true
	return CONFORM_EXCLUDE_MESHLIBS.has(grid.mesh_library.resource_path.get_file().get_basename())


## Merged world-space XZ AABB of a placed piece's MeshInstance3D descendants, as a Rect2.
static func _piece_footprint(piece: Node3D) -> Rect2:
	var rect := Rect2()
	var has := false
	for node in piece.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var mt := mi.global_transform
		var aabb := mi.mesh.get_aabb()
		for ci in 8:
			var c := mt * aabb.get_endpoint(ci)
			var p := Vector2(c.x, c.z)
			if not has:
				rect = Rect2(p, Vector2.ZERO)
				has = true
			else:
				rect = rect.expand(p)
	return rect if has else Rect2()


## Recipe family of a placed prefab, from its scene_file_path
## (res://kit/prefabs/<kit>/<name>.tscn) classified through the kit recipe; "" if unknown.
## recipe_cache maps kit -> families Array so each recipe JSON parses once per conform pass.
static func piece_family(piece: Node, recipe_cache: Dictionary) -> String:
	var path := piece.scene_file_path
	if path.is_empty():
		return ""
	var base := path.get_file().get_basename()
	var kit := path.get_base_dir().get_file()
	if kit.is_empty() or base.is_empty():
		return ""
	if not recipe_cache.has(kit):
		recipe_cache[kit] = _load_recipe_families(kit)
	var families: Array = recipe_cache[kit]
	if families.is_empty():
		return ""
	return String(Recipe.classify([base], families).assignments.get(base, ""))


static func _load_recipe_families(kit: String) -> Array:
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("%s/%s.json" % [RECIPE_DIR, kit]))
	if parsed is Dictionary:
		return (parsed as Dictionary).get("families", [])
	return []


static func _find_authoring(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("is_carlito_authoring"):
		return node
	for child in node.get_children():
		var found := _find_authoring(child)
		if found != null:
			return found
	return null
