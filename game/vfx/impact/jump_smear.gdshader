shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — takeoff smear.
//
// A hand-animated smear frame is a drawing of the character stretched along its
// path. We cannot draw one — the creature only exists as a signed distance
// field inside someone else's shader — but we can do the thing the smear frame
// is an approximation *of*: sample the frame the creature was drawn into,
// several times along the motion vector, and lay the result down behind it.
//
// Direction matters. For a pixel behind the pet we step *forwards* towards
// where the pet actually is, so every tap that lands on the body contributes
// and every tap that lands on empty desktop contributes nothing. The result is
// a trail that exists only where the animal has been, which is why it survives
// a transparent window with no background to smear.
//
// Five taps. Four is visibly banded on a fast jump and six is not better.

#include "res://vfx/vfx_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

/// Unit vector, in screen UV space, pointing the way the creature is going.
uniform vec2 travel = vec2(1.0, -1.0);
/// Length of the trail in screen UV. Scaled by the caller from real speed.
uniform float smear_len : hint_range(0.0, 0.4) = 0.06;
/// Overall strength, faded by the effect's envelope.
uniform float strength : hint_range(0.0, 1.0) = 0.7;
/// Tint pushed into the trail — a touch of the key light, so the smear reads as
/// motion blur catching the sun rather than as a grey ghost.
uniform vec4 tint : source_color = vec4(1.0, 0.95, 0.86, 1.0);
/// How much the trail narrows towards its tail.
uniform float taper : hint_range(0.0, 1.0) = 0.7;

const int TAPS = 5;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	vec2 dir = normalize(travel + vec2(1e-5));
	// Local frame: `along` is distance behind the creature, `across` is offset
	// from the motion axis.
	float along = -dot(p, dir);
	float across = dot(p, vec2(-dir.y, dir.x));

	// The trail lives behind the body only, and narrows as it goes.
	float half_w = mix(1.0, 1.0 - taper, clamp(along, 0.0, 1.0));
	float band = 1.0 - smoothstep(half_w * 0.55, half_w, abs(across));
	float run = smoothstep(-0.05, 0.15, along) * (1.0 - smoothstep(0.55, 1.0, along));
	float mask = band * run;

	if (mask <= 0.001) {
		COLOR = vec4(0.0);
	} else {
		vec4 acc = vec4(0.0);
		float wsum = 0.0;
		for (int i = 1; i <= TAPS; i++) {
			float f = float(i) / float(TAPS);
			// Weight the near taps hardest: a smear is dense against the body
			// and thins towards the tail.
			float w = 1.0 - f * 0.75;
			acc += texture(screen_tex, SCREEN_UV + dir * smear_len * f) * w;
			wsum += w;
		}
		acc /= max(wsum, 1e-4);
		vec3 col = mix(acc.rgb, tint.rgb, 0.18);
		COLOR = vec4(col, acc.a * mask * strength);
	}
}
