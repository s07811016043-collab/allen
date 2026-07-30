shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — fur displacement under a stroking hand.
//
// The creature's coat is resolved inside a shader this layer does not own, so
// there is no fur geometry to push. What there *is* is the frame that shader
// already drew: a BackBufferCopy hands it to us and we re-sample it with an
// offset. Displacing the rendered fur is not a trick — the result is exactly
// the same read as bending real strands, because the strands we are bending
// were drawn by the coat model a frame ago.
//
// Making it feel like an animal rather than like a UI ripple came down to four
// things, and dropping any one of them puts it straight back in the browser:
//
//   1. The field is mostly a *shove along the stroke*, not a radial swell. A
//      symmetric radial lens is a water drop; fur goes the way the hand went.
//   2. The travelling front is asymmetric: a fast crest out, a long slow relax
//      back. Fur has damping. Water rings.
//   3. Strand clumping. The displacement is modulated by angular noise so the
//      wave breaks into locks of hair instead of staying a clean circle.
//   4. A parting shade. Where the coat is swept open the underfur reads dark;
//      where it bunches at the crest it catches the key. Without this the
//      pixels move but nothing looks *disturbed*.
//
// The alpha gate is what keeps this honest on a transparent desktop window: we
// only affect pixels that already had something drawn in them, so the ripple
// can never smear a rectangle of desktop wallpaper.

#include "res://vfx/vfx_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

/// Ripple life, 0 at the touch, 1 when the coat has settled.
uniform float phase : hint_range(0.0, 1.0) = 0.0;
/// Peak displacement in screen UV. Tiny numbers: 0.02 is already too much.
uniform float amp : hint_range(0.0, 0.06) = 0.010;
/// Screen-space direction the hand is travelling.
uniform vec2 stroke_dir = vec2(1.0, 0.0);
/// How far the crest travels, in quad radii.
uniform float reach : hint_range(0.2, 1.2) = 0.86;
/// Locks of hair per turn. Higher for short coats.
uniform float strands : hint_range(3.0, 48.0) = 17.0;
/// Strength of the light/dark parting at the crest.
uniform float parting : hint_range(0.0, 1.0) = 0.42;
/// Warm subsurface bloom under the hand, 0..1.
uniform float bloom : hint_range(0.0, 1.0) = 0.0;
uniform vec4 bloom_color : source_color = vec4(1.0, 0.86, 0.70, 1.0);
/// 0 disables the screen read entirely and leaves only the bloom. The low
/// quality tier takes this path; a back buffer copy per touch is the single
/// most expensive thing this layer can ask for.
uniform float use_screen : hint_range(0.0, 1.0) = 1.0;
/// 1 restricts the effect to pixels that already have coverage.
uniform float alpha_gate : hint_range(0.0, 1.0) = 1.0;
uniform float seed = 0.0;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float d = length(p);
	if (d > 1.0) {
		COLOR = vec4(0.0);
	} else {
		vec2 n = p / max(d, 1e-4);
		float ang = atan(p.y, p.x);

		// Locks of hair: the same displacement, chewed into clumps.
		float clump = 0.66 + 0.34 * (0.5 + 0.5 * vfx_noise(
			vec2(ang * strands, seed * 13.7 + d * 2.4)));

		// The crest: out fast, then a wide slow trailing edge as the coat
		// relaxes. `width` grows with phase, which is the relaxation.
		float front = reach * vfx_ease_out(phase);
		float width = mix(0.14, 0.44, phase);
		float u = (d - front) / width;
		float crest = exp(-u * u);
		float decay = (1.0 - phase) * (1.0 - phase);

		// Directly under the hand the coat is simply dragged bodily.
		float core = exp(-pow(d / 0.44, 2.0));

		vec2 disp = (n * crest * 0.30 + stroke_dir * (crest * 0.55 + core * 0.95))
			* amp * decay * clump;

		if (use_screen > 0.5) {
			vec4 s = texture(screen_tex, SCREEN_UV + disp);
			// Parting: inside the crest the coat has been swept open and reads
			// darker; on the outside it is piled up and catches the light.
			float lean = clamp(u, -1.6, 1.6) * crest;
			float shade = 1.0 + parting * lean * decay * clump;
			vec3 col = s.rgb * shade;
			col += bloom_color.rgb * bloom * core * 0.22;
			float mask = smoothstep(1.0, 0.70, d);
			COLOR = vec4(col, mask * mix(1.0, s.a, alpha_gate));
		} else {
			float mask = smoothstep(1.0, 0.70, d);
			COLOR = vec4(bloom_color.rgb, bloom * core * 0.30 * mask);
		}
	}
}
