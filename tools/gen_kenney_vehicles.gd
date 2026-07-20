extends Node
## One-shot generator for the Kenney car-kit vehicle variants (CC0). For each variant it
## writes src/vehicles/kenney/<variant>.tscn + <variant>_spec.tres:
##   - a BaseVehicle (car/truck) or TractorVehicle (tractor) RigidBody3D root,
##   - the GLB body instanced + centred at the kit-wide scale, a BoxShape3D from its AABB,
##   - a shared Lamps subtree (same node names/paths as car.tscn) sized to the body,
##   - a spec whose feel starts from the family baseline + per-variant overrides; wheels
##     come from spec.wheel_scene (the shared Kenney wheel wrapper) at runtime.
##
## brake_torque / handbrake_torque are DERIVED from each variant's drivetrain so the §6
## force hierarchy (brake > peak drive per wheel > handbrake, handbrake capped low) holds
## by construction for every generated spec — never hand-tuned.
##
## GAME-MODE tool scene, NOT --script: base_vehicle.gd / tractor.gd reference the
## InputRouter / Bridge autoloads, which only resolve with autoloads registered. Run:
##   godot --headless --path . res://tools/gen_kenney_vehicles.tscn
## Deterministic + destructive-by-run. Delete tools/measure_kenney.gd after; this stays as
## the regen path (rerun after a scale/feel change, then re-bake).

const OUT_DIR := "res://src/vehicles/kenney"
const MODELS := OUT_DIR + "/models"
const BASE_SCRIPT := "res://src/vehicles/base/base_vehicle.gd"
const TRACTOR_SCRIPT := "res://src/vehicles/tractor/tractor.gd"

const KIT_SCALE := 1.2
const WHEEL_RADIUS := 0.36  ## physics radius, all four corners (RayWheel is single-radius)
const GRAVITY := 9.8
const MIN_CLEARANCE := 0.12  ## m the collision hull floor is held above the wheel-contact plane
const WHEEL_BAND := 0.4   ## m z-window (body space) the body half-width is measured over per axle

## Wheel visuals per model: the radius-normalized scene, the rendered radius, and the tread
## half-width AT that radius (native half-width / native radius * rendered radius) — the flush-X
## rule below places the wheel's outer face at the body side, so it must match the model.
const WHEEL_DEFAULT := {"scene": OUT_DIR + "/wheel.tscn", "radius": WHEEL_RADIUS, "half": 0.240}
const WHEEL_TRUCK := {"scene": OUT_DIR + "/wheel-truck.tscn", "radius": WHEEL_RADIUS, "half": 0.210}
## Tractor axles differ VISUALLY only (0.30 / 0.45 straddling the 0.36 physics radius).
const WHEEL_TRACTOR_FRONT := {
	"scene": OUT_DIR + "/wheel-tractor-front.tscn", "radius": 0.30, "half": 0.206}
const WHEEL_TRACTOR_REAR := {
	"scene": OUT_DIR + "/wheel-tractor-rear.tscn", "radius": 0.45, "half": 0.276}

# Not const: Vector2 / NodePath / Array literals aren't constant expressions in GDScript.
var _grip_curve := PackedVector2Array([
		Vector2(0, 0), Vector2(0.12, 1), Vector2(0.4, 0.9), Vector2(1, 0.8)])
var _lamp_paths := {
	"headlight_paths": [NodePath("Lamps/HeadlightL"), NodePath("Lamps/HeadlightR")],
	"brake_lamp_paths": [NodePath("Lamps/BrakeLampL"), NodePath("Lamps/BrakeLampR")],
	"turn_left_paths": [NodePath("Lamps/TurnLF"), NodePath("Lamps/TurnLR")],
	"turn_right_paths": [NodePath("Lamps/TurnRF"), NodePath("Lamps/TurnRR")],
}
var _shape_report: Array = []  ## per-variant collision shape kind + hull vertex count

# --- family baselines (spec fields; brake/handbrake are derived, not listed) -----------
const CAR_BASE := {
	"mass": 1150.0, "com_y": 0.20, "spring_rate": 22000.0, "damper_bump": 1800.0,
	"damper_rebound": 2400.0, "max_suspension_force": 30000.0, "rest_length": 0.28,
	"wheel_inertia": 1.2, "driven_front": true, "driven_rear": true,
	"mu_long": 1.05, "mu_lat": 1.1, "handbrake_grip": 0.45,
	"torque_curve": [900, 150, 2000, 235, 3200, 285, 4800, 290, 6000, 255, 6800, 100],
	"idle_rpm": 900.0, "redline_rpm": 6800.0,
	"gear_ratios": [3.5, 2.2, 1.55, 1.18, 0.88, 0.66], "reverse_ratio": 2.2,
	"final_drive": 3.9, "efficiency": 0.9, "shift_up_rpm": 5600.0, "shift_down_rpm": 2200.0,
	"max_steer_deg": 38.0, "steer_speed": 7.0,
}
const TRUCK_BASE := {
	"mass": 4000.0, "com_y": 0.30, "spring_rate": 65000.0, "damper_bump": 5000.0,
	"damper_rebound": 7000.0, "max_suspension_force": 90000.0, "rest_length": 0.32,
	"wheel_inertia": 3.0, "driven_front": false, "driven_rear": true,
	"mu_long": 1.0, "mu_lat": 0.95, "handbrake_grip": 1.0,
	"torque_curve": [700, 400, 1200, 650, 1800, 800, 2400, 780, 2800, 600, 3200, 200],
	"idle_rpm": 700.0, "redline_rpm": 3200.0,
	"gear_ratios": [6.5, 3.7, 2.4, 1.6, 1.2, 1], "reverse_ratio": 6.0,
	"final_drive": 4.5, "efficiency": 0.9, "shift_up_rpm": 2600.0, "shift_down_rpm": 1200.0,
	"max_steer_deg": 26.0, "steer_speed": 2.0,
}
const TRACTOR_BASE := {
	"mass": 4200.0, "com_y": 0.35, "spring_rate": 70000.0, "damper_bump": 6000.0,
	"damper_rebound": 8000.0, "max_suspension_force": 110000.0, "rest_length": 0.35,
	"wheel_inertia": 4.0, "driven_front": false, "driven_rear": true,
	"mu_long": 1.0, "mu_lat": 0.95, "handbrake_grip": 1.0,
	"torque_curve": [800, 550, 1200, 680, 1600, 700, 2000, 640, 2400, 480, 2600, 300],
	"idle_rpm": 800.0, "redline_rpm": 2600.0,
	"gear_ratios": [7, 4.2, 2.8, 1.9, 1.4, 1.1], "reverse_ratio": 7.0,
	"final_drive": 5.5, "efficiency": 0.9, "shift_up_rpm": 2200.0, "shift_down_rpm": 1000.0,
	"max_steer_deg": 38.0, "steer_speed": 1.8,
}

# variant id -> { base, family, tractor?, torque_mul?, <spec field overrides...> }
const VARIANTS := {
	# car family
	"sedan": {"family": "car"},
	"sedan-sports": {"family": "car", "mass": 1050.0, "torque_mul": 1.12, "final_drive": 4.1, "max_steer_deg": 40.0},
	"hatchback-sports": {"family": "car", "mass": 1000.0, "torque_mul": 1.10, "final_drive": 4.2, "max_steer_deg": 42.0},
	"suv": {"family": "car", "mass": 1500.0, "torque_mul": 1.05, "mu_lat": 1.0, "max_steer_deg": 34.0},
	"suv-luxury": {"family": "car", "mass": 1600.0, "torque_mul": 1.10, "mu_lat": 1.0, "max_steer_deg": 33.0},
	"taxi": {"family": "car", "mass": 1250.0},
	"police": {"family": "car", "mass": 1300.0, "torque_mul": 1.18, "final_drive": 4.0, "max_steer_deg": 40.0},
	# open-wheelers keep the default rim and stand proud of the slim body (F1 track width)
	"race": {"family": "car", "mass": 900.0, "torque_mul": 1.35, "final_drive": 4.2, "mu_long": 1.2, "mu_lat": 1.3, "max_steer_deg": 40.0, "handbrake_grip": 0.5, "wheels": [WHEEL_DEFAULT, WHEEL_DEFAULT], "wheel_x_out": 0.12},
	"race-future": {"family": "car", "mass": 850.0, "torque_mul": 1.42, "final_drive": 4.2, "mu_long": 1.25, "mu_lat": 1.35, "max_steer_deg": 42.0, "handbrake_grip": 0.5, "wheels": [WHEEL_DEFAULT, WHEEL_DEFAULT], "wheel_x_out": 0.12},
	"van": {"family": "car", "mass": 1600.0, "max_steer_deg": 32.0},
	"pickup": {"family": "car", "mass": 1550.0, "torque_mul": 1.05, "max_steer_deg": 33.0},
	"pickup-flat": {"family": "car", "mass": 1500.0, "torque_mul": 1.05, "max_steer_deg": 33.0},
	# truck family (J1939)
	"delivery": {"family": "truck", "mass": 4200.0},
	"delivery-flat": {"family": "truck", "mass": 4000.0},
	"firetruck": {"family": "truck", "mass": 7500.0, "torque_mul": 1.3, "max_steer_deg": 22.0, "steer_speed": 1.6},
	"garbage-truck": {"family": "truck", "mass": 8000.0, "torque_mul": 1.3, "max_steer_deg": 22.0, "steer_speed": 1.6},
	"ambulance": {"family": "truck", "mass": 4800.0, "torque_mul": 1.1, "max_steer_deg": 24.0},
	# tractor family (ISOBUS)
	"tractor-kenney": {"family": "tractor", "tractor": true, "mass": 4000.0},
	"tractor-police": {"family": "tractor", "tractor": true, "mass": 4200.0, "torque_mul": 1.1},
	"tractor-shovel": {"family": "tractor", "tractor": true, "mass": 5000.0, "torque_mul": 1.15, "max_steer_deg": 34.0},
}

const BASELINES := {"car": CAR_BASE, "truck": TRUCK_BASE, "tractor": TRACTOR_BASE}

## family -> [front wheel, rear wheel]; a variant may override with "wheels".
const FAMILY_WHEELS := {
	"car": [WHEEL_TRUCK, WHEEL_TRUCK],
	"truck": [WHEEL_TRUCK, WHEEL_TRUCK],
	"tractor": [WHEEL_TRACTOR_FRONT, WHEEL_TRACTOR_REAR],
}


func _ready() -> void:
	var base_script := load(BASE_SCRIPT)
	var tractor_script := load(TRACTOR_SCRIPT)
	var ok := 0
	for variant: String in VARIANTS:
		var ov: Dictionary = VARIANTS[variant]
		var family := String(ov["family"])
		var wheels: Array = ov.get("wheels", FAMILY_WHEELS[family])
		var geo := _analyze(MODELS.path_join(variant + ".glb"), wheels)
		if geo.is_empty():
			continue
		var spec := _build_spec(family, ov, geo, wheels)
		var spec_path := OUT_DIR.path_join(variant + "_spec.tres")
		if ResourceSaver.save(spec, spec_path) != OK:
			push_error("failed to save " + spec_path)
			continue
		var scene_script: Variant = tractor_script if ov.get("tractor", false) else base_script
		var scene := _build_scene(variant, scene_script, load(spec_path), geo)
		var scene_path := OUT_DIR.path_join(variant + ".tscn")
		if _save_scene_stable(scene, scene_path) != OK:
			push_error("failed to save " + scene_path)
			continue
		ok += 1
	print("gen_kenney_vehicles: wrote %d/%d variants" % [ok, VARIANTS.size()])
	print("collision shapes: ", ", ".join(_shape_report))
	get_tree().quit(0 if ok == VARIANTS.size() else 1)


# --- spec ------------------------------------------------------------------------------

func _build_spec(family: String, ov: Dictionary, geo: Dictionary, wheels: Array) -> VehicleSpec:
	var b: Dictionary = BASELINES[family]
	var get_f := func(key: String) -> float: return float(ov.get(key, b[key]))

	var spec := VehicleSpec.new()
	spec.mass = get_f.call("mass")
	spec.center_of_mass = Vector3(0, float(b["com_y"]), 0)
	spec.wheel_radius = WHEEL_RADIUS
	spec.wheel_inertia = float(b["wheel_inertia"])
	# Wheel visuals: one scene per axle when they differ (tractor), plus the rendered radii.
	# Physics stays single-radius — spec.wheel_radius above is the only radius RayWheel uses.
	var front_wheel: Dictionary = wheels[0]
	var rear_wheel: Dictionary = wheels[1]
	spec.wheel_scene = load(String(front_wheel["scene"])) as PackedScene
	if String(rear_wheel["scene"]) != String(front_wheel["scene"]):
		spec.wheel_scene_rear = load(String(rear_wheel["scene"])) as PackedScene
	var front_r := float(front_wheel["radius"])
	var rear_r := float(rear_wheel["radius"])
	# Left at 0 (= wheel_radius) only when both axles render at the physics radius; otherwise
	# both are set explicitly, since the rear field falls back to the front one when unset.
	if front_r != WHEEL_RADIUS or rear_r != WHEEL_RADIUS:
		spec.wheel_visual_radius = front_r
		spec.wheel_visual_radius_rear = rear_r
	spec.driven_front = bool(b["driven_front"])
	spec.driven_rear = bool(b["driven_rear"])
	spec.rest_length = float(b["rest_length"])
	spec.spring_rate = float(b["spring_rate"])
	spec.damper_bump = float(b["damper_bump"])
	spec.damper_rebound = float(b["damper_rebound"])
	spec.max_suspension_force = float(b["max_suspension_force"])
	spec.grip_curve = _grip_curve.duplicate()
	spec.mu_long = get_f.call("mu_long")
	spec.mu_lat = get_f.call("mu_lat")
	spec.handbrake_grip = get_f.call("handbrake_grip")

	var torque_mul := float(ov.get("torque_mul", 1.0))
	spec.torque_curve = _scaled_curve(b["torque_curve"], torque_mul)
	spec.idle_rpm = float(b["idle_rpm"])
	spec.redline_rpm = float(b["redline_rpm"])
	spec.gear_ratios = PackedFloat32Array(b["gear_ratios"])
	spec.reverse_ratio = float(b["reverse_ratio"])
	spec.final_drive = get_f.call("final_drive")
	spec.efficiency = float(b["efficiency"])
	spec.shift_up_rpm = float(b["shift_up_rpm"])
	spec.shift_down_rpm = float(b["shift_down_rpm"])
	spec.max_steer_deg = get_f.call("max_steer_deg")
	spec.steer_speed = get_f.call("steer_speed")

	spec.wheel_positions = _wheel_positions(geo, spec, float(ov.get("wheel_x_out", 0.0)))
	_derive_brakes(spec)

	spec.headlight_paths.assign(_lamp_paths["headlight_paths"])
	spec.brake_lamp_paths.assign(_lamp_paths["brake_lamp_paths"])
	spec.turn_left_paths.assign(_lamp_paths["turn_left_paths"])
	spec.turn_right_paths.assign(_lamp_paths["turn_right_paths"])
	return spec


## FL, FR, RL, RR hub anchors placed at the Kenney model's own wheel positions (x/z from
## each `wheel-*` node, transformed into body space), so the RayWheel visuals sit exactly in
## the wheel wells. Anchor Y is uniform across the four so the body rests level: at spring
## equilibrium the visual wheel centre lands at WHEEL_RADIUS above ground (ground at body
## y = 0, the Kenney wheel-contact plane), i.e. wheels flush with the chassis as designed.
## `x_out` pushes each corner further outboard (open-wheelers): it widens the real track, so
## suspension and visual move together.
func _wheel_positions(geo: Dictionary, spec: VehicleSpec, x_out: float) -> PackedVector3Array:
	var corner_mass := spec.mass / 4.0
	var comp := clampf(corner_mass * GRAVITY / spec.spring_rate, 0.0, spec.rest_length * 0.8)
	var y := WHEEL_RADIUS + spec.rest_length - comp
	var fl := Vector3.ZERO
	var fr := Vector3.ZERO
	var rl := Vector3.ZERO
	var rr := Vector3.ZERO
	for xz: Vector2 in geo["wheel_xz"]:
		var p := Vector3(xz.x + signf(xz.x) * x_out, y, xz.y)  # body space (front = -Z, right = +X)
		if p.z < 0.0:
			if p.x < 0.0: fl = p
			else: fr = p
		else:
			if p.x < 0.0: rl = p
			else: rr = p
	return PackedVector3Array([fl, fr, rl, rr])


## Derive brake/handbrake from the drivetrain so the §6 hierarchy always holds:
## total_brake (x4) = 1.4 * peak drive torque; total_handbrake (x2) = 1.5 * launch torque
## at idle+25% throttle (strictly between the 25% and 50% launch brackets the test checks).
func _derive_brakes(spec: VehicleSpec) -> void:
	var peak_engine := 0.0
	var idle_engine := VehicleSpec.sample_curve(spec.torque_curve, spec.idle_rpm)
	for i in spec.torque_curve.size():
		peak_engine = maxf(peak_engine, spec.torque_curve[i].y)
	var ratio1 := spec.gear_ratios[0] * spec.final_drive
	var max_drive := peak_engine * ratio1 * spec.efficiency
	var launch_25 := idle_engine * 0.25 * ratio1 * spec.efficiency
	spec.brake_torque = ceilf(max_drive * 0.35)
	spec.handbrake_torque = maxf(1.0, roundf(launch_25 * 0.75))


func _scaled_curve(flat: Array, mul: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	@warning_ignore("integer_division")
	for i in flat.size() / 2:
		out.append(Vector2(float(flat[i * 2]), float(flat[i * 2 + 1]) * mul))
	return out


# --- scene -----------------------------------------------------------------------------

func _build_scene(variant: String, scene_script: Variant, spec: VehicleSpec, geo: Dictionary) -> PackedScene:
	var box_aabb: AABB = geo["box"]   # wheel-less body, already in body space (front = -Z)

	var root := RigidBody3D.new()
	root.name = variant.to_pascal_case()
	root.set_script(scene_script)
	root.set("spec", spec)

	# Collision: one convex hull hugging the wheel-less body (valid on a moving RigidBody3D,
	# unlike trimesh; hugs sloped hoods/cabs far better than a box for ~free). Its verts are
	# clamped to >= MIN_CLEARANCE so the hull can't hang below the chassis and fight the
	# suspension rays. Falls back to a box if the hull comes out degenerate.
	var col := _body_shape(variant, geo)
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	cs.shape = col["shape"]
	cs.position = col["pos"]
	_add(root, root, cs)

	# Body model: instance the GLB, then steal its non-wheel children into a Model node under
	# the body transform (180deg Y flip so Kenney's +Z front faces this project's -Z, + kit
	# scale + x/z centring). The GLB's own wheel-* meshes are dropped with the freed instance.
	var glb := (load(MODELS.path_join(variant + ".glb")) as PackedScene).instantiate()
	var model := Node3D.new()
	model.name = "Model"
	model.transform = geo["xform"]
	_add(root, root, model)
	for child in glb.get_children():
		var lname := String(child.name).to_lower()
		if lname.begins_with("wheel") and (lname.ends_with("left") or lname.ends_with("right")):
			continue  # a driven corner wheel — RayWheel provides these
		glb.remove_child(child)
		model.add_child(child)
		_own(child, root)
	glb.free()

	_add_lamps(root, box_aabb)

	var packed := PackedScene.new()
	packed.pack(root)
	root.free()
	return packed


## Set owner recursively so pack() serialises the stolen GLB subtree into the vehicle scene.
func _own(node: Node, scene_owner: Node) -> void:
	node.owner = scene_owner
	for c in node.get_children():
		_own(c, scene_owner)


## Convex hull of the wheel-less body (verts clamped up to MIN_CLEARANCE for a flat floor
## above the wheel-contact plane), simplified by QuickHull. Box fallback if degenerate.
## Returns {shape, pos}. Verts already sit in body space, so pos is the origin for a hull.
func _body_shape(variant: String, geo: Dictionary) -> Dictionary:
	var xform: Transform3D = geo["xform"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 0
	for pair: Array in geo["body_pairs"]:
		var full := xform * (pair[1] as Transform3D)
		for v in (pair[0] as Mesh).get_faces():
			var p := full * v
			p.y = maxf(p.y, MIN_CLEARANCE)
			st.add_vertex(p)
			n += 1
	if n >= 12:
		var hull := (st.commit() as ArrayMesh).create_convex_shape(true, true)
		if hull != null and hull.points.size() >= 4:
			_shape_report.append("%s=hull(%d)" % [variant, hull.points.size()])
			return {"shape": hull, "pos": Vector3.ZERO}
	push_warning("%s: convex hull degenerate, falling back to box" % variant)
	_shape_report.append("%s=box" % variant)
	return _box_shape(geo)


func _box_shape(geo: Dictionary) -> Dictionary:
	var box_aabb: AABB = geo["box"]
	var box_min_y := maxf(box_aabb.position.y, MIN_CLEARANCE)
	var box_h := box_aabb.position.y + box_aabb.size.y - box_min_y
	var ctr := box_aabb.get_center()
	var box := BoxShape3D.new()
	box.size = Vector3(box_aabb.size.x, box_h, box_aabb.size.z)
	return {"shape": box, "pos": Vector3(ctr.x, box_min_y + box_h * 0.5, ctr.z)}


## Lamps subtree matching car.tscn's names/paths (LampSet needs zero changes). Headlights
## are SpotLight3D at the front face (-Z, they emit down local -Z = forward); brake/turn
## lenses are small BoxMesh at the rear/corners. Placed off the wheel-less body box —
## cosmetic later.
func _add_lamps(root: RigidBody3D, box: AABB) -> void:
	var lamps := Node3D.new()
	lamps.name = "Lamps"
	_add(root, root, lamps)

	var ctr := box.get_center()
	var hw := box.size.x * 0.5
	var front := ctr.z - box.size.z * 0.5 * 0.98
	var rear := ctr.z + box.size.z * 0.5 * 0.98
	var cy := ctr.y
	var low := ctr.y - box.size.y * 0.15
	var lens := BoxMesh.new()
	lens.size = Vector3(0.2, 0.12, 0.06)

	_add(root, lamps, _spot("HeadlightL", Vector3(-hw * 0.6, cy, front)))
	_add(root, lamps, _spot("HeadlightR", Vector3(hw * 0.6, cy, front)))
	_add(root, lamps, _lens("BrakeLampL", Vector3(-hw * 0.62, cy, rear), lens))
	_add(root, lamps, _lens("BrakeLampR", Vector3(hw * 0.62, cy, rear), lens))
	_add(root, lamps, _lens("TurnLF", Vector3(-hw * 0.86, low, front), lens))
	_add(root, lamps, _lens("TurnLR", Vector3(-hw * 0.86, low, rear), lens))
	_add(root, lamps, _lens("TurnRF", Vector3(hw * 0.86, low, front), lens))
	_add(root, lamps, _lens("TurnRR", Vector3(hw * 0.86, low, rear), lens))


func _spot(spot_name: String, pos: Vector3) -> SpotLight3D:
	var s := SpotLight3D.new()
	s.name = spot_name
	s.position = pos
	s.visible = false
	s.light_energy = 0.0
	s.spot_range = 28.0
	s.spot_angle = 38.0
	return s


func _lens(lens_name: String, pos: Vector3, mesh: BoxMesh) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = lens_name
	mi.position = pos
	mi.mesh = mesh
	return mi


func _add(scene_owner: Node, parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = scene_owner


# --- geometry --------------------------------------------------------------------------

## Analyse a Kenney vehicle GLB into geometry the spec/scene builders share:
##   xform:     body-model transform — 180deg Y flip (Kenney +Z front -> project -Z) + kit
##              scale + x/z centring on the body, native y = 0 kept (the wheel-contact plane)
##   wheel_xz:  the four wheels' body-space (x, z). z is the Kenney wheel z; x is the flush
##              rule below (never inset from the authored position).
##   body_pairs: [Mesh, native transform] for the wheel-less body (collision hull source)
##   box:       body_aabb transformed by xform (lamp placement + hull fallback)
func _analyze(path: String, wheel_models: Array) -> Dictionary:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("cannot load " + path)
		return {}
	var inst := scene.instantiate()
	var body_pairs: Array = []
	var wheels: Array = []
	_collect_body_wheels(inst, Transform3D.IDENTITY, body_pairs, wheels)
	inst.free()
	if body_pairs.is_empty() or wheels.size() != 4:
		push_error("%s: body meshes=%d, wheel nodes=%d (expected 4)" %
				[path, body_pairs.size(), wheels.size()])
		return {}

	# Native body verts + AABB (AABB centre drives the x/z centring in xform).
	var bverts := PackedVector3Array()
	var body_aabb := AABB()
	var first := true
	for pair: Array in body_pairs:
		for v in (pair[0] as Mesh).get_faces():
			var wpt: Vector3 = (pair[1] as Transform3D) * v
			bverts.append(wpt)
			if first:
				body_aabb = AABB(wpt, Vector3.ZERO)
				first = false
			else:
				body_aabb = body_aabb.expand(wpt)

	var c := body_aabb.get_center()
	var basis := Basis(Vector3.UP, PI).scaled(Vector3.ONE * KIT_SCALE)
	var xform := Transform3D(basis, Vector3(KIT_SCALE * c.x, 0.0, KIT_SCALE * c.z))

	# Per-wheel flush X: place the wheel's OUTER face at the body side measured in a z-band
	# around that wheel (fenders differ front/rear), i.e. |x| = body_half - wheel_half. The
	# tread half-width is per axle, since the two axles may wear different models (tractor).
	# Never pull a wheel inward from where Kenney put it (open-wheel cars sit proud of a slim
	# body): take max(flush, authored). The embedded wheel z is kept as-is.
	var wheel_xz: Array = []
	for w: Vector3 in wheels:
		var tw: Vector3 = xform * w
		var body_half := 0.0
		for v in bverts:
			var tv: Vector3 = xform * v
			if absf(tv.z - tw.z) < WHEEL_BAND:
				body_half = maxf(body_half, absf(tv.x))
		var half: float = wheel_models[0 if tw.z < 0.0 else 1]["half"]
		var flush := body_half - half
		var x := signf(tw.x) * maxf(flush, absf(tw.x))
		wheel_xz.append(Vector2(x, tw.z))

	return {"xform": xform, "wheel_xz": wheel_xz, "body_pairs": body_pairs,
			"box": _xform_aabb(body_aabb, xform)}


## Collect body mesh pairs and wheel-node centres. The four driven wheels are the corner
## nodes `wheel-{front,back}-{left,right}`; a bare `wheel-back` etc. is the SUV's spare tyre —
## real body geometry, so it is NOT treated as a wheel (kept in the model, no RayWheel).
func _collect_body_wheels(node: Node, xform: Transform3D, body_pairs: Array, wheels: Array) -> void:
	var nx := xform
	if node is Node3D:
		nx = xform * (node as Node3D).transform
	var lname := String(node.name).to_lower()
	if lname.begins_with("wheel") and (lname.ends_with("left") or lname.ends_with("right")):
		wheels.append(nx.origin)
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		body_pairs.append([(node as MeshInstance3D).mesh, nx])
	for child in node.get_children():
		_collect_body_wheels(child, nx, body_pairs, wheels)


## AABB of `aabb` after `xform` (8 corners; xform is rotation+uniform-scale+translation).
func _xform_aabb(aabb: AABB, xform: Transform3D) -> AABB:
	var out := AABB(xform * aabb.position, Vector3.ZERO)
	for i in 8:
		out = out.expand(xform * (aabb.position + Vector3(
				aabb.size.x if (i & 1) else 0.0,
				aabb.size.y if (i & 2) else 0.0,
				aabb.size.z if (i & 4) else 0.0)))
	return out


# --- stable save (strip churny per-node unique_id, like gen_kit_assets) ----------------

var _unique_id_re := RegEx.create_from_string(" unique_id=\\d+")


func _save_scene_stable(packed: PackedScene, path: String) -> Error:
	var before := FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""
	var err := ResourceSaver.save(packed, path)
	if err != OK or before.is_empty():
		return err
	var after := FileAccess.get_file_as_string(path)
	if after != before and _unique_id_re.sub(after, "", true) == _unique_id_re.sub(before, "", true):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(before)
	return OK
