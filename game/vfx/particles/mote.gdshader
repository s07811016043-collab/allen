shader_type canvas_item;
render_mode blend_add, unshaded;

// Petalia — airborne mote catching the key light.
//
// The restraint budget for this whole layer is spent here. Motes run
// continuously next to the pet all day, so each one is a sub-pixel core, a wide
// faint halo, and nothing else. Additive, because a mote is light scattered
// towards the eye, not an object.
//
// The twinkle is the one piece of motion: a mote is only visible when its facet
// happens to be turned towards the light, so brightness is a slow, irregular
// function of a per-particle phase rather than a sine. Irregular matters —
// synchronised twinkling reads as a fairy filter.

#include "res://vfx/vfx_common.gdshaderinc"

uniform vec4 mote_color : source_color = vec4(1.0, 0.95, 0.84, 1.0);
/// Peak additive brightness. This should feel too low when you set it.
uniform float gain : hint_range(0.0, 1.0) = 0.20;
uniform float core_size : hint_range(0.02, 0.5) = 0.10;
uniform float halo_size : hint_range(0.1, 1.0) = 0.62;
/// Depth of the twinkle, 0 = steady, 1 = fully on/off.
uniform float twinkle : hint_range(0.0, 1.0) = 0.65;
uniform float twinkle_hz : hint_range(0.05, 3.0) = 0.55;

varying vec4 cust;

void vertex() {
	cust = INSTANCE_CUSTOM;
}

void fragment() {
	float age = clamp(cust.y, 0.0, 1.0);
	float seed = cust.z;

	vec2 p = (UV - 0.5) * 2.0;
	float sz = mix(0.55, 1.25, vfx_hash11(seed * 6.7));

	float core = vfx_blob(p, core_size * sz, 0.15);
	float halo = vfx_blob(p, halo_size * sz, 1.0);

	// Two detuned oscillators per particle: their beat never repeats over the
	// few seconds a mote lives, so no two motes ever pulse together.
	float ph = seed * VFX_TAU;
	float t = TIME * twinkle_hz;
	float flick = 0.5 + 0.5 * (sin(t * VFX_TAU + ph) * 0.6
		+ sin(t * VFX_TAU * 1.61 + ph * 2.3) * 0.4);
	float bright = mix(1.0, flick, twinkle);

	// Motes drift in and out of the shaft rather than popping; the long tails on
	// both ends of the envelope are doing that work.
	float env = vfx_env(age, 0.28, 0.42);

	float a = (core * 0.85 + halo * 0.30) * bright * env * gain;
	COLOR = vec4(mote_color.rgb * COLOR.rgb, clamp(a, 0.0, 1.0) * COLOR.a);
}
