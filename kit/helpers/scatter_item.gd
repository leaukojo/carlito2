@tool
class_name ScatterItem
extends Resource
## One entry in a ScatterRegion's item table: which kit
## prefab to scatter, how often relative to its siblings, and whether its instances
## carry physics. The prefab is a PackedScene reference (never a path string) so the
## level's stale-bake input hash tracks it automatically via scene dependencies.

@export var prefab: PackedScene
## Relative pick weight against the region's other items (<= 0 never picked).
@export var weight := 1.0
## Off = zero physics (grass tufts, small rocks): no dev collision, no baked shapes.
@export var collision := true
## Instances-per-region at or above which the bake emits one MultiMeshInstance3D per
## chunk instead of merging the prefab's verts into chunk meshes. -1 = the baker's
## default (LevelBaker.SCATTER_MULTIMESH_THRESHOLD).
@export var bake_threshold_override := -1
