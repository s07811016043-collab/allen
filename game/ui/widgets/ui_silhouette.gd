class_name UISilhouette
extends Control

## A creature drawn from its own species spec, as flat vector shapes.
##
## The journal's growth timeline and the adoption screen both have to show what
## an animal looks like at a life stage the player has not reached yet. Spinning
## up a real `CreatureRenderer` for each would mean five shader quads, five
## uniform uploads and five rigs for what is, in interface terms, an
## illustration. So this reads the same `SDFPart` list the renderer does and
## draws each capsule as a filled path: the convex hull of two circles, which is
## exactly what a tapered capsule's outline is.
##
## The result is intentionally not a miniature of the game view. It is a
## paper-cut of the same animal — same proportions, same growth morph, same
## palette, flattened. A shrunken screenshot would compete with the pet on the
## desktop; an illustration reads as a record of it.
##
## Everything reaches into `core/` and `species/` by path rather than by type.
## Those files are under active development by other people, and an interface
## that fails to parse because a rig refactor is halfway done is worse than one
## that quietly draws nothing.

enum Style {
	TINTED,  ## Palette colours, layer-separated. The hero treatment.
	FLAT,    ## One colour. Timeline steps, ghosted future stages.
}

const GROWTH_PATH := "res://core/creature/growth.gd"
const PART_PATH := "res://core/creature/sdf_part.gd"
const EYE_PATH := "res://core/creature/eye_spec.gd"

@export var species: StringName = &"cat":
	set(v):
		species = v
		_spec = null
		queue_redraw()
@export var growth: float = 3.0:
	set(v):
		growth = v
		_dirty = true
		queue_redraw()
@export var style: Style = Style.TINTED:
	set(v):
		style = v
		queue_redraw()
## Colour used by `FLAT`, and the colour everything tints toward in `TINTED`.
@export var flat_color: Color = Color(1, 1, 1, 1)
## Fraction of the control's height the creature fills.
@export var fill_ratio: float = 0.86
## Vertical bob, in pixels. The adoption preview breathes; a timeline step
## does not.
@export var bob_px: float = 0.0
## Ground shadow under the feet. Off for timeline chips, on for hero previews.
@export var contact_shadow: bool = true

var _spec: Object = null
var _live: Array = []
var _live_eyes: Array = []
var _dirty := true
var _t := 0.0
var _bounds := Rect2()

static var _spec_cache := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if bob_px <= 0.0 or UITokens.reduced_motion:
		set_process(false)
		return
	_t += delta
	queue_redraw()


## Load and cache a species spec. Specs are pure data built by a static factory,
## so one instance can back every silhouette on screen.
static func spec_for(id: StringName) -> Object:
	if _spec_cache.has(id):
		return _spec_cache[id]
	var result: Object = null
	var path := "res://species/%s/%s_spec.gd" % [id, id]
	if ResourceLoader.exists(path):
		var script: Script = load(path)
		if script != null and script.has_method("build"):
			var built: Variant = script.call("build")
			if built is Object:
				result = built
	_spec_cache[id] = result
	return result


## Does a drawable spec exist for this species? The adoption screen asks before
## offering a card, so a species that has not been authored yet degrades to
## "coming soon" rather than to an empty box.
static func has_species(id: StringName) -> bool:
	return spec_for(id) != null


func _rebuild() -> void:
	_dirty = false
	_live.clear()
	_live_eyes.clear()
	if _spec == null:
		_spec = spec_for(species)
	if _spec == null:
		return
	var parts: Variant = _spec.get("parts")
	if typeof(parts) != TYPE_ARRAY:
		return
	var raw: Array = []
	for p in parts:
		if p == null:
			continue
		raw.append(p.duplicate_part() if p.has_method("duplicate_part")
			else p.duplicate(true))

	# `Growth.apply` takes a typed `Array[SDFPart]`. Building the typed array
	# from the loaded script rather than naming the class keeps this widget out
	# of `core/`'s compile graph — the rig and the growth curves are under
	# active development, and an interface that will not parse while someone
	# else's refactor is half-landed is an interface nobody can review.
	var part_script: Script = load(PART_PATH) if ResourceLoader.exists(PART_PATH) else null
	_live = raw
	if part_script != null:
		_live = Array(raw, TYPE_OBJECT, &"Resource", part_script)

	# Apply the real growth morph rather than a uniform scale. A kitten is not
	# a small cat, and a timeline that pretends otherwise is worse than no
	# timeline: it removes the very thing the player is being shown.
	if ResourceLoader.exists(GROWTH_PATH):
		var g: Script = load(GROWTH_PATH)
		if g != null:
			if g.has_method("apply"):
				g.call("apply", _spec, _live, growth)
			if g.has_method("apply_eyes"):
				_build_live_eyes()
				if not _live_eyes.is_empty():
					g.call("apply_eyes", _spec, _live_eyes, growth, _live)

	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in _live:
		var ra: float = p.radius_a
		var rb: float = p.radius_b
		mn = mn.min(p.a - Vector2(ra, ra)).min(p.b - Vector2(rb, rb))
		mx = mx.max(p.a + Vector2(ra, ra)).max(p.b + Vector2(rb, rb))
	if not is_finite(mn.x):
		_bounds = Rect2()
		return
	_bounds = Rect2(mn, mx - mn)


## `EyeSpec.Live` instances, reached through the script's constant map so the
## widget never names the inner class. Growth moves eyes with the skull, which
## after the re-link and grounding passes is not simply `center * scale`; asking
## the same code the game uses is the only way an illustration of a kitten has
## its eyes in the right place.
func _build_live_eyes() -> void:
	var eyes: Variant = _spec.get("eyes")
	if typeof(eyes) != TYPE_ARRAY or not ResourceLoader.exists(EYE_PATH):
		return
	var es: Script = load(EYE_PATH)
	if es == null:
		return
	var live_cls: Variant = es.get_script_constant_map().get("Live")
	if live_cls == null:
		return
	for e in eyes:
		if e == null:
			continue
		var l: Object = live_cls.new()
		if l.has_method("copy_from"):
			l.copy_from(e)
		_live_eyes.append(l)


## Outline of a tapered capsule: the convex hull of the two end circles.
##
## The tangent line touches both circles at the same angle from the axis,
## `acos((ra - rb) / L)` — so the big end wraps past a half-circle and the small
## end wraps short of one, which is what gives a limb its taper instead of a
## sausage's parallel sides.
static func capsule_path(a: Vector2, b: Vector2, ra: float, rb: float,
		steps: int = 16) -> PackedVector2Array:
	var d := b - a
	var l := d.length()
	if l < 0.0001 or absf(ra - rb) >= l:
		# One circle swallows the other; draw the larger and stop.
		var c: Vector2 = a if ra >= rb else b
		return UIDraw.circle_path(c, maxf(ra, rb), steps * 2)
	var theta := atan2(d.y, d.x)
	var beta: float = acos(clampf((ra - rb) / l, -1.0, 1.0))
	var pts := PackedVector2Array()
	# Far cap of A: from +beta all the way round to -beta.
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		var ang: float = theta + lerpf(beta, TAU - beta, t)
		pts.append(a + Vector2(cos(ang), sin(ang)) * ra)
	# Far cap of B, closing the hull.
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		var ang: float = theta + lerpf(-beta, beta, t)
		pts.append(b + Vector2(cos(ang), sin(ang)) * rb)
	return pts


func _draw() -> void:
	if _dirty:
		_rebuild()
	if _live.is_empty() or _bounds.size.y <= 0.0:
		_draw_placeholder()
		return

	var box := Rect2(Vector2.ZERO, size)
	var fit: float = minf(box.size.y * fill_ratio / _bounds.size.y,
		box.size.x * 0.94 / maxf(_bounds.size.x, 0.001))
	var bob: float = 0.0
	if bob_px > 0.0 and not UITokens.reduced_motion:
		bob = -bob_px * sin(_t * 1.9) * 0.5
	# Feet on the floor of the box, horizontally centred on the body's bounds
	# rather than on the rig origin — a bird's origin is not its centre of mass.
	var origin := Vector2(
		box.size.x * 0.5 - (_bounds.position.x + _bounds.size.x * 0.5) * fit,
		box.size.y * (0.5 + fill_ratio * 0.5) - _bounds.end.y * fit + bob)

	if contact_shadow:
		# Grounding matters as much for an illustration as for the real render:
		# without it the creature floats in the middle of the card. Stacked
		# flattened ellipses give a penumbra that tightens under the feet, which
		# is the same two-falloff shape the game's contact shadow uses.
		var ground := Vector2(origin.x + (_bounds.position.x
			+ _bounds.size.x * 0.5) * fit, origin.y + _bounds.end.y * fit)
		var w: float = _bounds.size.x * fit * 0.60
		for i in 4:
			var t: float = float(i) / 3.0
			var c := UITokens.col(&"shadow")
			c.a = 0.13 * (1.0 - t) * flat_color.a
			UIDraw.fill_path(self, UIDraw.circle_path(ground,
				w * lerpf(0.45, 1.05, t), 20, Vector2(1.0, 0.22)), c)

	# Back to front, so a far leg sits behind the torso exactly as the body
	# shader composites it.
	for layer in 3:
		for p in _live:
			if int(p.layer) != layer:
				continue
			var path := capsule_path(origin + p.a * fit, origin + p.b * fit,
				maxf(p.radius_a * fit, 0.6), maxf(p.radius_b * fit, 0.6))
			UIDraw.fill_path(self, path, _part_color(p, layer))

	_draw_eyes(origin, fit)


func _part_color(part: Object, layer: int) -> Color:
	if style == Style.FLAT:
		# Layer separation still applies: a completely flat shape loses the
		# animal's volume and reads as a stain.
		var c := flat_color
		c = c.darkened(0.22) if layer == 0 else c
		return c
	var base := flat_color
	if _spec != null and _spec.has_method("palette_color"):
		base = _spec.palette_color(int(part.palette_index))
	# Pull every palette colour toward the panel's own light so the
	# illustration belongs to the UI rather than looking like a cut-out of the
	# game view dropped into it.
	var lift: float = 0.10 if UITokens.scheme == UITokens.Scheme.DARK else -0.04
	var c2: Color = base.lerp(flat_color, 0.18)
	c2 = c2.lightened(lift) if lift > 0.0 else c2.darkened(-lift)
	if layer == 0:
		c2 = c2.darkened(0.30)
	elif layer == 2:
		c2 = c2.lightened(0.06)
	c2.a = flat_color.a
	return c2


## One eye is the whole difference between a shape and a creature. Drawn from
## the spec's own eye list so a lizard's slit pupil and a bird's round one are
## still different animals at 40px.
func _draw_eyes(origin: Vector2, fit: float) -> void:
	if _spec == null:
		return
	# The near eye only. Both eyes on a side-on illustration reads as a face-on
	# stare, which is a different animal entirely.
	var e: Object = null
	if not _live_eyes.is_empty():
		e = _live_eyes[_live_eyes.size() - 1]
	else:
		var eyes: Variant = _spec.get("eyes")
		if typeof(eyes) != TYPE_ARRAY or (eyes as Array).is_empty():
			return
		e = eyes[(eyes as Array).size() - 1]
		# Fallback path: no growth pass ran, so fold in the species curves by
		# hand. Approximate, and only ever seen mid-refactor.
		var bias := 1.0
		var body_scale := 1.0
		if _spec.has_method("eye_bias_at"):
			bias = float(_spec.eye_bias_at(growth))
		if _spec.has_method("scale_at"):
			body_scale = float(_spec.scale_at(growth))
		var cf: Vector2 = origin + Vector2(e.center) * body_scale * fit
		_eye_marks(cf, maxf(float(e.radius) * bias * body_scale * fit, 1.4))
		return
	var c: Vector2 = origin + Vector2(e.center) * fit
	var r: float = maxf(float(e.radius) * fit, 1.4)
	_eye_marks(c, r)


func _eye_marks(c: Vector2, r: float) -> void:
	var dark := Color(0.06, 0.05, 0.08, flat_color.a)
	if style == Style.FLAT:
		dark = flat_color.darkened(0.55)
	UIDraw.fill_path(self, UIDraw.circle_path(c, r, 18), dark)
	if style == Style.TINTED and r > 3.0:
		# Catchlight, up and to the light side, matching the creature shader's
		# key direction.
		var hl := Color(1, 1, 1, 0.85 * flat_color.a)
		UIDraw.fill_path(self, UIDraw.circle_path(
			c + Vector2(r * 0.32, -r * 0.34), r * 0.30, 10), hl)


## Drawn when a species has no spec yet: an egg, not an error. A player looking
## at an unfinished build should see a promise, not a stack trace.
func _draw_placeholder() -> void:
	var c := size * 0.5
	var s: float = minf(size.x, size.y) * 0.55
	var col := flat_color
	col.a *= 0.35
	UIGlyphs.draw_glyph(self, &"adopt", c, s, col)
