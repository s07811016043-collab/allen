class_name UIDraw
extends RefCounted

## Vector drawing primitives shared by every custom-drawn widget.
##
## Petalia's UI is drawn, not assembled from nine-patch images — there are no
## bitmaps in this project at all. That means the quality of a rounded corner is
## decided here, once, rather than being a property of an asset someone exported
## at the wrong scale.
##
## The recurring trick below is *fill plus outline*: `draw_colored_polygon` has
## no anti-aliasing, `draw_polyline` does, so filling a path and then stroking
## its own boundary in its own colour recovers a clean edge for the cost of one
## extra draw call. Without it every icon in the radial menu would have visible
## stair-stepping at the 22px it is actually seen at.

## Corner subdivision. Eight segments is where a 22px radius stops showing
## facets on a 1x display; more is wasted on a widget this size.
const CORNER_STEPS := 8


static func _close(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	if out.size() > 0:
		out.append(out[0])
	return out


## Filled path with an anti-aliased boundary.
##
## Coincident vertices are dropped first. Godot's polygon triangulator rejects
## the whole shape when two points land on each other, and several of the
## generated paths here legitimately produce them — a tapered arc's tips, a
## closed curve whose last sample meets its first.
static func fill_path(ci: CanvasItem, pts: PackedVector2Array, color: Color) -> void:
	var clean := dedupe(pts)
	if clean.size() < 3 or color.a <= 0.002:
		return
	ci.draw_colored_polygon(clean, color)
	ci.draw_polyline(_close(clean), color, 1.0, true)


static func dedupe(pts: PackedVector2Array, epsilon: float = 0.02) -> PackedVector2Array:
	var out := PackedVector2Array()
	var e2: float = epsilon * epsilon
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_squared_to(p) > e2:
			out.append(p)
	while out.size() > 1 and out[0].distance_squared_to(out[out.size() - 1]) <= e2:
		out.remove_at(out.size() - 1)
	return out


static func stroke_path(ci: CanvasItem, pts: PackedVector2Array, color: Color,
		width: float, closed: bool = false) -> void:
	if pts.size() < 2:
		return
	ci.draw_polyline(_close(pts) if closed else pts, color, width, true)


## Rounded-rectangle outline as a point list, so it can be filled, stroked, or
## used as a clip path by the caller.
static func round_rect_path(rect: Rect2, radius: float) -> PackedVector2Array:
	var r: float = minf(radius, minf(rect.size.x, rect.size.y) * 0.5)
	var pts := PackedVector2Array()
	var corners := [
		Vector2(rect.end.x - r, rect.position.y + r),
		Vector2(rect.end.x - r, rect.end.y - r),
		Vector2(rect.position.x + r, rect.end.y - r),
		Vector2(rect.position.x + r, rect.position.y + r),
	]
	# Start at the +x/-y corner and sweep clockwise in screen space (y down).
	for c in 4:
		var base: float = -PI * 0.5 + float(c) * PI * 0.5
		for i in CORNER_STEPS + 1:
			var a: float = base + PI * 0.5 * (float(i) / float(CORNER_STEPS))
			pts.append(corners[c] + Vector2(cos(a), sin(a)) * r)
	return pts


static func round_rect(ci: CanvasItem, rect: Rect2, radius: float, color: Color) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	fill_path(ci, round_rect_path(rect, radius), color)


static func round_rect_outline(ci: CanvasItem, rect: Rect2, radius: float,
		color: Color, width: float = 1.0) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	stroke_path(ci, round_rect_path(rect, radius), color, width, true)


## A capsule — a rounded rect whose radius is half its height. Every meter in
## the game is one of these, so it gets its own name.
static func capsule(ci: CanvasItem, rect: Rect2, color: Color) -> void:
	round_rect(ci, rect, rect.size.y * 0.5, color)


## Cubic bezier sampled into `steps` segments, appended to `into`. The first
## point is skipped when `into` already ends on it, so chained curves do not
## deposit duplicate vertices for the outline pass to trip over.
static func bezier(into: PackedVector2Array, p0: Vector2, p1: Vector2,
		p2: Vector2, p3: Vector2, steps: int = 10) -> void:
	var start: int = 0 if into.is_empty() else 1
	for i in range(start, steps + 1):
		var t: float = float(i) / float(steps)
		var u: float = 1.0 - t
		into.append(u * u * u * p0 + 3.0 * u * u * t * p1
			+ 3.0 * u * t * t * p2 + t * t * t * p3)


## Circle path as points, so it can go through the same fill/stroke pair as
## everything else (and be scaled into an ellipse by the caller).
static func circle_path(center: Vector2, radius: float, steps: int = 28,
		squash: Vector2 = Vector2.ONE, rotation: float = 0.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var a: float = TAU * float(i) / float(steps)
		var p := Vector2(cos(a), sin(a)) * radius * squash
		pts.append(center + p.rotated(rotation))
	return pts


## Arc as a *tapered ribbon*: a centreline arc with a half-width that varies
## along it. This is how the crescent moon, the affection ribbon's highlight and
## the growth arc's leading tip are all drawn — a constant-width arc reads as a
## progress bar bent into a circle, a tapered one reads as a drawn mark.
static func tapered_arc(center: Vector2, radius: float, a0: float, a1: float,
		half_width_at: Callable, steps: int = 32) -> PackedVector2Array:
	var outer := PackedVector2Array()
	var inner := PackedVector2Array()
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		var a: float = lerpf(a0, a1, t)
		var dir := Vector2(cos(a), sin(a))
		var w: float = float(half_width_at.call(t))
		outer.append(center + dir * (radius + w))
		inner.append(center + dir * (radius - w))
	inner.reverse()
	outer.append_array(inner)
	return outer


## Ring meter. `t` in [0,1] of the sweep from `from_angle` over `sweep`.
## Drawn with `draw_arc` because a thick AA arc is one primitive there and a
## few hundred vertices here.
static func ring(ci: CanvasItem, center: Vector2, radius: float, width: float,
		from_angle: float, sweep: float, t: float, color: Color) -> void:
	var amount: float = clampf(t, 0.0, 1.0)
	if amount <= 0.0005:
		return
	ci.draw_arc(center, radius, from_angle, from_angle + sweep * amount,
		maxi(12, int(48.0 * amount)), color, width, true)


## Focus ring. Two rings, not one: a bright inner ring for the accent and a
## dark outer halo so the indicator survives on both a white document and a
## black terminal. A single-colour focus ring is invisible half the time on a
## desktop overlay, which makes keyboard navigation unusable exactly when the
## player needs it most.
static func focus_ring(ci: CanvasItem, rect: Rect2, radius: float,
		strength: float = 1.0) -> void:
	if strength <= 0.01:
		return
	var halo := Color(0.0, 0.0, 0.0, 0.45 * strength)
	if UITokens.scheme == UITokens.Scheme.LIGHT:
		halo = Color(1.0, 1.0, 1.0, 0.75 * strength)
	var outer := rect.grow(UITokens.s(3.5))
	round_rect_outline(ci, outer, radius + UITokens.s(3.5), halo, UITokens.s(3.0))
	var focus := UITokens.col(&"focus")
	focus.a *= strength
	round_rect_outline(ci, rect.grow(UITokens.s(2.0)),
		radius + UITokens.s(2.0), focus, UITokens.s(2.0))


## Text helper that positions by the *top-left of the line box* rather than by
## the baseline, which is what every layout in this UI actually wants.
static func text(ci: CanvasItem, pos: Vector2, s: String, role: UIType.Role,
		color: Color, weight: float = -1.0,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
		width: float = -1.0) -> void:
	var f := UIType.font(role, weight)
	var px := UIType.px(role)
	ci.draw_string(f, pos + Vector2(0.0, f.get_ascent(px)), s, align, width, px, color)


## Uppercase micro-label with tracking, used for section headings. Small caps
## with wide tracking is how a UI says "this is a category, not content" without
## spending a heavier weight or a colour on it.
static func eyebrow(ci: CanvasItem, pos: Vector2, s: String, color: Color) -> void:
	var f := UIType.variation(UIType.WEIGHT_SEMI, 1.0)
	var px := UIType.px(UIType.Role.MICRO)
	ci.draw_string(f, pos + Vector2(0.0, f.get_ascent(px)), s.to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, color)


## Soft radial glow, for hover states and for "this need is critical". Built
## from concentric strokes rather than a texture, since there are no textures.
static func glow(ci: CanvasItem, center: Vector2, radius: float, color: Color,
		layers: int = 6) -> void:
	for i in layers:
		var t: float = float(i) / float(layers - 1)
		var c := color
		c.a = color.a * pow(1.0 - t, 2.2) * 0.5
		ci.draw_circle(center, radius * lerpf(0.35, 1.0, t), c, true, -1.0, true)
