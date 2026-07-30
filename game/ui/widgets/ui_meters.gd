class_name UIMeters
extends RefCounted

## Drawing routines for every meter in the game — need rings, the affection
## ribbon, the growth arc.
##
## They live together because they share one rule: **the number is never the
## message**. A desktop pet whose interface is four labelled percentages is a
## task list, and people close task lists. So the value is carried by fill,
## colour and motion first, and the number is available underneath for the
## player who wants it.
##
## Static functions rather than nodes: a need ring is drawn inside the care
## panel's own `_draw`, and spawning four `Control`s to host four arcs would
## cost more than it explains.


## A need, as a ring with the need's glyph inside.
##
## `t` is the animated fill (already smoothed by the caller), `pulse` a [0,1]
## breath used when the need is critical. The ring starts at the top and sweeps
## clockwise, because a partly-drained ring has to be readable as "how much is
## left" at a glance and top-start is the clock convention everyone already has.
static func need_ring(ci: CanvasItem, center: Vector2, radius: float,
		need: StringName, t: float, pulse: float = 0.0,
		hover: float = 0.0) -> void:
	var width: float = radius * 0.20
	var col := UITokens.need_col_at(need, t)
	var track := UITokens.col(&"sunken")

	# Critical needs glow rather than flash. A flash is an alarm; a glow is a
	# creature asking for something, which is the relationship this game wants.
	if pulse > 0.001:
		var g := col
		g.a = 0.20 * pulse
		UIDraw.glow(ci, center, radius * 1.55, g, 5)

	ci.draw_arc(center, radius, 0.0, TAU, 40, track, width, true)
	var start: float = -PI * 0.5
	UIDraw.ring(ci, center, radius, width, start, TAU, t,
		col.lightened(hover * 0.14))

	# A cap on the leading end turns a stroke into a dial. Without it the arc's
	# butt end looks like a rendering mistake at small radii.
	if t > 0.012 and t < 0.995:
		var a: float = start + TAU * t
		UIDraw.fill_path(ci, UIDraw.circle_path(
			center + Vector2(cos(a), sin(a)) * radius, width * 0.5, 12), col)

	var glyph_col := UITokens.col(&"text_dim").lerp(col, 0.55 + hover * 0.45)
	UIGlyphs.draw_glyph(ci, need, center, radius * 1.02, glyph_col)


## Affection. Wider and warmer than a need meter, with a gradient built from
## stacked capsules — there is no gradient primitive in Godot's 2D drawing API,
## and stepping it by hand keeps the whole UI free of textures.
static func affection_ribbon(ci: CanvasItem, rect: Rect2, t: float,
		beat: float = 0.0) -> void:
	var r: float = rect.size.y * 0.5
	UIDraw.capsule(ci, rect, UITokens.col(&"sunken"))

	var amount: float = clampf(t, 0.0, 1.0)
	if amount <= 0.001:
		return
	var fill_w: float = maxf(rect.size.y, rect.size.x * amount)
	var fill := Rect2(rect.position, Vector2(fill_w, rect.size.y))

	# Warm end to cool end across the fill, so a nearly-full bar is visibly a
	# different colour from a nearly-empty one even in greyscale.
	var a_col := UITokens.col(&"affection")
	var b_col := UITokens.col(&"accent")
	const STEPS := 14
	for i in STEPS:
		var f0: float = float(i) / float(STEPS)
		var f1: float = float(i + 1) / float(STEPS)
		var seg := Rect2(fill.position + Vector2(fill.size.x * f0, 0.0),
			Vector2(fill.size.x * (f1 - f0) + 1.0, fill.size.y))
		# Each slice is a capsule clipped by the next one drawn over it, which
		# keeps the rounded ends without a stencil.
		var c: Color = a_col.lerp(b_col, f0)
		if i == 0 or i == STEPS - 1:
			UIDraw.round_rect(ci, seg, minf(r, seg.size.x * 0.5), c)
		else:
			ci.draw_rect(seg, c)
	# The heartbeat: a soft highlight travelling the length of the filled part.
	# It is the only always-on motion in the interface, and it is there because
	# affection is the one value that should feel alive rather than measured.
	if beat > 0.0 and not UITokens.reduced_motion:
		var x: float = fill.position.x + fill.size.x * beat
		for i in 5:
			var k: float = float(i) / 4.0
			var hl := Color(1, 1, 1, 0.13 * (1.0 - k))
			var w: float = rect.size.y * (0.6 + k * 2.2)
			var seg := Rect2(x - w * 0.5, rect.position.y, w, rect.size.y)
			seg = seg.intersection(fill)
			if seg.size.x > 0.5:
				ci.draw_rect(seg, hl)

	# Inner shadow along the top of the groove. One line, and the meter stops
	# looking like a coloured rectangle.
	var lip := Rect2(rect.position, Vector2(rect.size.x, UITokens.s(1.0)))
	ci.draw_rect(lip, Color(0, 0, 0, 0.13))


## Growth toward the next life stage, as a three-quarter arc around the pet's
## portrait. Three quarters rather than a full circle so it has a visible
## beginning and end — a full ring at 40% looks like a loading spinner.
static func growth_arc(ci: CanvasItem, center: Vector2, radius: float,
		t: float, complete: bool) -> void:
	const SWEEP := TAU * 0.74
	var start: float = PI * 0.5 + (TAU - SWEEP) * 0.5
	var width: float = UITokens.s(4.0)
	ci.draw_arc(center, radius, start, start + SWEEP, 56,
		UITokens.col(&"sunken"), width, true)

	var col := UITokens.col(&"accent")
	if complete:
		col = UITokens.col(&"positive")
	UIDraw.ring(ci, center, radius, width, start, SWEEP, t, col)

	# Ticks at the three stage boundaries, so the arc reads as a life rather
	# than as a percentage.
	for i in 4:
		var f: float = float(i) / 3.0
		var a: float = start + SWEEP * f
		var dir := Vector2(cos(a), sin(a))
		var reached: bool = f <= t + 0.001
		var c: Color = col if reached else UITokens.col(&"edge_strong")
		UIDraw.fill_path(ci, UIDraw.circle_path(center + dir * radius,
			width * (0.85 if reached else 0.55), 10), c)

	if t > 0.02 and t < 0.999:
		var a2: float = start + SWEEP * t
		var tip := center + Vector2(cos(a2), sin(a2)) * radius
		var g := col
		g.a = 0.35
		UIDraw.glow(ci, tip, width * 2.6, g, 4)


## A thin linear bar, for settings sliders and journal stat strips.
static func track(ci: CanvasItem, rect: Rect2, t: float, col: Color,
		filled_from: float = 0.0) -> void:
	UIDraw.capsule(ci, rect, UITokens.col(&"sunken"))
	var a: float = clampf(minf(filled_from, t), 0.0, 1.0)
	var b: float = clampf(maxf(filled_from, t), 0.0, 1.0)
	if b - a <= 0.0005:
		return
	var fill := Rect2(rect.position + Vector2(rect.size.x * a, 0.0),
		Vector2(maxf(rect.size.x * (b - a), rect.size.y), rect.size.y))
	UIDraw.capsule(ci, fill, col)
