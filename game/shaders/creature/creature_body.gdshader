shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — implicit creature body.
//
// The whole animal is resolved here from a list of tapered capsules. There is
// no mesh, no sprite sheet and no normal map. Per pixel we:
//
//   1. smooth-union the capsules into a signed distance field,
//   2. lift that field into a height field (an exact capsule cross-section),
//   3. differentiate the height field analytically for a true surface normal,
//   4. shade it with a three-point rig plus a coat model chosen per part,
//   5. composite three depth layers so far limbs sit behind the torso.
//
// Doing it implicitly is what buys the AAA read: silhouettes are resolution
// independent, the coat fringe is real geometry rather than a painted edge,
// and creases between body parts occlude themselves for free.

#include "res://shaders/creature/noise.gdshaderinc"

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

uniform vec3 light_dir = vec3(-0.42, -0.62, 0.66);
uniform vec4 ambient_tint : source_color = vec4(0.62, 0.68, 0.82, 1.0);
uniform vec4 bounce_tint : source_color = vec4(0.30, 0.28, 0.26, 1.0);
uniform float exposure : hint_range(0.1, 4.0) = 1.0;

const int MAT_FUR = 0;
const int MAT_FEATHER = 1;
const int MAT_SCALE = 2;
const int MAT_SKIN = 3;
const int MAT_CLAW = 4;
const int MAT_EYE = 5;

// ---------------------------------------------------------------------------
// Field evaluation
// ---------------------------------------------------------------------------

// Tapered capsule. Also reports the unit gradient, which we need for both the
// height-field derivative and the coat grooming frame.
float sd_capsule(vec2 p, vec2 a, vec2 b, float ra, float rb, out vec2 grad, out float radius) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-7), 0.0, 1.0);
	vec2 d = pa - ba * t;
	float len = length(d);
	radius = mix(ra, rb, t);
	grad = len > 1e-5 ? d / len : vec2(0.0, -1.0);
	return len - radius;
}

// Quadratic smooth minimum. `h` is returned so callers can blend the two
// surfaces' materials with exactly the same weight that blended their distance,
// which is what stops a colour seam appearing along every joint.
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
	float crease;   // how much smoothing happened here → self-occlusion
	float mat;      // dominant material id
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
	f.crease = 0.0;
	f.mat = float(coat_surface);
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
		float d = sd_capsule(p, g0.xy, g0.zw, g1.x, g1.y, grad, radius);

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
			f.mat = g2.x - float(layer) * 16.0;
			f.hit = true;
			continue;
		}

		float h;
		float hard = min(f.d, d);
		float sd = smin_h(f.d, d, g1.z, h);
		// The gap between the hard union and the smooth union is exactly the
		// volume the blend added — i.e. the crease. Accumulate it as ambient
		// occlusion so armpits, ear roots and toe webbing darken naturally.
		f.crease += max(0.0, hard - sd);

		f.d = sd;
		f.radius = mix(f.radius, radius, h);
		f.grad = normalize(mix(f.grad, grad, h) + 1e-6);
		f.albedo = mix(f.albedo, col, h);
		f.groom = normalize(mix(f.groom, groom, h) + 1e-6);
		f.coat_len = mix(f.coat_len, g2.w, h);
		f.height_scale = mix(f.height_scale, g1.w, h);
		if (h > 0.5) { f.mat = g2.x - float(layer) * 16.0; }
	}
	return f;
}

// ---------------------------------------------------------------------------
// Coat models
// ---------------------------------------------------------------------------

// Kajiya-Kay anisotropic strand highlight. Fur has no single surface normal, so
// the specular lobe is defined by the strand tangent instead: this is the
// difference between "plush animal" and "shiny plastic toy".
float strand_spec(vec3 tangent, vec3 l, vec3 v, float rough) {
	float tl = dot(tangent, l);
	float tv = dot(tangent, v);
	float s = sqrt(max(0.0, 1.0 - tl * tl)) * sqrt(max(0.0, 1.0 - tv * tv)) - tl * tv;
	return pow(clamp(s, 0.0, 1.0), max(1.0, 2.0 / max(rough * rough, 1e-3)));
}

float ggx(vec3 n, vec3 l, vec3 v, float rough) {
	vec3 h = normalize(l + v);
	float a = max(rough * rough, 1e-3);
	float ndh = max(dot(n, h), 0.0);
	float d = a * a / (PETALIA_TAU * 0.5 * pow(ndh * ndh * (a * a - 1.0) + 1.0, 2.0));
	float ndl = max(dot(n, l), 0.0);
	float ndv = max(dot(n, v), 0.0);
	float k = a * 0.5;
	float g = (ndl / (ndl * (1.0 - k) + k)) * (ndv / (ndv * (1.0 - k) + k));
	float f = 0.04 + 0.96 * pow(1.0 - max(dot(h, v), 0.0), 5.0);
	return d * g * f;
}

// ---------------------------------------------------------------------------
// Shading
// ---------------------------------------------------------------------------

vec4 shade_layer(Field f, vec2 p, float layer_depth, vec2 frag) {
	if (!f.hit) { return vec4(0.0); }

	int mat = int(f.mat + 0.5);
	float unit_px = 1.0 / max(px_per_unit, 1.0);

	// --- coat silhouette ----------------------------------------------------
	// Displacing the distance field by a strand-shaped noise gives the outline
	// real fringe. It is applied only in a band around the surface so the
	// interior field stays smooth for the height lift.
	float coat = f.coat_len * fluff * (1.0 + 0.35 * (3.0 - growth) / 3.0);
	float fringe = 0.0;
	if (mat == MAT_FUR || mat == MAT_FEATHER) {
		float band = smoothstep(coat * 2.5, 0.0, abs(f.d));
		float s = pet_strands(p * (60.0 * coat_density), f.groom, 1.0, 3.2);
		float clump = pet_fbm(p * (14.0 * coat_density), 3);
		fringe = coat * (0.55 * s + 0.45 * clump) * band * (1.0 - wetness * 0.8);
	}
	float d = f.d - fringe;

	// --- coverage -----------------------------------------------------------
	// One-pixel-wide analytic antialias. `fwidth` on the field would be ideal
	// but the fringe term makes it noisy, so we use the known pixel scale.
	float aa = unit_px * 0.9;
	float alpha = smoothstep(aa, -aa, d);
	if (alpha <= 0.001) { return vec4(0.0); }

	// --- height field and normal -------------------------------------------
	// For a capsule cross-section the exact height is R*sqrt(1-u^2) where u
	// walks 0 (spine) → 1 (silhouette). Differentiating analytically avoids the
	// stair-stepping that screen-space derivatives produce on curved bodies.
	float R = max(f.radius, 1e-4);
	float u = clamp(1.0 + f.d / R, 0.0, 1.0);
	float su = sqrt(max(1.0 - u * u, 1e-6));
	float slope = -f.height_scale * u / su;
	vec3 n = normalize(vec3(-slope * f.grad.x, -slope * f.grad.y, 1.0));

	// Coat perturbs the normal at a much finer scale than the body does.
	if (mat == MAT_FUR) {
		vec2 t = vec2(dot(p, f.groom), dot(p, vec2(-f.groom.y, f.groom.x)));
		float e = 0.9 * unit_px;
		float c = pet_strands(p * 90.0 * coat_density, f.groom, 1.0, 4.0);
		float cx = pet_strands((p + vec2(e, 0.0)) * 90.0 * coat_density, f.groom, 1.0, 4.0);
		float cy = pet_strands((p + vec2(0.0, e)) * 90.0 * coat_density, f.groom, 1.0, 4.0);
		float amp = 0.55 * fluff * (1.0 - wetness * 0.7);
		n = normalize(n + vec3((c - cx) / e, (c - cy) / e, 0.0) * amp * 0.004);
	} else if (mat == MAT_SCALE) {
		// Cellular tiling lifted into little domed plates.
		vec2 sp = p * (26.0 * coat_density);
		vec2 w = pet_worley(sp);
		float edge = smoothstep(0.0, 0.14, w.y - w.x);
		float e = 1.0 / (26.0 * coat_density) * 0.5;
		vec2 wx = pet_worley(sp + vec2(e, 0.0) * 26.0 * coat_density);
		vec2 wy = pet_worley(sp + vec2(0.0, e) * 26.0 * coat_density);
		float h0 = smoothstep(0.0, 0.14, w.y - w.x);
		float hx = smoothstep(0.0, 0.14, wx.y - wx.x);
		float hy = smoothstep(0.0, 0.14, wy.y - wy.x);
		n = normalize(n + vec3((h0 - hx), (h0 - hy), 0.0) * 1.9);
		f.albedo *= mix(0.74, 1.06, edge);
	} else if (mat == MAT_FEATHER) {
		// Barbs run out from a central rachis at a slight angle.
		vec2 axis = f.groom;
		vec2 t = vec2(dot(p, axis), dot(p, vec2(-axis.y, axis.x)));
		float barb = sin((t.y * 210.0 + t.x * 40.0) * coat_density);
		float vane = smoothstep(-0.2, 0.9, barb);
		n = normalize(n + vec3(axis.y, -axis.x, 0.0) * (vane - 0.5) * 0.22);
		f.albedo *= mix(0.9, 1.05, vane);
	} else if (mat == MAT_SKIN) {
		float pore = pet_fbm(p * 260.0, 2);
		n = normalize(n + vec3(pore, pore * 0.7, 0.0) * 0.05);
	}

	// --- albedo variation ---------------------------------------------------
	// Real coats are never one colour. A low-frequency melanin field plus a
	// touch of high frequency stops the body reading as vector art.
	float melanin = pet_fbm(p * 3.1, 4) * 0.5 + 0.5;
	vec3 albedo = f.albedo * mix(0.86, 1.12, melanin);
	albedo *= mix(1.0, 0.62, wetness);
	// Blood flush on thin, well-lit extremities when the pet is excited.
	float thin = 1.0 - smoothstep(0.02, 0.16, R);
	albedo = mix(albedo, albedo * vec3(1.35, 0.72, 0.70), emotion_flush * thin * 0.7);

	// --- lighting rig -------------------------------------------------------
	vec3 L = normalize(light_dir);
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec3 fill_dir = normalize(vec3(0.55, -0.15, 0.55));
	vec3 rim_dir = normalize(vec3(0.25, 0.72, -0.55));

	float ndl = dot(n, L);
	// Wrapped diffuse. Fur and skin both scatter, so the terminator should be
	// soft and warm rather than a hard Lambert edge.
	float wrap = 0.45 + 0.35 * translucency;
	float diff = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
	diff *= diff;

	// Self-occlusion from creases, plus a general cavity term from how deep the
	// pixel sits inside the body.
	float crease_ao = 1.0 / (1.0 + f.crease * 26.0);
	float depth_ao = mix(0.78, 1.0, smoothstep(0.0, 0.6, u));
	float ao = crease_ao * mix(1.0, depth_ao, 0.65);

	// Transmission: thin parts (ears, wings, webbing, tail tips) glow when lit
	// from behind. This single term does more for "expensive" than anything
	// else in the shader.
	float thickness = clamp(R * f.height_scale * 6.0, 0.05, 1.0);
	float back = clamp(-ndl, 0.0, 1.0);
	float trans = translucency * pow(back, 1.6) * (1.0 - thickness) * 1.9;
	vec3 trans_col = vec3(1.0, 0.42, 0.32) * trans;

	// Rim / kicker along the silhouette.
	float fres = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.0);
	float rim = fres * clamp(dot(n, rim_dir) * 0.5 + 0.5, 0.0, 1.0);

	vec3 lit = albedo * diff * ao;
	lit += albedo * ambient_tint.rgb * (0.28 * ao);
	lit += albedo * bounce_tint.rgb * clamp(-n.y * 0.5 + 0.5, 0.0, 1.0) * 0.22;
	lit += trans_col * albedo;
	lit += vec3(0.95, 0.97, 1.0) * rim * (0.42 + 0.5 * translucency);

	// --- specular -----------------------------------------------------------
	float rough = roughness;
	vec3 spec = vec3(0.0);
	if (mat == MAT_FUR || mat == MAT_FEATHER) {
		vec3 tangent = normalize(vec3(f.groom, 0.28));
		float s1 = strand_spec(tangent, L, V, rough);
		float s2 = strand_spec(tangent, L, V, rough * 0.45);
		// Two lobes: a broad sheen tinted by the coat, and a tight white
		// secondary highlight — the classic Marschner split.
		spec += albedo * s1 * 0.35 + vec3(1.0) * s2 * 0.22;
		if (mat == MAT_FEATHER) {
			// Thin-film iridescence on the vane, strongest at grazing angles.
			float ang = clamp(dot(n, V), 0.0, 1.0);
			vec3 irid = 0.5 + 0.5 * cos(PETALIA_TAU * (vec3(0.0, 0.33, 0.67) + ang * 2.6));
			spec += irid * fres * 0.35;
		}
	} else {
		float r = mat == MAT_CLAW ? 0.18 : (mat == MAT_SCALE ? 0.3 : 0.55);
		spec += vec3(1.0) * ggx(n, L, V, r) * (mat == MAT_SKIN ? 0.6 : 1.2);
	}
	spec *= mix(1.0, 2.4, wetness);
	lit += spec * max(ndl * 0.5 + 0.5, 0.0);

	// A wet coat both darkens and gains a broad sheen.
	if (wetness > 0.001) {
		lit += vec3(1.0) * ggx(n, L, V, 0.12) * wetness * 1.6;
	}

	// Far layers sit in the body's own shadow.
	lit *= layer_depth;

	return vec4(lit, alpha);
}

// ---------------------------------------------------------------------------

void fragment() {
	vec2 p = mix(bounds_min, bounds_max, UV);
	vec2 frag = FRAGCOORD.xy;

	// Back-to-front so a far leg is occluded by the torso.
	vec4 acc = vec4(0.0);
	for (int layer = 0; layer < LAYERS; layer++) {
		Field f = eval_layer(p, layer);
		float depth_shade = layer == 0 ? 0.58 : (layer == 1 ? 1.0 : 1.06);
		vec4 c = shade_layer(f, p, depth_shade, frag);
		// Standard source-over, straight alpha.
		acc.rgb = mix(acc.rgb, c.rgb, c.a);
		acc.a = acc.a + c.a * (1.0 - acc.a);
	}

	if (acc.a <= 0.002) { discard; }

	vec3 col = acc.rgb * exposure;
	// Filmic-ish shoulder so hot rim light rolls off instead of clipping flat.
	col = (col * (2.51 * col + 0.03)) / (col * (2.43 * col + 0.59) + 0.14);
	col += pet_dither(frag);

	COLOR = vec4(col, acc.a);
}
