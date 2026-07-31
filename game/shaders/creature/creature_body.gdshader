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

// Set when the post stack is live: it owns the filmic curve instead, so the
// creature is not tonemapped twice.
uniform bool defer_tonemap = false;

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

		vec3 col = palette[int(g2.y)].rgb;
		float ga = g2.z;
		vec2 groom = vec2(cos(ga), sin(ga));

		if (!f.hit) {
			f.d = d;
			f.radius = radius;
			f.grad = grad;
			f.albedo = col;
			f.groom = groom;
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
		f.radius = mix(radius, f.radius, h);
		f.grad = normalize(mix(grad, f.grad, h) + 1e-6);
		f.albedo = mix(col, f.albedo, h);
		f.groom = normalize(mix(groom, f.groom, h) + 1e-6);
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
		float engulf = smoothstep(0.15 * radius, 0.6 * radius, d - prev_d);
		float distinct = smoothstep(0.06, 0.20, length(col - f.albedo));
		float paint = smoothstep(g1.z + 1e-4, -g1.z - 1e-4, d) * engulf * distinct;
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

vec4 shade_layer(Field f, vec2 p, LayerCtx ctx) {
	if (!f.hit) { return vec4(0.0); }

	int mat = int(f.mat + 0.5);
	float unit_px = 1.0 / max(px_per_unit, 1.0);
	bool furry = mat == MAT_FUR || mat == MAT_FEATHER;

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
		float spikes = pet_fur_fringe(p, f.grad, f.groom, coat_density,
			px_per_unit, ctx.detail, cover);
		float band = smoothstep(-coat * 3.0, coat * 0.2, f.d);
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
	float R = max(f.radius, 1e-4);
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
		float small = 1.0 - smoothstep(0.026, 0.048, f.decal_r / ctx.body_h);
		float ud = clamp(1.0 + f.decal_d / max(f.decal_r, 1e-4), 0.0, 1.0);
		float sud = sqrt(max(1.0 - ud * ud, 0.0));
		nxy += f.decal_grad * (0.36 * ud / max(sud, 0.46)) * f.decal_w * small;
	}

	// --- groom field --------------------------------------------------------
	// Fur has to curve, and there are two ways to get that wrong. Leaving it
	// dead parallel reads as brushed metal. Rotating the strand frame per pixel
	// looks like the obvious fix and is worse: the lane coordinate stops being
	// integrable, so lanes close into concentric loops and the coat turns into
	// wood grain. Displacing the *sample point* through a smooth vector field
	// with the frame held fixed bends the lanes and can never form a loop.
	//
	// The frequencies matter as much as the trick. A large displacement at a low
	// frequency bends every lane the same way at once, and smoothly wavy parallel
	// lines are the definition of wood grain. Three small octaves, the finest at
	// strand scale, make lanes wander apart from their neighbours instead.
	vec2 pw = p;
	if (furry) {
		pw += vec2(pet_noise(p * 3.6 + 11.0), pet_noise(p * 3.6 + 43.0)) * 0.024
			+ vec2(pet_noise(p * 11.0 + 3.0), pet_noise(p * 11.0 + 71.0)) * 0.009
			+ vec2(pet_noise(p * 34.0 + 5.0), pet_noise(p * 34.0 + 17.0)) * 0.0026;
	}
	// The shading tangent does follow the surface, though: a strand lies on the
	// body, so it sweeps around the barrel as the surface turns away from us.
	// That sweep is what turns a flat sheen into a band running along the back.
	vec2 groom = f.groom;
	vec2 tang = vec2(-f.grad.y, f.grad.x);
	if (dot(tang, groom) < 0.0) { tang = -tang; }
	vec2 groom_s = normalize(mix(groom, tang, u * u * 0.45) + 1e-6);

	// Local frame across the part's spine, used by every non-fur family so their
	// detail wraps the body instead of being stamped in screen space.
	vec2 across = vec2(-groom.y, groom.x);
	float arc = dot(p, groom);
	float side = dot(f.grad, across) >= 0.0 ? 1.0 : -1.0;
	float v = (f.d + R) * side;
	// Dorsal-to-ventral coordinate: +1 at the top line of the part, 0 across the
	// middle of the flank where the surface faces the viewer, -1 at the belly
	// line. It falls out of the capsule frame for free and it is what lets a
	// marking or a landmark be told to keep to the back and off the underside.
	float dv = clamp(v / R, -1.0, 1.0);

	// --- skeleton -----------------------------------------------------------
	// A cat's back is not a tube. The blade of the scapula stands proud where the
	// foreleg swings under it, the point of the hip sits above the femur head,
	// the loin muscles roll either side of the spine and the last ribs show on
	// the lower flank. Those are most of what makes light read as falling on an
	// animal rather than on a sausage, and none of them can be a capsule: the cat
	// is at 28 parts of 28. So they are relief, added to the same height-field
	// slope everything else in this shader uses.
	//
	// `bulk` keeps them on the body masses. The identical field stamped onto a
	// leg or an ear is a dent in a tube, and the gate is a ratio against body
	// height so it means the same thing for a kitten and an adult.
	float bulk = smoothstep(0.055, 0.100, R / ctx.body_h);
	float skel = 0.0;
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

	if (mat == MAT_FUR) {
		Coat c = pet_fur(pw, groom, coat_density, px_per_unit,
			fluff * (1.0 - wetness * 0.7));
		nxy += c.slope * ctx.detail;
		micro_occ = mix(1.0, c.occ, ctx.detail);
		// A twentieth of what it used to be. Everything the coat used to say
		// through albedo it now says through the specular break-up below —
		// pigment noise at this scale is what made the body read as damp clay.
		micro_tint = c.tint * 0.085 * ctx.detail;
		spec_mul = mix(1.0, c.spec, ctx.detail);
		strand_tilt = c.tilt * ctx.detail;
		glint = c.glint;
	} else if (mat == MAT_FEATHER) {
		Surf s = pet_feather(arc, v, u, coat_density, px_per_unit);
		nxy += s.slope.x * across;
		micro_occ = s.occ;
		micro_tint = s.tint * 0.18;
		spec_mul = s.spec;
		irid = s.extra;
	} else if (mat == MAT_SCALE) {
		Surf s = pet_scale(arc, v, nxy, coat_density, px_per_unit);
		nxy += s.slope.x * across + s.slope.y * f.grad;
		micro_occ = s.occ;
		micro_tint = s.tint;
		spec_mul = s.spec;
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

	// --- albedo -------------------------------------------------------------
	vec3 albedo = f.albedo;
	if (furry) {
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
		float takes = smoothstep(0.88, 0.60, lum) * marking_strength;
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
			float bars = sin(arc * 33.0 + wob * 1.4 + dv * 1.1);
			float broken = pet_fbm(p * 2.1 + 19.0, 2);
			// A bar is about a third of the period wide, not a tenth: narrow the
			// dark core any further and the stripes stop being stripes and turn
			// into a pinstripe nobody reads as a cat. The *edge* is the part that
			// has to stay tight, though. Ramped over half the sine's range the
			// bar has no edge at all, only a gradient, and a set of soft gradients
			// at stripe spacing is not a tabby — it is the blotchy smear the coat
			// pass just spent its whole budget getting rid of.
			float bar = smoothstep(0.06, 0.34, bars)
				* mix(0.40, 1.0, smoothstep(-0.50, -0.05, broken));
			// The dorsal line is solid, and the pigment fades out under the
			// animal: a tabby's belly is always the palest part of it.
			float dorsal = smoothstep(0.58, 0.94, dv);
			float flank = smoothstep(-0.55, 0.05, dv);
			float mark = clamp(max(bar * flank, dorsal * 0.92), 0.0, 1.0);
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
	float ao = crease_ao * curve_ao * micro_occ * ctx.ao;

	// Height above the ground plane, normalised by body height so the falloffs
	// below mean the same thing for a kitten and for an adult.
	float height01 = clamp(-p.y / ctx.body_h, 0.0, 1.5);
	// The floor and the body between them close off the hemisphere under the
	// belly and around the paws, so both ambient terms fall away near contact.
	float down = clamp(0.5 + 0.5 * n.y, 0.0, 1.0);
	float ground_ao = mix(1.0, mix(0.34, 1.0, smoothstep(0.0, 0.26, height01)),
		0.28 + 0.72 * down);

	// --- lighting -----------------------------------------------------------
	vec3 L = pet_key_dir();
	vec3 V = vec3(0.0, 0.0, 1.0);
	float ndl = dot(n, L);

	float wrap = 0.26 + 0.44 * translucency;
	vec3 lit = albedo * pet_key(n, ctx.shadow, wrap) * ao;
	// Warm scatter through the coat at the terminator.
	lit += albedo * vec3(1.55, 0.62, 0.45) * pet_terminator_band(n)
		* translucency * 0.30 * ctx.shadow * ao;
	lit += albedo * pet_sky(n, ao * ground_ao);
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
	// stroke drawn round the animal. A receded layer gets almost none of it: a
	// crisp bright edge is the strongest "this is the nearest thing in frame"
	// cue there is, and putting one on a far leg undoes the whole depth pass.
	float rim = pet_rim(n) * ao * (1.0 - ctx.atmos * 0.80);
	if (mat == MAT_FUR) { rim *= mix(0.45, 1.20, tip_cover + micro_occ * 0.30); }
	lit += rim_color.rgb * rim * (0.16 + 0.30 * translucency);

	// --- specular -----------------------------------------------------------
	float lit_face = clamp(ndl * 0.5 + 0.5, 0.0, 1.0);
	vec3 spec = vec3(0.0);
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
	lit += key_color.rgb * key_energy * spec * lit_face * ctx.shadow * ao;

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
	c0.detail = 0.30;
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
	vec4 l0 = shade_layer(f0, p, c0);
	acc.rgb = mix(acc.rgb, l0.rgb, l0.a);
	acc.a = acc.a + l0.a * (1.0 - acc.a);
	vec4 l1 = shade_layer(f1, p, c1);
	acc.rgb = mix(acc.rgb, l1.rgb, l1.a);
	acc.a = acc.a + l1.a * (1.0 - acc.a);
	vec4 l2 = shade_layer(f2, p, c2);
	acc.rgb = mix(acc.rgb, l2.rgb, l2.a);
	acc.a = acc.a + l2.a * (1.0 - acc.a);

	for (int i = 0; i < 4; i++) {
		if (i >= eye_count) { break; }
		vec4 e = pet_shade_eye(eyes[i * 4 + 0], eyes[i * 4 + 1], eyes[i * 4 + 2],
			eyes[i * 4 + 3], p, 1.0 / max(px_per_unit, 1.0));
		acc.rgb = mix(acc.rgb, e.rgb, e.a);
		acc.a = acc.a + e.a * (1.0 - acc.a);
	}

	if (acc.a <= 0.002) { discard; }

	vec3 col = acc.rgb * exposure;
	if (!defer_tonemap) { col = pet_tonemap(col); }
	col += pet_dither(FRAGCOORD.xy);

	COLOR = vec4(col, acc.a);
}
