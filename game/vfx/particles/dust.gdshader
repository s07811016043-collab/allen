shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — dust puff.
//
// One quad per particle, no texture. The silhouette is an fbm-warped disc that
// expands and thins over the particle's life, and it is *shaded*: the side of
// the puff facing the key light is warm, the far side keeps only the bounce.
// That single gradient is the whole difference between dust and a grey circle —
// unlit particles read as UI, and this layer's entire job is to not read as UI.
//
// All timing comes from INSTANCE_CUSTOM.y (normalised age) and all per-particle
// variation from INSTANCE_CUSTOM.z (the seed we smuggle through anim_offset).
// See vfx_common.gdshaderinc for why.

#include "res://vfx/vfx_common.gdshaderinc"

uniform vec4 lit_color : source_color = vec4(1.0, 0.95, 0.86, 1.0);
uniform vec4 shade_color : source_color = vec4(0.32, 0.29, 0.27, 1.0);
/// Screen-space direction towards the key light.
uniform vec2 key_dir = vec2(-0.55, -0.83);
/// Peak opacity. Dust is almost always wrong at more than a third.
uniform float density : hint_range(0.0, 1.0) = 0.30;
/// 0 = a crisp grain of grit, 1 = pure haze.
uniform float softness : hint_range(0.0, 1.0) = 0.62;
/// How much the disc is chewed up by noise. Low for droplets of mist, high for
/// floor dust that has to look like it is made of something.
uniform float breakup : hint_range(0.0, 1.0) = 0.55;
/// Radius multiplier from birth to death. A puff that does not expand does not
/// look like it is entraining air.
uniform float expand : hint_range(1.0, 4.0) = 1.9;
/// Fraction of life spent appearing. Impact dust wants ~0.05, breath ~0.25.
uniform float rise : hint_range(0.01, 0.6) = 0.10;
/// Fraction of life spent dissipating.
uniform float settle : hint_range(0.1, 0.95) = 0.66;

varying vec4 cust;

void vertex() {
	cust = INSTANCE_CUSTOM;
}

void fragment() {
	float age = clamp(cust.y, 0.0, 1.0);
	float seed = cust.z;

	vec2 p = (UV - 0.5) * 2.0;
	// Each puff gets its own orientation and its own slow tumble, so a burst of
	// eight never shows the same silhouette twice.
	float spin = (seed - 0.5) * VFX_TAU + age * mix(-1.1, 1.1, vfx_hash11(seed * 3.1));
	vec2 q = vfx_rot(spin) * p;

	// Warping the *distance* rather than masking the result keeps the edge a
	// real silhouette, so it stays soft under magnification instead of
	// dissolving into visible noise.
	float warp = vfx_fbm3(q * 2.4 + vec2(seed * 37.0, seed * 11.0)) * breakup;
	float r = 0.34 * mix(1.0, expand, vfx_ease_out(age));
	float d = length(q) * (1.0 + warp * 0.6);
	float m = pow(clamp(1.0 - d / max(r, 1e-4), 0.0, 1.0), mix(0.85, 2.8, softness));

	// Asymmetric envelope: dust arrives fast and leaves slowly. A symmetric
	// fade reads as a blink.
	float env = vfx_env(age, rise, settle);

	// Lambert on the puff's own curvature: treat the offset from the centre as
	// the surface normal of a little ball of particles.
	float ndl = dot(normalize(q + vec2(1e-5)), normalize(key_dir));
	vec3 col = mix(shade_color.rgb, lit_color.rgb, clamp(0.5 + 0.5 * ndl, 0.0, 1.0));
	// A faint rim where the light grazes through the thin edge; the same
	// forward-scatter that makes real dust visible at all.
	col += lit_color.rgb * pow(clamp(1.0 - d / max(r, 1e-4), 0.0, 1.0), 6.0)
		* clamp(ndl, 0.0, 1.0) * 0.35;

	COLOR = vec4(col * COLOR.rgb, m * env * density * COLOR.a);
}
