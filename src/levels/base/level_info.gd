class_name LevelInfo
extends Resource
## Per-level metadata: what the shell needs to load and populate a level
## without reading its scene tree. Spawn markers live in the scene as VehicleSpawn
## nodes; everything else that is data (name, allowed/default vehicle) lives here.

@export var display_name := "Untitled Level"
## Vehicle type ids allowed here (match contract 'vehicles' tags, e.g. "car").
## Empty = allow all. The garage menu reads this to build its roster.
@export var allowed_vehicles := PackedStringArray(["car"])
## Vehicle type spawned when the level first loads. Must be in allowed_vehicles.
@export var default_vehicle := "car"


## True when `type` may drive here (empty allow-list = everything allowed).
func allows(type: String) -> bool:
	return allowed_vehicles.is_empty() or allowed_vehicles.has(type)
