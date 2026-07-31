shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — implicit creature body.
//
// The whole animal is resolved here from a list of tapered capsules. There is
// no mesh, no sprite sheet and no normal map. Per pixel we:
//
//   1. smooth-union the capsules into a signed distance field, once per depth
//      layer,
//   2. lift that field into a height field (an exact capsule cross-section),
//   3. differentiate the height field analytically for a true surface normal,
//   4. grow a coat on it — undercoat, guard hairs, and a silhouette fringe made
//      of individual strands rather than a blurred edge,
//   5. light it with the rig in `lighting.gdshaderinc`, including shadows that
//      one depth layer casts onto the ones behind it,
//   6. composite the three layers back to front with atmospheric separation, so
//      a far leg genuinely sits behind the torso rather than merely darker.
//
// Doing it implicitly is what buys the AAA read: silhouettes are resolution
// independent, the coat fringe is real geometry rather than a painted edge, and
// creases between body parts occlude themselves for free.

#include "res://shaders/creature/noise.gdshaderinc"
#include "res://shaders/creature/coat.gdshaderinc"
#include "res://shaders/creature/lighting.gdshaderinc"
#include "res://shaders/creature/eye.gdshaderinc"
#include "res://shaders/common/tonemap.gdshaderinc"

const int MAX_PARTS = 28;
const int LAYERS = 3;

// parts[i*3+0] = (a.x, a.y, b.x, b.y)      capsule spine, rig space
// parts[i*3+1] = (radius_a, radius_b, blend, height_scale)
// parts[i*3+2] = (layer*16 + material, palette_index, groom_angle, coat_length)
uniform vec4 parts[84];
uniform int part_count = 0;
uniform vec4 palette[12];

uniform vec2 bounds_min = vec2(-1.0);
uniform vec2 bounds_max = vec2(1.0);
// Screen pixels per rig unit, including the node's own scale. Every level-of-
// detail decision in the coat keys off this, so it has to be the real on-screen
// density and not the spec's nominal value.
uniform float px_per_unit = 180.0;

uniform int coat_surface = 0;
uniform float coat_length : hint_range(0.0, 0.2) = 0.02;
uniform float coat_density : hint_range(0.1, 8.0) = 1.0;
uniform float translucency : hint_range(0.0, 1.0) = 0.35;
uniform float roughness : hint_range(0.02, 1.0) = 0.55;

// Coat markings. A wild-type mammal coat is never one flat colour, and the
// second pigment is already in every species palette — it is the shade the
// shadowed parts are drawn in. `marking_index` says which slot that is, so the
// stripes stay inside the palette indirection instead of being a colour the
// shader invented.
uniform int marking_index = 1;
uniform float marking_strength : hint_range(0.0, 1.0) = 1.0;

// Skeletal landmarks, packed (x, y, radius, slope) in rig space, uploaded by
// `CreatureRenderer` from where each limb enters the body. The part budget is
// full at 28 of 28, so a scapula cannot be a capsule; it has to be relief.
const int MAX_LANDMARKS = 4;
uniform vec4 landmarks[4];
// Where each limb *enters* the body, packed (x, y, radius, 1) in rig space and
// parallel to `landmarks`. The landmark is the crest of the bone up under the
// top line; this is the socket down on the side of the barrel, and they are two
// different features that happen to be found by the same search. The armpit and
// the groin are the darkest things on a standing animal's underside and nothing
// in this file could find them, because a limb lives on a different depth layer
// from the torso, smooth-unions with nothing, and so accumulates no crease.
uniform vec4 limb_roots[4];
uniform int landmark_count = 0;

uniform float growth : hint_range(0.0, 3.0) = 3.0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float fluff : hint_range(0.0, 2.0) = 1.0;
uniform float emotion_flush : hint_range(0.0, 1.0) = 0.0;
uniform float mouth_open : hint_range(0.0, 1.0) = 0.0;
uniform float cheek_puff : hint_range(0.0, 1.0) = 0.0;

// eyes[i*4+0] = (center.x, center.y, radius, tilt)
// eyes[i*4+1] = (iris_ratio, pupil_ratio, pupil_slit, blink)
// eyes[i*4+2] = (iris.rgb, socket_depth)
// eyes[i*4+3] = (gaze.x, gaze.y, lid_open, limbal_luminance)
uniform vec4 eyes[16];
uniform int eye_count = 0;

// Whisker pad, packed (x, y, length, amount) in rig space by `CreatureRenderer`.
// Zero amount for anything that does not have them, which is everything that is
// not a mammal. See `pet_whiskers` for why they cannot be parts.
uniform vec4 whisker_pad = vec4(0.0, 0.0, 0.0, 0.0);

// Set when the post stack is live: it owns the filmic curve instead, so the
// creature is not tonemapped twice.
uniform bool defer_tonemap = false;

// Diagnostic channel. 0 is the shipped render; anything else replaces the lit
// colour of the front-most hit layer with one intermediate value, flat, with no
// tonemap in the way.
//
// This is here on purpose and it earns its keep. Twice now an agent has argued a
// sign or a frame direction from the algebra, changed it, and made the picture
// worse — the groom frame's `dv` is signed the opposite way from the obvious
// derivation, and a single capture of `dv` settled in one shot what a page of
// reasoning had got backwards. Set by `CreatureRenderer` from the
// `PETALIA_DEBUG_VIEW` environment variable so it costs the shipped build one
// dead branch and no plumbing anywhere else.
//
//   1 groom direction, as a colour wheel   7 marking mask
//   2 dv, red dorsal / blue ventral        8 total occlusion
//   3 fibre lane coordinate, banded        9 local radius, banded
//   4 key only                            10 `arc`, banded
//   5 sky + bounce only                   12 field albedo, before markings
//   6 albedo after markings, unlit
uniform int debug_view = 0;

const int MAT_FUR = 0;
const int MAT_FEATHER = 1;
const int MAT_SCALE = 2;
const int MAT_SKIN = 3;
const int MAT_CLAW = 4;
const int MAT_EYE = 5;

// ---------------------------------------------------------------------------
// Field evaluation
// ---------------------------------------------------------------------------

// Tapered capsule. Reports the unit gradient (needed for the height-field
// derivative and the coat grooming frame) and the position along the spine,
// which is what lets a claw know where its tip is and a feather where its
// rachis runs.
float sd_capsule(vec2 p, vec2 a, vec2 b, float ra, float rb,
		out vec2 grad, out float radius, out float along) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-7), 0.0, 1.0);
	vec2 d = pa - ba * t;
	float len = length(d);
	radius = mix(ra, rb, t);
	along = t;
	grad = len > 1e-5 ? d / len : vec2(0.0, -1.0);
	return len - radius;
}

// Quadratic smooth minimum. `h` is returned so callers can blend the two
// surfaces' materials with exactly the same weight that blended their distance,
// which is what stops a colour seam appearing along every joint.
//
// Note the convention: the result is `mix(b, a, h)`, so h = 1 means "keep a",
// the accumulated surface. Every attribute blend below has to read the same way
// round or parts inherit each other's colours.
float smin_h(float a, float b, float k, out float h) {
	h = clamp(0.5 + 0.5 * (b - a) / max(k, 1e-5), 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

struct Field {
	float d;        // signed distance to the layer's surface
	float radius;   // local half-thickness, drives the height lift
	vec2  grad;     // unit gradient of d
	vec3  albedo;
	vec2  groom;    // unit grooming direction
	// Unit direction of the dominant part's own spine, tail-to-tip. Distinct from
	// `groom` on purpose: the groom is where the *hair* points and a species is
	// entitled to leave it at its default, but a marking has to wrap the part it
	// is painted on whatever the hair is doing. Read the two as one and a vertical
	// leg gets a band coordinate that barely changes down its length, so its ring
	// stretches into a single stripe running from hip to paw — which is most of
	// why the legs have been reading as turned dowels.
	vec2  axis;
	// Thickest part present at this pixel, which is a *different* question from
	// `radius` and has to be answered separately. `radius` is the height lift's
	// local half-thickness and is entitled to dip inside a blend; `bulk_r` asks
	// whether this is a body mass or a limb, and half this file gates on the
	// answer — countershading, the skeleton relief, the underside occlusion, the
	// groom's own lean. Taken from `radius` it dips wherever a thin capsule runs
	// along a fat one, every one of those terms switches at once, and what lands
	// on screen is a hard-edged bright lens the length of the belly. Three passes
	// went looking for that in the pigment; it was never in the pigment.
	//
	// A max over the parts actually present cannot dip, which is the whole point.
	float bulk_r;
	// Position along that axis, blended as a *scalar* rather than recomputed from
	// the blended direction. `dot(p, axis(p))` with a direction that rotates is
	// how a whorl gets made: where two parts' axes differ, the blend weight sweeps
	// the direction through the angle between them, and near the middle the
	// projection turns into something close to `length(p - centre)`, whose level
	// sets are circles. Rendering `arc` banded showed four such closed centres on
	// the bird, and they are exactly where its plumage was wearing a fingerprint.
	// A convex combination of the two parts' own linear projections has no such
	// centre, and it costs one `mix`.
	float arc;
	// Signed perpendicular offset from that axis, dorsal positive. Blended as a
	// scalar for the same reason `arc` is, and it replaces what used to be a
	// `sign()` taken off the blended gradient.
	//
	// That sign was the belly slab. Inside the pocket where a thin capsule is
	// engulfed by a fat one the accumulated gradient points back up toward the
	// fat one's spine, the sign flips, and `dv` steps from +0.5 to -0.5 across one
	// pixel. Everything keyed on `dv` steps with it — the countershading, the
	// tabby, the coat sheen, the underside occlusion and the groom frame's own
	// lean — so the underside came out wearing a hard-edged pale lens that three
	// separate passes went looking for in the pigment and could not find, because
	// it was never in the pigment. Rendering `dv` to the framebuffer showed it in
	// one capture: a blue island in a red field.
	float off;
	float coat_len;
	float height_scale;
	float along;    // 0 at the dominant part's root, 1 at its tip
	float crease;   // how much smoothing happened here → self-occlusion
	float mat;      // dominant material id
	// Strongest marking painted onto the surface here, and the field of the part
	// that painted it, so the marking can be given its own relief.
	float decal_w;
	float decal_d;
	float decal_r;
	vec2  decal_grad;
	bool  hit;
};

Field eval_layer(vec2 p, int want_layer) {
	Field f;
	f.d = 1e6;
	f.radius = 0.1;
	f.grad = vec2(0.0, -1.0);
	f.albedo = vec3(0.5);
	f.groom = vec2(0.0, 1.0);
	f.axis = vec2(1.0, 0.0);
	f.arc = 0.0;
	f.bulk_r = 0.0;
	f.off = 0.0;
	f.coat_len = coat_length;
	f.height_scale = 1.0;
	f.along = 0.5;
	f.crease = 0.0;
	f.mat = float(coat_surface);
	f.decal_w = 0.0;
	f.decal_d = 1e6;
	f.decal_r = 0.1;
	f.decal_grad = vec2(0.0, -1.0);
	f.hit = false;

	for (int i = 0; i < MAX_PARTS; i++) {
		if (i >= part_count) { break; }
		vec4 g2 = parts[i * 3 + 2];
		int layer = int(floor(g2.x / 16.0));
		if (layer != want_layer) { continue; }

		vec4 g0 = parts[i * 3 + 0];
		vec4 g1 = parts[i * 3 + 1];

		vec2 grad;
		float radius;
		float along;
		float d = sd_capsule(p, g0.xy, g0.zw, g1.x, g1.y, grad, radius, along);
		// Weighted by how completely this part covers the pixel, so a capsule whose
		// edge merely brushes past does not claim the pixel is body-thick.
		f.bulk_r = max(f.bulk_r,
			radius * smoothstep(radius * 0.9 + g1.z, -radius, d));

		vec3 col = palette[int(g2.y)].rgb;
		float ga = g2.z;
		vec2 groom = vec2(cos(ga), sin(ga));
		// A near-spherical part (a skull, a paw) has no meaningful spine, so it
		// borrows the groom.
		//
		// The sign is then forced onto the *rig's* convention — forward, and for a
		// part with no forward component, downward — and not onto the part's own
		// authored groom, which is what it used to be. Every species shares the rig
		// convention, so this makes `arc` run the same way on every capsule on every
		// animal; a per-part groom angle that most species leave at its default does
		// not. Two neighbouring parts that disagreed about the sign put a reversal in
		// `arc`, the blend then swept the band coordinate through zero between them,
		// and the bands bunched into a closed centre. Rendering `arc` banded found
		// four of those on the bird, and they are exactly where its plumage was
		// wearing a fingerprint instead of vanes.
		vec2 seg = g0.zw - g0.xy;
		vec2 axis = dot(seg, seg) > 1e-8 ? normalize(seg) : groom;
		if (axis.x < -1e-3 || (abs(axis.x) <= 1e-3 && axis.y < 0.0)) { axis = -axis; }

		if (!f.hit) {
			f.d = d;
			f.radius = radius;
			f.grad = grad;
			f.albedo = col;
			f.groom = groom;
			f.axis = axis;
			f.arc = dot(p, axis);
			f.off = -(d + radius) * dot(grad, vec2(-axis.y, axis.x));
			f.coat_len = g2.w;
			f.height_scale = g1.w;
			f.along = along;
			f.mat = g2.x - float(layer) * 16.0;
			f.hit = true;
			continue;
		}

		float h;
		float prev_d = f.d;
		float hard = min(f.d, d);
		float sd = smin_h(f.d, d, g1.z, h);
		// The gap between the hard union and the smooth union is exactly the
		// volume the blend added — i.e. the crease. Accumulate it as ambient
		// occlusion so armpits, ear roots and toe webbing darken naturally.
		f.crease += max(0.0, hard - sd);

		f.d = sd;
		// The radius drives the height lift, and it has to be blended as a *max*
		// and not as an average. Both capsules straddle the mid-plane, so where they
		// overlap the union's half-thickness is the thicker one's — a plain mix digs
		// a groove the width of the blend along every join between parts of
		// different girth, and because the normal is the analytic derivative of the
		// height field, that groove arrives as a hard bright line.
		//
		// Rendering `R` to the framebuffer is what found this. The straight pale bar
		// under this cat's belly, reported twice now as a blown-out slab, is the
		// belly capsule's 0.06 radius pulling the torso's 0.198 down along the whole
		// underside; the bar's hard top and bottom edges are the two walls of that
		// groove. It is drawn by the renderer, not authored, and no amount of work
		// on the belly *pigment* could have touched it.
		//
		// The bias is weighted by `4h(1-h)`, which is zero at both ends and one in
		// the middle, so it only ever acts inside the blend. That matters: at h = 0
		// the accumulated surface is entirely the new part and must keep its own
		// radius, or a tail inherits the rump's thickness for its whole length.
		//
		// And only *inside* the union, which is the second half of it. At the
		// surface the thin part's own radius is the honest one — that is genuinely
		// how thick the body is there — and inflating it raises the pixel-width
		// bound on the height field's slope, so the belly capsule's emergent edge
		// came back as a blown-out white hairline instead of a groove. Traded one
		// drawn line for another. The groove that matters is the one across the
		// interior, so the bias fades out as the surface is approached.
		float thicker = (f.radius - radius) / max(f.radius + radius, 1e-4);
		float deep = smoothstep(0.0, -0.55 * min(f.radius, radius), sd);
		f.radius = mix(radius, f.radius,
			clamp(h + 4.0 * h * (1.0 - h) * thicker * 1.6 * deep, 0.0, 1.0));
		f.grad = normalize(mix(grad, f.grad, h) + 1e-6);

		// Which markings are *objects* and which are *regions* of different pigment.
		// Both this blend and the decal path below need the distinction, so it is
		// made once, here.
		//
		// Size alone cannot make the call, and trying it is what left a hard-edged
		// pale lens under this cat on the first attempt: measured against body
		// height the belly capsule is 0.046 and the muzzle mask 0.040, which is no
		// separation at all, and the threshold that softened the belly softened the
		// face with it. The face is the one part of this animal a blind reviewer
		// already reads correctly and it is not available to spend.
		//
		// Elongation is the honest second axis. A region of pigment is painted with
		// a long thin capsule laid along the body — the belly runs seven radii —
		// while an object is compact: the muzzle is one radius long, the nose half of
		// one. Requiring both separates them with room to spare.
		//
		// Both are read off the *part*, never off the locally interpolated radius.
		// That distinction is not cosmetic: a belly capsule tapers, and keyed on the
		// local radius the same capsule came out a region at its thick end and an
		// object at its thin one, so half of it kept the stencil edge — which is
		// exactly the pale sliver that survived two rounds of work here and was only
		// found by painting the qualifying pixels green and looking.
		float pr = max(g1.x, g1.y);
		float body_h = max(bounds_max.y - bounds_min.y, 1e-3);
		float region = smoothstep(0.024, 0.048, pr / body_h)
			* smoothstep(2.2, 4.5, length(g0.zw - g0.xy) / max(pr, 1e-5));

		// Colour is blended over its own, wider window rather than over the one that
		// blended the distance, and *that* is the belly slab.
		//
		// The pale belly capsule is not a decal at all — it hangs below the barrel,
		// so it wins the distance outright and takes the ordinary union path, where
		// the colour crosses from coat to belly over one blend width. A blend width
		// is a couple of hundredths of a unit, chosen to make the *silhouette*
		// smooth, and a pigment boundary that sharp running a quarter of the length
		// of the animal is a stencil. Rendering the albedo on its own is what
		// settled it: the pale lens was still there with the decal path switched off
		// entirely, which is where two rounds of work on the decal edge went.
		//
		// Countershading on a real animal is a gradient a hand's breadth deep, so a
		// region gets one and an object keeps the hard edge that makes it an object.
		float col_k = mix(g1.z, max(g1.z, pr * 1.35), region);
		float hc = clamp(0.5 + 0.5 * (d - prev_d) / max(col_k, 1e-5), 0.0, 1.0);
		f.albedo = mix(col, f.albedo, hc);
		f.groom = normalize(mix(groom, f.groom, h) + 1e-6);
		f.axis = normalize(mix(axis, f.axis, h) + 1e-6);
		f.arc = mix(dot(p, axis), f.arc, h);
		f.off = mix(-(d + radius) * dot(grad, vec2(-axis.y, axis.x)), f.off, h);
		f.coat_len = mix(g2.w, f.coat_len, h);
		f.height_scale = mix(g1.w, f.height_scale, h);
		f.along = mix(along, f.along, h);
		if (h < 0.5) { f.mat = g2.x - float(layer) * 16.0; }

		// Markings. A part whose own surface lies *inside* the volume it was
		// unioned with is not a lump — it is a patch of different stuff on the
		// surface: the leather of a nose on a muzzle, the bare pink inside an
		// ear, a white sock on a leg. Smooth-union blending cannot express that,
		// because the deeper field always wins the colour, and the marking
		// silently vanishes. So an engulfed part paints instead of unioning, and
		// brings its material and coat length with it, which is what lets a nose
		// be bald in the middle of a furry face.
		//
		// Two guards keep this from eating the ordinary joints. The part has to
		// be buried by a real fraction of its own radius, and it has to be
		// *different* from what it would paint over — two same-coloured capsules
		// meeting at a knee are a smooth union, and treating them as a marking
		// puts a bright ridge on every joint in the animal.
		float distinct = smoothstep(0.06, 0.20, length(col - f.albedo));
		// The marking's edge width, on the same object-versus-region call `region`
		// makes above: an object's edge is where the leather stops and is one blend
		// width, a region's is a gradient that takes a good fraction of the patch to
		// complete. Drawn with a nose's edge, a pale underside is a rectangle stuck
		// on the animal with a straight bottom line. Worse than merely hard: the
		// countershading further down keys off luminance, so it switches off inside
		// the pale patch and full on immediately outside it, and the two treatments
		// meet along that edge and square its corners.
		float feather = max(g1.z, pr * mix(0.10, 1.55, region));
		// The burial gate widens with it, and that is the half that was still
		// drawing a line. Rendering the albedo alone showed the residual: a
		// hard-edged pale lens right where the belly capsule crosses from "buried by
		// 0.6 of its radius" to "buried by 0.15", because that window is a couple of
		// hundredths of a unit wide however big the marking is. On a nose it is the
		// right window — a nose is either leather or it is not. On a belly it is a
		// stencil, and what a belly wants is for the pigment to come up gradually as
		// the patch sinks into the barrel, which is countershading.
		float engulf = smoothstep(0.15 * radius,
			mix(0.60, 2.20, region) * radius, d - prev_d);
		float paint = smoothstep(feather, -feather, d) * engulf * distinct;
		if (paint > 0.002) {
			f.albedo = mix(f.albedo, col, paint);
			f.coat_len = mix(f.coat_len, g2.w, paint);
			if (paint > 0.5) { f.mat = g2.x - float(layer) * 16.0; }
			if (paint > f.decal_w) {
				f.decal_w = paint;
				f.decal_d = d;
				f.decal_r = radius;
				f.decal_grad = grad;
			}
		}
	}
	return f;
}

// ---------------------------------------------------------------------------
// Inter-layer occlusion
//
// The layers are a depth sort, not a depth buffer, so shadowing between them has
// to be asked for explicitly. Both terms below re-use a field that was already
// evaluated for its own layer: offsetting it with its own gradient is a
// first-order sample at the shifted point, which is accurate at the distance two
// body layers are ever apart and costs nothing next to a second 28-part loop.
// ---------------------------------------------------------------------------

float layer_shadow(Field occ, vec2 lxy, float reach, float depth) {
	if (!occ.hit) { return 1.0; }
	float d = occ.d + dot(occ.grad, lxy) * reach;
	return mix(1.0 - depth, 1.0, smoothstep(0.0, reach, d));
}

float layer_contact(Field occ, float radius, float depth) {
	if (!occ.hit) { return 1.0; }
	return mix(1.0 - depth, 1.0, smoothstep(0.0, radius, occ.d));
}

// Ambient occlusion a nearer layer casts on the one behind it.
//
// This is the term that makes a far leg a leg. It differs from `layer_contact`
// in reach and in falloff: something a few centimetres behind a body sees a
// hemisphere that the body has taken a bite out of, and the bite closes slowly
// with distance rather than ending at the occluder's outline. Squaring the
// falloff puts most of the darkening right against the occluder, so the far limb
// has a dark side where it disappears under the near one and opens up away from
// it. Without that gradient the far limb is uniformly dark, and a uniformly dark
// shape next to a lit one reads as its cast shadow, not as another limb.
float layer_occlude(Field occ, float reach, float depth) {
	if (!occ.hit) { return 1.0; }
	float t = clamp(occ.d / max(reach, 1e-5), 0.0, 1.0);
	float open = t * t;
	return 1.0 - depth * (1.0 - open);
}

// ---------------------------------------------------------------------------
// Shading
// ---------------------------------------------------------------------------

struct LayerCtx {
	float shadow;   // directional shadow cast by nearer layers
	float ao;       // ambient occlusion from nearer layers
	float contact;  // tight crevice darkening, applied *after* the haze
	float atmos;    // 0 = up front, 1 = fully receded
	float soften;   // antialias width multiplier, for depth softening
	float detail;   // 0 = defocused, 1 = crisp: scales micro-surface and fringe
	float body_h;   // creature height in rig units, for scale-free falloffs
};

vec4 shade_layer(Field f, vec2 p, LayerCtx ctx, out vec3 dbg) {
	dbg = vec3(0.0);
	if (!f.hit) { return vec4(0.0); }

	int mat = int(f.mat + 0.5);
	float unit_px = 1.0 / max(px_per_unit, 1.0);
	bool furry = mat == MAT_FUR || mat == MAT_FEATHER;
	float R = max(f.radius, 1e-4);

	// --- surface frame ------------------------------------------------------
	// Local frame across the part's spine. Every marking, every non-fur family
	// and — from this pass — the groom itself is written in it, so their detail
	// wraps the body instead of being stamped in screen space. Built on the
	// spine, not on the groom; see `Field.axis`.
	vec2 across = vec2(-f.axis.y, f.axis.x);
	float arc = f.arc;
	// Dorsal-to-ventral coordinate: +1 at the top line of the part, 0 across the
	// middle of the flank where the surface faces the viewer, -1 at the belly
	// line. It falls out of the capsule frame for free and it is what lets a
	// marking or a landmark be told to keep to the back and off the underside.
	//
	// The sign is not obvious from the algebra and it is worth not re-deriving.
	// Rendering `dv` straight to the framebuffer settles it in one capture; do
	// that rather than reasoning about it, because reasoning about it puts the
	// tabby's spine stripe down the animal's underside. Measured again this round
	// on the standing cat at ship size: +1 is the back. The same capture also says
	// `|dv|` and `u` are the same number to every digit it can print, which is the
	// identity the groom frame below is built on.
	// Signed distance from the part's own *spine*, blended as a scalar. Positive
	// is dorsal; that is not obvious from the algebra and it is worth not
	// re-deriving — render `dv` and look, which is what settled it.
	//
	// This used to be `(f.d + R) * sign(dot(f.grad, across))`, and the `sign` was
	// the belly slab. Inside the pocket where a thin capsule is engulfed by a fat
	// one the accumulated gradient points back up toward the fat one's spine, so
	// the sign flips and `dv` steps from +0.5 to -0.5 across a single pixel.
	// Everything keyed on `dv` steps with it — the countershading, the tabby, the
	// coat sheen, the underside occlusion and the groom frame's own lean — and what
	// lands on screen is a hard-edged pale lens the length of the belly. Three
	// passes went looking for that in the pigment and could not find it; rendering
	// `dv` showed it in one capture, as a blue island in a red field.
	//
	// Measured from the spine and *per part* before the blend, which is the other
	// half. Measured from a capsule's endpoint instead, two capsules whose spines
	// are offset perpendicular to each other disagree by a constant — the cat's
	// torso chain alone by 0.17 of a radius — and the animal comes out quilted with
	// rounded rectangles.
	float dv = clamp(f.off / R, -1.0, 1.0);
	float v = dv * R;
	// `bulk` separates a body mass from a limb — the only thing on an animal
	// thinner than a body section is a limb — and a good half of this file keys
	// off it. The gate is a ratio against body height, so it means the same thing
	// for a kitten and for an adult.
	float bulk = smoothstep(0.055, 0.100, max(f.bulk_r, R) / ctx.body_h);

	// --- groom frame --------------------------------------------------------
	// Where the hair points, derived from the surface instead of authored.
	//
	// A species hands each part one `groom_angle`, and most of them barely set it:
	// measured at ship size, 58% of this cat's body pixels carry the identical
	// direction — dead level, from the base of the neck to the root of the tail.
	// Fur grown on that frame runs as one unbroken set of parallel lanes across
	// the whole animal, and parallel lanes sampled at two pixels a lane are sawn
	// timber whatever pigment they are drawn in. That is the wood grain at its
	// root, and it is why the two previous passes, which both worked on the lanes
	// themselves, could only move it around.
	//
	// Real fur flows over the form, and the form here has an exact unfolding: the
	// part is a capsule seen from the side, `arc` runs along its spine, and the
	// angle round the barrel is `theta` with `sin(theta) = dv` by construction.
	// (That is the same identity as `u = |dv|`, which the height field below
	// already depends on, so the whole frame costs one `asin`.) Arc length round
	// the barrel is `R * theta`, and hair is spaced evenly in *that* — which is
	// what crowds the lanes toward the silhouette the way a real pelt does instead
	// of holding one screen pitch from spine to outline.
	//
	// Unfolding is also what makes this safe. The groom is a constant rotation in
	// that plane, so the across-hair coordinate stays a genuine scalar field: its
	// level sets bend but can never close. Rotating the frame per pixel — the
	// obvious way to make fur curve — gives up exactly that property, and what
	// comes back is concentric loops, which is the fingerprint artefact the bird's
	// vanes are wearing further down this file.
	//
	// The whole frame therefore comes out of one scalar, the across-hair
	// coordinate
	//
	//     PSI(p) = sin(tilt) * arc  +  THETA(theta)
	//
	// and *that shape* is what makes this safe rather than the constant rotation
	// the first attempt used. PSI is a sum of a function of `arc` and a function
	// of `theta` alone, so every level set is the graph of `arc` against `theta`:
	// it can bend as sharply as it likes and it still cannot close, cross itself
	// or fold, whatever THETA does. Which means THETA is free, and the flow can be
	// shaped anatomically instead of being one authored angle rotated.
	//
	// The first attempt spent that freedom on nothing — it took THETA = cos(tilt)
	// * R * theta, a straight line, and a straight THETA is a constant lean. It
	// was measured on this cat at ship size and the hair direction varied by nine
	// degrees over the entire flank, which is not a flow, it is the same parallel
	// grain rotated thirty degrees. The wood read survived it.
	//
	// So THETA is bent instead:
	//
	//     THETA(theta) = ctil * R * (theta - beta * sin(theta + FLOW_PHASE))
	//
	// The hair's angle below horizontal works out as atan(tan(tilt) * cos(theta) *
	// R / THETA'), so the flow lies flattest where THETA' is largest. The cos in
	// the numerator already flattens it at both poles — hair runs along the spine
	// on the top line and along the belly underneath, which is what a real one
	// does — and the `beta * sin` term drops THETA' to its minimum at
	// theta = -FLOW_PHASE, putting the steep part on the *lower* flank. Measured on
	// the adult cat that is 6 degrees on the top line, 37 on the upper flank, 56
	// over the ribs and 10 under the belly: down and back over the barrel, which is
	// the reference photograph and is the thing a single authored angle cannot say.
	//
	// `dv` rather than `u` on purpose — it is signed, and it is taken from the
	// field before the fringe displaces it, so the frame is continuous across the
	// outline where the fringe is at its noisiest.
	float sfore = max(sqrt(max(1.0 - dv * dv, 0.0)), 0.16);
	float theta = asin(clamp(dv, -0.985, 0.985));
	// How far the flow leans off the spine. A pelt on a body mass runs down and
	// back across the ribs; on a limb, an ear or a tail it runs along the bone and
	// barely wraps at all, and `bulk` is already precisely that distinction.
	float tilt = mix(0.10, 0.62, bulk);
	float ctil = cos(tilt);
	float stil = sin(tilt);
	// Where round the barrel the flow is steepest, in radians below the spine
	// line, and how much it steepens there. Held under 1 so THETA' never reaches
	// zero: at zero the lanes are exactly level, and past it the across-hair axis
	// reverses, which would put a seam round the animal.
	const float FLOW_PHASE = 0.35;
	float beta = 0.62 * bulk;
	float theta_rate = ctil * R * (1.0 - beta * cos(theta + FLOW_PHASE));
	// The two axes in screen space. A step along the spine moves a whole unit; a
	// step round the barrel is foreshortened by `cos(theta)`, because the screen
	// offset from the spine line is `R*sin(theta)`. Both axes are read straight off
	// PSI: the hair runs along its level set and the across-hair axis is the screen
	// perpendicular of that, which is not the same thing as the gradient once the
	// barrel is foreshortened.
	vec2 groom_s = normalize(theta_rate * f.axis - stil * R * sfore * across + 1e-6);
	vec2 across_s = vec2(-groom_s.y, groom_s.x);
	if (dot(across_s, across) < 0.0) { across_s = -across_s; }
	// Screen pixels per rig unit measured *across* the hair, which is the pitch
	// that decides whether a lane can be resolved at all. This is the one place the
	// *gradient* of PSI is wanted rather than the perpendicular of its level set —
	// how fast the lane index climbs, not which way the lane runs — and the two
	// differ by the foreshortening, `sfore`, once round the wrong way. Getting that
	// inverted (the first attempt did) claims the lanes *spread* toward the
	// silhouette when they are crowding into it, so the coat runs full contrast on
	// sub-pixel lanes exactly where the barrel turns away: a shimmering rim.
	// Floored so the fade is a fade and not a bald band round every outline.
	float psi_grad = min(sqrt(stil * stil
		+ (theta_rate / max(R * sfore, 1e-4)) * (theta_rate / max(R * sfore, 1e-4))), 4.2);
	float px_groom = px_per_unit / max(psi_grad, 0.22);
	if (debug_view == 1) { dbg = vec3(0.5 + 0.5 * groom_s, 0.35); }
	if (debug_view == 2) { dbg = vec3(max(dv, 0.0), 0.10, max(-dv, 0.0)); }
	if (debug_view == 9) { dbg = vec3(fract(R * 24.0), R * 3.0, 0.2); }
	// `arc` banded. Every non-fur family and every marking is written in it, so
	// wherever these bands close into rings that family gets a fingerprint.
	if (debug_view == 10) { dbg = vec3(step(0.5, fract(arc * 40.0))); }

	// --- coat silhouette ----------------------------------------------------
	// Real strands, indexed along the outline, displacing the distance field.
	// The band keeps the displacement near the surface so the interior field
	// stays smooth for the height lift.
	float coat = f.coat_len * fluff * (1.0 + 0.35 * (3.0 - growth) / 3.0);
	float fringe = 0.0;
	float tip_cover = 0.0;
	if (mat == MAT_FUR && coat > 1e-5) {
		float cover;
		// A receded layer gets its individual hairs taken away, not just blurred:
		// you cannot resolve a strand on the far side of an animal, and leaving
		// the fringe crisp back there is a depth cue pointing the wrong way.
		float spikes = pet_fur_fringe(p, f.grad, groom_s, coat_density,
			px_per_unit, ctx.detail, cover);
		// How far in from the outline the fringe is allowed to disturb the field.
		// Budgeted against the part's own radius as well as the coat length,
		// because on a leg the two are the same size: a band three coat-lengths
		// deep swallows a whole limb, and then the spike pattern is not breaking
		// up the silhouette any more, it is corrugating the shading right across
		// the leg. Which is a fair description of what the legs looked like.
		float band = smoothstep(-min(coat * 3.0, f.radius * 0.55), coat * 0.2, f.d);
		fringe = coat * spikes * band * (1.0 - wetness * 0.85);
		tip_cover = cover * band;
	}
	float d = f.d - fringe;

	// --- coverage -----------------------------------------------------------
	// One-pixel analytic antialias. `fwidth` on the field would be ideal but the
	// fringe term makes it noisy, so we use the known pixel scale. The far layer
	// widens it, which is the cheapest honest defocus available.
	float aa = unit_px * 0.85 * ctx.soften;
	float alpha = smoothstep(aa, -aa, d);
	if (alpha <= 0.002) { return vec4(0.0); }

	// --- height field and normal -------------------------------------------
	// For a capsule cross-section the exact height is R*sqrt(1-u^2) where u
	// walks 0 (spine) → 1 (silhouette). Differentiating analytically avoids the
	// stair-stepping that screen-space derivatives produce on curved bodies.
	//
	// The slope has to be bounded at the rim or every silhouette pixel becomes a
	// mirror, which is what makes cheap implicit bodies glow white round the
	// edge. The bound is set in *pixels*: the normal is not allowed to turn
	// faster than one pixel can resolve. A fixed bound instead would flatten a
	// 15 px leg into pure silhouette while leaving a torso untouched — which is
	// exactly how thin limbs end up as pale featureless tubes.
	float u = clamp(1.0 + d / R, 0.0, 1.0);
	float u_res = 1.0 - 1.0 / max(R * px_per_unit, 2.0);
	float su_min = sqrt(max(1.0 - u_res * u_res, 1e-4));
	float su = sqrt(max(1.0 - u * u, 0.0));
	float slope = -f.height_scale * u / max(su, su_min);
	vec2 nxy = -slope * f.grad;

	// A marking still has thickness: nose leather and paw pads stand proud of
	// the coat around them, and the inside of an ear is a shallow bowl. Give the
	// painted part its own low dome so it is not a flat sticker.
	//
	// Only the small ones, though. A patch the size of a nose is an *object* and
	// wants an edge; a patch the size of a belly is a *region* of different coat,
	// and giving that one a raised lip draws a hard line all the way round the
	// animal's underside where there should be nothing but a change of colour.
	// The gate is a ratio against body height so it means the same for a kitten.
	if (f.decal_w > 0.01) {
		// The window is tight, and deliberately tighter than it was. Measured on
		// this cat the nose sits at 0.012 of body height and the belly at 0.045, and
		// at the old threshold the belly still kept a tenth of a dome — which on a
		// patch that long is a raised lip running the whole underside, catching the
		// key as a hard bright line. A tenth of the wrong shape is still the wrong
		// shape when the shape is a quarter of the animal long.
		float small = 1.0 - smoothstep(0.020, 0.036, f.decal_r / ctx.body_h);
		float ud = clamp(1.0 + f.decal_d / max(f.decal_r, 1e-4), 0.0, 1.0);
		float sud = sqrt(max(1.0 - ud * ud, 0.0));
		nxy += f.decal_grad * (0.36 * ud / max(sud, 0.46)) * f.decal_w * small;
	}

	// --- skeleton -----------------------------------------------------------
	// A cat's back is not a tube. The blade of the scapula stands proud where the
	// foreleg swings under it, the point of the hip sits above the femur head,
	// the loin muscles roll either side of the spine and the last ribs show on
	// the lower flank. Those are most of what makes light read as falling on an
	// animal rather than on a sausage, and none of them can be a capsule: the cat
	// is at 28 parts of 28. So they are relief, added to the same height-field
	// slope everything else in this shader uses.
	//
	// `bulk` (computed with the surface frame above) keeps them on the body
	// masses. The identical field stamped onto a leg or an ear is a dent in a
	// tube.
	float skel = 0.0;
	// Lane displacement the coat picks up from the same bones, in rig-space
	// surface arc length. See where it is used, below.
	float whorl = 0.0;
	if (bulk > 0.002) {
		for (int i = 0; i < MAX_LANDMARKS; i++) {
			if (i >= landmark_count) { break; }
			vec4 lm = landmarks[i];
			// Neither of these bones is round, and a round one is the failure: a
			// radially symmetric dome halfway up a flank is the shape of a boil,
			// not of a skeleton. Both are crests hanging off the top line — the
			// blade of the scapula, the point of the hip — so the relief is
			// stretched *upward*, toward the spine, and cut off short below, where
			// on a live animal the muscle simply fills in behind the bone. The
			// horizontal squeeze keeps them from reading as a barrel band.
			vec2 raw = p - lm.xy;
			vec2 dp = raw * vec2(1.30, 1.0);
			dp.y *= mix(0.58, 1.70, step(0.0, dp.y));
			float q = length(dp);
			float dsl;
			float dome = pet_ridge(q / max(lm.z, 1e-4), dsl);
			// The dome's own analytic slope *is* the normal tilt, exactly as for
			// the capsule height field. Only the crest is allowed to move, though:
			// a bone shows because the light catches its upper face, not because
			// the flesh beneath it goes dark, and a symmetric dome tilts its lower
			// half away from the key and leaves a grey thumbprint on the flank —
			// which is worse than having no landmark at all. Losing integrability
			// here is fine; this is a shading model, not a displacement map.
			float crest = smoothstep(0.55, -0.30, raw.y / max(lm.z, 1e-4));
			nxy -= (dp / max(q, 1e-5)) * dsl * lm.w * bulk * crest;
			skel = max(skel, dome * bulk * crest);

			// The coat sweeps *around* a shoulder rather than straight over it,
			// which is why a real cat has a visible whorl there and why the review
			// asks for one. It is added to the lane coordinate, not to the frame
			// direction: any smooth scalar added to a lane index bends the lanes
			// and cannot fold them, whereas rotating the frame here would put a
			// set of concentric rings on the shoulder.
			//
			// Hung on the *socket*, not on the landmark. The landmark has already
			// been lifted up under the top line, because that is where the blade of
			// the scapula shows; a whorl put there is a whorl on the withers, which
			// no animal has. And it is deliberately wider and weaker than the bone
			// it sits under: rendering the lane index showed the previous amplitude
			// pushing about three quarters of a lane-gradient into a dome a fifth of
			// the body across, which is enough to close the level sets — the
			// shoulder came out wearing a fingerprint, exactly the artefact this
			// frame exists to avoid, and it is one of the blotches the last capture
			// was covered in. Held near a quarter of the base gradient, the lanes
			// bend round the joint and stay lanes.
			vec4 lr = limb_roots[i];
			float wq = length((p - lr.xy) * vec2(0.86, 1.22)) / max(lr.z, 1e-4);
			float wsl;
			whorl += pet_ridge(wq, wsl) * lr.z * 0.30 * bulk;
		}
		// The loin: two long muscles running either side of the spine. Seen from
		// the side the groove between them is edge-on, so what actually reads is
		// the roll of the muscle just below the top line — which is why this is a
		// band near dv = 0.7 and not a groove at dv = 1.
		float loin = smoothstep(0.42, 0.78, dv) * smoothstep(1.0, 0.82, dv);
		nxy -= across * 0.085 * loin * bulk;
		// Ribs, on the lower flank only: covered by muscle up at the spine, and
		// past the ribcage down at the belly. Very shallow — on a short-coated
		// cat in condition these are a change in how the light runs, not relief
		// you could feel, and pushed any further they read as corduroy.
		float ribs = smoothstep(0.40, -0.05, dv) * smoothstep(-0.80, -0.35, dv);
		nxy += across * cos(arc * 128.0) * 0.014 * ribs * bulk;
	}

	float micro_occ = 1.0;
	float micro_tint = 0.0;
	float spec_mul = 1.0;
	float glint = 0.0;
	float irid = 0.0;
	float piping = 0.0;
	float strand_tilt = 0.0;
	float wet_film = wetness;

	// Where two capsules smooth-union, the blended frame turns fast: `groom` and
	// `grad` are interpolated by the same weight that blended the distance, and
	// that weight swings the whole way across a couple of pixels. The coat's lane
	// coordinate is built out of both, so over a steep blend the lanes of the two
	// parts sweep through each other and leave a cross-hatched etch — visible over
	// the brow, where the skull, the cheek and the ear root all meet at once.
	//
	// The measurement is the screen-space derivative of the frame itself, which is
	// exactly "how far the blend field's gradient has moved since the last pixel".
	// Anything past a few hundredths of a radian per pixel cannot be a lane
	// direction, only a moire, so the stroke displacement is clamped away there.
	// The coat's *lighting* keeps running; only the relief and the sub-pixel
	// break-up stop, so the brow loses its hatch without turning bald.
	// `axis` is in here as well as `groom`, because the markings are written in
	// the axis frame and they fail the same way: where the spine direction spins
	// through a blend, `arc` sweeps fast, and a band of constant `arc` collapses
	// into a set of tight concentric rings round the joint. On the shoulder that
	// draws what looks like a wireframe over the chest.
	float frame_twist = (length(fwidth(f.groom)) + length(fwidth(f.grad))
		+ length(fwidth(f.axis))) * 0.34;
	float frame_ok = 1.0 - 0.92 * smoothstep(0.020, 0.115, frame_twist);
	// The other way a band coordinate fails, and the one that draws the rings. A
	// projection onto a unit direction advances by exactly one pixel of rig
	// distance per pixel, so this number sits at 1 wherever `arc` means anything.
	// Where two parts' axes are close to perpendicular the blend can *stall* it
	// instead — the coordinate has a local extremum, and a family of bands round an
	// extremum is a set of closed contours, which is a fingerprint and not a
	// stripe. There is genuinely no "along the part" at a point where two parts
	// disagree about which way that is, so the honest answer is to fade the bands
	// out rather than to draw a wrong one.
	float arc_rate = fwidth(arc) * px_per_unit;
	float band_ok = frame_ok * smoothstep(0.12, 0.50, arc_rate);

	if (mat == MAT_FUR) {
		// The lane coordinate, in the unfolded surface plane: along the hair, then
		// across it. `t.y` is PSI itself — the scalar whose level sets *are* the
		// lanes — so it carries the bent THETA from the groom-frame block above,
		// and the flow the frame promised is the flow the strands actually get.
		// `t.x` only sets where along a hair the dash starts and stops, so it stays
		// the plain conjugate.
		//
		// `sarc` is arc length round the barrel from the spine line, so equal steps
		// in it are equal steps *on the animal* — which is what makes the lanes
		// crowd into the silhouette instead of holding one screen pitch all the way
		// to the outline.
		float sarc = R * theta;
		vec2 t = vec2(arc * ctil - sarc * stil,
			arc * stil + ctil * R * (theta - beta * sin(theta + FLOW_PHASE)) + whorl);
		// Three small octaves of wander, the finest at strand scale, so neighbouring
		// lanes drift apart from each other instead of the whole field bending as a
		// block — a single large low-frequency warp bends every lane the same way at
		// once, and smoothly wavy parallel lines are the definition of wood grain.
		// Applied to the lane coordinate rather than to the sample point: it is the
		// same displacement, and doing it here keeps it inside the unfolded frame
		// where it provably cannot fold one lane over another.
		t += vec2(pet_noise(p * 3.6 + 11.0), pet_noise(p * 3.6 + 43.0)) * 0.024
			+ vec2(pet_noise(p * 11.0 + 3.0), pet_noise(p * 11.0 + 71.0)) * 0.009
			+ vec2(pet_noise(p * 34.0 + 5.0), pet_noise(p * 34.0 + 17.0)) * 0.0026;
		// The lane index itself, wrapped into stripes. Two bands per lane-pitch so
		// the picture shows where the lanes go, not where the hairs are: if the
		// stripes run parallel from nose to tail this is the wood grain, and if
		// they sweep round the ribs and fan at the chest it is a pelt.
		if (debug_view == 3) {
			// The lane index alone, wrapped into hard bands at a quarter of the
			// authored pitch so the lanes are legible at review zoom. If these run
			// parallel from nose to tail the coat is wood grain; if they sweep down
			// the ribs and turn at the shoulder it is a pelt.
			float lanes = step(0.5, fract(t.y * 48.0 * coat_density * 0.25));
			dbg = vec3(lanes);
		}
		Coat c = pet_fur(t, across_s, coat_density, px_groom,
			fluff * (1.0 - wetness * 0.7));
		nxy += c.slope * ctx.detail * frame_ok;
		micro_occ = mix(1.0, c.occ, ctx.detail * frame_ok);
		// A twentieth of what it used to be. Everything the coat used to say
		// through albedo it now says through the specular break-up below —
		// pigment noise at this scale is what made the body read as damp clay.
		micro_tint = c.tint * 0.085 * ctx.detail * frame_ok;
		spec_mul = mix(1.0, c.spec, ctx.detail * frame_ok);
		strand_tilt = c.tilt * ctx.detail;
		glint = c.glint;
	} else if (mat == MAT_FEATHER) {
		Surf s = pet_feather(arc, v, u, coat_density, px_per_unit);
		// Gated on `band_ok` for the same reason the fur's relief is: the barb lanes
		// are written in `arc`, so wherever `arc` stalls they are contour lines round
		// a stall point rather than vanes. The feather path never had this guard,
		// which is why the fingerprint showed up here first when the family was
		// finally ungated.
		nxy += s.slope.x * across * band_ok;
		micro_occ = mix(1.0, s.occ, band_ok);
		micro_tint = s.tint * 0.18 * band_ok;
		spec_mul = mix(1.0, s.spec, band_ok);
		irid = s.extra * band_ok;
	} else if (mat == MAT_SCALE) {
		Surf s = pet_scale(arc, v, nxy, coat_density, px_per_unit);
		// Same guard: squamation rows are indexed off `arc` too, and a lizard with
		// its plates spiralling round a stall point reads as a machined thread.
		nxy += (s.slope.x * across + s.slope.y * f.grad) * band_ok;
		micro_occ = mix(1.0, s.occ, band_ok);
		micro_tint = s.tint * band_ok;
		spec_mul = mix(1.0, s.spec, band_ok);
	} else if (mat == MAT_SKIN) {
		// A nose is always the smallest bare volume on the animal, and it is the
		// only one that is wet; paw pads and bellies are matte leather.
		float nose = 1.0 - smoothstep(0.014, 0.045, R);
		Surf s = pet_skin(p, coat_density, px_per_unit,
			max(wetness, nose * 0.9));
		nxy += s.slope;
		micro_occ = s.occ;
		micro_tint = s.tint;
		spec_mul = s.spec;
		wet_film = max(wet_film, nose * 0.9);
	} else if (mat == MAT_CLAW) {
		Surf s = pet_claw(u, f.along);
		micro_occ = s.occ;
		micro_tint = s.tint;
		spec_mul = s.spec;
		piping = s.extra;
	}

	// Hair lies flatter, tighter and glossier where it is stretched over bone.
	// That is the other half of why a scapula reads on a live animal: the light
	// finds it by shape *and* by gloss. Kept small — it is a tendency in the
	// coat, not a bald patch.
	spec_mul *= 1.0 + skel * 0.28;
	micro_occ *= 1.0 - skel * 0.05;

	vec3 n = normalize(vec3(nxy, 1.0));

	// Height above the ground plane, normalised by body height so the falloffs
	// below mean the same thing for a kitten and for an adult.
	float height01 = clamp(-p.y / ctx.body_h, 0.0, 1.5);

	// --- albedo -------------------------------------------------------------
	vec3 albedo = f.albedo;
	if (furry) {
		// Broad coat pattern, before any of the fine detail.
		//
		// This is the block that decides whether the animal can be identified at
		// the size it ships at, and it is deliberately the crudest thing in the
		// file. At 260 px a cat is about 230 px nose to rump: a tabby bar is four
		// pixels, a guard hair is a third of one, and *none* of the coat pass
		// below survives the downsample as anything but grain. What does survive
		// is a value break the size of a body section — a dark saddle over the
		// back, a pale bib and underside, dark socks — and that is why every
		// shipped animal in the reference titles is marked in big shapes rather
		// than in texture. A blind reviewer called this build a wooden ox at 260
		// px, and the reason was not that the fur was wrong; it was that there
		// was no shape in the value at all, so the coat had nothing to be a coat
		// *on*.
		//
		// Everything here is written in the part's own dorsal-ventral coordinate
		// and in height above the ground, never in absolute rig position, so it
		// costs no species authoring and it lands correctly on a body that is
		// currently mid-stride.
		float lum0 = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		// The same luminance gate the tabby uses. A muzzle, a chin, a bib and the
		// inside of an ear are already a second pigment; countershading them a
		// second time is how a white chest turns grey.
		float takes_p = smoothstep(0.88, 0.60, lum0) * marking_strength;
		if (takes_p > 0.004) {
			// `bulk` separates a body mass from a limb, and it is already the
			// right test: a saddle lies on the trunk, points lie on the limbs.
			float saddle = smoothstep(-0.02, 0.58, dv) * bulk;
			// Countershading. The underside of every wild mammal carries less
			// pigment than its back, and that single gradient does more for
			// "solid animal" at thumbnail size than any amount of stripe. Lifting
			// the coat colour rather than mixing toward a stored one keeps it a
			// pigment-density change instead of a colour the shader invented.
			// Ramped from just below the spine rather than from the lower flank.
			// Started low it is a *band* with a top edge, and a pale band with an
			// edge across an animal's middle is a painted stripe; started high it
			// is the gradient countershading actually is.
			float bib = smoothstep(0.06, -0.82, dv) * bulk;
			// Points: every extremity darker than the trunk. `1 - bulk` already
			// selects exactly the set — legs, paws, tail, ears, muzzle — because
			// the only thing on an animal thinner than a body section is a limb.
			// The muzzle is carried out of it by the luminance gate above, which
			// is where it belongs; a pale mask is a pigment decision the species
			// already made.
			//
			// It is also the term the whole ship-size read leans on hardest. The
			// far and near legs are the same colour as the flank and get twice the
			// floor bounce, so they come out *brighter* than the body they hang
			// off — four pale dowels under a dark mass, which is the exact shape of
			// a carved figurine on a stand. Making them genuinely darker in pigment
			// is what turns them back into legs.
			float points = 1.0 - bulk;
			// Deepest right at the paws and at the ear tips, the way a seal-point
			// or a mackerel tabby actually grades.
			points *= mix(0.72, 1.0, max(1.0 - smoothstep(0.02, 0.30, height01),
				smoothstep(0.64, 0.80, height01)));

			// The shade pigment alone is not dark enough to build a saddle out of —
			// it is chosen to be a *stripe* against the ground colour, a third of a
			// stop down, and a third of a stop spread over half a body is not a
			// shape, it is a wash. So the mix is followed by a straight reduction in
			// pigment density, which is what actually separates a wild-type back
			// from its own flank.
			vec3 shade = palette[marking_index].rgb;
			float dark = clamp(saddle * 0.74 + points * 0.58, 0.0, 0.88) * takes_p;
			albedo = mix(albedo, shade, dark);
			albedo *= 1.0 - dark * 0.24;
			// The lift is deliberately smaller than the darkening. A species that
			// already has a pale belly capsule is paying for the underside once
			// before this term runs, and paying twice is how countershading stops
			// being a gradient and becomes a white stripe painted round the middle
			// of the animal.
			albedo = mix(albedo, albedo * 1.30, bib * 0.85 * takes_p);
		}
		// Tabby. Pigment in a mammal coat is laid down in bands along each hair,
		// and in wild-type coats those bands line up into stripes: bars running
		// down the flanks off a solid dorsal line, rings round the legs and the
		// tail. One expression does all three, because it is written in the
		// part's own groom frame — a band of constant `arc` is a vertical bar on
		// the ribs and a ring on a limb, since the groom already turns with the
		// part. Without this the whole animal is one flat brown, which is the
		// single cheapest-looking thing a coat can be.
		//
		// Pale markings keep out of it. A muzzle, a chin, a belly and the inside
		// of an ear are a different pigment, and a tabby never stripes them —
		// striping them anyway reads as dirt, so the mask keys off luminance.
		float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		// The window has to straddle the gap between the two pigments, not hug
		// the ground colour: set too tight it fades the stripes out over the
		// whole mid-flank, where a smooth-union with the belly has already lifted
		// the luminance a little, and the markings end up a collar round the
		// shoulders instead of a coat.
		//
		// It also has to be *wide*, and that is the less obvious half. A narrow
		// window turns into a step, the step lands somewhere across the middle of
		// the flank — wherever the belly capsule's paint has lifted the luminance
		// past it — and every bar running down the flank is guillotined along the
		// same contour. What that draws is a row of hard-cornered rectangles,
		// which is the exact artifact the bars were reshaped to get rid of, coming
		// back in through the mask instead of through the profile.
		// And the underside carries no bars at all, said in the part's own
		// dorsal-ventral coordinate rather than left to the luminance gate.
		//
		// The gate was meant to do this on its own — a pale belly is a second
		// pigment and a tabby never stripes it — but luminance is a proxy, and the
		// countershading gradient crosses the gate's window right where the belly
		// pigment comes up. A bar's own edge landing on that crossing draws a hard
		// pale lens with a dark rim round it, which is what survived three separate
		// attempts to soften the belly and was only found by rendering the field's
		// albedo and the shaded albedo side by side: the first was a clean gradient
		// and the second had a two-pixel step in it.
		float takes = smoothstep(0.96, 0.50, lum) * marking_strength
			* smoothstep(-0.70, -0.24, dv);
		if (takes > 0.004) {
			// The bars have to bend and break. A clean periodic set reads as a
			// paint job on a toy: one field warps them, a second and much slower
			// one lets whole bars thin out or drop, which is what mackerel
			// actually does along a real flank.
			//
			// Both warps are budgeted against the bar *wavelength*, which is the
			// thing that is easy to get wrong here. A phase term of a couple of
			// radians is half a period: it does not bend the stripes, it destroys
			// them, and what comes back is the field of soft blotches the coat
			// spent this whole pass getting away from.
			float wob = pet_fbm(p * 3.4, 3);
			float broken = pet_fbm(p * 2.1 + 19.0, 2);
			// Counted in whole periods rather than read off a sine, because a sine
			// gives every bar the same width, the same strength and the same two
			// square ends — which is precisely what made the flank read as a
			// painted barrel. With a band index in hand each bar can be given its
			// own everything, exactly the way the coat's fibre lanes already are.
			const float BAR_FREQ = 33.0;
			float phase = (arc * BAR_FREQ + wob * 1.4 + dv * 1.1) / PETALIA_TAU;
			float band = floor(phase);
			float b1 = pet_hash1(vec2(band, 7.0));
			float b2 = pet_hash1(vec2(band, 23.0));
			float b3 = pet_hash1(vec2(band, 41.0));

			// Where this bar starts and stops. A mackerel bar leaves the spine and
			// dies somewhere on the lower flank, and no two die in the same place;
			// running every bar the full height of the body is what turns a coat
			// into a set of barrel hoops. Both ends are ramps, not cuts.
			float top = mix(0.62, 0.92, b2);
			float bot = mix(-0.66, -0.16, b3);
			float along = smoothstep(top + 0.20, top - 0.08, dv)
				* smoothstep(bot, bot + 0.44, dv);

			// A band painted on a barrel is foreshortened as the surface turns
			// away, so it narrows toward the silhouette; and the light on it falls
			// off at the same time, so it also deepens. Holding both constant round
			// the curve is the single clearest tell of a decal, because a decal is
			// the only thing that behaves that way.
			float away = 1.0 - clamp(dot(n, pet_key_dir()) * 0.5 + 0.5, 0.0, 1.0);
			float half_w = mix(0.15, 0.26, b1)
				* (1.0 - 0.30 * u) * (0.55 + 0.45 * along);

			// Marking edge softness in *screen pixels*, not in rig units. A stripe
			// edge held at a fixed rig width is razor sharp at head-close-up zoom
			// and a full pixel of stair-stepping at ship size, and stair-stepped
			// stripes on a brown body are the "plank grain" the ship-size review
			// keeps reporting. One and a bit pixels of ramp, whatever the zoom.
			float period = PETALIA_TAU / BAR_FREQ;
			float soft_edge = clamp(1.35 / (max(px_per_unit, 1.0) * period), 0.03, 0.34);
			// The ramp has to stay a *fraction* of the bar as well as a fixed
			// number of pixels. Held absolute, a bar that has tapered down to a
			// tenth of a period stops fading and becomes a hard hairline instead —
			// so the ends of every band, and the whole shoulder where the frame
			// twists, come out drawn in wire. A band should thin out and disappear,
			// not sharpen on its way out.
			float edge = max(soft_edge, half_w * 0.55);
			float f = fract(phase) - 0.5;
			float bar = smoothstep(half_w, max(half_w - edge, 0.002), abs(f))
				* along * mix(0.86, 1.16, away) * band_ok
				* mix(0.30, 1.0, smoothstep(-0.50, -0.05, broken));
			// The dorsal line is solid, and the pigment fades out under the
			// animal: a tabby's belly is always the palest part of it.
			// The saddle above already owns the top of the back, so the dorsal line
			// only has to be the narrow solid spine stripe sitting inside it.
			// Leaving it at full strength on top of the saddle stacks two dark
			// terms into one flat black roof, and a flat roof is not a marking.
			float dorsal = smoothstep(0.66, 0.94, dv);
			float mark = clamp(max(bar, dorsal * 0.62), 0.0, 1.0);
			if (debug_view == 7) { dbg = vec3(mark * takes, takes * 0.4, 0.0); }
			albedo = mix(albedo, palette[marking_index].rgb, mark * takes * 0.88);

			// Agouti ticking over the top of it, so the ground colour between the
			// bars is not flat either. It rides the coat's own per-strand random
			// rather than a sine of its own, which is the only way to get it at
			// the right frequency: a band on a hair is a hair-sized thing, and an
			// independent sine has to guess a rig-space wavelength that is wrong
			// at every zoom but one — guessing low is what put a second field of
			// soft blotches on top of the stripes. It only ever darkens; pigment
			// adds, it does not bleach.
			albedo *= 1.0 - smoothstep(0.30, 0.95, glint) * 0.15 * takes;
		}
	}
	albedo *= 1.0 + micro_tint;
	albedo *= mix(1.0, 0.58, wet_film * 0.8);
	// Blood flush on thin, well-lit extremities when the pet is excited.
	float thin = 1.0 - smoothstep(0.02, 0.16, R);
	albedo = mix(albedo, albedo * vec3(1.35, 0.72, 0.70), emotion_flush * thin * 0.7);
	albedo = max(albedo, vec3(0.0));

	// --- occlusion ----------------------------------------------------------
	// Self-occlusion from creases, a cavity term from how deep the pixel sits
	// inside the body, and the contact occlusion handed down from nearer layers.
	// A convex limb is most exposed along its spine and progressively more
	// occluded by its neighbours as the surface turns away, so the cavity term
	// darkens toward grazing. Running it the other way round — bright rim, dark
	// middle — is what draws an outline round every part.
	float crease_ao = 1.0 / (1.0 + f.crease * 30.0);
	float curve_ao = mix(1.0, 0.80, smoothstep(0.45, 1.0, u));
	// A limb sees far less of the room than a flank does. It is boxed in by the
	// body above it and by its three neighbours around it, and it is close to the
	// floor — but none of that reaches the shading, because each layer is
	// evaluated on its own and a free-hanging leg blends with nothing, so it
	// accumulates no crease at all. The measured result is that a leg comes out
	// brighter per unit of albedo than the torso it hangs off, and four bright
	// dowels under a dark mass is the silhouette of a figurine on a stand.
	// Thinness is the available proxy and it is the honest one: what makes a limb
	// enclosed is precisely that it is thin next to everything around it.
	float limb_ao = mix(0.76, 1.0, bulk);

	// The armpit and the groin.
	//
	// A limb does not abut the barrel, it sinks into it, and the crease where the
	// two volumes meet is the darkest thing on a standing animal's underside. It
	// is also the only thing that breaks the underside into shapes — take it away
	// and everything from elbow to groin is one continuous surface with one
	// continuous value, which is precisely the slab the review keeps reporting.
	//
	// Nothing already in this file could find it. Creases come out of the
	// smooth-union, and a limb lives on a *different depth layer* from the torso,
	// so it unions with nothing and contributes no crease at all. Hence
	// `limb_roots`, uploaded by `CreatureRenderer` from where each limb chain
	// hangs off the body mass.
	float socket = 0.0;
	if (bulk > 0.002) {
		for (int i = 0; i < MAX_LANDMARKS; i++) {
			if (i >= landmark_count) { break; }
			vec4 lr = limb_roots[i];
			vec2 sq = (p - lr.xy) / max(lr.z, 1e-4);
			// Hanging downward and slightly narrow: the crease runs down the front
			// and the back of the limb where it enters, and above the joint there is
			// nothing but the muscle over the shoulder. A round patch centred on the
			// socket puts as much shadow on the withers as in the armpit.
			sq.y *= sq.y > 0.0 ? 0.80 : 2.4;
			socket = max(socket, 1.0 - smoothstep(0.30, 1.10, length(sq)));
		}
		// Ventral half only, for the same reason: it is an armpit, not a saddle.
		socket *= smoothstep(0.62, -0.34, dv);
	}
	float ao = crease_ao * curve_ao * micro_occ * limb_ao
		* mix(1.0, 0.52, socket) * ctx.ao;

	// The floor and the body between them close off the hemisphere under the
	// belly and around the paws, so both ambient terms fall away near contact.
	float down = clamp(0.5 + 0.5 * n.y, 0.0, 1.0);
	float ground_ao = mix(1.0, mix(0.34, 1.0, smoothstep(0.0, 0.26, height01)),
		0.28 + 0.72 * down);
	// The slot under a standing body. Height above the floor cannot say this on
	// its own: a cat's belly is a third of a body up, well past where the
	// ground-proximity term above has faded back to 1.0, and that is exactly how
	// the underside came out at the same value as the lit back. What closes the
	// hemisphere down there is not the floor's proximity, it is the floor *and*
	// four limbs boxing the underside in at both ends — so the gate is which way
	// the surface faces, not how low it is.
	//
	// The bounce is deliberately left out of it. The floor is what does the
	// occluding and it is also the only thing still lighting the belly, so taking
	// the key and the sky away and leaving the bounce is both the physical account
	// and the picture the review asked for: a torso with a dark underside carrying
	// one warm gradient along its lowest line.
	// Written mostly in `dv` and only modulated by the normal. What puts a surface
	// in the slot is being on the underside of a body mass — the floor and the four
	// limbs box that in whatever the local micro-normal does — and keying it purely
	// on which way the surface faces leaves anything down there whose own top face
	// happens to point up sitting at full key. On this cat that is the belly
	// capsule, which hangs below the barrel as a thin pale tube and was catching the
	// key along its whole length as a blown-out white bar. Gating on `dv` needs a
	// `dv` that does not step, which it now is.
	float slot = mix(down * down, 1.0, 0.55) * smoothstep(0.12, -0.52, dv)
		* bulk * smoothstep(0.02, 0.20, height01);
	// Measured rather than judged by eye. Across the standing cat's torso the lit
	// back peaks at 0.49 luminance and the lowest rows sit at 0.18, a ratio of
	// 2.75; before this term it was 0.54 against 0.24, which is 2.27 — the back and
	// the belly at nearly the same value, which is the review's complaint stated as
	// a number. Driven harder (0.44 and 0.36 were the first try) the ratio goes
	// past three, and a species whose underside is one big downward-facing capsule,
	// like the dog, comes out with a black plate bolted under it — a different
	// wrong answer from a pale slab, not a better one.
	float key_occ = ctx.shadow * mix(1.0, 0.58, slot);
	float sky_occ = ao * ground_ao * mix(1.0, 0.46, slot);

	// --- lighting -----------------------------------------------------------
	vec3 L = pet_key_dir();
	vec3 V = vec3(0.0, 0.0, 1.0);
	float ndl = dot(n, L);

	float wrap = 0.26 + 0.44 * translucency;
	if (debug_view == 6) { dbg = albedo; }
	// 12 is the *field's* albedo, before the marking block runs on it. The pair
	// isolates which of the two is drawing an edge.
	if (debug_view == 12) { dbg = f.albedo; }
	if (debug_view == 8) { dbg = vec3(ao * ground_ao); }
	vec3 lit = albedo * pet_key(n, key_occ, wrap) * ao;
	if (debug_view == 4) { dbg = pet_key(n, key_occ, wrap) * ao; }
	if (debug_view == 5) {
		dbg = (pet_sky(n, sky_occ) + pet_bounce(n, height01, ao * ground_ao)) * 3.0;
	}
	// Warm scatter through the coat at the terminator.
	lit += albedo * vec3(1.55, 0.62, 0.45) * pet_terminator_band(n)
		* translucency * 0.30 * key_occ * ao;
	lit += albedo * pet_sky(n, sky_occ);
	lit += albedo * pet_bounce(n, height01, ao * ground_ao);

	// Transmission: membranes (ears, wings, webbing) glow when lit from behind.
	// This single term does more for "expensive" than anything else in the
	// shader, which is exactly why it has to be gated properly — a leg is thin
	// too, and a leg that glows reads as a plastic straw. What separates a
	// membrane from a limb is that it is *flattened*, so height_scale gates it.
	float thin01 = 1.0 - smoothstep(0.008, 0.032, R / ctx.body_h);
	float membrane = thin01 * mix(1.0, 0.22, smoothstep(0.25, 0.9, f.height_scale));
	float back = clamp(-ndl, 0.0, 1.0);
	lit += albedo * vec3(1.0, 0.44, 0.31)
		* (translucency * pow(back, 1.5) * membrane * 1.9 * ctx.shadow);
	// Claw keratin pipes light to its point.
	lit += albedo * piping * vec3(1.0, 0.86, 0.78) * 0.55;

	// Hair tips outside the body proper are lit like fibres, not like surface:
	// mostly forward-scattered, warm, and semi-transparent. This is where the
	// silhouette stops being an outline and becomes hair.
	if (tip_cover > 0.002) {
		float glow = tip_cover * (0.30 + 0.70 * clamp(ndl * 0.5 + 0.5, 0.0, 1.0));
		lit += albedo * key_color.rgb * key_energy * glow
			* (0.10 + 0.32 * translucency) * ctx.shadow;
		alpha *= mix(1.0, 0.88, tip_cover);
	}

	// Rim. Broken up by the coat so it reads as backlit hair rather than as a
	// stroke drawn round the animal.
	//
	// A receded layer keeps a rim, and that is a reversal. Taking it away was the
	// right instinct — a crisp bright edge is the strongest "nearest thing in
	// frame" cue there is — but taken to nearly zero it leaves the far limbs with
	// no edge at all, and a dark shape with no edge beside a lit one is read as
	// that shape's cast shadow, not as a limb. What separates them is not
	// brightness, it is *quality*: the far rim is narrower, because it is
	// unresolved, and colder, because the only light still reaching round there is
	// the sky. So the far limb keeps an edge and pays for it in hue instead.
	float rim = pet_rim(n) * ao;
	rim = pow(rim, mix(1.0, 1.55, ctx.atmos)) * (1.0 - ctx.atmos * 0.42);
	if (mat == MAT_FUR) { rim *= mix(0.45, 1.20, tip_cover + micro_occ * 0.30); }
	vec3 rim_c = mix(rim_color.rgb, ambient_tint.rgb * 1.9, ctx.atmos * 0.7);
	lit += rim_c * rim * (0.16 + 0.30 * translucency);

	// --- specular -----------------------------------------------------------
	float lit_face = clamp(ndl * 0.5 + 0.5, 0.0, 1.0);
	vec3 spec = vec3(0.0);
	// Kept out of `spec` deliberately; see the sheen block below.
	vec3 sheen_add = vec3(0.0);
	if (furry) {
		// Marschner R + TRT off the strand tangent. Fur has no single surface
		// normal, so the lobes hang off the groom direction — but the strand
		// lies *on* the surface, so the groom has to be projected into the
		// tangent plane first. Leaving it flat in screen space is what makes a
		// Kajiya-Kay lobe saturate over the whole body instead of forming the
		// band of sheen that runs along a real animal's back.
		// Every strand leans a little differently, and rotating the tangent by
		// that lean is what splits one broad sheen into hundreds of individual
		// fibre highlights. This is the coat's *visible* structure now: it is
		// specular, it lives at strand frequency, and unlike albedo noise it
		// disappears where the light does — which is exactly how hair behaves.
		float ct = cos(strand_tilt);
		float st = sin(strand_tilt);
		vec2 gs = vec2(groom_s.x * ct - groom_s.y * st,
			groom_s.x * st + groom_s.y * ct);
		vec3 g3 = vec3(gs, 0.0);
		vec3 tangent = normalize(g3 - n * dot(g3, n) + 1e-6);
		spec = pet_hair_spec(tangent, n, L, V, roughness, albedo, glint);

		// Coat sheen — the one specular term deliberately built out of a big
		// shape rather than out of strands.
		//
		// Everything above is per-fibre, so it is the first thing the downsample
		// destroys: at ship size the strand lobes average to a flat number and the
		// pelt comes out lit like felt. What a real coat still has at that size is
		// a broad anisotropic band along the top of the back and the top of the
		// tail, because every hair up there lies along the body and a cylinder
		// lying along the body reflects into a band, not a point. It is the same
		// Kajiya-Kay lobe, opened almost all the way up and hung on the *unjittered*
		// tangent — jitter it and it breaks back into fibres, which is exactly the
		// detail that does not survive.
		//
		// Gated to surfaces that face upward as well as dorsally, so the belly and
		// the inside of a leg stay matte: a sheen everywhere is a sheen nowhere,
		// and it is what makes cheap fur look like satin.
		//
		// Accumulated apart from `spec` because everything in `spec` is about to be
		// multiplied by the per-strand break-up, and running a low-frequency band
		// through a strand-frequency modulator does not give a broken-up band — it
		// gives the band *as* the strands, which lands on screen as long bright
		// filaments along the back. That is plank grain wearing a different hat.
		vec3 gflat = vec3(groom_s, 0.0);
		vec3 tan0 = normalize(gflat - n * dot(gflat, n) + 1e-6);
		float up = clamp(-n.y, 0.0, 1.0);
		float sheen = pet_strand_lobe(normalize(tan0 + n * 0.22), L, V, 1.05)
			* smoothstep(-0.05, 0.62, dv) * (0.34 + 0.66 * up);
		sheen_add = mix(vec3(1.0), albedo * 2.2, 0.45) * sheen * 0.26;
		if (mat == MAT_FEATHER) {
			// Thin-film on the vane: strongest at grazing angles, gone in the
			// gaps between barbs.
			float ang = clamp(dot(n, V), 0.0, 1.0);
			vec3 sheen = 0.5 + 0.5 * cos(PETALIA_TAU * (vec3(0.0, 0.33, 0.67) + ang * 2.6));
			spec += sheen * pow(1.0 - ang, 2.4) * irid * 0.55;
		}
	} else {
		float rough = mat == MAT_CLAW ? 0.16 : (mat == MAT_SCALE ? 0.26 : 0.42);
		rough = mix(rough, 0.09, wet_film);
		vec3 h = normalize(L + V);
		float a = max(rough * rough, 1e-3);
		float ndh = max(dot(n, h), 0.0);
		float dt = a * a / (PETALIA_TAU * 0.5 * pow(ndh * ndh * (a * a - 1.0) + 1.0, 2.0));
		float fr = 0.04 + 0.96 * pow(1.0 - max(dot(h, V), 0.0), 5.0);
		spec = vec3(dt * fr) * (mat == MAT_SKIN ? 0.55 : 1.1);
	}
	spec *= spec_mul * mix(1.0, 2.2, wet_film) * (1.0 - ctx.atmos * 0.70);
	spec += sheen_add * (1.0 - ctx.atmos * 0.70);
	// `key_occ`, not `ctx.shadow`: a specular is the key seen in a mirror, so
	// whatever occludes the key occludes it. Left on the raw shadow the underside
	// kept a full-strength anisotropic sheen while its diffuse was being taken
	// down to 0.44, and on this cat that lands as a blown-out white bar along the
	// belly capsule — the coat's own hair lobe running the length of a cylinder,
	// which is exactly what it is for, fired in the one place the light cannot
	// reach.
	lit += key_color.rgb * key_energy * spec * lit_face * key_occ * ao;

	// --- depth --------------------------------------------------------------
	// Atmospheric separation. A far leg is not "the same leg, darker": it loses
	// saturation and, crucially, *contrast* — haze lifts its shadows and pulls
	// its highlights down toward one flat value. Only darkening it produces a
	// black cut-out, and a black cut-out beside a lit limb reads as that limb's
	// shadow rather than as another limb. That is the failure this replaces.
	if (ctx.atmos > 0.002) {
		float lum = dot(lit, vec3(0.2126, 0.7152, 0.0722));
		lit = mix(lit, vec3(lum), ctx.atmos * 0.44);
		// The value the range collapses toward is what *this material* looks like
		// under a room's worth of fill, because that is physically what the far
		// side of an animal is: five centimetres of air does nothing, the key is
		// simply blocked and the sky and the floor still reach it. Pivoting on an
		// absolute haze colour is the obvious formulation and it is wrong twice
		// over — it is brighter than the limb, so compression pushes the limb *up*
		// past the background, and it is blue, so a brown limb arrives grey. A
		// pale blue smear behind a cat reads as fog. This reads as the same cat,
		// in shade.
		//
		// The multiplier is the load-bearing number in the whole depth pass: it is
		// the floor the far limb cannot fall below however many occlusion terms
		// have multiplied into it, and set too low it is the difference between a
		// leg and a smudge. It sits high deliberately, because a species has
		// usually *already* paid for the depth once by giving its far-side parts
		// the shadow pigment — the cat's are 0.62 of the near coat before the
		// shader touches them — and paying twice is how the far side went black.
		vec3 pivot = albedo * mix(ambient_tint.rgb, vec3(1.0), 0.45)
			* ambient_energy * 5.2;
		lit = mix(lit, pivot + (lit - pivot) * 0.58, ctx.atmos);
	}
	// After the haze, not before it: the crack where a near limb crosses the one
	// behind it is dark all the way to the viewer, so compressing it toward the
	// haze first is precisely what lets two overlapping legs fuse into one shape.
	lit *= ctx.contact;

	return vec4(lit, alpha);
}

void fragment() {
	vec2 p = mix(bounds_min, bounds_max, UV);
	float body_h = max(bounds_max.y - bounds_min.y, 1e-3);

	// All three layers up front: shading a layer needs to know what is in front
	// of it, and evaluating them in the composite loop would make that a second
	// pass over the part array.
	Field f0 = eval_layer(p, 0);
	Field f1 = eval_layer(p, 1);
	Field f2 = eval_layer(p, 2);

	vec2 lxy = pet_key_dir().xy;
	float reach = body_h * 0.085;

	// The far side of the animal. Everything here is deliberately overdriven
	// compared with a physical estimate, because the layers are only a few
	// centimetres apart in world terms and a physically honest separation at
	// that distance is invisible. The brief is that a viewer must be able to
	// count four legs without effort, and that costs: a hard cast shadow, a
	// hemisphere that the near body has bitten a chunk out of, a crevice line
	// where the two limbs overlap, a soft outline, and no resolvable coat.
	//
	// Every reach here is calibrated against how much of the far limb is
	// actually *visible*, which is a sliver twenty pixels wide beside the near
	// limb — not against how far apart the two limbs are in the world. A falloff
	// wider than the sliver puts the whole thing in the darkest part of the
	// curve, and a far leg crushed to black is no more countable than one that
	// melted into the torso. So the torso's occlusion is broad (it really does
	// shade everything under the belly) and the near limb's is tight: a crevice
	// line, then daylight.
	// The budget below is set by arithmetic rather than by feel, because every one
	// of these terms multiplies and it is very easy to stack four reasonable-
	// looking numbers into a black cut-out. A far limb that reads is roughly half
	// the value of the near one — dark enough to be behind it, light enough to
	// still be a limb — so the shadow, the two occlusion terms and the crevice
	// together may not take more than about a third of the light away, and the
	// haze pivot then puts a floor under whatever is left. What buys the depth is
	// the *desaturation* and the loss of contrast, which cost no value at all.
	LayerCtx c0;
	c0.shadow = min(layer_shadow(f1, lxy, reach * 1.8, 0.30),
		layer_shadow(f2, lxy, reach * 1.2, 0.24));
	c0.ao = layer_occlude(f1, body_h * 0.22, 0.22)
		* layer_occlude(f2, body_h * 0.055, 0.16);
	// The crevice is the one term allowed to go properly dark, and it is kept
	// narrow on purpose: a hard line where the two limbs cross is what separates
	// them, and a wide one just paints the far limb out.
	c0.contact = layer_contact(f2, body_h * 0.015, 0.44)
		* layer_contact(f1, body_h * 0.014, 0.26);
	c0.atmos = 0.85;
	// The far limb is only a sliver a dozen pixels wide beside the near one, so
	// the defocus has to stay narrow enough to leave that sliver a shape. Past
	// about two pixels of feather there is no silhouette left to soften.
	c0.soften = 2.0;
	// The far side gets a real coat, at reduced contrast, rather than a flat
	// tint. Held at 0.30 the fur terms were effectively switched off back there,
	// and a limb with no coat, no fringe and no rim is not a limb — it is a
	// painted shadow, which is what the review reported. The argument for
	// switching them off was that a strand cannot be resolved on the far side of
	// an animal, and it is a good argument about *strands*; it is the wrong
	// argument about whether the surface is made of hair at all. Two thirds of
	// the near coat is enough to say "hair" and not enough to compete with it.
	c0.detail = 0.66;
	c0.body_h = body_h;

	LayerCtx c1;
	c1.shadow = layer_shadow(f2, lxy, reach, 0.42);
	c1.ao = layer_contact(f2, reach * 1.3, 0.32)
		* layer_occlude(f2, body_h * 0.16, 0.22);
	c1.contact = layer_contact(f2, body_h * 0.028, 0.26);
	c1.atmos = 0.12;
	c1.soften = 1.0;
	c1.detail = 1.0;
	c1.body_h = body_h;

	LayerCtx c2;
	c2.shadow = 1.0;
	c2.ao = 1.0;
	c2.contact = 1.0;
	c2.atmos = 0.0;
	c2.soften = 0.95;
	c2.detail = 1.0;
	c2.body_h = body_h;

	// Back to front so a far leg is occluded by the torso.
	vec4 acc = vec4(0.0);
	vec3 dbg = vec3(0.0);
	vec3 d0, d1, d2;
	vec4 l0 = shade_layer(f0, p, c0, d0);
	acc.rgb = mix(acc.rgb, l0.rgb, l0.a);
	acc.a = acc.a + l0.a * (1.0 - acc.a);
	dbg = mix(dbg, d0, l0.a);
	vec4 l1 = shade_layer(f1, p, c1, d1);
	acc.rgb = mix(acc.rgb, l1.rgb, l1.a);
	acc.a = acc.a + l1.a * (1.0 - acc.a);
	dbg = mix(dbg, d1, l1.a);
	vec4 l2 = shade_layer(f2, p, c2, d2);
	acc.rgb = mix(acc.rgb, l2.rgb, l2.a);
	acc.a = acc.a + l2.a * (1.0 - acc.a);
	dbg = mix(dbg, d2, l2.a);
	// The diagnostic channel replaces the lit colour here, before the eye and
	// whisker passes draw over it and before the tonemap bends it. Written as a
	// select rather than an early `return`, which Godot's shader compiler rejects
	// in `fragment`.
	if (debug_view != 0) { acc.rgb = dbg; }

	// Centre of the pair, so each eye can be told how far off it sits. That
	// offset is what puts the two catchlights in different places; see
	// `pet_shade_eye`.
	vec2 eye_mid = vec2(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= eye_count) { break; }
		eye_mid += eyes[i * 4 + 0].xy;
	}
	eye_mid /= float(max(eye_count, 1));

	float unit_px = 1.0 / max(px_per_unit, 1.0);
	for (int i = 0; i < 4; i++) {
		if (i >= eye_count) { break; }
		vec4 e0 = eyes[i * 4 + 0];
		vec4 e = pet_shade_eye(e0, eyes[i * 4 + 1], eyes[i * 4 + 2],
			eyes[i * 4 + 3], p, unit_px,
			(e0.xy - eye_mid) / max(e0.z, 1e-4));
		acc.rgb = mix(acc.rgb, e.rgb, e.a);
		acc.a = acc.a + e.a * (1.0 - acc.a);
	}

	// Whiskers last, over the eyes as well as the coat: they physically pass in
	// front of the face, and a whisker that stops at the eyelid is a decal.
	//
	// Bright against the body and barely there against the background, because a
	// whisker is a highlight rather than a hair whose pigment you can see. It
	// borrows the key's colour and most of its opacity from whatever it is lying
	// over, which is also what keeps eight of them from stamping a white asterisk
	// across the desktop behind the pet.
	float wh = pet_whiskers(p, whisker_pad, unit_px);
	if (wh > 0.002) {
		vec3 wc = key_color.rgb * key_energy * 1.10 + ambient_tint.rgb * 0.22;
		float wa = wh * mix(0.34, 0.78, acc.a);
		acc.rgb = mix(acc.rgb, wc, wa);
		acc.a = acc.a + wa * (1.0 - acc.a);
	}

	if (acc.a <= 0.002) { discard; }

	vec3 col = acc.rgb * exposure;
	if (debug_view == 0) {
		if (!defer_tonemap) { col = pet_tonemap(col); }
		col += pet_dither(FRAGCOORD.xy);
	}

	COLOR = vec4(col, acc.a);
}
