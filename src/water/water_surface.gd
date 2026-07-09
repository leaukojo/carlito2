@tool
class_name WaterSurface
extends Area3D
## One rectangular water region (plan §4.4/§4.5/§8): the water HEIGHT API, the visual
## surface, and the non-boat kill/respawn volume in a single node a level drops in.
##
## - Height API: get_height() returns the node's global Y — FLAT at launch (plan §4.4).
##   The visual waves live entirely in water.gdshader and never feed physics (plan §8).
## - Buoyancy callers (BoatVehicle) find water via the "water" group + contains_xz().
## - Kill volume (plan §8 "water region defines kill/respawn volume for non-boats"):
##   the Area's box spans the water body but its top sits kill_margin below the surface,
##   so a splash at the shoreline is survivable while a sunk vehicle respawns (the
##   existing BaseVehicle.respawn path, which already zeroes the accel history).
##
## The region is an axis-aligned rect around the node's origin; don't rotate the node.

const WATER_GROUP := "water"
const SHADER := preload("res://src/water/water.gdshader")
## Visual plane subdivisions (fixed: enough for the vertex waves, one draw call).
const MESH_SUBDIV := 32

@export var size := Vector2(24.0, 24.0):
	set(v):
		size = v
		_rebuild()
## Water body depth below the surface (kill box bottom; keep >= actual basin depth).
@export var depth := 2.0:
	set(v):
		depth = v
		_rebuild()
## The kill box top sits this far below the surface: grazing the surface is not death.
@export var kill_margin := 0.5:
	set(v):
		kill_margin = v
		_rebuild()

var _mesh: MeshInstance3D
var _shape: CollisionShape3D


func _ready() -> void:
	add_to_group(WATER_GROUP)
	_rebuild()
	if not Engine.is_editor_hint():
		monitoring = true
		body_entered.connect(_on_body_entered)


## Water surface height at `pos` — constant across the region at launch (plan §4.4).
## Boats sample this; the shader waves are cosmetic and deliberately not reflected here.
func get_height(_pos: Vector3) -> float:
	return global_position.y


## Whether `pos` is over this water region (axis-aligned rect around the origin).
func contains_xz(pos: Vector3) -> bool:
	var d := pos - global_position
	return absf(d.x) <= size.x * 0.5 and absf(d.z) <= size.y * 0.5


## Build the visual plane + kill-volume shape as internal children (never serialized,
## same pattern as VehicleSpawn's gizmo) so levels only author the WaterSurface node.
func _rebuild() -> void:
	if not is_inside_tree():
		return
	if _mesh == null:
		_mesh = MeshInstance3D.new()
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		_mesh.material_override = mat
		add_child(_mesh, false, Node.INTERNAL_MODE_BACK)
		_shape = CollisionShape3D.new()
		_shape.shape = BoxShape3D.new()
		add_child(_shape, false, Node.INTERNAL_MODE_BACK)
	var plane := PlaneMesh.new()
	plane.size = size
	plane.subdivide_width = MESH_SUBDIV
	plane.subdivide_depth = MESH_SUBDIV
	_mesh.mesh = plane
	var box_height := maxf(depth - kill_margin, 0.05)
	(_shape.shape as BoxShape3D).size = Vector3(size.x, box_height, size.y)
	_shape.position = Vector3(0.0, -kill_margin - box_height * 0.5, 0.0)


## Non-boat vehicle in the water body -> drown: reuse the respawn path (plan §8).
## Deferred because Area3D signals fire during the physics flush, where transforms
## can't be written. Boats float; everything else that isn't a vehicle is ignored.
func _on_body_entered(body: Node3D) -> void:
	if body is BaseVehicle and not body is BoatVehicle:
		body.call_deferred("respawn")
