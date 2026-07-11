extends RefCounted
## Pure, unit-tested brush math (level_kit_plan.md LK4). The terrain sculpt/paint brush
## (addons/carlito_kit/terrain_brush.gd) is editor-only, but the per-pixel stamp math is
## plain Image arithmetic with no editor API, so it gets the same test discipline as
## TerrainGen/Drivetrain (tests/test_brush_ops.gd). Lives in kit/ (plan §2: data +
## runtime-safe logic here, editor UX in addons/carlito_kit).
##
## Everything is deterministic and works in PIXEL space with separate x/z pixel radii, so a
## world-circular brush on a non-square terrain stamps as an ellipse in image space. The
## height image is greyscale (red channel = normalized height [0,1]); the splatmap is RGBA
## weights (R=grass, G=dirt, B=sand, A=rock — TerrainGen's channel order).

# Sculpt modes (raise/lower shift the normalized height; smooth blurs; flatten pulls toward
# a captured target). Paint is a separate stamp (stamp_splat), not a sculpt mode.
enum { RAISE, LOWER, SMOOTH, FLATTEN }

## Normalized height change per full-strength, full-weight sample for raise/lower. Small so a
## drag ramps smoothly (samples are throttled by spacing in the brush) and 8-bit height PNGs
## still accumulate visibly (0.05 * 255 ~ 13 levels at full strength).
const RATE := 0.05


## Radial brush weight for a normalized distance t (0 at centre, 1 at the rim). `falloff`
## in [0,1] is the softness: 0 = a hard disk (weight 1 out to the rim), 1 = a smooth dome
## from the centre. The solid inner fraction is (1 - falloff); beyond it the weight
## smoothsteps down to 0 at t = 1.
static func weight(t: float, falloff: float) -> float:
	if t <= 0.0:
		return 1.0
	if t >= 1.0:
		return 0.0
	var inner := clampf(1.0 - falloff, 0.0, 1.0)
	if t <= inner:
		return 1.0
	var x := (t - inner) / maxf(1.0 - inner, 1e-4)
	return 1.0 - x * x * (3.0 - 2.0 * x)


## One sculpt op on a normalized height value. `amount` is strength * weight (0..1): raise/
## lower add/subtract amount*RATE, smooth lerps toward the local average, flatten lerps
## toward the stroke's captured target. Result clamped to [0,1].
static func sculpt_value(mode: int, value: float, avg: float, target: float,
		amount: float) -> float:
	match mode:
		RAISE:
			return clampf(value + amount * RATE, 0.0, 1.0)
		LOWER:
			return clampf(value - amount * RATE, 0.0, 1.0)
		SMOOTH:
			return clampf(lerpf(value, avg, amount), 0.0, 1.0)
		FLATTEN:
			return clampf(lerpf(value, target, amount), 0.0, 1.0)
	return value


## Stamp a sculpt op into the greyscale height image, centred on pixel (cx, cy) with pixel
## radii (rx, rz). Reads base + neighbour heights from a snapshot of the touched region (so
## smooth is unbiased by the write order) and writes new heights back. Returns the tight
## dirty Rect2i in pixels (empty when nothing changed), which the brush unions for the undo
## snapshot and the incremental remesh.
static func stamp_height(img: Image, cx: int, cy: int, rx: float, rz: float,
		mode: int, strength: float, falloff: float, target: float) -> Rect2i:
	var iw := img.get_width()
	var ih := img.get_height()
	var x0 := clampi(cx - int(ceil(rx)) - 1, 0, iw - 1)
	var x1 := clampi(cx + int(ceil(rx)) + 1, 0, iw - 1)
	var y0 := clampi(cy - int(ceil(rz)) - 1, 0, ih - 1)
	var y1 := clampi(cy + int(ceil(rz)) + 1, 0, ih - 1)
	var src := img.get_region(Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1))
	var sw := src.get_width()
	var sh := src.get_height()

	var minx := iw
	var miny := ih
	var maxx := -1
	var maxy := -1
	for py in range(y0, y1 + 1):
		for px in range(x0, x1 + 1):
			var dx := float(px - cx) / maxf(rx, 1e-4)
			var dz := float(py - cy) / maxf(rz, 1e-4)
			var t := sqrt(dx * dx + dz * dz)
			if t > 1.0:
				continue
			var w := weight(t, falloff)
			if w <= 0.0:
				continue
			var lx := px - x0
			var ly := py - y0
			var value := src.get_pixel(lx, ly).r
			var nv := sculpt_value(mode, value, _avg(src, lx, ly, sw, sh), target,
					strength * w)
			img.set_pixel(px, py, Color(nv, nv, nv))
			minx = mini(minx, px); miny = mini(miny, py)
			maxx = maxi(maxx, px); maxy = maxi(maxy, py)
	if maxx < 0:
		return Rect2i()
	return Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)


## Stamp a splat-channel paint into the RGBA splatmap: pulls each touched pixel toward the
## pure selected channel (channel 0..3 = R/G/B/A = grass/dirt/sand/rock) by strength*weight.
## The splat shader renormalizes, so lerping toward the unit colour reads as "painting grass
## over dirt". Returns the dirty Rect2i in pixels.
static func stamp_splat(img: Image, cx: int, cy: int, rx: float, rz: float,
		channel: int, strength: float, falloff: float) -> Rect2i:
	var iw := img.get_width()
	var ih := img.get_height()
	var x0 := clampi(cx - int(ceil(rx)) - 1, 0, iw - 1)
	var x1 := clampi(cx + int(ceil(rx)) + 1, 0, iw - 1)
	var y0 := clampi(cy - int(ceil(rz)) - 1, 0, ih - 1)
	var y1 := clampi(cy + int(ceil(rz)) + 1, 0, ih - 1)
	var unit := Color(0, 0, 0, 0)
	match clampi(channel, 0, 3):
		0: unit.r = 1.0
		1: unit.g = 1.0
		2: unit.b = 1.0
		3: unit.a = 1.0

	var minx := iw
	var miny := ih
	var maxx := -1
	var maxy := -1
	for py in range(y0, y1 + 1):
		for px in range(x0, x1 + 1):
			var dx := float(px - cx) / maxf(rx, 1e-4)
			var dz := float(py - cy) / maxf(rz, 1e-4)
			var t := sqrt(dx * dx + dz * dz)
			if t > 1.0:
				continue
			var w := weight(t, falloff)
			if w <= 0.0:
				continue
			img.set_pixel(px, py, img.get_pixel(px, py).lerp(unit, clampf(strength * w, 0.0, 1.0)))
			minx = mini(minx, px); miny = mini(miny, py)
			maxx = maxi(maxx, px); maxy = maxi(maxy, py)
	if maxx < 0:
		return Rect2i()
	return Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)


## Average of a pixel and its 4 clamped neighbours (the smooth kernel), read from the region
## snapshot so the blur is independent of write order.
static func _avg(src: Image, x: int, y: int, w: int, h: int) -> float:
	var acc := src.get_pixel(x, y).r
	var n := 1.0
	for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		acc += src.get_pixel(clampi(x + d.x, 0, w - 1), clampi(y + d.y, 0, h - 1)).r
		n += 1.0
	return acc / n
