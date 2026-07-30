shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — a single loose hair.
//
// The detail that sells a stroke is not the dust, it is the two or three hairs
// that come away with the hand. They have to be *hairs*: tapered at both ends,
// bent, and carrying one sharp anisotropic highlight down their length, because
// that highlight is the only reason a strand a pixel wide is visible at all.
//
// Drawn as three tapered capsules along a sine spine. Three is the smallest
// number that reads as a curve rather than as a bent stick.

#include "res://vfx/vfx_common.gdshaderinc"

uniform vec4 hair_color : source_color = vec4(0.42, 0.34, 0.28, 1.0);
uniform vec4 sheen_color : source_color = vec4(1.0, 0.94, 0.84, 1.0);
uniform vec2 key_dir = vec2(-0.55, -0.83);
/// Half-length of the strand in quad units.
uniform float length_frac : hint_range(0.2, 1.0) = 0.82;
/// Peak half-thickness. Kept small; a fat hair reads as a twig.
uniform float thickness : hint_range(0.01, 0.12) = 0.045;
/// Lateral amplitude of the strand's curve.
uniform float curl : hint_range(0.0, 0.6) = 0.24;
uniform float rise : hint_range(0.01, 0.5) = 0.06;
uniform float settle : hint_range(0.1, 0.9) = 0.42;

varying vec4 cust;

void vertex() {
	cust = INSTANCE_CUSTOM;
}

// Spine of the strand at parameter s in [-1, 1], plus its half-thickness there.
vec2 spine(float s, float bend, float phase) {
	return vec2(sin(s * 2.1 + phase) * bend, s * length_frac);
}

void fragment() {
	float age = clamp(cust.y, 0.0, 1.0);
	float seed = cust.z;

	vec2 p = (UV - 0.5) * 2.0;
	float bend = curl * mix(-1.0, 1.0, vfx_hash11(seed * 5.7));
	float phase = seed * VFX_TAU;
	// Hairs relax as they fall: the curl opens up once the strand is no longer
	// being dragged by the hand.
	bend *= mix(1.0, 0.55, vfx_ease_out(age));

	vec2 a = spine(-1.0, bend, phase);
	vec2 b = spine(-0.34, bend, phase);
	vec2 c = spine(0.34, bend, phase);
	vec2 e = spine(1.0, bend, phase);
	float th = thickness * mix(0.7, 1.25, vfx_hash11(seed * 2.3 + 0.4));

	// Taper towards both tips — a hair has no blunt end.
	float d = vfx_sd_cone(p, a, b, th * 0.25, th);
	d = min(d, vfx_sd_cone(p, b, c, th, th * 0.9));
	d = min(d, vfx_sd_cone(p, c, e, th * 0.9, th * 0.2));

	float aa = max(fwidth(d), 1e-4);
	float m = 1.0 - smoothstep(-aa, aa, d);

	// One specular streak, offset towards the light across the strand's width.
	// `d` is negative inside, so -d/th is 0 at the edge and 1 at the core.
	float across = clamp(-d / max(th, 1e-4), 0.0, 1.0);
	float side = dot(normalize(vec2(p.y, -p.x) + vec2(1e-5)), normalize(key_dir));
	float sheen = pow(across, 2.5) * clamp(0.35 + 0.65 * side, 0.0, 1.0);

	vec3 col = mix(hair_color.rgb, sheen_color.rgb, sheen * 0.75);
	float env = vfx_env(age, rise, settle);
	COLOR = vec4(col * COLOR.rgb, m * env * COLOR.a);
}
