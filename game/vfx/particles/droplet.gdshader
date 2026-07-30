shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — water droplet.
//
// Water is not a blue circle. What the eye actually reads is a bright rim where
// the surface bends the background into the edge, one hard specular dot, and a
// body that is mostly whatever is behind it. So the alpha here is concentrated
// in the rim and the highlight, and the interior stays nearly transparent.
//
// The quad is stretched along its local Y and the emitter aligns Y with
// velocity, so a droplet leaving a shaking dog is a streak and a droplet at the
// top of its arc is a bead. That transition is free and it is most of the read.

#include "res://vfx/vfx_common.gdshaderinc"

uniform vec4 water_color : source_color = vec4(0.62, 0.74, 0.86, 1.0);
uniform vec4 spec_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec2 key_dir = vec2(-0.55, -0.83);
/// How far the bead is drawn out into a teardrop. 0 is a bead, 1 is a streak.
uniform float stretch : hint_range(0.0, 1.0) = 0.45;
uniform float body_alpha : hint_range(0.0, 0.6) = 0.20;
uniform float rise : hint_range(0.01, 0.4) = 0.05;
uniform float settle : hint_range(0.05, 0.9) = 0.22;

varying vec4 cust;

void vertex() {
	cust = INSTANCE_CUSTOM;
}

void fragment() {
	float age = clamp(cust.y, 0.0, 1.0);
	float seed = cust.z;

	vec2 p = (UV - 0.5) * 2.0;
	float r = mix(0.28, 0.44, vfx_hash11(seed * 4.1));
	// Tail behind, head in front. The emitter aligns local +Y with velocity, so
	// the tail sits at -Y.
	float tail = mix(0.10, 0.85, stretch) * mix(0.7, 1.3, vfx_hash11(seed * 9.3));
	float d = vfx_sd_cone(p, vec2(0.0, -tail), vec2(0.0, r * 0.4), r * 0.06, r);

	float aa = max(fwidth(d), 1e-4);
	float inside = 1.0 - smoothstep(-aa, aa, d);
	// Rim: a thin band just inside the surface, brightest where the light
	// grazes it. This is the part that actually makes water look wet.
	float rim = exp(-pow(max(-d, 0.0) / (r * 0.42), 2.0)) * inside;

	// One specular, pushed towards the light and up the head of the drop.
	vec2 sp = normalize(key_dir) * r * 0.42 + vec2(0.0, r * 0.20);
	float spec = vfx_blob(p - sp, r * 0.40, 0.35);

	vec3 col = mix(water_color.rgb * 0.66, water_color.rgb * 1.15, rim);
	col = mix(col, spec_color.rgb, clamp(spec * 1.6, 0.0, 1.0));

	float env = vfx_env(age, rise, settle);
	float a = (inside * body_alpha + rim * 0.80 + spec * 1.05) * env;
	COLOR = vec4(col * COLOR.rgb, clamp(a, 0.0, 1.0) * COLOR.a);
}
