shader_type canvas_item;
render_mode blend_disabled, unshaded;

// Petalia's post stack.
//
// Petalia is a desktop overlay: its window is transparent and the player's
// wallpaper, editor and browser show through it. That single fact dictates the
// whole design here, because the naive version of every effect below smears
// opaque pixels over the desktop and the illusion dies instantly.
//
// The framebuffer Godot hands us holds *premultiplied* colour with straight
// alpha — the canvas blender writes RGB with SRC_ALPHA and A with ONE, so what
// accumulates is already colour-times-coverage. Every operation here therefore
// works in premultiplied space and only unpremultiplies for the grade, which is
// the one step that has to see the surface's actual colour. Bloom carries its
// own alpha out with it, so a glow around the pet is a genuinely translucent
// halo rather than a rectangle of fog.
//
// `blend_disabled` is deliberate: this pass replaces the frame rather than
// compositing over it, so alpha is written verbatim and window transparency
// survives.

#include "res://shaders/common/tonemap.gdshaderinc"

uniform sampler2D screen : hint_screen_texture, repeat_disable, filter_linear;

group_uniforms Bloom;
uniform float bloom_intensity : hint_range(0.0, 2.0) = 0.42;
uniform float bloom_threshold : hint_range(0.0, 1.5) = 0.68;
uniform float bloom_knee : hint_range(0.01, 0.6) = 0.22;
/// Blur radius as a fraction of the shorter screen axis.
uniform float bloom_radius : hint_range(0.0, 0.12) = 0.022;
/// How much coverage the glow carries. Zero makes bloom invisible against the
/// desktop; one makes the halo as solid as the pet. The truth is near the floor.
uniform float bloom_alpha : hint_range(0.0, 1.0) = 0.30;

group_uniforms Lens;
/// Lateral chromatic aberration, in fractions of the frame. Ramped from the
/// centre outward, because that is where a real lens has it.
uniform float aberration : hint_range(0.0, 0.02) = 0.0035;

group_uniforms Grade;
uniform float exposure_post : hint_range(0.0, 4.0) = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.06;
uniform float saturation : hint_range(0.0, 2.0) = 1.10;
uniform vec4 shadow_tint : source_color = vec4(0.48, 0.52, 0.62, 1.0);
uniform vec4 highlight_tint : source_color = vec4(1.0, 0.97, 0.90, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.16;
/// Set only when the viewport is an HDR target. On a plain 8-bit canvas the
/// creature shader has already applied the curve, because values above one are
/// clipped by the framebuffer long before this pass could roll them off.
uniform bool hdr_input = false;

uniform vec2 screen_size = vec2(1280.0, 800.0);

const float GOLDEN_ANGLE = 2.39996323;
const int BLOOM_TAPS = 12;


// Soft-knee bright pass, on premultiplied colour so that a half-covered bright
// pixel contributes half as much glow — which is what stops the coat fringe
// from throwing a hard ring of light.
vec3 bright_pass(vec3 premul) {
	float lum = dot(premul, vec3(0.2126, 0.7152, 0.0722));
	float t = clamp((lum - bloom_threshold + bloom_knee) / (2.0 * bloom_knee), 0.0, 1.0);
	float w = max(lum - bloom_threshold, t * t * bloom_knee);
	return premul * (w / max(lum, 1e-4));
}


void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 aspect = vec2(screen_size.x / max(screen_size.y, 1.0), 1.0);

	// --- chromatic aberration ----------------------------------------------
	// Sampled per channel with a radial ramp. Alpha comes from the green tap
	// only: fringing the coverage as well would leave coloured lace around the
	// silhouette where it meets the desktop.
	vec2 centred = (uv - 0.5) * aspect;
	vec2 ca = centred * dot(centred, centred) * aberration;
	vec4 g = texture(screen, uv);
	vec4 base = vec4(texture(screen, uv - ca).r, g.g, texture(screen, uv + ca).b, g.a);

	// --- bloom --------------------------------------------------------------
	// A single golden-angle spiral. It is not a separable Gaussian, but on a
	// window this small the difference is invisible and the cost is one pass
	// instead of three — which matters, because this ships on integrated GPUs.
	vec3 sum = bright_pass(base.rgb);
	float norm = 1.0;
	float scale = bloom_radius / max(sqrt(float(BLOOM_TAPS)), 1.0);
	for (int i = 0; i < BLOOM_TAPS; i++) {
		float a = float(i) * GOLDEN_ANGLE;
		float rr = sqrt(float(i) + 0.5) * scale;
		vec2 o = vec2(cos(a), sin(a)) * rr / aspect;
		sum += bright_pass(texture(screen, uv + o).rgb);
		norm += 1.0;
	}
	vec3 bloom = sum / norm;

	vec3 premul = base.rgb + bloom * bloom_intensity;
	// The halo needs coverage of its own or it is invisible over the desktop,
	// but it must stay well under the pet's own alpha or the window grows a
	// visible rectangle wherever the glow reaches the frame edge.
	float glow_a = dot(bloom, vec3(0.2126, 0.7152, 0.0722)) * bloom_intensity * bloom_alpha;
	float alpha = clamp(base.a + glow_a * (1.0 - base.a), 0.0, 1.0);
	if (alpha <= 0.0015) { discard; }

	// --- grade --------------------------------------------------------------
	// Unpremultiply first: contrast and saturation have to see the surface's
	// real colour, not colour scaled by its coverage, or every soft edge shifts
	// hue as it fades out.
	vec3 col = premul / max(alpha, 1e-4);
	col *= exposure_post;
	if (hdr_input) { col = pet_tonemap(col); }

	float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(lum), col, saturation);
	col = clamp((col - 0.5) * contrast + 0.5, vec3(0.0), vec3(1.4));
	// Split tone: cool the shadows, warm the highlights. Two colours of light in
	// one frame is most of what makes an image read as photographed.
	col *= mix(shadow_tint.rgb * 2.0, highlight_tint.rgb, clamp(lum, 0.0, 1.0))
		* tint_strength + (1.0 - tint_strength);

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)) * alpha, alpha);
}
