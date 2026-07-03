class_name Level
extends Node3D
## Base script for every playable level (plan §4.5/§4.6). A level scene is
## self-contained: static geometry, VehicleSpawn markers, a WorldEnvironment, a
## ChaseCamera, and a LevelInfo resource. This script composes them at load time —
## it instances the default vehicle at a matching spawn, points the camera at it,
## and handles respawn. Vehicles/levels/UI stay independent scenes (plan §2 rule 6).

## Vehicle type id -> scene path. New vehicles register here; scenes are loaded on
## demand so a missing (not-yet-built) type never breaks level load.
const VEHICLE_SCENES := {
	"car": "res://src/vehicles/car/car.tscn",
}

@export var info: LevelInfo
## The chase camera to follow the active vehicle. Optional; a level may omit it.
@export var camera: ChaseCamera

var vehicle: BaseVehicle


func _ready() -> void:
	if info == null:
		info = LevelInfo.new()
	if camera == null:
		# Fall back to the first ChaseCamera in the level so a scene that only has
		# the node (no explicit `camera` wire) still follows the vehicle.
		for node in find_children("*", "ChaseCamera", true, false):
			camera = node as ChaseCamera
			break
	GameState.current_level = scene_file_path
	_spawn_vehicle(info.default_vehicle)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("respawn") and vehicle != null:
		vehicle.respawn()


## Instance `type` (falling back to the level's default) at a spawn that accepts it,
## replacing any current vehicle, and re-aim the camera. Used at load and (M4) by the
## garage menu.
func _spawn_vehicle(type: String) -> void:
	if not VEHICLE_SCENES.has(type):
		push_error("Level: no scene registered for vehicle type '%s'" % type)
		return
	var spawn := _pick_spawn(type)
	if spawn == null:
		push_error("Level: no spawn marker accepts vehicle type '%s'" % type)
		return

	if vehicle != null:
		vehicle.queue_free()

	vehicle = (load(VEHICLE_SCENES[type]) as PackedScene).instantiate()
	add_child(vehicle)
	vehicle.global_transform = spawn.global_transform
	vehicle.spawn_transform = spawn.global_transform
	vehicle.reset_physics_interpolation()
	GameState.current_vehicle = type

	if camera != null:
		camera.target = vehicle.get_camera_target()
		if not vehicle.respawned.is_connected(camera.snap):
			vehicle.respawned.connect(camera.snap)
		camera.snap.call_deferred()


## First VehicleSpawn under this level that accepts `type`; null if none.
func _pick_spawn(type: String) -> VehicleSpawn:
	for node in find_children("*", "VehicleSpawn", true, false):
		var spawn := node as VehicleSpawn
		if spawn != null and spawn.accepts(type):
			return spawn
	return null
