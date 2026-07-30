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

// ---------------------------------------------------------------------------
// Shading
// ---------------------------------------------------------------------------

struct LayerCtx {
	float shadow;   // directional shadow cast by nearer layers
	float ao;       // ambient occlusion from nearer layers
	float atmos;    // 0 = up front, 1 = fully receded
	float soften;   // antialias width multiplier, for depth softening
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
		float spikes = pet_fur_fringe(p, f.grad, f.groom, coat_density,
			px_per_unit, cover);
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
	if (f.decal_w > 0.01) {
		float ud = clamp(1.0 + f.decal_d / max(f.decal_r, 1e-4), 0.0, 1.0);
		float sud = sqrt(max(1.0 - ud * ud, 0.0));
		nxy += f.decal_grad * (0.40 * ud / max(sud, 0.42)) * f.decal_w;
	}

	// --- groom field --------------------------------------------------------
	// Fur has to curve, and there are two ways to get that wrong. Leaving it
	// dead parallel reads as brushed metal. Rotating the strand frame per pixel
	// looks like the obvious fix and is worse: the lane coordinate stops being
	// integrable, so lanes close into concentric loops and the coat turns into
	// wood grain. Displacing the *sample point* through a smooth vector field
	// with the frame held fixed bends the lanes and can never form a loop.
	vec2 pw = p;
	if (furry) {
		pw += vec2(pet_noise(p * 2.4 + 11.0), pet_noise(p * 2.4 + 43.0)) * 0.055
			+ vec2(pet_noise(p * 7.5 + 3.0), pet_noise(p * 7.5 + 71.0)) * 0.016;
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

	float micro_occ = 1.0;
	float micro_tint = 0.0;
	float spec_mul = 1.0;
	float glint = 0.0;
	float irid = 0.0;
	float piping = 0.0;
	float wet_film = wetness;

	if (mat == MAT_FUR) {
		Coat c = pet_fur(pw, groom, coat_density, px_per_unit,
			fluff * (1.0 - wetness * 0.7));
		nxy += c.slope;
		micro_occ = c.occ;
		micro_tint = c.tint * 0.16;
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

	vec3 n = normalize(vec3(nxy, 1.0));

	// --- albedo -------------------------------------------------------------
	vec3 albedo = f.albedo;
	// Agouti banding: pigment in a mammal coat is laid down in bands along each
	// hair, and the bands line up into the soft vertical ticking every tabby,
	// brindle and wild-type coat has. It is the difference between a coloured
	// shape and an animal. Pale parts (muzzle, belly, chin) keep out of it.
	if (furry) {
		// Agouti ticking. Pigment is laid down in bands across the body, and in
		// most wild-type coats those bands line up into soft mackerel stripes.
		// It only ever darkens — pigment adds, it does not bleach — and it keeps
		// off the pale markings, because a dirty muzzle reads as a mistake.
		float wobble = pet_fbm(p * 2.6, 3);
		float bands = sin(arc * 26.0 + wobble * 4.2);
		float tick = smoothstep(0.05, 0.9, bands) * (0.55 + 0.45 * (wobble * 0.5 + 0.5));
		float lum = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
		albedo *= 1.0 - tick * 0.24 * smoothstep(0.80, 0.38, lum);
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
	// stroke drawn round the animal.
	float rim = pet_rim(n) * ao;
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
		vec3 g3 = vec3(groom_s, 0.0);
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
	spec *= spec_mul * mix(1.0, 2.2, wet_film);
	lit += key_color.rgb * key_energy * spec * lit_face * ctx.shadow * ao;

	// --- depth --------------------------------------------------------------
	// Atmospheric separation. A far leg is not "the same leg, darker": it loses
	// saturation and, crucially, *contrast* — haze lifts its shadows and pulls
	// its highlights down. Only darkening it produces a black cut-out, which is
	// the failure this replaces.
	if (ctx.atmos > 0.002) {
		float lum = dot(lit, vec3(0.2126, 0.7152, 0.0722));
		lit = mix(lit, vec3(lum), ctx.atmos * 0.22);
		// The haze is only part-way to the sky colour: mixing all the way there
		// turns a brown animal grey-blue, which reads as fog rather than as a
		// few centimetres of depth.
		vec3 haze = mix(ambient_tint.rgb, vec3(1.0), 0.35) * ambient_energy * 1.7;
		lit = mix(lit, haze, ctx.atmos * 0.28);
		lit *= mix(1.0, 0.88, ctx.atmos);
	}

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

	LayerCtx c0;
	c0.shadow = min(layer_shadow(f1, lxy, reach, 0.40),
		layer_shadow(f2, lxy, reach, 0.26));
	c0.ao = min(layer_contact(f1, reach * 1.6, 0.40),
		layer_contact(f2, reach * 1.6, 0.26));
	c0.atmos = 0.80;
	c0.soften = 1.5;
	c0.body_h = body_h;

	LayerCtx c1;
	c1.shadow = layer_shadow(f2, lxy, reach, 0.42);
	c1.ao = layer_contact(f2, reach * 1.3, 0.32);
	c1.atmos = 0.14;
	c1.soften = 1.0;
	c1.body_h = body_h;

	LayerCtx c2;
	c2.shadow = 1.0;
	c2.ao = 1.0;
	c2.atmos = 0.0;
	c2.soften = 0.95;
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
