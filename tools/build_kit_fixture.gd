extends Node
## One-shot builder for the permanent CI bake fixture src/levels/dev/kit_fixture.tscn
## (level_kit_plan.md §4 LK1): a minimal level on the re-derived lattice — a small road
## loop from the roads palette (scale-verification), one prefab of each collision mode, a
## weld ramp, and a car spawn — all under an AuthoringRoot so the baker/CI cover it.
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

	var authoring := Node3D.new()
	authoring.name = "Authoring"
	authoring.set_script(load("res://kit/helpers/authoring_root.gd"))
	_add(root, root, authoring)
	_add(root, authoring, _make_road_loop())
	_add_prefabs(root, authoring)

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
	var size := Vector3(80, 2, 80)
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.name = "Shape"
	cs.shape = shape
	cs.position = Vector3(0, -1, 0)
	_add(root, body, cs)
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.42, 0.29)
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = Vector3(0, -1, 0)
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
	Vector2i(1, 1): 90, Vector2i(1, -1): 180, Vector2i(-1, -1): 270, Vector2i(-1, 1): 0,
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
