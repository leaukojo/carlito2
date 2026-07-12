@tool
class_name RoadPath
extends Node3D
## Spline road: owns a Path3D child ("Path", edited with the
## built-in path gizmo or the addon's Draw mode — road_draw_tool.gd appends
## ground-snapped points; the Drape button below re-snaps existing points to terrain)
## and extrudes a low-poly ribbon along its curve from a RoadProfile
## (kit/roads/ presets). Placed under a level's Authoring node; at bake the ribbon's
## triangles join the level-wide welded drivable body (LevelBaker._collect_road) and its
## render surfaces are chunk-bucketed; unbaked dev-play gets a dev trimesh here. The
## ribbon derives from the curve + profile ALONE (never reads the terrain), so bake
## output depends only on the scene file — the CI hash story is untouched.
##
## Conform terrain is destructive-by-button (the terrain-Generate discipline): flattens every
## overlapping HeightmapTerrain's heightmap under the ribbon with a side falloff, one
## deterministic write per terrain, undoable, saved to the PNG (reuses the terrain's
## _commit_generated pipeline). Conforming changes heightmap bytes, so scatter placed
## earlier trips its stale guard — authoring order is terrain -> roads + conform ->
## splat -> scatter.
##
## Non-goals: no junctions (cross two roads over a flat GridMap pad or a
## painted plaza), no lane-marking system, no traffic data.
##
## NOTE: no editor-only type annotations anywhere in this @tool script (they would break
## the exported build's parse — see HeightmapTerrain._commit_generated).

## Conform samples the curve at this fixed arc step (m): deterministic and independent
## of the render tessellation, so the flatten result never depends on view settings.
const CONFORM_STEP := 0.5
const ASPHALT_PROFILE_PATH := "res://kit/roads/asphalt_profile.tres"

## Cross-section + materials. Auto-assigned the asphalt preset in the editor when null
## via a plain property set, so it serializes as an ExtResource and gather_bake_inputs
## hash-tracks it (a preload export default equal to the stored value would be omitted
## from the .tscn — invisible to the input hash). The baker errors on a null profile.
@export var profile: RoadProfile:
	set(value):
		if profile != null and profile.changed.is_connected(_mark_dirty):
			profile.changed.disconnect(_mark_dirty)
		profile = value
		if profile != null and not profile.changed.is_connected(_mark_dirty):
			profile.changed.connect(_mark_dirty)
		_mark_dirty()
## Roll the ribbon by the curve's per-point tilt (the built-in path gizmo's tilt
## handles). Off: the road surface stays level through turns.
@export var banking := false:
	set(value):
		banking = value
		_mark_dirty()
## Longest ribbon segment (m) on straights; curvature subdivides below it.
@export var max_segment_length := 6.0:
	set(value):
		max_segment_length = maxf(value, 0.5)
		_mark_dirty()
## Tangent swing (degrees) a single segment may span before it is subdivided.
@export var max_segment_angle_deg := 6.0:
	set(value):
		max_segment_angle_deg = maxf(value, 0.1)
		_mark_dirty()

@export_group("Draw / drape")
## Ground clearance (m) for the addon's Draw mode and the Drape button below: points
## land this far above the terrain hit, so the ribbon never starts buried before
## Conform runs.
@export var draw_clearance := 0.3
## Snap every existing curve point's Y to the terrain under it + draw_clearance
## (editor-only, one undoable action; points over no terrain keep their height).
@warning_ignore("unused_private_class_variable")
@export_tool_button("Drape curve onto terrain") var _drape_action := _drape_curve
## Give every interior curve point Catmull-Rom handles (RoadBuilder.smooth_handles):
## hand-clicked polyline corners fold the extruded ribbon over itself, smoothing
## turns them into clean arcs. Endpoints keep their handles. Editor-only, one
## undoable action.
@warning_ignore("unused_private_class_variable")
@export_tool_button("Smooth curve (Catmull-Rom)") var _smooth_action := _smooth_curve

@export_group("Conform terrain")
## Blend band (m) beyond the full ribbon half-width over which the flatten fades out.
@export var conform_falloff := 4.0
## Terrain is flattened this far BELOW the road surface (the ribbon rides on top —
## the z-fighting guard). Any value > 0 works: the flatten floor-quantizes, so
## the PNG can never store terrain above the road. What must absorb the resulting
## epsilon + one-height-step gap is the profile's drop skirt — conform warns when
## edge_drop < conform_epsilon + terrain height / 255.
@export var conform_epsilon := 0.05
@warning_ignore("unused_private_class_variable")
@export_tool_button("Conform terrain (destructive)") var _conform_action := _conform_terrain

var _dirty := false


## Duck-typing marker: the baker detects roads via has_method() so CLI runs never
## depend on class_name cache state (the whole kit's contract).
func is_carlito_road() -> bool:
	return true


func _ready() -> void:
	_ensure_path()
	if Engine.is_editor_hint() and profile == null:
		# plain property set -> serializes as ExtResource (see the export's doc)
		profile = load(ASPHALT_PROFILE_PATH)
	_rebuild_road()


## The serialized Path3D child is the bake input: created owned (editor) so the curve
## saves with the level scene; curve_changed covers point edits AND curve swaps.
func _ensure_path() -> void:
	var path := get_node_or_null(^"Path") as Path3D
	if path == null:
		path = Path3D.new()
		path.name = "Path"
		var curve := Curve3D.new()
		curve.add_point(Vector3.ZERO)
		curve.add_point(Vector3(0, 0, 12))
		path.curve = curve
		add_child(path)
	if Engine.is_editor_hint():
		# Deferred on purpose: when the Add Node dialog creates this RoadPath, _ready
		# runs INSIDE add_child — before the editor assigns our own owner — so owning
		# the Path synchronously would misparent it out of the scene (invisible in the
		# dock, never saved). One frame later the owner is set. Idempotent on loaded
		# scenes (the Path is already correctly owned).
		call_deferred(&"_own_path", path)
	if not path.curve_changed.is_connected(_mark_dirty):
		path.curve_changed.connect(_mark_dirty)


func _own_path(path: Path3D) -> void:
	if not Engine.is_editor_hint() or not is_instance_valid(path) or not is_inside_tree():
		return
	var target := owner if owner != null else get_tree().edited_scene_root
	if target != null and path.owner != target:
		path.owner = target


## Debounced rebuild: gizmo drags fire curve_changed per motion event; one deferred
## rebuild per frame is plenty for a few hundred verts.
func _mark_dirty() -> void:
	if _dirty or not is_inside_tree():
		return
	_dirty = true
	call_deferred(&"_rebuild_road")


## Rebuild the unowned preview + dev collision from the curve (never serialized — the
## HeightmapTerrain Chunks / ScatterBase Preview discipline). The dev trimesh exists
## only OUTSIDE the editor: unbaked play is drivable, while editor raycasts (prop
## placement, scatter snap) never hit our own ribbon.
func _rebuild_road() -> void:
	_dirty = false
	if not is_inside_tree():
		return
	var old := get_node_or_null(^"Preview")
	if old != null:
		old.free()
	var old_col := get_node_or_null(^"DevCollision")
	if old_col != null:
		old_col.free()
	if Engine.is_editor_hint():
		update_configuration_warnings()
	var entries := ribbon_surfaces()
	if entries.is_empty():
		return
	var mesh := ArrayMesh.new()
	for e: Dictionary in entries:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, e.arrays)
		mesh.surface_set_material(mesh.get_surface_count() - 1, e.material)
	var mi := MeshInstance3D.new()
	mi.name = "Preview"
	mi.mesh = mesh
	add_child(mi)
	if not Engine.is_editor_hint():
		var body := StaticBody3D.new()
		body.name = "DevCollision"
		add_child(body)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(ribbon_faces())
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)


# ------------------------------------------------------------------ geometry API
# The single owner of the ribbon layout. Duck-called by the baker on an UNTREED level
# instance (no _ready has run there): get_node_or_null resolves off-tree and both fns
# depend only on the serialized Path child + profile.


## [{material: Material, arrays: Mesh.ARRAY_MAX Array}] in RoadPath-local space (a
## non-identity Path3D child transform is composed in). Empty when the profile is null
## or the curve is unusable (< 2 points / ~zero length).
func ribbon_surfaces() -> Array:
	var surfaces := _build_curve_surfaces()
	if surfaces.is_empty():
		return []
	var mats: Array = profile.materials()
	var out := []
	var keys := surfaces.keys()
	keys.sort()
	for slot: int in keys:
		out.append({"material": mats[slot], "arrays": surfaces[slot]})
	return out


## RoadPath-local triangle soup of the whole ribbon (weld pool / dev trimesh input).
func ribbon_faces() -> PackedVector3Array:
	return RoadBuilder.faces_from_surfaces(_build_curve_surfaces())


## Shared build: cross-section -> adaptive offsets -> extrude, then compose the Path3D
## child transform (identity fast-path). {} when anything is unusable.
func _build_curve_surfaces() -> Dictionary:
	if profile == null:
		return {}
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		return {}
	var cs: Dictionary = profile.cross_section()
	if (cs.points as PackedVector2Array).size() < 2:
		return {}
	var offsets := RoadBuilder.adaptive_offsets(path.curve, max_segment_length,
			max_segment_angle_deg)
	if offsets.size() < 2:
		return {}
	var surfaces := RoadBuilder.extrude(path.curve, cs.points, cs.mats, offsets, banking)
	if path.transform != Transform3D.IDENTITY:
		for slot in surfaces:
			surfaces[slot] = RoadBuilder.transform_surface_arrays(surfaces[slot], path.transform)
	return surfaces


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if _find_authoring_ancestor() == null:
		warnings.append("RoadPath must sit under the level's Authoring node to be baked.")
	if profile == null:
		warnings.append("No profile — assign one from kit/roads/.")
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null or path.curve.point_count < 2:
		warnings.append("The Path child's curve needs at least 2 points.")
	return warnings


func _find_authoring_ancestor() -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method("is_carlito_authoring"):
			return node
		node = node.get_parent()
	return null


# ------------------------------------------------------------------ drape curve
# Editor-only, one undoable action (the Conform discipline). The curve is the bake
# input, so drape edits it exactly like the gizmo would — nothing else changes.


func _drape_curve() -> void:
	if not Engine.is_editor_hint():
		return
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null or path.curve.point_count == 0:
		push_warning("RoadPath: no curve points to drape.")
		return
	var terrains: Array[Node] = []
	ScatterBase.find_terrains_under(owner if owner != null else self, terrains)
	if terrains.is_empty():
		push_warning("RoadPath: no HeightmapTerrain in the scene to drape onto.")
		return
	var curve := path.curve
	var to_world := global_transform * path.transform
	var to_local := to_world.affine_inverse()
	var before := PackedVector3Array()
	var after := PackedVector3Array()
	var missed := 0
	for i in curve.point_count:
		var p := curve.get_point_position(i)
		before.append(p)
		var w := to_world * p
		var snapped := false
		for t in terrains:
			if t.contains_xz(w):
				w.y = float(t.height_at(w)) + draw_clearance
				snapped = true
				break
		if snapped:
			p = to_local * w
		else:
			missed += 1
		after.append(p)
	if missed > 0:
		push_warning("RoadPath '%s': %d point(s) over no terrain kept their height." % [name, missed])
	if after == before:
		return
	# Untyped singleton fetch — the HeightmapTerrain._commit_generated rule: an
	# editor-only type annotation would break this @tool script's parse in exports.
	var undo_redo = Engine.get_singleton(&"EditorInterface").get_editor_undo_redo()
	undo_redo.create_action("Drape road '%s' onto terrain" % name)
	undo_redo.add_do_method(self, &"_set_curve_point_positions", after)
	undo_redo.add_undo_method(self, &"_set_curve_point_positions", before)
	undo_redo.commit_action()


## Undo/redo helper: bulk-assign curve point positions (handles/tilts untouched —
## in/out handles are point-relative, so they survive a Y move).
func _set_curve_point_positions(positions: PackedVector3Array) -> void:
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		return
	for i in mini(positions.size(), path.curve.point_count):
		path.curve.set_point_position(i, positions[i])


func _smooth_curve() -> void:
	if not Engine.is_editor_hint():
		return
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null or path.curve.point_count < 3:
		push_warning("RoadPath: need at least 3 curve points to smooth.")
		return
	var curve := path.curve
	var before_in := PackedVector3Array()
	var before_out := PackedVector3Array()
	var after_in := PackedVector3Array()
	var after_out := PackedVector3Array()
	for i in curve.point_count:
		before_in.append(curve.get_point_in(i))
		before_out.append(curve.get_point_out(i))
		if i == 0 or i == curve.point_count - 1:
			after_in.append(curve.get_point_in(i))
			after_out.append(curve.get_point_out(i))
			continue
		var h: Dictionary = RoadBuilder.smooth_handles(curve.get_point_position(i - 1),
				curve.get_point_position(i), curve.get_point_position(i + 1))
		after_in.append(h["in"])
		after_out.append(h["out"])
	if after_in == before_in and after_out == before_out:
		return
	# Untyped singleton fetch — the HeightmapTerrain._commit_generated rule.
	var undo_redo = Engine.get_singleton(&"EditorInterface").get_editor_undo_redo()
	undo_redo.create_action("Smooth road '%s' curve" % name)
	undo_redo.add_do_method(self, &"_set_curve_handles", after_in, after_out)
	undo_redo.add_undo_method(self, &"_set_curve_handles", before_in, before_out)
	undo_redo.commit_action()


## Undo/redo helper: bulk-assign curve point in/out handles (positions untouched).
func _set_curve_handles(ins: PackedVector3Array, outs: PackedVector3Array) -> void:
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null:
		return
	for i in mini(ins.size(), path.curve.point_count):
		path.curve.set_point_in(i, ins[i])
		path.curve.set_point_out(i, outs[i])


# --------------------------------------------------------------- conform terrain
# Editor-only, destructive-by-button (the terrain-Generate discipline). The heavy lifting
# is pure (RoadBuilder.conform_heights); the PNG write / reimport / undo action reuses
# HeightmapTerrain._commit_generated verbatim (the same cross-file reuse decision as
# ScatterBase calling height_at — GDScript has no privacy, and the pipeline must be
# byte-identical to Generate/Auto-splat).


func _conform_terrain() -> void:
	if not Engine.is_editor_hint():
		return
	if profile == null:
		push_warning("RoadPath: assign a profile before conforming.")
		return
	var path := get_node_or_null(^"Path") as Path3D
	if path == null or path.curve == null or path.curve.point_count < 2:
		push_warning("RoadPath: the curve needs at least 2 points.")
		return
	var curve := path.curve
	var length := curve.get_baked_length()
	if length < 0.001:
		push_warning("RoadPath: the curve has no length.")
		return

	# Deterministic world-space centerline samples at a fixed arc step (incl. endpoint).
	var to_world := global_transform * path.transform
	var count := maxi(2, int(ceil(length / CONFORM_STEP)) + 1)
	var world := PackedVector3Array()
	for i in count:
		var o := length * float(i) / float(count - 1)
		world.append(to_world * curve.sample_baked(o))

	var terrains: Array[Node] = []
	ScatterBase.find_terrains_under(owner if owner != null else self, terrains)
	var reach: float = profile.full_half_width() + conform_falloff
	var touched := 0
	for t in terrains:
		if not _overlaps_terrain(t, world, reach):
			continue
		var img: Image = t._read_image()
		if img == null:
			push_warning("RoadPath: terrain '%s' has no heightmap to conform." % t.name)
			continue
		var t3d := t as Node3D
		var amp := maxf(float(t.get("height")), 0.001)
		# The skirt must absorb epsilon plus one 8-bit height step, or the seam can
		# open under its outer edge (terrain quantizes below the skirt bottom).
		var height_step := amp / 255.0
		if profile.edge_drop < conform_epsilon + height_step:
			push_warning("RoadPath '%s': profile edge_drop %.2f < conform_epsilon %.2f + terrain '%s' height step %.3f — raise the profile's edge_drop (or lower the terrain height) or the skirt seam can open." % [name, profile.edge_drop, conform_epsilon, t.name, height_step])
		var clamped := false
		var samples := PackedVector3Array()
		for w in world:
			var tn := (w.y - conform_epsilon - t3d.global_position.y) / amp
			if tn < 0.0 or tn > 1.0:
				clamped = true
			samples.append(Vector3(w.x - t3d.global_position.x,
					w.z - t3d.global_position.z, clampf(tn, 0.0, 1.0)))
		if clamped:
			push_warning("RoadPath: parts of '%s' sit outside terrain '%s's height range — the flatten clamps there." % [name, t.name])
		var dims: Vector2i = t._grid_dims()
		# Plateau spans the FULL ribbon half-width (skirt included): terrain under the
		# skirt sits at a predictable road - epsilon and always crosses the skirt on
		# its slope; the falloff to original terrain starts beyond the ribbon.
		var dirty := RoadBuilder.conform_heights(img, samples,
				profile.full_half_width(), conform_falloff,
				float(dims.x - 1), float(dims.y - 1))
		if not dirty.has_area():
			continue
		t._commit_generated("Conform terrain to road '%s'" % name, &"heightmap",
				t.png_path_for("height"), img, {})
		touched += 1
	if touched == 0:
		push_warning("RoadPath: no HeightmapTerrain overlaps this road — nothing conformed.")
	else:
		print("RoadPath '%s': conformed %d terrain(s)." % [name, touched])


## Whether any centerline sample lands within `pad` of the terrain's XZ rect.
func _overlaps_terrain(t: Node, world: PackedVector3Array, pad: float) -> bool:
	var t3d := t as Node3D
	var half: Vector2 = t.get("terrain_size") * 0.5
	for w in world:
		if absf(w.x - t3d.global_position.x) <= half.x + pad \
				and absf(w.z - t3d.global_position.z) <= half.y + pad:
			return true
	return false
