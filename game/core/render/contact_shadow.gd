class_name ContactShadow
extends Node2D

## Ground contact for one creature: a broad ambient ellipse under the body, plus
## one tight, dark patch under every paw that is actually on the floor.
##
## The rig grounds its feet exactly — the probe reports slip and sink of 0.0000
## on every stance foot — and none of that was visible, because a single
## body-wide soft ellipse says "there is a creature somewhere above this" and
## nothing more. What tells an eye that a foot is *touching* is the hard,
## near-black, few-pixel-wide occlusion right where the two surfaces meet: the
## ambient term carries the body's weight, the contact term carries the plant.
##
## Both are composited here rather than being one shape with a hot centre,
## because they move independently. The ambient ellipse tracks the body's
## footprint; each contact patch tracks its own paw, hardens as that paw lands
## and blooms outward as it lifts, which is exactly how a penumbra behaves when
## the occluder pulls away from the receiver.
##
## Lives in local rig space scaled by `pixels_per_unit`, and copies the
## creature's transform every frame, so a facing flip mirrors the shadow with the
## animal and no caller has to keep two transforms in sync.

## Paw slots, in `Gait`'s order: fore-near, fore-far, hind-near, hind-far.
const MAX_PAWS := 4

const RigBones := preload("res://core/rig/bone_map.gd")

## Darkest the contact patch under a fully planted paw gets.
const CONTACT_STRENGTH := 0.82
## Opacity of the broad ambient ellipse at its centre.
##
## Held below the contact patches on purpose, and lower than it used to be. The
## ambient term says "there is a body above this"; the patches say "these four
## points are touching". Run the ambient near the patches' own value and the
## composite is one even smudge the width of the animal — which is exactly what
## the standing capture has been showing, and it is the reason four separate
## plants read as one.
## Raised now that it covers the right footprint. Held low it was defending
## against a body-wide smudge that the *shape* is the real defence against — and
## measured against the desktop a 30% wash of a near-black tint is a four per cent
## luminance change under the animal, which is not a shadow, it is a suggestion.
const AMBIENT_STRENGTH := 0.42
## Height above the floor, as a fraction of the creature's standing height, at
## which a lifted paw has no contact shadow left at all.
const LIFT_RANGE := 0.20
## How much wider the patch grows over that range. A penumbra spreads roughly
## linearly with the gap, and it is the *spread*, not the fade, that reads as
## height — a foot 2 cm off the floor still casts a dark mark, just a blurrier
## one.
const LIFT_SPREAD := 2.2
## Smallest radius a contact patch may be drawn at, in *screen* pixels.
##
## Everything else here is authored in rig units, which is right for a shape that
## belongs to the animal and wrong for one whose entire job is to be seen. The
## reptile is the case that proves it: measured at ship size the lizard is drawn at
## 40 screen pixels to the rig unit — a third of what the mammals get, because it
## is four units long and the frame is square — so its 0.034 paws produced patches
## five pixels across and two pixels tall. The probe reported all four uploaded at
## full opacity and the picture had nothing in it, which is exactly the "briefed
## twice and still not visible" pattern. A contact mark is a real penumbra and a
## real penumbra is wider than its occluder anyway, so a floor here is not a cheat.
const MIN_PATCH_PX := 7.5
## Opacity of the hard contact core — the small, almost solid mark right at the
## sole, sitting inside the penumbra above.
##
## The penumbra is what a foot's shadow *looks* like; the core is what makes it
## read as touching. Everything else here is a gradient, and a composite made
## only of gradients has no value anywhere near its nominal opacity except at one
## infinitesimal point, so at ship size the four plants averaged out into the
## ambient pool they were meant to be punched into. The measurement: on the bird
## at 260 px the darkest pixel under a planted toe was 46 against a 187
## background, and it was two pixels wide.
const CORE_STRENGTH := 0.95
## Smallest the core may be drawn, in *screen* pixels, for the same reason
## `MIN_PATCH_PX` exists — and it bit harder here. The old patch already had an
## inner plateau, at 30% of a radius that was itself floored at 7.5 px and then
## squashed to 0.45 of its width: a core two pixels across and one tall. A
## one-pixel core is not a core, it is a dark pixel.
const MIN_CORE_PX := 4.0
## How flat the core is drawn, against 0.45 for the penumbra. The ground is seen
## nearly edge on, so everything down here is squashed — but the core is the part
## the eye is being asked to find, and squashing it to a line is how it was lost.
const CORE_FLAT := 0.62
## How fast the core dies as the paw leaves the floor, as a multiple of the
## penumbra's `LIFT_RANGE`. Contact is very nearly binary: the penumbra blooms
## and fades over a couple of centimetres, the hard core is gone the moment the
## sole is not on the floor. It *shrinks* rather than fading, which is what a real
## umbra does when the occluder pulls away.
const CORE_LIFT_RATE := 3.2

var creature: Node2D

var _rect: ColorRect
var _mat: ShaderMaterial
var _ppu := 190.0
var _body_h := 1.0
var _paw_parts: Array = []
var _paw_slots: PackedInt32Array = PackedInt32Array()


## Build a shadow for `p_creature` and return it. The caller owns placement in
## the tree; put it behind the creature (a lower `z_index`, not a lower sibling
## index — with a transparent background there may be nothing to sit in front
## of).
static func make_for(p_creature: Node2D) -> ContactShadow:
	var s := ContactShadow.new()
	s.name = "ContactShadow"
	s.creature = p_creature
	return s


func _ready() -> void:
	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.color = Color.WHITE
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = _SHADER
	_mat.shader = sh
	_rect.material = _mat
	add_child(_rect)
	_bind()
	# One update before the first draw, so the shadow is never one frame stale —
	# a capture settles for a fixed number of frames and then shoots.
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


## Cache what does not change between frames: the paw parts to follow, which gait
## slot each belongs to, and the footprint the ambient ellipse is sized from.
##
## Exactly one part per gait slot, chosen as the *most distal segment of that
## limb* rather than as "the part whose id contains the word paw". Insisting on a
## named foot is why the standing cat has been shipping one body-wide ellipse:
## the cat spec deliberately drops its far paws — at ship size each was two pixels
## of shadow tucked behind a near one — so its far legs end in a lower segment
## that still stands on the floor and was never asked to cast anything. Two
## patches instead of four is precisely the case where nothing disambiguates a
## fused leg pair, which is the whole reason the per-paw term exists.
##
## One part per slot also matters for the other direction: a lizard has six parts
## classifying as limbs across four slots, and the old loop simply let the last
## one it happened to see win.
func _bind() -> void:
	_paw_parts.clear()
	_paw_slots = PackedInt32Array()
	if creature == null or creature.get("renderer") == null:
		return
	var spec = creature.get("spec")
	if spec != null:
		_ppu = spec.pixels_per_unit
	var lowest := 0.0
	var highest := 0.0
	# Per slot: the best part so far, and how distal it is. Rank on the parsed
	# segment first, then on which reaches lower — a chain that names none of its
	# segments still resolves, because the foot is the end that touches the floor.
	var best: Array = [null, null, null, null]
	var rank := PackedFloat32Array([-INF, -INF, -INF, -INF])
	for p in creature.renderer.live_parts:
		var sole: float = maxf(p.a.y + p.radius_a, p.b.y + p.radius_b)
		lowest = maxf(lowest, sole)
		highest = minf(highest, minf(p.a.y - p.radius_a, p.b.y - p.radius_b))
		var tag = RigBones.classify(p.id, int(p.layer))
		if tag.slot != RigBones.Slot.LIMB:
			continue
		var slot: int = (0 if tag.fore else 2) + (1 if tag.far else 0)
		var score: float = float(tag.seg) + sole
		if score > rank[slot]:
			rank[slot] = score
			best[slot] = p
	for slot in MAX_PAWS:
		if best[slot] != null:
			_paw_parts.append(best[slot])
			_paw_slots.append(slot)
	_body_h = maxf(lowest - highest, 0.05)


func _refresh() -> void:
	if creature == null or _rect == null or not is_instance_valid(creature):
		return
	if _paw_parts.is_empty():
		_bind()
	# The creature's own transform carries its facing flip and whatever scale the
	# host or the capture harness fitted it at; inheriting it wholesale is the
	# only way the two can never drift apart.
	global_transform = creature.global_transform

	var mn := INF
	var mx := -INF
	for p in creature.renderer.live_parts:
		mn = minf(mn, minf(p.a.x - p.radius_a, p.b.x - p.radius_b))
		mx = maxf(mx, maxf(p.a.x + p.radius_a, p.b.x + p.radius_b))
	if not is_finite(mn):
		return
	# What the ambient ellipse has to cover is everything the body occludes from the
	# floor, and that is the union of two spans, not either one alone.
	#
	# The stance span is right for a quadruped, where the trunk lives between the
	# feet. It is badly wrong for a biped: the bird stands on two toes tucked under
	# its middle and its body reaches most of a body length behind them, so a shadow
	# sized off the stance is a small smudge under the feet with the whole animal
	# overhanging it. That is not a subtle depth error — an object whose shadow is
	# far smaller than the object reads as hovering above it, which is precisely the
	# "the bird floats off its own shadow" the review reported. It was never a
	# vertical gap; measured, the patches sit within two pixels of the toes.
	#
	# The body span alone is not usable either, because a raised tail or an open wing
	# is part of it and casts nothing on the floor beneath the animal. So the body's
	# contribution is taken over its *masses* only — anything close to the thickest
	# part — which excludes a tail and a wing tip by construction and needs no naming.
	var thickest := 0.0
	for p in creature.renderer.live_parts:
		thickest = maxf(thickest, maxf(p.radius_a, p.radius_b))
	var bmn := INF
	var bmx := -INF
	for p in creature.renderer.live_parts:
		if maxf(p.radius_a, p.radius_b) < thickest * 0.45:
			continue
		bmn = minf(bmn, minf(p.a.x - p.radius_a, p.b.x - p.radius_b))
		bmx = maxf(bmx, maxf(p.a.x + p.radius_a, p.b.x + p.radius_b))
	var lo_x: float = bmn if is_finite(bmn) else mn
	var hi_x: float = bmx if is_finite(bmx) else mx
	if not _paw_parts.is_empty():
		for p in _paw_parts:
			lo_x = minf(lo_x, minf(p.a.x, p.b.x))
			hi_x = maxf(hi_x, maxf(p.a.x, p.b.x))
	var span: float = (hi_x - lo_x) + _body_h * 0.30
	var centre: float = (lo_x + hi_x) * 0.5

	var half_w: float = span * 0.5
	# Flat: the camera is nearly level with the floor, so the ground plane is
	# seen close to edge on. Deeper than this and the ellipse stops reading as
	# something lying on the floor and starts reading as a dark pool the animal
	# is standing in. It also has to stay inside the depth the capture harness
	# reserves below the ground line, or the review frame clips it.
	var half_d: float = maxf(half_w * 0.20, _body_h * 0.05)
	# Room for the widest bloomed penumbra on either side, so nothing is clipped
	# by the quad the moment a paw leaves the floor.
	var pad: float = _body_h * 0.22
	var lo := Vector2(centre - half_w - pad, -half_d - pad)
	var hi := Vector2(centre + half_w + pad, half_d + pad)
	_rect.position = lo * _ppu
	_rect.size = (hi - lo) * _ppu

	_mat.set_shader_parameter("rect_min", lo)
	_mat.set_shader_parameter("rect_size", hi - lo)
	# Sunk very slightly below the ground line: the viewer looks down on the
	# floor a little, so the ellipse's near edge shows and its far edge hides
	# behind the animal.
	_mat.set_shader_parameter("ambient", Vector4(centre, _body_h * 0.03, half_w, half_d))
	_mat.set_shader_parameter("ambient_strength", AMBIENT_STRENGTH)
	_mat.set_shader_parameter("core_strength", CORE_STRENGTH)
	_mat.set_shader_parameter("core_flat", CORE_FLAT)
	_mat.set_shader_parameter("tint", Color(0.035, 0.035, 0.055))

	# On-screen density, including whatever scale the host or the capture harness
	# fitted the creature at. `global_transform` was copied from the creature above,
	# so this is the real number and not the spec's nominal one.
	var view_px: float = _ppu * maxf(sqrt(absf(global_scale.x * global_scale.y)), 1e-4)
	var min_r: float = MIN_PATCH_PX / maxf(view_px, 1.0)
	var min_core: float = MIN_CORE_PX / maxf(view_px, 1.0)

	var gait = _gait()
	var cores := Vector4.ZERO
	for i in MAX_PAWS:
		_mat.set_shader_parameter("paw_%d" % i, Vector4.ZERO)
	for i in _paw_parts.size():
		var p = _paw_parts[i]
		var slot: int = _paw_slots[i]
		# How far the paw's sole is off the floor, normalised. The rig plants a
		# stance foot at exactly y = 0, so this is 0 for a planted paw and the
		# whole read is driven by it.
		var sole: float = maxf(p.a.y + p.radius_a, p.b.y + p.radius_b)
		var lift: float = clampf(-sole / (LIFT_RANGE * _body_h), 0.0, 1.0)
		var stance := true
		if gait != null and slot < gait.feet.size():
			var f = gait.feet[slot]
			stance = bool(f.stance) and bool(f.present)
		var strength: float = CONTACT_STRENGTH * (1.0 - lift) * (1.0 - lift)
		if not stance:
			# A swing foot still darkens the floor under itself; it just does it
			# faintly and broadly. Halving it keeps the four patches from reading
			# as four planted feet during a gallop's suspension.
			strength *= 0.5
		if strength <= 0.004:
			continue
		# Wider than the paw itself. A patch the size of its occluder is invisible
		# at ship size — most of it hides *behind* the paw — and the mark a real
		# foot leaves on a floor is bigger than the foot anyway, because the light
		# is an area source. 2.6x is the smallest that still reads at 260 px.
		#
		# Floored in screen pixels as well, because 2.6x of a small number is still a
		# small number: see `MIN_PATCH_PX`.
		var r: float = maxf(maxf(p.radius_a, p.radius_b) * 2.6, min_r) \
			* (1.0 + lift * LIFT_SPREAD)
		# Centred on the middle of the span this part actually rests on, and only
		# just below the floor line. Sinking it further made the patch easier to
		# see and turned the read into a cat hovering over a spot — the gap between
		# a foot and its own contact mark is the exact thing that says "not
		# touching".
		#
		# This used to be the toe *tip*, `b.x` plus a nudge, which is right only
		# for a foot that meets the floor at a point. The bird's toe now lies flat
		# over 0.12 rig units, so the patch landed past the front of the foot —
		# measured on the ship-size frame, the two patches sat at x = 164 and 178
		# with the toes spanning 114 to 186, about ten rendered pixels of offset on
		# an animal 200 px long. A mark that is not under the foot is not a contact
		# mark, and it is a large part of why the bird reads as floating.
		var cx: float = lerpf(p.a.x, p.b.x, _contact_t(p))
		_mat.set_shader_parameter("paw_%d" % slot,
			Vector4(cx, _body_h * 0.012, r, strength))
		# The hard core: a small near-opaque umbra inside that penumbra. Only for a
		# foot that is genuinely down — a swing foot casts a soft mark and no core
		# at all, which is the whole distinction the term exists to draw.
		if stance:
			var core_lift: float = clampf(1.0 - lift * CORE_LIFT_RATE, 0.0, 1.0)
			var core_r: float = maxf(maxf(p.radius_a, p.radius_b) * 0.80, min_core) \
				* core_lift
			match slot:
				0: cores.x = core_r
				1: cores.y = core_r
				2: cores.z = core_r
				_: cores.w = core_r
	_mat.set_shader_parameter("paw_core", cores)


## Where along `p`'s spine its ground-contact span is centred, as a 0..1
## parameter.
##
## Both the spine and the radius vary linearly along a tapered capsule, so the
## height of its underside does too — which makes this exact rather than a
## search. If one end hangs lower the contact is a short arc near that end; if
## the underside is level the whole segment is on the floor and the answer is the
## midpoint. A bird's toe is the second case and a cat's paw is close to the
## first, and the same expression covers both.
##
## `tol` is how far the sole may rise and still count as touching. Taken off the
## part's own radius because that is what sets the size of the flat a rounded
## foot presses into the floor.
func _contact_t(p) -> float:
	var s_a: float = p.a.y + p.radius_a
	var s_b: float = p.b.y + p.radius_b
	var drop: float = absf(s_a - s_b)
	var low_a: bool = s_a >= s_b
	var tol: float = maxf((p.radius_a if low_a else p.radius_b) * 0.55, _body_h * 0.004)
	var frac: float = clampf(tol / maxf(drop, 1e-5), 0.0, 1.0)
	return frac * 0.5 if low_a else 1.0 - frac * 0.5


func _gait():
	if creature == null:
		return null
	var rig = creature.get("rig")
	return null if rig == null else rig.get("gait")


# Four scalar uniforms rather than a `vec4[4]`: array uniforms are set per-index
# through a string key anyway, and the flat form is one fewer thing to go wrong
# on `gl_compatibility`, which is the renderer this project ships on.
const _SHADER := """
shader_type canvas_item;
render_mode blend_mix, unshaded;

uniform vec2 rect_min;
uniform vec2 rect_size;
// cx, cy, half-width, half-depth of the broad ambient ellipse.
uniform vec4 ambient;
uniform float ambient_strength;
// cx, cy, radius, opacity per paw. Opacity 0 means the slot is unused.
uniform vec4 paw_0;
uniform vec4 paw_1;
uniform vec4 paw_2;
uniform vec4 paw_3;
// Hard-core radius per paw, same slot order. Zero means the foot is not down.
uniform vec4 paw_core;
uniform float core_strength;
uniform float core_flat;
uniform vec4 tint : source_color;

float ellipse(vec2 p, vec2 c, vec2 r) {
	return length((p - c) / max(r, vec2(1e-5)));
}

// A contact patch: near-opaque core, short penumbra. Flattened to 0.45 of its
// width vertically because it is a ground plane seen almost edge on.
//
// The core has to be a real core. Faded from the rim all the way in — which is
// what a single wide smoothstep does — the patch is a soft blob with no value
// anywhere near its nominal opacity except at one point, and against the ambient
// ellipse underneath it that is invisible at 260 px. What says "touching" is a
// small flat dark centre with the penumbra outside it.
float patch(vec2 p, vec4 q, float core_r) {
	if (q.w <= 0.0) return 0.0;
	float d = ellipse(p, q.xy, vec2(q.z, q.z * 0.45));
	float core = smoothstep(0.62, 0.30, d);
	float penumbra = smoothstep(1.0, 0.45, d);
	float soft = (0.30 * penumbra + 0.70 * core) * q.w;
	// The umbra proper. Sized and squashed on its own terms rather than as a
	// fraction of the penumbra, because a fraction of a soft mark is a soft mark:
	// the old inner plateau was 30% of a radius already floored at 7.5 px and then
	// flattened to 0.45, which is two rendered pixels by one, and two pixels by one
	// is not what tells an eye that a foot is on a floor.
	float hard = 0.0;
	if (core_r > 0.0) {
		float dc = ellipse(p, q.xy, vec2(core_r, core_r * core_flat));
		hard = smoothstep(1.0, 0.35, dc) * core_strength;
	}
	// Transmittance again, so the core sits *inside* the penumbra rather than
	// adding to it and clipping.
	return 1.0 - (1.0 - soft) * (1.0 - hard);
}

void fragment() {
	vec2 p = rect_min + UV * rect_size;
	// Two stacked falloffs on the ambient term. Both are gradients all the way to
	// the centre rather than plateaux: an ambient term with a flat top is a slab
	// the width of the animal, and the four contact patches then have nothing to
	// stand out against. The body's weight should read as a pool that deepens
	// toward the middle, with the plants punched into it.
	float d = ellipse(p, ambient.xy, ambient.zw);
	float a = (smoothstep(1.0, 0.0, d) * 0.62 + smoothstep(1.45, 0.0, d) * 0.38)
		* ambient_strength;
	// Composited as transmittance, not added: four overlapping patches under a
	// gathered gallop must not stack into a black hole.
	float t = 1.0 - clamp(a, 0.0, 1.0);
	t *= 1.0 - patch(p, paw_0, paw_core.x);
	t *= 1.0 - patch(p, paw_1, paw_core.y);
	t *= 1.0 - patch(p, paw_2, paw_core.z);
	t *= 1.0 - patch(p, paw_3, paw_core.w);
	COLOR = vec4(tint.rgb, clamp(1.0 - t, 0.0, 1.0));
}
"""
