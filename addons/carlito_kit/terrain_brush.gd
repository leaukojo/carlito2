@tool
extends "res://addons/carlito_kit/brush_chassis.gd"
## Terrain sculpt/paint brush (level_kit_plan.md LK4). Rides the shared brush chassis; adds
## the terrain-specific half: raise / lower / smooth / flatten on the heightmap image, and
## splat-channel painting on the LK3 splatmap.
##
## Editor-only by construction (plan LK4): a brush edits image CONTENT only. It never swaps
## the terrain's exported heightmap/splatmap Texture2D (so the scene always serializes the
## PNG reference, never a transient in-memory texture). Live feedback comes from remeshing
## the touched chunks straight off the working image (height) and a temporary splatmap shader
## override (paint). Edits accumulate in memory and are written to the PNGs only on SCENE
## SAVE (flush_all, wired to the plugin's _save_external_data) — never reimported per stroke.
## The heightmap/splat PNGs stay the sole artifact the runtime and baker already read.

const BrushOps := preload("res://kit/helpers/brush_ops.gd")
const TerrainGen := preload("res://kit/terrain/terrain_gen.gd")

# Brush modes (index-matched to the panel's buttons: 0 = Off .. 5 = Paint).
enum { OFF, RAISE, LOWER, SMOOTH, FLATTEN, PAINT }

var mode := OFF
var channel := 0  # splat channel to paint: 0/1/2/3 = grass/dirt/sand/rock

var _undo: EditorUndoRedoManager
var _terrain: HeightmapTerrain = null

# Per-terrain edit session, kept until scene save (flush) or plugin exit — so deselecting
# doesn't drop uncommitted work and undo stays coherent across reselection.
# id -> { terrain, height:Image, splat:Image, splat_tex:ImageTexture,
#         height_dirty:bool, splat_dirty:bool }
var _sessions := {}

# Active-stroke state.
var _stroke_kind := "height"
var _stroke_before: Image = null   # full snapshot at stroke begin (dirty region carved out at end)
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


## Write every dirty session's working image back to its PNG and reimport once (plan LK4:
## PNGs saved on scene save). Called from the plugin's _save_external_data hook.
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


func teardown() -> void:
	_free_cursor()
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
			return [Color(0.4, 0.8, 0.35), Color(0.6, 0.45, 0.3),
					Color(0.85, 0.78, 0.55), Color(0.55, 0.55, 0.55)][clampi(channel, 0, 3)]
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
	_dirty_any = false
	if work == null:
		push_warning("Kit brush: %s first." % ("auto-splat the terrain" if _stroke_kind == "splat"
				else "generate a heightmap"))
		return
	_stroke_before = work.duplicate()
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
		dirty = BrushOps.stamp_splat(work, c.x, c.y, rx, rz, channel, strength, falloff)
	else:
		dirty = BrushOps.stamp_height(work, c.x, c.y, rx, rz, mode - RAISE, strength, falloff,
				_flatten_target)
	if dirty.size == Vector2i.ZERO:
		return
	_dirty = dirty if not _dirty_any else _dirty.merge(dirty)
	_dirty_any = true

	if mode == PAINT:
		_refresh_splat(_terrain, work)
		_mark_dirty(_terrain, "splat")
	else:
		# Remesh only the chunks under the brush footprint (plan LK4: never a full rebuild
		# per stroke). Collision is deferred to stroke end.
		_terrain.rebuild_region_world(work, center.x - radius, center.x + radius,
				center.z - radius, center.z + radius)
		_mark_dirty(_terrain, "height")


func _stroke_end() -> void:
	if not _dirty_any or _stroke_before == null:
		_stroke_before = null
		return
	var work := _work_for(_terrain, _stroke_kind)
	if _stroke_kind == "height":
		_terrain.rebuild_collision_from_image(work)  # catch physics up once, at stroke end

	# Undo snapshots only the touched region of each side (plan LK4).
	var before_region := _stroke_before.get_region(_dirty)
	var after_region := work.get_region(_dirty)
	_stroke_before = null
	var pos := _dirty.position
	var scene_root := EditorInterface.get_edited_scene_root()
	_undo.create_action("Paint terrain" if _stroke_kind == "splat" else "Sculpt terrain",
			UndoRedo.MERGE_DISABLE, scene_root)
	_undo.add_do_method(self, "_apply_region", _terrain, _stroke_kind, after_region, pos)
	_undo.add_undo_method(self, "_apply_region", _terrain, _stroke_kind, before_region, pos)
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
	if kind == "splat":
		_refresh_splat(terrain, work)
		return
	var lo := _px_to_world(terrain, work, pos)
	var hi := _px_to_world(terrain, work, pos + region.get_size())
	terrain.rebuild_region_world(work, minf(lo.x, hi.x), maxf(lo.x, hi.x),
			minf(lo.y, hi.y), maxf(lo.y, hi.y))
	terrain.rebuild_collision_from_image(work)


# ------------------------------------------------------------------ session / image helpers

func _work_for(terrain: HeightmapTerrain, kind: String) -> Image:
	var id := terrain.get_instance_id()
	if not _sessions.has(id):
		_sessions[id] = {
			"terrain": terrain, "height": null, "splat": null, "splat_tex": null,
			"height_dirty": false, "splat_dirty": false,
		}
	var s: Dictionary = _sessions[id]
	if kind == "height":
		if s.height == null:
			s.height = _decode(terrain.heightmap, Image.FORMAT_L8)
		return s.height
	if s.splat == null:
		s.splat = _decode(terrain.splatmap, Image.FORMAT_RGBA8)
	return s.splat


func _mark_dirty(terrain: HeightmapTerrain, kind: String) -> void:
	var s: Dictionary = _sessions[terrain.get_instance_id()]
	s["height_dirty" if kind == "height" else "splat_dirty"] = true


## Show live paint without touching the exported splatmap property: drive the material's
## splatmap shader param from a throwaway ImageTexture we update per sample. On save, flush
## sets terrain.splatmap to the reimported PNG, which overwrites this override.
func _refresh_splat(terrain: HeightmapTerrain, work: Image) -> void:
	var s: Dictionary = _sessions[terrain.get_instance_id()]
	if s.splat_tex == null:
		s.splat_tex = ImageTexture.create_from_image(work)
	else:
		(s.splat_tex as ImageTexture).update(work)
	if terrain.material is ShaderMaterial:
		(terrain.material as ShaderMaterial).set_shader_parameter(&"splatmap", s.splat_tex)


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
