class_name UIGlyphs
extends RefCounted

## The icon set, as maths.
##
## No image files, no icon font: every glyph here is generated from curves at
## the size it is drawn, so a 20px radial-menu icon and a 44px journal icon are
## the same drawing rather than the same bitmap resampled twice. That is not
## purity for its own sake — a desktop overlay renders at whatever UI scale the
## player's display forced on them, and 125% is the setting that exposes every
## pre-baked icon in the world.
##
## Every glyph draws inside a unit box: `size` is the full width and height it
## will occupy, centred on `center`. They are authored line-first, because a
## stroked icon holds up at 18px where a filled one turns into a blob, with a
## few solid accents (paw beans, kibble) where a filled shape is the read.

## Stroke weight as a fraction of the glyph's size. Tuned so a 20px icon gets a
## ~1.8px stroke: heavy enough to survive a light backdrop, light enough not to
## look like a warning sign.
const STROKE_RATIO := 0.09


static func stroke_w(size: float) -> float:
	return maxf(1.25, size * STROKE_RATIO)


## Draw glyph `id` centred on `center`, occupying `size` pixels.
static func draw_glyph(ci: CanvasItem, id: StringName, center: Vector2,
		size: float, color: Color) -> void:
	match id:
		&"feed": _feed(ci, center, size, color)
		&"play": _play(ci, center, size, color)
		&"pet": _paw(ci, center, size, color)
		&"sleep": _moon(ci, center, size, color)
		&"journal": _book(ci, center, size, color)
		&"settings": _gear(ci, center, size, color)
		&"adopt": _egg(ci, center, size, color)
		&"food": _feed(ci, center, size, color)
		&"rest": _moon(ci, center, size, color)
		&"clean": _droplet(ci, center, size, color)
		&"affection": _heart(ci, center, size, color, true)
		&"heart": _heart(ci, center, size, color, true)
		&"star": _star(ci, center, size, color)
		&"close": _close(ci, center, size, color)
		&"check": _check(ci, center, size, color)
		&"sparkle": _sparkle(ci, center, size, color)
		&"paw": _paw(ci, center, size, color)
		&"clock": _clock(ci, center, size, color)
		&"lock": _lock(ci, center, size, color)
		_: _paw(ci, center, size, color)


# --- Actions -----------------------------------------------------------------

## A bowl with two pieces of kibble above it. Filled rather than stroked: at
## 20px a hollow bowl and a hollow ball are the same grey ring, and the kibble
## is what disambiguates "feed" from "a bowl of soup".
static func _feed(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var r: float = s * 0.40
	var lip: float = s * 0.02
	var bowl := PackedVector2Array()
	bowl.append(c + Vector2(-r, lip))
	UIDraw.bezier(bowl, c + Vector2(-r, lip), c + Vector2(-r * 0.80, r * 0.98),
		c + Vector2(r * 0.80, r * 0.98), c + Vector2(r, lip), 16)
	UIDraw.fill_path(ci, bowl, col)
	# The rim overhangs the bowl on both sides, which is the silhouette cue
	# that says "vessel" rather than "half a circle".
	UIDraw.capsule(ci, Rect2(c.x - r * 1.20, c.y + lip - s * 0.055,
		r * 2.40, s * 0.11), col)
	UIDraw.fill_path(ci, UIDraw.circle_path(c + Vector2(-r * 0.34, -r * 0.36),
		s * 0.085, 12), col)
	UIDraw.fill_path(ci, UIDraw.circle_path(c + Vector2(r * 0.26, -r * 0.52),
		s * 0.068, 12), col)


## A ball of yarn: a circle with two wrap lines and a loose end. The wraps have
## to be well inside the rim to read as "wound around" rather than as a stray
## highlight, which is why they are ellipses at 0.34 rather than 0.42.
static func _play(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s)
	var r: float = s * 0.38
	UIDraw.stroke_path(ci, UIDraw.circle_path(c, r, 30), col, w, true)
	UIDraw.stroke_path(ci, UIDraw.circle_path(c, r * 0.99, 30,
		Vector2(1.0, 0.34), 0.70), col, w * 0.72, true)
	UIDraw.stroke_path(ci, UIDraw.circle_path(c, r * 0.99, 30,
		Vector2(1.0, 0.34), -0.70), col, w * 0.72, true)
	# The loose end. Without it the icon is a beach ball.
	var tail := PackedVector2Array()
	UIDraw.bezier(tail, c + Vector2(r * 0.72, r * 0.66), c + Vector2(r * 1.24, r * 0.86),
		c + Vector2(r * 0.94, r * 1.24), c + Vector2(r * 1.38, r * 1.34), 12)
	UIDraw.stroke_path(ci, tail, col, w * 0.72)


## Paw print: a pad and four toe beans. Used for the touch action and as the
## generic pet marker.
static func _paw(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var pad := PackedVector2Array()
	var pw: float = s * 0.30
	var ph: float = s * 0.24
	var pc: Vector2 = c + Vector2(0.0, s * 0.16)
	UIDraw.bezier(pad, pc + Vector2(-pw, -ph * 0.2), pc + Vector2(-pw * 1.15, ph * 1.25),
		pc + Vector2(pw * 1.15, ph * 1.25), pc + Vector2(pw, -ph * 0.2), 16)
	UIDraw.bezier(pad, pc + Vector2(pw, -ph * 0.2), pc + Vector2(pw * 0.72, -ph * 1.15),
		pc + Vector2(-pw * 0.72, -ph * 1.15), pc + Vector2(-pw, -ph * 0.2), 16)
	UIDraw.fill_path(ci, pad, col)
	var toes := [
		Vector2(-0.30, -0.20), Vector2(-0.11, -0.34),
		Vector2(0.11, -0.34), Vector2(0.30, -0.20),
	]
	var tilt := [-0.5, -0.18, 0.18, 0.5]
	for i in 4:
		var p: Vector2 = c + (toes[i] as Vector2) * s
		UIDraw.fill_path(ci, UIDraw.circle_path(p, s * 0.115, 16,
			Vector2(0.86, 1.14), tilt[i]), col)


## Crescent moon, drawn as a tapered arc rather than as a boolean of two
## circles: the taper puts real points on the tips, which is the difference
## between a moon and a fat comma.
static func _moon(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var r: float = s * 0.36
	var path := UIDraw.tapered_arc(c + Vector2(s * 0.07, 0.0), r,
		PI * 0.42, PI * 1.58,
		func(t: float) -> float: return s * 0.155 * pow(sin(PI * t), 0.62), 30)
	UIDraw.fill_path(ci, path, col)


## Closed book seen from the front: cover, spine and a ribbon.
static func _book(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s)
	var half := Vector2(s * 0.32, s * 0.40)
	var rect := Rect2(c - half, half * 2.0)
	UIDraw.round_rect_outline(ci, rect, s * 0.09, col, w)
	# Spine, inset from the left edge — the one line that says "book" and not
	# "rectangle".
	ci.draw_line(Vector2(rect.position.x + s * 0.15, rect.position.y + w),
		Vector2(rect.position.x + s * 0.15, rect.end.y - w), col, w * 0.85, true)
	# Bookmark ribbon, inset from the cover edge so it does not weld itself to
	# the outline and turn the whole glyph into a solid block.
	var rx: float = rect.end.x - s * 0.155
	var ribbon := PackedVector2Array([
		Vector2(rx - s * 0.055, rect.position.y),
		Vector2(rx + s * 0.055, rect.position.y),
		Vector2(rx + s * 0.055, rect.position.y + s * 0.27),
		Vector2(rx, rect.position.y + s * 0.20),
		Vector2(rx - s * 0.055, rect.position.y + s * 0.27),
	])
	UIDraw.fill_path(ci, ribbon, col)


## Gear. Teeth are generated by modulating the radius with a plateau function
## rather than by extruding boxes, so the profile stays smooth at any size.
static func _gear(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s)
	const TEETH := 7
	var r_out: float = s * 0.42
	var r_in: float = s * 0.32
	var pts := PackedVector2Array()
	var steps: int = TEETH * 16
	for i in steps:
		var a: float = TAU * float(i) / float(steps)
		var t: float = fposmod(a * float(TEETH) / TAU, 1.0)
		var tooth: float = smoothstep(0.06, 0.22, t) - smoothstep(0.50, 0.66, t)
		var r: float = lerpf(r_in, r_out, tooth)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	UIDraw.stroke_path(ci, pts, col, w, true)
	UIDraw.stroke_path(ci, UIDraw.circle_path(c, s * 0.145, 20), col, w * 0.9, true)


## Egg with a sparkle: "a new life arrives", which is what adoption is. A heart
## would have collided with the affection meter's language.
static func _egg(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s)
	var pts := PackedVector2Array()
	var steps := 40
	for i in steps:
		var t: float = TAU * float(i) / float(steps)
		# Classic egg curve: the (1 - k*cos) term narrows the top pole only.
		var x: float = s * 0.27 * sin(t)
		var y: float = -s * 0.37 * cos(t) * (1.0 - 0.16 * cos(t))
		pts.append(c + Vector2(x - s * 0.04, y + s * 0.05))
	UIDraw.stroke_path(ci, pts, col, w, true)
	# The sparkle sits clear of the shell. Touching it, the two shapes merge
	# into one blob and the glyph starts reading as a magnifier.
	_sparkle(ci, c + Vector2(s * 0.36, -s * 0.33), s * 0.23, col)


# --- Needs and status --------------------------------------------------------

static func _droplet(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var top: Vector2 = c + Vector2(0.0, -s * 0.42)
	var r: float = s * 0.28
	var bc: Vector2 = c + Vector2(0.0, s * 0.14)
	var pts := PackedVector2Array()
	pts.append(top)
	UIDraw.bezier(pts, top, bc + Vector2(-r * 0.95, -r * 0.85),
		bc + Vector2(-r, r * 0.55), bc + Vector2(0.0, r), 14)
	UIDraw.bezier(pts, bc + Vector2(0.0, r), bc + Vector2(r, r * 0.55),
		bc + Vector2(r * 0.95, -r * 0.85), top, 14)
	UIDraw.fill_path(ci, pts, col)


static func heart_path(c: Vector2, s: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 44
	for i in steps:
		var t: float = TAU * float(i) / float(steps)
		# The standard cardioid-ish heart; scaled so the widest span is `s`.
		var x: float = 16.0 * pow(sin(t), 3.0)
		var y: float = -(13.0 * cos(t) - 5.0 * cos(2.0 * t)
			- 2.0 * cos(3.0 * t) - cos(4.0 * t))
		pts.append(c + Vector2(x, y) * (s / 33.0))
	return pts


static func _heart(ci: CanvasItem, c: Vector2, s: float, col: Color,
		filled: bool) -> void:
	var pts := heart_path(c + Vector2(0.0, s * 0.02), s)
	if filled:
		UIDraw.fill_path(ci, pts, col)
	else:
		UIDraw.stroke_path(ci, pts, col, stroke_w(s), true)


static func _star(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 10:
		var a: float = -PI * 0.5 + TAU * float(i) / 10.0
		var r: float = s * (0.46 if i % 2 == 0 else 0.20)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	UIDraw.fill_path(ci, pts, col)


## Four-point sparkle with concave sides — the "new / special" mark. Concave is
## what stops it reading as a plus sign.
static func _sparkle(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var pts := PackedVector2Array()
	var steps := 48
	for i in steps:
		var a: float = TAU * float(i) / float(steps)
		var k: float = pow(absf(cos(2.0 * a)), 1.8)
		pts.append(c + Vector2(cos(a), sin(a)) * s * 0.5 * lerpf(0.10, 1.0, k))
	UIDraw.fill_path(ci, pts, col)


static func _close(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s) * 0.95
	var r: float = s * 0.28
	ci.draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, w, true)
	ci.draw_line(c + Vector2(r, -r), c + Vector2(-r, r), col, w, true)


static func _check(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s) * 1.05
	UIDraw.stroke_path(ci, PackedVector2Array([
		c + Vector2(-s * 0.30, s * 0.02),
		c + Vector2(-s * 0.08, s * 0.24),
		c + Vector2(s * 0.32, -s * 0.24),
	]), col, w)


static func _clock(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s) * 0.9
	UIDraw.stroke_path(ci, UIDraw.circle_path(c, s * 0.38, 26), col, w, true)
	ci.draw_line(c, c + Vector2(0.0, -s * 0.22), col, w, true)
	ci.draw_line(c, c + Vector2(s * 0.17, s * 0.05), col, w, true)


static func _lock(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var w := stroke_w(s) * 0.9
	var body := Rect2(c + Vector2(-s * 0.26, -s * 0.04), Vector2(s * 0.52, s * 0.40))
	UIDraw.round_rect(ci, body, s * 0.09, col)
	var shackle := PackedVector2Array()
	for i in 17:
		var a: float = PI + PI * float(i) / 16.0
		shackle.append(c + Vector2(cos(a), sin(a)) * s * 0.17 + Vector2(0.0, -s * 0.04))
	UIDraw.stroke_path(ci, shackle, col, w)
