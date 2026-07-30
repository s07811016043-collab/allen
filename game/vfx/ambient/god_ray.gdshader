shader_type canvas_item;
render_mode blend_add, unshaded;

// Petalia — a shaft of light across the pet.
//
// This is the effect most likely to ruin the program. A god ray that is one
// notch too strong turns a desktop companion into a screensaver, and unlike a
// dust puff it is on screen continuously, so there is no moment where the
// player stops seeing it. Every constant here is therefore set low and the
// caller multiplies it lower again.
//
// The shaft is built in the light's own frame: `u` runs along the beam, `v`
// across it. Across is a soft gaussian; along is a long fade so the beam has no
// visible start or end. The sub-shafts are one octave of noise in `v`, drifting
// slowly along `u`, which is what stops it looking like an airbrushed cone.

#include "res://vfx/vfx_common.gdshaderinc"

/// Unit vector, quad space, pointing the way the light travels (away from the
/// sun). The caller derives it from `VfxTimeOfDay.light_dir_2d()`.
uniform vec2 beam_dir = vec2(0.55, 0.83);
uniform vec4 tint : source_color = vec4(1.0, 0.93, 0.78, 1.0);
/// Peak additive brightness. Above about 0.10 this stops being atmosphere.
uniform float gain : hint_range(0.0, 0.3) = 0.055;
/// Half-width of the shaft in quad units.
uniform float width : hint_range(0.05, 1.0) = 0.34;
/// Number of sub-shafts across the beam.
uniform float bands : hint_range(1.0, 12.0) = 4.5;
/// How fast the sub-shafts crawl. Slow enough to be deniable.
uniform float drift : hint_range(0.0, 0.4) = 0.055;
/// Softens the beam's own edges into the quad so no rectangle is ever visible.
uniform float feather : hint_range(0.1, 1.0) = 0.55;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	vec2 d = normalize(beam_dir + vec2(1e-5));
	float u = dot(p, d);
	float v = dot(p, vec2(-d.y, d.x));

	// Across the beam: a gaussian core with a wide skirt. Two lobes rather than
	// one, because a single gaussian has no penumbra and reads as a laser.
	float core = exp(-pow(v / max(width, 1e-3), 2.0));
	float skirt = exp(-pow(v / max(width * 2.6, 1e-3), 2.0));
	float across = core * 0.72 + skirt * 0.28;

	// Along the beam: brightest where it enters, dying out before it leaves.
	float along = smoothstep(-1.1, -0.35, u) * (1.0 - smoothstep(0.15, 1.0, u));

	// Sub-shafts: one octave, crawling. The `u` term shears them so they are
	// not parallel stripes.
	float n = vfx_noise(vec2(v * bands, u * 0.6 + TIME * drift));
	float shafts = 0.68 + 0.32 * (0.5 + 0.5 * n);

	// The quad must never show a corner.
	float vig = 1.0 - smoothstep(feather, 1.0, length(p));

	float a = across * along * shafts * vig * gain;
	COLOR = vec4(tint.rgb, clamp(a, 0.0, 1.0)) * COLOR;
}
