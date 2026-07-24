class_name Level
extends Node3D
## Base script for every playable level. A level scene is
## self-contained: static geometry, VehicleSpawn markers, a WorldEnvironment, a
## ChaseCamera, and a LevelInfo resource. This script composes them at load time —
## it instances the default vehicle at a matching spawn, points the camera at it,
## and handles respawn. Vehicles/levels/UI stay independent scenes.

## Emitted after the active vehicle is (re)spawned — at load and on a garage/cycle swap —
## so the shell can rebind the dashboard/bridge to the new vehicle FAMILY.
signal vehicle_changed(type: String)

@export var info: LevelInfo
## The chase camera to follow the active vehicle. Optional; a level may omit it.
@export var camera: ChaseCamera

## Night preset: a dim bluish sun + low
## ambient. The 'day_night' action toggles between the scene-authored day values
## (captured at load) and these — a level convenience, not a bridge signal.
const NIGHT_SUN_ENERGY := 0.12
const NIGHT_SUN_COLOR := Color(0.55, 0.62, 0.85)
const NIGHT_AMBIENT_ENERGY := 0.12
const NIGHT_FOG_COLOR := Color(0.05, 0.07, 0.13)
const NIGHT_SKY_ENERGY := 0.05

var vehicle: BaseVehicle

var _sun: DirectionalLight3D
var _env: Environment
var _is_night := false
var _day_sun_energy := 1.0
var _day_sun_color := Color.WHITE
var _day_ambient_energy := 1.0
var _day_fog_color := Color.WHITE
var _day_sky_energy := 1.0


func _ready() -> void:
	if info == null:
		info = LevelInfo.new()
	if camera == null:
		# Fall back to the first ChaseCamera in the level so a scene that only has
		# the node (no explicit `camera` wire) still follows the vehicle.
		for node in find_children("*", "ChaseCamera", true, false):
			camera = node as ChaseCamera
			break
	# GameState is fetched by path, not by autoload identifier: the CLI bake tools
	# (--script mode) load level scenes headless, where autoload
	# globals don't resolve at compile time. Runtime behaviour is identical.
	_game_state().current_level = scene_file_path
	_setup_baked()
	_capture_day_night()
	_spawn_vehicle(info.default_vehicle)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("respawn") and vehicle != null:
		vehicle.respawn()
	elif event.is_action_pressed("day_night"):
		_toggle_day_night()
	elif event.is_action_pressed("camera_view"):
		cycle_camera()


## Advance the chase camera to its next view (C key / touch VIEW button).
func cycle_camera() -> void:
	if camera != null:
		camera.cycle()


## Swap kit authoring content for the baked scene when one exists.
## The AuthoringRoot subtree (GridMap palettes + KitPiece prefabs) is the bake
## tool's INPUT: with a bake present it is freed at load (and export strips it from
## shipped builds entirely); without one the level plays the authoring content
## directly — fine for dev iteration, but per-piece collision means seams are
## possible until the level is baked. Bake output sits next to the level scene by
## convention: <level>.baked.scn (see kit/bake/level_baker.gd).
func _setup_baked() -> void:
	if scene_file_path.is_empty():
		return
	var baked_path := scene_file_path.get_basename() + ".baked.scn"
	if not ResourceLoader.exists(baked_path):
		return
	var authoring := _find_authoring(self)
	add_child((load(baked_path) as PackedScene).instantiate())
	if authoring != null:
		authoring.queue_free()


## See the note in _ready: bare `GameState` would fail to compile under the CLI
## bake tools. Only called from inside the tree, where the autoload exists.
func _game_state() -> Node:
	return get_node("/root/GameState")


## AuthoringRoot is detected by its duck-typing marker (same contract the baker and
## the export-strip plugin use), so this file never depends on kit/ scripts.
static func _find_authoring(node: Node) -> Node:
	if node.has_method("is_carlito_authoring"):
		return node
	for child in node.get_children():
		var found := _find_authoring(child)
		if found != null:
			return found
	return null


## Grab the level's sun + environment and remember the authored (day) lighting so the
## night toggle is reversible. Both are optional — a level may omit either.
func _capture_day_night() -> void:
	for node in find_children("*", "DirectionalLight3D", true, false):
		_sun = node as DirectionalLight3D
		break
	for node in find_children("*", "WorldEnvironment", true, false):
		var we := node as WorldEnvironment
		if we.environment != null:
			# Levels share one saved Environment resource; night-mode mutations must
			# stay per-level, so work on a runtime copy.
			we.environment = we.environment.duplicate(true)
		_env = we.environment
		break
	if _sun != null:
		_day_sun_energy = _sun.light_energy
		_day_sun_color = _sun.light_color
	if _env != null:
		_day_ambient_energy = _env.ambient_light_energy
		_day_fog_color = _env.fog_light_color
		_day_sky_energy = _env.background_energy_multiplier


func _toggle_day_night() -> void:
	_is_night = not _is_night
	if _sun != null:
		_sun.light_energy = NIGHT_SUN_ENERGY if _is_night else _day_sun_energy
		_sun.light_color = NIGHT_SUN_COLOR if _is_night else _day_sun_color
	if _env != null:
		_env.ambient_light_energy = NIGHT_AMBIENT_ENERGY if _is_night else _day_ambient_energy
		_env.fog_light_color = NIGHT_FOG_COLOR if _is_night else _day_fog_color
		_env.background_energy_multiplier = NIGHT_SKY_ENERGY if _is_night else _day_sky_energy


## Respawn the player as `variant` at a matching spawn marker (garage / V-cycle).
## Ignores unknown/disallowed variants so a bad choice can't break the level.
func set_vehicle(variant: String) -> void:
	if not info.allows(variant):
		push_error("Level: vehicle variant '%s' not allowed here" % variant)
		return
	_spawn_vehicle(variant)


## Instance `variant` at a spawn that accepts its FAMILY, replacing any current vehicle,
## and re-aim the camera. Used at load and by set_vehicle. The family (not the variant) is
## what the bridge/dashboard/spawn filters key off, so it goes into GameState.current_vehicle.
func _spawn_vehicle(variant: String) -> void:
	var scene_path := VehicleCatalog.scene_of(variant)
	if scene_path.is_empty():
		push_error("Level: no scene registered for vehicle variant '%s'" % variant)
		return
	var family := VehicleCatalog.family_of(variant)
	# The train is rail-guided: it ignores VehicleSpawn markers and self-places on a closed
	# rail loop in its own _ready (Phase 4 adds random-loop choice + garage gating on top).
	var is_train := family == "train"
	var spawn: VehicleSpawn = null
	if is_train:
		if _find_closed_rail() == null:
			push_error("Level: vehicle family 'train' needs a closed rail loop here")
			return
	else:
		spawn = _pick_spawn(family)
		if spawn == null:
			push_error("Level: no spawn marker accepts vehicle family '%s'" % family)
			return

	if vehicle != null:
		vehicle.queue_free()

	vehicle = (load(scene_path) as PackedScene).instantiate()
	add_child(vehicle)  # triggers the vehicle's _ready — the train places its consist here
	if spawn != null:
		vehicle.global_transform = spawn.global_transform
		vehicle.spawn_transform = spawn.global_transform
		vehicle.reset_physics_interpolation()
	_game_state().current_vehicle = family
	_game_state().current_variant = variant

	if camera != null:
		camera.target = vehicle.get_camera_target()
		if not vehicle.respawned.is_connected(camera.snap):
			vehicle.respawned.connect(camera.snap)
		camera.snap.call_deferred()

	vehicle_changed.emit(family)


## First VehicleSpawn under this level that accepts `family`; null if none.
func _pick_spawn(family: String) -> VehicleSpawn:
	for node in find_children("*", "VehicleSpawn", true, false):
		var spawn := node as VehicleSpawn
		if spawn != null and spawn.accepts(family):
			return spawn
	return null


## First closed rail loop under this level (RailTrack.find_closed_rail is the one shared walk,
## used by TrainVehicle too so the spawn gate and the train agree on what a rail is); null if
## none.
func _find_closed_rail() -> Node:
	return RailTrack.find_closed_rail(self)


## Whether a closed rail loop exists here — the shell's roster gate: the "train" family is
## dropped from the garage menu on a level with no loop (so a stray allow-list entry can't
## offer a train that _spawn_vehicle would then refuse). Same one walk the spawn gate uses.
func has_closed_rail() -> bool:
	return _find_closed_rail() != null
