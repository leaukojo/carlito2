extends Node
## One-shot builder for the permanent CI bake fixture src/levels/dev/kit_fixture.tscn
## (level_kit_plan.md §4 LK1): a level on the re-derived lattice — a small road loop from
## the roads palette (scale-verification), one prefab of each collision mode + a weld ramp
## (the bake canary), a per-kit ASSET SHOWCASE (evenly-sampled prefabs in labelled rows so
## every kit's scale can be eyeballed against the car), two LK5 scatter regions (MultiMesh
## and merge bake paths), and a car spawn — all the kit content under an AuthoringRoot so
## the baker/CI cover it.
##
## Built programmatically because hand-authoring GridMap cell+orientation data in a .tscn
## is fragile; re-run if the roads palette rescales (item ids are stable across regen).
## GAME-MODE tool scene, not --script: level.gd types against BaseVehicle -> InputRouter,
## which only compiles with autoloads registered (the P6 CLI lesson, CLAUDE.md kit notes):
##   godot --headless --path . res://tools/build_kit_fixture.tscn
## The built tree is never added to the active SceneTree, so no _ready hook fires.

const OUT := "res://src/levels/dev/kit_fixture.tscn"
const ROADS_MESHLIB := "res://kit/palettes/roads.meshlib"
const CELL := 12.0  # roads scale (lane-fit); must match roads.json cell_size x/z

# roads.meshlib item ids (stable across regen). road-bend is the TIGHT 1x1 corner
# (road-curve is a 2x2 sweeping curve — wrong for a one-cell corner, it overlaps).
const ID_STRAIGHT := 49
const ID_BEND := 0

# One prefab per collision mode (KitPiece.collision_mode), for the bake canary.
const PREFABS := {
	"none": "res://kit/prefabs/nature/grass.tscn",
	"box": "res://kit/prefabs/suburban/building-type-a.tscn",
	"hull": "res://kit/prefabs/nature/tree_default.tscn",
	"multiconvex": "res://kit/prefabs/roads/light-square.tscn",
	"weld": "res://kit/prefabs/racing/ramp.tscn",
}

# Asset showcase: one labelled row per kit, SHOWCASE_N prefabs sampled evenly across the
# kit's sorted prefab list (a representative spread, robust to prefab renames). Rows march
# north (+Z) beyond the loop; drive among them to judge each kit's scale against the car.
const SHOWCASE_KITS := ["suburban", "commercial", "industrial", "nature", "watercraft", "racing"]
const SHOWCASE_N := 6         # prefabs per kit row
const SHOWCASE_DX := 16.0     # X spacing between items in a row
const SHOWCASE_Z0 := 44.0     # Z of the first row
const SHOWCASE_DZ := 16.0     # Z spacing between kit rows


func _ready() -> void:
	var root := Node3D.new()
	root.name = "KitFixture"
	root.set_script(load("res://src/levels/base/level.gd"))
	root.set("info", load("res://src/levels/dev/kit_fixture_info.tres"))

	_add(root, root, _make_environment())
	_add(root, root, _make_sun())
	_add(root, root, _make_camera())
	_add_ground(root)
	_add(root, root, _make_spawn())
	# Temporary boat-test rig (removed later): a small water body west of the ground
	# plane plus a boat spawn over it, so the garage can spawn/float a boat here.
	_add(root, root, _make_water())
	_add(root, root, _make_boat_spawn())

	var authoring := Node3D.new()
	authoring.name = "Authoring"
	authoring.set_script(load("res://kit/helpers/authoring_root.gd"))
	_add(root, root, authoring)
	_add(root, authoring, _make_road_loop())
	_add_prefabs(root, authoring)
	_add_showcase(root, authoring)
	_add_scatter(root, authoring)

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		push_error("pack failed")
		get_tree().quit(1)
		return
	var err := ResourceSaver.save(packed, OUT)
	if err != OK:
		push_error("save failed: %d" % err)
		get_tree().quit(1)
		return
	print("wrote ", OUT)
	get_tree().quit(0)


func _add(owner: Node, parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = owner


func _make_environment() -> WorldEnvironment:
	var sky_mat := ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	return we


func _make_sun() -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(-50), deg_to_rad(40), 0)),
			Vector3(0, 40, 0))
	sun.shadow_enabled = true
	return sun


func _make_camera() -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "ChaseCamera"
	cam.set_script(load("res://src/vehicles/base/chase_camera.gd"))
	cam.transform = Transform3D(Basis.IDENTITY, Vector3(0, 2.5, 6))
	return cam


## A flat ground plane so the car has somewhere to land off the loop and props sit on
## solid ground. Not kit content -> a sibling of Authoring, not baked.
## pack() only serialises descendants whose owner is the scene root, and owner sticks
## only once a node is already inside that root — so add the body first, then populate.
func _add_ground(root: Node) -> void:
	var body := StaticBody3D.new()
	body.name = "Ground"
	_add(root, root, body)
	# Big enough to hold the loop, the canary props, and all showcase rows (which run to
	# ~Z SHOWCASE_Z0 + 5*SHOWCASE_DZ). Centred north of the origin to frame that content.
	var size := Vector3(120, 2, 190)
	var center := Vector3(0, -1, 55)
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	cs.position = center
	_add(root, body, cs)
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.42, 0.29)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = center
	_add(root, body, mi)


func _make_spawn() -> Marker3D:
	var spawn := Marker3D.new()
	spawn.name = "Spawn"
	spawn.set_script(load("res://src/levels/base/vehicle_spawn.gd"))
	spawn.set("vehicle_types", PackedStringArray(["car"]))
	# On the loop's south straight (0,0,1) -> world (0, .8, 8), facing +X along the road.
	spawn.transform = Transform3D(Basis.from_euler(Vector3(0, deg_to_rad(-90), 0)),
			Vector3(0, 0.8, CELL))
	return spawn


const WATER_POS := Vector3(-90, 0.5, 0)


## Temporary boat-test water body, west of the 120-wide ground plane so it never
## overlaps the road loop / props / scatter. A direct child of the level (never under
## Authoring — water is not bakeable kit content).
func _make_water() -> Area3D:
	var water := Area3D.new()
	water.name = "Water"
	water.set_script(load("res://src/water/water_surface.gd"))
	water.position = WATER_POS
	water.set("size", Vector2(40, 40))
	water.set("depth", 3.0)
	return water


func _make_boat_spawn() -> Marker3D:
	var spawn := Marker3D.new()
	spawn.name = "BoatSpawn"
	spawn.set_script(load("res://src/levels/base/vehicle_spawn.gd"))
	spawn.set("vehicle_types", PackedStringArray(["boat"]))
	spawn.set("is_water", true)
	spawn.transform = Transform3D(Basis.IDENTITY, WATER_POS + Vector3(0, 1.0, 0))
	return spawn


## A 3x3 perimeter loop centred on the origin (cells at i,k in {-1,0,1}, hole at 0,0):
## a tight bend at each corner, a straight on each edge. Orientation indices come from
## GridMap.get_orthogonal_index_from_basis so the Y-rotations are exact.
##
## The road/sidewalk on these tiles is texture-painted (one flat surface), so the correct
## default orientation can't be read from geometry — the six values below are set by eye.
## If the loop looks incoherent, adjust STRAIGHT_*_DEG / the four bend degrees and re-run.
const STRAIGHT_EW_DEG := 0     # horizontal edges (road runs east-west / along X)
const STRAIGHT_NS_DEG := 90    # vertical edges (road runs north-south / along Z)
const BEND_DEG := {            # per corner cell (x,z) -> Y-rotation of the bend
	# +180 from the first cut: the bend tile's painted road faces the opposite way, so
	# every corner was mirrored (hand-fixed in-editor, folded back in here).
	Vector2i(1, 1): 270, Vector2i(1, -1): 0, Vector2i(-1, -1): 90, Vector2i(-1, 1): 180,
}

func _make_road_loop() -> GridMap:
	var gm := GridMap.new()
	gm.name = "RoadLoop"
	gm.mesh_library = load(ROADS_MESHLIB)
	gm.cell_size = Vector3(CELL, 3.0, CELL)
	gm.cell_center_y = false

	var o := func(d: int) -> int:
		return gm.get_orthogonal_index_from_basis(Basis(Vector3.UP, deg_to_rad(d)))

	# straights on the four edges
	gm.set_cell_item(Vector3i(0, 0, 1), ID_STRAIGHT, o.call(STRAIGHT_EW_DEG))
	gm.set_cell_item(Vector3i(0, 0, -1), ID_STRAIGHT, o.call(STRAIGHT_EW_DEG))
	gm.set_cell_item(Vector3i(1, 0, 0), ID_STRAIGHT, o.call(STRAIGHT_NS_DEG))
	gm.set_cell_item(Vector3i(-1, 0, 0), ID_STRAIGHT, o.call(STRAIGHT_NS_DEG))
	# tight bends at the four corners
	for corner: Vector2i in BEND_DEG:
		gm.set_cell_item(Vector3i(corner.x, 0, corner.y), ID_BEND, o.call(BEND_DEG[corner]))
	return gm


## One prefab per collision mode, spread on the ground clear of the loop. The weld ramp
## sits just south of the loop so it can be driven onto.
func _add_prefabs(owner: Node, parent: Node) -> void:
	var poses := {
		"none": Vector3(28, 0, 0),
		"box": Vector3(-28, 0, 0),
		"hull": Vector3(26, 0, 22),
		"multiconvex": Vector3(-26, 0, 22),
		"weld": Vector3(0, 0, 28),
	}
	for mode: String in PREFABS:
		var inst := (load(PREFABS[mode]) as PackedScene).instantiate()
		inst.position = poses[mode]
		parent.add_child(inst)
		inst.owner = owner


## One labelled row per kit of evenly-sampled prefabs, for eyeballing scale. The prefabs go
## under Authoring (baked/CI-covered); the Label3D signposts go under a sibling node so they
## survive the bake (which frees the authoring subtree) and still show in play.
func _add_showcase(owner: Node, authoring: Node) -> void:
	var labels := Node3D.new()
	labels.name = "ShowcaseLabels"
	_add(owner, owner, labels)

	for row in SHOWCASE_KITS.size():
		var kit: String = SHOWCASE_KITS[row]
		var z := SHOWCASE_Z0 + row * SHOWCASE_DZ
		var names := _sample_prefabs(kit, SHOWCASE_N)
		var x0 := -0.5 * (names.size() - 1) * SHOWCASE_DX
		for i in names.size():
			var inst := (load(names[i]) as PackedScene).instantiate()
			inst.position = Vector3(x0 + i * SHOWCASE_DX, 0, z)
			authoring.add_child(inst)
			inst.owner = owner

		var label := Label3D.new()
		label.name = "Label_" + kit
		label.text = kit.to_upper()
		label.position = Vector3(x0 - SHOWCASE_DX, 4, z)
		label.pixel_size = 0.08
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.modulate = Color(1, 0.95, 0.6)
		_add(owner, labels, label)


const SCATTER_SEED := 20260711

## Two scatter regions on the east strip (LK5's permanent bake canary): trees above
## the MultiMesh threshold with collision, grass below it collision-off — so CI's
## baked smoke covers both scatter bake paths forever. The builder is the fixture's
## "Regenerate": it runs the pure placement and snaps to the known flat ground at
## y=0 (no editor, no physics), then stores the transforms — the baker only ever
## consumes stored data. No terrain in the fixture, so the default
## stored_ground_hash "" already matches.
func _add_scatter(owner: Node, authoring: Node) -> void:
	# 16x100 m at density 0.05 -> ~80 trees (>= the 64 MultiMesh threshold)
	_add(owner, authoring, _make_region("TreeScatter",
			"res://kit/prefabs/nature/tree_default.tscn", true,
			Vector3(50, 0, 45), Vector2(16, 100), 0.05, 2.5))
	# 10x20 m at density 0.1 -> ~20 grass tufts (merge path, zero physics)
	_add(owner, authoring, _make_region("GrassScatter",
			"res://kit/prefabs/nature/grass.tscn", false,
			Vector3(50, 0, -20), Vector2(10, 20), 0.1, 1.0))


func _make_region(region_name: String, prefab_path: String, collision: bool,
		pos: Vector3, size: Vector2, density: float, spacing: float) -> Node3D:
	var region := Node3D.new()
	region.name = region_name
	region.set_script(load("res://kit/helpers/scatter_region.gd"))
	region.position = pos
	region.set("box_size", size)
	region.set("density", density)
	region.set("min_spacing", spacing)
	region.set("placement_seed", SCATTER_SEED)
	var item: Resource = (load("res://kit/helpers/scatter_item.gd") as GDScript).new()
	item.set("prefab", load(prefab_path))
	item.set("collision", collision)
	var items: Array[ScatterItem] = [item]
	region.set("items", items)

	var placements: Array[PackedFloat32Array] = \
			ScatterRegion.generate_placements(region.call("build_params"))
	var stored: Array[PackedFloat32Array] = []
	var total := 0
	for flat in placements:
		var s := PackedFloat32Array()
		for j in flat.size() / 4:
			s.append_array(PackedFloat32Array([
					flat[j * 4], 0.0, flat[j * 4 + 1], flat[j * 4 + 2], flat[j * 4 + 3]]))
		stored.append(s)
		total += s.size() / 5
	region.set("stored_transforms", stored)
	print("scatter %s: %d instances" % [region_name, total])
	return region


## Evenly-spaced sample of a kit's sorted prefab .tscn paths (indices 0 .. n-1 spread across
## the list), so a row shows the kit's variety rather than the alphabetical head.
func _sample_prefabs(kit: String, k: int) -> Array[String]:
	var dir := "res://kit/prefabs/" + kit
	var files: Array[String] = []
	var da := DirAccess.open(dir)
	if da != null:
		for f in da.get_files():
			# low-detail-* are the horizon-scale skyline set (scale_mul 10 -> ~120): far too
			# big for this small gallery, they belong on the island's horizon, so skip them.
			if f.ends_with(".tscn") and not f.begins_with("low-detail-"):
				files.append(dir.path_join(f))
	files.sort()
	var out: Array[String] = []
	var n := files.size()
	if n == 0:
		return out
	for i in mini(k, n):
		var idx := 0 if k <= 1 else int(round(float(i) * (n - 1) / (k - 1)))
		out.append(files[idx])
	return out
