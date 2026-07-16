@tool
extends "res://addons/carlito_kit/brush_chassis.gd"
## Terrain sculpt/paint brush. Rides the shared brush chassis; adds
## the terrain-specific half: raise / lower / smooth / flatten on the heightmap image, and
## 8-channel painting across the terrain's two splat weight images.
##
## Editor-only by construction: a brush edits image CONTENT only. It never swaps
## the terrain's exported heightmap/splatmap Texture2D (the one exception: painting a channel
## >= 4 on a terrain with no splatmap2 creates that PNG, and flush points the node at it), and
## never touches the terrain's saved
## material (so the scene always serializes the PNG reference, never a transient in-memory
## texture). Live feedback comes from remeshing the touched chunks straight off the working
## image (height) and a preview material_override on those chunks (paint) — the chunks are
## unowned, so nothing put on them can serialize. Edits accumulate in memory and are written
## to the PNGs only on SCENE SAVE (flush_all, wired to the plugin's _save_external_data) —
## never reimported per stroke. The heightmap/splat PNGs stay the sole artifact the runtime
## and baker already read.

const BrushOps := preload("res://kit/helpers/brush_ops.gd")
const TerrainGen := preload("res://kit/terrain/terrain_gen.gd")

# Brush modes (index-matched to the panel's buttons: 0 = Off .. 5 = Paint).
enum { OFF, RAISE, LOWER, SMOOTH, FLATTEN, PAINT }

var mode := OFF
## Splat channel to paint, 0..7: 0..3 live in the splatmap (grass/dirt/sand/rock), 4..7 in
## the optional splatmap2. Names and colors are the terrain's (see HeightmapTerrain).
var channel := 0

var _undo: EditorUndoRedoManager
var _terrain: HeightmapTerrain = null

# Per-terrain edit session, kept until scene save (flush) or plugin exit — so deselecting
# doesn't drop uncommitted work and undo stays coherent across reselection.
# id -> { terrain, height:Image, splat:Image, splat2:Image,
#         splat_tex:ImageTexture, splat2_tex:ImageTexture, preview_mat:ShaderMaterial,
#         height_dirty:bool, splat_dirty:bool, splat2_dirty:bool }
var _sessions := {}

# Active-stroke state. A paint stroke edits BOTH splat images (painting any channel has to
# fade the seven others, which straddle the two), so the snapshots come in pairs; a sculpt
# stroke only fills the first.
var _stroke_kind := "height"
var _stroke_before: Image = null   # full snapshot at stroke begin (dirty region carved out at end)
var _stroke_before2: Image = null  # ditto for splat2 (paint strokes only)
var _dirty := Rect2i()
var _dirty_any := false
var _flatten_target := 0.0


func _init(undo: EditorUndoRedoManager) -> void:
	_undo = undo


# ------------------------------------------------------------------ plugin API

func set_target(terrain: HeightmapTerrain) -> void:
	if terrain == _terrain:
		return
	_free_cursor()  # cursor lives under the terrain; a new target needs a new one
	_terrain = terrain


func set_mode(m: int) -> void:
	mode = m
	if mode == OFF:
		_hide_cursor()


## Write every dirty session's working image back to its PNG and reimport once (PNGs are
## saved on scene save, never per stroke). Called from the plugin's _save_external_data hook.
func flush_all() -> void:
	for id: int in _sessions:
		var s: Dictionary = _sessions[id]
		var terrain: HeightmapTerrain = s.terrain
		if not is_instance_valid(terrain):
			continue
		if s.height_dirty and s.height != null:
			_flush_image(terrain, "height", s.height)
			s.height_dirty = false
		if s.splat_dirty and s.splat != null:
			_flush_image(terrain, "splat", s.splat)
			s.splat_dirty = false
		if s.splat2_dirty and s.splat2 != null:
			_flush_image(terrain, "splat2", s.splat2)
			s.splat2_dirty = false
		# The reimported PNGs are now the real splatmaps, so dropping the preview can't pop.
		_drop_preview(s)
		_heal_material(terrain)


func teardown() -> void:
	_free_cursor()
	for id: int in _sessions:
		_drop_preview(_sessions[id])
	_sessions.clear()
	_terrain = null


# ------------------------------------------------------------------ chassis virtuals

func _target_valid() -> bool:
	return Engine.is_editor_hint() and mode != OFF and is_instance_valid(_terrain)


func _cursor_parent() -> Node3D:
	return _terrain


func _cursor_color() -> Color:
	match mode:
		RAISE:
			return Color(0.4, 1.0, 0.45)
		LOWER:
			return Color(1.0, 0.5, 0.4)
		SMOOTH:
			return Color(0.45, 0.7, 1.0)
		FLATTEN:
			return Color(1.0, 0.9, 0.4)
		PAINT:
			# The cursor wears the channel's own (per-level, editable) color.
			return _terrain.channel_color(channel) if is_instance_valid(_terrain) else Color.GRAY
	return Color.WHITE


## Circular cursor that hugs the LIVE surface (the working image, not the stale PNG the node
## still points at), so it tracks sculpting in progress.
func _cursor_points(center: Vector3) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in CURSOR_SEGMENTS + 1:
		var a := TAU * float(i) / float(CURSOR_SEGMENTS)
		var x := center.x + cos(a) * radius
		var z := center.z + sin(a) * radius
		pts.append(Vector3(x, _surface_y(x, z) + 0.05, z))
	return pts


## Ground point under the cursor by iterating ray vs. heightfield (no physics — editor space
## isn't reliably populated, and we want the terrain surface specifically, not a placed prop).
## A few refinements converge for non-overhang terrain.
func _project(camera: Camera3D, mouse: Vector2) -> Variant:
	if not is_instance_valid(_terrain):
		return null
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	var p: Variant = _ray_plane(origin, dir, _terrain.global_position.y)
	for _i in 4:
		if p == null:
			return null
		var q: Variant = _ray_plane(origin, dir, _surface_y((p as Vector3).x, (p as Vector3).z))
		if q == null:
			break
		p = q
	return p


# ------------------------------------------------------------------ stroke

func _stroke_begin(center: Vector3) -> void:
	_stroke_kind = "splat" if mode == PAINT else "height"
	var work := _work_for(_terrain, _stroke_kind)
	_stroke_before = null
	_stroke_before2 = null
	_dirty_any = false
	if work == null:
		push_warning("Kit brush: %s first." % ("auto-splat the terrain" if _stroke_kind == "splat"
				else "generate a heightmap"))
		return
	_stroke_before = work.duplicate()
	if mode == PAINT:
		_stroke_before2 = _work_for(_terrain, "splat2").duplicate()
	if mode == FLATTEN:
		_flatten_target = _sample_work_red(work, center.x, center.z)


func _stroke_apply(center: Vector3) -> void:
	if _stroke_before == null:
		return
	var work := _work_for(_terrain, _stroke_kind)
	if work == null:
		return
	var iw := work.get_width()
	var ih := work.get_height()
	var c := _world_to_px(work, center)
	var ts := _terrain.terrain_size
	var rx := radius / maxf(ts.x, 1e-3) * float(iw - 1)
	var rz := radius / maxf(ts.y, 1e-3) * float(ih - 1)

	var dirty: Rect2i
	if mode == PAINT:
		# Both images take the same kernel with their own slice of the unit vector, so the
		# channel painted rises and every other channel — in either image — fades.
		dirty = BrushOps.stamp_splat(work, c.x, c.y, rx, rz,
				BrushOps.unit_slice(channel, 0), strength, falloff)
		BrushOps.stamp_splat(_work_for(_terrain, "splat2"), c.x, c.y, rx, rz,
				BrushOps.unit_slice(channel, 1), strength, falloff)
	else:
		dirty = BrushOps.stamp_height(work, c.x, c.y, rx, rz, mode - RAISE, strength, falloff,
				_flatten_target)
	if dirty.size == Vector2i.ZERO:
		return
	_dirty = dirty if not _dirty_any else _dirty.merge(dirty)
	_dirty_any = true

	if mode == PAINT:
		_refresh_splat(_terrain)
		_mark_dirty(_terrain, "splat")
		_mark_dirty(_terrain, "splat2")
	else:
		# Remesh only the chunks under the brush footprint (never a full rebuild
		# per stroke). Collision is deferred to stroke end.
		_terrain.rebuild_region_world(work, center.x - radius, center.x + radius,
				center.z - radius, center.z + radius)
		_repush_preview(_terrain)
		_mark_dirty(_terrain, "height")


func _stroke_end() -> void:
	if not _dirty_any or _stroke_before == null:
		_stroke_before = null
		_stroke_before2 = null
		return
	var work := _work_for(_terrain, _stroke_kind)
	if _stroke_kind == "height":
		_terrain.rebuild_collision_from_image(work)  # catch physics up once, at stroke end

	# Undo snapshots only the touched region of each side — of both images for a paint
	# stroke (same dirty rect: one kernel stamped into both).
	var kinds := ["splat", "splat2"] if _stroke_kind == "splat" else ["height"]
	var befores := [_stroke_before, _stroke_before2]
	_stroke_before = null
	_stroke_before2 = null
	var pos := _dirty.position
	var scene_root := EditorInterface.get_edited_scene_root()
	_undo.create_action("Paint terrain" if _stroke_kind == "splat" else "Sculpt terrain",
			UndoRedo.MERGE_DISABLE, scene_root)
	for i in kinds.size():
		var kind: String = kinds[i]
		var before_region := (befores[i] as Image).get_region(_dirty)
		var after_region := _work_for(_terrain, kind).get_region(_dirty)
		_undo.add_do_method(self, "_apply_region", _terrain, kind, after_region, pos)
		_undo.add_undo_method(self, "_apply_region", _terrain, kind, before_region, pos)
		_undo.add_do_reference(after_region)
		_undo.add_undo_reference(before_region)
	_undo.commit_action(false)  # edits are already live — don't re-run the do now


## Undo/redo target: blit a saved region back into the working image and refresh the visual.
## Robust to the terrain no longer being the current target (re-derives the session).
func _apply_region(terrain: HeightmapTerrain, kind: String, region: Image, pos: Vector2i) -> void:
	if not is_instance_valid(terrain):
		return
	var work := _work_for(terrain, kind)
	if work == null:
		return
	work.blit_rect(region, Rect2i(Vector2i.ZERO, region.get_size()), pos)
	_mark_dirty(terrain, kind)
	if kind == "splat" or kind == "splat2":
		_refresh_splat(terrain)
		return
	var lo := _px_to_world(terrain, work, pos)
	var hi := _px_to_world(terrain, work, pos + region.get_size())
	terrain.rebuild_region_world(work, minf(lo.x, hi.x), maxf(lo.x, hi.x),
			minf(lo.y, hi.y), maxf(lo.y, hi.y))
	_repush_preview(terrain)
	terrain.rebuild_collision_from_image(work)


# ------------------------------------------------------------------ session / image helpers

## The working image for `kind` ("height" / "splat" / "splat2"), decoded from the terrain's
## texture on first touch. splat2 is the exception: a terrain that has never been painted with
## a channel >= 4 has no splatmap2, so one is created all-zero (= no extra weight anywhere,
## the shader's own default) sized like the splatmap — the first such stroke just works, and
## flush writes the new PNG. Sizing off the splatmap is enough because a paint stroke without
## a splatmap is refused in _stroke_begin.
func _work_for(terrain: HeightmapTerrain, kind: String) -> Image:
	var id := terrain.get_instance_id()
	if not _sessions.has(id):
		_sessions[id] = {
			"terrain": terrain, "height": null, "splat": null, "splat2": null,
			"splat_tex": null, "splat2_tex": null, "preview_mat": null,
			"height_dirty": false, "splat_dirty": false, "splat2_dirty": false,
		}
	var s: Dictionary = _sessions[id]
	if kind == "height":
		if s.height == null:
			s.height = _decode(terrain.heightmap, Image.FORMAT_L8)
		return s.height
	if kind == "splat2":
		if s.splat2 == null:
			s.splat2 = _decode(terrain.splatmap2, Image.FORMAT_RGBA8)
		if s.splat2 == null:
			var base: Image = _work_for(terrain, "splat")
			if base == null:
				return null
			s.splat2 = Image.create(base.get_width(), base.get_height(), false,
					Image.FORMAT_RGBA8)
			(s.splat2 as Image).fill(Color(0, 0, 0, 0))
		return s.splat2
	if s.splat == null:
		s.splat = _decode(terrain.splatmap, Image.FORMAT_RGBA8)
	return s.splat


func _mark_dirty(terrain: HeightmapTerrain, kind: String) -> void:
	var s: Dictionary = _sessions[terrain.get_instance_id()]
	s[kind + "_dirty"] = true


## Show live paint without touching the SAVED material: throwaway ImageTextures (updated in
## place per sample) for BOTH weight images feed a duplicate of the material, applied as
## material_override on the terrain's unowned chunk MeshInstance3Ds. Writing the transient
## textures into the saved material instead would embed the whole raw images into the .tscn
## on save.
func _refresh_splat(terrain: HeightmapTerrain) -> void:
	var work := _work_for(terrain, "splat")
	if work == null:
		return
	var s: Dictionary = _sessions[terrain.get_instance_id()]
	s.splat_tex = _live_texture(s.splat_tex, work)
	s.splat2_tex = _live_texture(s.splat2_tex, _work_for(terrain, "splat2"))
	if s.preview_mat == null:
		if not (terrain.material is ShaderMaterial):
			return
		s.preview_mat = (terrain.material as ShaderMaterial).duplicate() as ShaderMaterial
	var mat: ShaderMaterial = s.preview_mat
	mat.set_shader_parameter(&"splatmap", s.splat_tex)
	mat.set_shader_parameter(&"splatmap2", s.splat2_tex)
	_push_preview(terrain, mat)


## Create-or-update the transient ImageTexture mirroring a working image.
func _live_texture(tex: ImageTexture, img: Image) -> ImageTexture:
	if img == null:
		return tex
	if tex == null:
		return ImageTexture.create_from_image(img)
	tex.update(img)
	return tex


## (Re)apply the preview material to the terrain's current chunk nodes. Called after every
## paint sample and after any incremental remesh — _build_chunk recreates chunks with
## material_override = terrain.material, dropping the preview.
func _push_preview(terrain: HeightmapTerrain, mat: Material) -> void:
	var container := terrain.get_node_or_null(^"Chunks")
	if container == null:
		return
	for child in container.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_override = mat


## Re-apply the live preview after an incremental remesh, if this terrain has one. A full
## rebuild() from an inspector edit mid-session also recreates chunks; that loses the preview
## until the next paint sample, which is acceptable.
func _repush_preview(terrain: HeightmapTerrain) -> void:
	var s: Dictionary = _sessions.get(terrain.get_instance_id(), {})
	if s.get("preview_mat") != null:
		_push_preview(terrain, s.preview_mat)


## Restore the chunks to the saved material and drop the preview.
func _drop_preview(s: Dictionary) -> void:
	if s.get("preview_mat") == null:
		return
	var terrain: HeightmapTerrain = s.terrain
	if is_instance_valid(terrain):
		_push_preview(terrain, terrain.material)
	s.preview_mat = null


## Tripwire + self-heal: the saved material must never hold a pathless (transient) splatmap
## texture — that is what embeds a raw image into the .tscn on save.
func _heal_material(terrain: HeightmapTerrain) -> void:
	var mat := terrain.material as ShaderMaterial
	if mat == null:
		return
	for param: StringName in [&"splatmap", &"splatmap2"]:
		var value: Variant = mat.get_shader_parameter(param)
		if value is ImageTexture and (value as ImageTexture).resource_path.is_empty():
			mat.set_shader_parameter(param,
					terrain.splatmap if param == &"splatmap" else terrain.splatmap2)
			push_warning("Kit brush: transient %s found on the saved material — reset to the "
					% param + "terrain's texture. The live preview should never write to it.")


func _flush_image(terrain: HeightmapTerrain, kind: String, img: Image) -> void:
	var path := terrain.png_path_for(kind)
	if path.is_empty():
		return
	var err := img.save_png(path)
	if err != OK:
		push_error("Kit brush: failed to write %s (%s)" % [path, error_string(err)])
		return
	TerrainGen.ensure_import_settings(path)
	var fs := EditorInterface.get_resource_filesystem()
	fs.update_file(path)
	fs.reimport_files(PackedStringArray([path]))
	var tex := ResourceLoader.load(path, "Texture2D", ResourceLoader.CACHE_MODE_REPLACE)
	# Assigning the reimported PNG texture (same res:// path -> unchanged scene reference)
	# refreshes the node off disk: its setter full-rebuilds (height) or repushes the splat
	# param, so live state and saved artifact agree.
	if kind == "height":
		terrain.heightmap = tex
	elif kind == "splat2":
		terrain.splatmap2 = tex
	else:
		terrain.splatmap = tex


func _decode(tex: Texture2D, fmt: int) -> Image:
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null:
		return null
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	elif img.get_format() != fmt:
		img = img.duplicate()
	if img.get_format() != fmt:
		img.convert(fmt)
	return img


# ------------------------------------------------------------------ world <-> image mapping

## World surface Y under (x, z): the live working image when a height session exists (so the
## cursor and projection track in-progress sculpting), else the terrain's committed sample.
func _surface_y(x: float, z: float) -> float:
	if is_instance_valid(_terrain):
		var s: Dictionary = _sessions.get(_terrain.get_instance_id(), {})
		if s.get("height") != null:
			return _terrain.global_position.y + _sample_work_red(s.height, x, z) * _terrain.height
	return _terrain.height_at(Vector3(x, 0, z)) if is_instance_valid(_terrain) else 0.0


func _world_to_px(img: Image, world: Vector3) -> Vector2i:
	var ts := _terrain.terrain_size
	var gp := _terrain.global_position
	var u := (world.x - gp.x + ts.x * 0.5) / maxf(ts.x, 1e-3)
	var v := (world.z - gp.z + ts.y * 0.5) / maxf(ts.y, 1e-3)
	return Vector2i(roundi(u * float(img.get_width() - 1)), roundi(v * float(img.get_height() - 1)))


## Inverse of _world_to_px, returning world XZ as a Vector2 (x, z).
func _px_to_world(terrain: HeightmapTerrain, img: Image, px: Vector2i) -> Vector2:
	var ts := terrain.terrain_size
	var gp := terrain.global_position
	var u := float(px.x) / maxf(float(img.get_width() - 1), 1.0)
	var v := float(px.y) / maxf(float(img.get_height() - 1), 1.0)
	return Vector2(gp.x - ts.x * 0.5 + u * ts.x, gp.z - ts.y * 0.5 + v * ts.y)


## Bilinear red-channel sample of the working image at world XZ (matches HeightmapTerrain's
## height_at mapping, so live and committed surfaces line up).
func _sample_work_red(img: Image, x: float, z: float) -> float:
	var ts := _terrain.terrain_size
	var gp := _terrain.global_position
	var u := clampf((x - gp.x + ts.x * 0.5) / maxf(ts.x, 1e-3), 0.0, 1.0)
	var v := clampf((z - gp.z + ts.y * 0.5) / maxf(ts.y, 1e-3), 0.0, 1.0)
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
