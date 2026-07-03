@tool
class_name VehicleSpawn
extends Marker3D
## A place a vehicle can start (plan §4.5). Its transform is the spawn pose; the
## filter says which vehicle types belong here. Water spawns (is_water) are where a
## boat starts and where a drowned car respawns from — land vehicles never pick one.
##
## @tool only for the editor gizmo tint; it holds no runtime logic.

## Vehicle type ids this spawn accepts (e.g. "car", "boat"). Empty = any type.
@export var vehicle_types := PackedStringArray()
## Water spawn: chosen for boats and as the safe respawn after a car falls in.
@export var is_water := false


## True when a vehicle of `type` may use this spawn.
func accepts(type: String) -> bool:
	return vehicle_types.is_empty() or vehicle_types.has(type)
