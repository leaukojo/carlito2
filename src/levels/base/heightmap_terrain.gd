@tool
class_name HeightmapTerrain
extends StaticBody3D
## Terrain from a heightmap image (plan §4.5): a greyscale texture becomes both a
## welded ground mesh and a matching HeightMapShape3D. This is the §2-rule-2 ground
## path — a dedicated collision surface, never a trimesh scatter. One grid cell = one
## world unit, so the mesh and collision vertices coincide exactly (no shape scaling).
##
## @tool so authors see the terrain in the editor; call rebuild() after changing the
## image or size. Cells sample the red channel as normalized height [0,1] * height.

@export var heightmap: Texture2D:
	set(value):
		heightmap = value
		_rebuild_if_ready()
## World-unit extent on X (width) and Z (depth). Also the collision/mesh grid size.
@export var terrain_size := Vector2(64, 64):
	set(value):
		terrain_size = value
		_rebuild_if_ready()
## World-unit Y of a fully white pixel (black = 0). The hill's peak height.
@export var height := 8.0:
	set(value):
		height = value
		_rebuild_if_ready()
@export var material: Material:
	set(value):
		material = value
		_rebuild_if_ready()
@warning_ignore("unused_private_class_variable")
@export_tool_button("Rebuild terrain") var _rebuild_action := rebuild


func _ready() -> void:
	rebuild()


func _rebuild_if_ready() -> void:
	if is_inside_tree():
		rebuild()


## (Re)generate the mesh + collision from the current heightmap. Safe to call in the
## editor or at runtime; a null heightmap flattens to a plane at y=0.
func rebuild() -> void:
	var dims := _grid_dims()
	var cols := dims.x   # vertices along X
	var rows := dims.y   # vertices along Z
	var img := _read_image()
	var heights := _sample_heights(img, cols, rows)

	_apply_mesh(cols, rows, heights)
	_apply_collision(cols, rows, heights)


## Vertex grid dimensions: one cell = one world unit, so verts = extent + 1 (min 2).
## Shared by rebuild() and height_at() so the world<->grid mapping lives in one place.
func _grid_dims() -> Vector2i:
	return Vector2i(maxi(2, int(terrain_size.x) + 1), maxi(2, int(terrain_size.y) + 1))


## World-space surface height under `world_pos`'s XZ, bilinearly sampled from the
## heightmap (the §2-rule-2 ground query — used by the LK2 placement fallback and, later,
## LK5 scatter ground-snap). Assumes the terrain is axis-aligned (unrotated/unscaled, as
## all authored HeightmapTerrains are); a null heightmap is flat at the node's Y.
func height_at(world_pos: Vector3) -> float:
	var img := _read_image()
	if img == null:
		return global_position.y
	var dims := _grid_dims()
	var span_x := float(dims.x - 1)
	var span_z := float(dims.y - 1)
	# grid X spans [-span_x/2, +span_x/2] in local space (see _apply_mesh's x0/z0).
	var lx := world_pos.x - global_position.x
	var lz := world_pos.z - global_position.z
	var u := clampf((lx + span_x * 0.5) / span_x, 0.0, 1.0)
	var v := clampf((lz + span_z * 0.5) / span_z, 0.0, 1.0)
	return global_position.y + _sample_red_bilinear(img, u, v) * height


## Whether `world_pos`'s XZ lies within this terrain's extent (axis-aligned rect).
func contains_xz(world_pos: Vector3) -> bool:
	var lx := world_pos.x - global_position.x
	var lz := world_pos.z - global_position.z
	return absf(lx) <= terrain_size.x * 0.5 and absf(lz) <= terrain_size.y * 0.5


## Bilinear red-channel lookup at normalized (u, v) in [0,1]. Smoother than the mesh's
## nearest sampling, so a placed prop sits on the interpolated surface, not a vertex step.
func _sample_red_bilinear(img: Image, u: float, v: float) -> float:
	var iw := img.get_width()
	var ih := img.get_height()
	var fx := u * float(iw - 1)
	var fy := v * float(ih - 1)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var x1 := mini(x0 + 1, iw - 1)
	var y1 := mini(y0 + 1, ih - 1)
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var top := lerpf(img.get_pixel(x0, y0).r, img.get_pixel(x1, y0).r, tx)
	var bot := lerpf(img.get_pixel(x0, y1).r, img.get_pixel(x1, y1).r, tx)
	return lerpf(top, bot, ty)


## Decoded, uncompressed copy of the heightmap image, or null when unset.
func _read_image() -> Image:
	if heightmap == null:
		return null
	var img := heightmap.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	return img


## Row-major (z*cols + x) height grid: red channel * height, or all-zero without an image.
func _sample_heights(img: Image, cols: int, rows: int) -> PackedFloat32Array:
	var data := PackedFloat32Array()
	data.resize(cols * rows)
	if img == null:
		return data
	var iw := img.get_width()
	var ih := img.get_height()
	for z in rows:
		var v := float(z) / float(rows - 1)
		var py := clampi(int(round(v * (ih - 1))), 0, ih - 1)
		for x in cols:
			var u := float(x) / float(cols - 1)
			var px := clampi(int(round(u * (iw - 1))), 0, iw - 1)
			data[z * cols + x] = img.get_pixel(px, py).r * height
	return data


func _apply_mesh(cols: int, rows: int, heights: PackedFloat32Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x0 := -float(cols - 1) * 0.5
	var z0 := -float(rows - 1) * 0.5
	for z in rows:
		for x in cols:
			st.set_uv(Vector2(float(x) / float(cols - 1), float(z) / float(rows - 1)))
			st.add_vertex(Vector3(x0 + x, heights[z * cols + x], z0 + z))
	for z in rows - 1:
		for x in cols - 1:
			var i := z * cols + x
			# two triangles per quad, wound CW (Godot's front-face order) so the
			# generated normals point up and the top surface renders / lights.
			st.add_index(i); st.add_index(i + 1); st.add_index(i + cols)
			st.add_index(i + 1); st.add_index(i + cols + 1); st.add_index(i + cols)
	st.generate_normals()
	var mi := get_node_or_null(^"Mesh") as MeshInstance3D
	if mi == null:
		# Left unowned on purpose: the mesh is regenerated from the heightmap on
		# every load, so it must never be serialized into the level scene (an
		# editor save would otherwise bake stale geometry — plan §2 rule 1). It
		# still renders in the editor viewport as a preview.
		mi = MeshInstance3D.new()
		mi.name = "Mesh"
		add_child(mi)
	mi.mesh = st.commit()
	mi.material_override = material


func _apply_collision(cols: int, rows: int, heights: PackedFloat32Array) -> void:
	var shape := HeightMapShape3D.new()
	shape.map_width = cols
	shape.map_depth = rows
	shape.map_data = heights
	var cs := get_node_or_null(^"Collision") as CollisionShape3D
	if cs == null:
		# Unowned like the mesh (see _apply_mesh): regenerated per load, never saved.
		cs = CollisionShape3D.new()
		cs.name = "Collision"
		add_child(cs)
	cs.shape = shape
