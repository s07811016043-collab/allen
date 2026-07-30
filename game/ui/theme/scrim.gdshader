shader_type canvas_item;
render_mode blend_mix, unshaded;

// Petalia — frosted panel scrim.
//
// Every panel in the overlay draws its own backdrop through this shader. It
// exists because a desktop pet has no control over what is behind it: the same
// panel has to stay readable over a black terminal, a white document and a
// photograph of a beach. Three things together buy that guarantee:
//
//   1. a blur, which destroys the high-frequency detail that fights with text,
//   2. a desaturation pull toward the blurred luminance, so a saturated
//      wallpaper cannot tint the panel into a different design,
//   3. a near-opaque tint on top, which is what actually sets the contrast.
//
// The blur is the part that makes it feel like glass rather than a grey box,
// but it is deliberately *not* load-bearing: with the screen texture empty (a
// fully transparent overlay window on a compositor that will not hand us the
// desktop behind it) the tint alone still passes contrast. Nothing here is
// allowed to depend on the backdrop existing.
//
// The node this runs on is inflated by `pad` on every side so the drop shadow
// has somewhere to live; the panel's own rectangle is `panel_size`, centred.

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;

uniform vec2 panel_size = vec2(320.0, 240.0);
uniform float pad = 44.0;
uniform float radius = 20.0;

uniform vec4 fill : source_color = vec4(0.068, 0.064, 0.086, 0.90);
uniform vec4 edge : source_color = vec4(1.0, 0.98, 1.0, 0.11);
uniform vec4 sheen : source_color = vec4(1.0, 0.99, 1.0, 0.16);
uniform vec4 shadow : source_color = vec4(0.01, 0.006, 0.02, 0.42);

uniform float blur_px : hint_range(0.0, 48.0) = 16.0;
uniform float shadow_px : hint_range(0.0, 96.0) = 34.0;
uniform float shadow_lift : hint_range(0.0, 48.0) = 12.0;
uniform float grain : hint_range(0.0, 0.05) = 0.012;
// 0 while opening, 1 when open. Scales the box rather than the node so the
// corner radius and the hairline stay physically constant as it grows —
// scaling the node instead makes a 22px radius visibly swell, which is the
// tell that separates a cheap pop-in from an expensive one.
uniform float reveal : hint_range(0.0, 1.0) = 1.0;

float sd_round_box(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

// A 13-tap golden-angle spiral. A separable two-pass gaussian is out of reach
// for a canvas shader, and at this radius the spiral's slight softness is an
// asset: it reads as depth of field rather than as a box blur.
vec3 sample_backdrop(vec2 uv, vec2 texel) {
	vec3 acc = texture(screen_tex, uv).rgb;
	for (int i = 0; i < 12; i++) {
		float a = float(i) * 2.39996323;
		float r = sqrt((float(i) + 0.5) / 12.0);
		vec2 o = vec2(cos(a), sin(a)) * r * blur_px * texel;
		acc += texture(screen_tex, uv + o).rgb;
	}
	return acc / 13.0;
}

void fragment() {
	vec2 full = panel_size + vec2(pad * 2.0);
	vec2 p = UV * full - full * 0.5;
	vec2 b = panel_size * 0.5 * mix(0.94, 1.0, reveal);
	float r = min(radius, min(b.x, b.y));

	float d = sd_round_box(p, b, r);
	float aa = fwidth(d) + 0.0001;
	float inside = 1.0 - smoothstep(-aa, aa, d);

	// Two stacked falloffs, the same trick the creature's contact shadow uses:
	// a wide ambient term plus a tight one under the panel's lower edge. One
	// falloff alone reads either as fog or as a hard drop shadow from 2003.
	float ds = sd_round_box(p - vec2(0.0, shadow_lift), b, r);
	float sh = smoothstep(shadow_px, 0.0, ds) * 0.75
		+ smoothstep(shadow_px * 0.34, 0.0, ds) * 0.45;
	sh = clamp(sh, 0.0, 1.0) * shadow.a * reveal * (1.0 - inside);

	vec3 back = sample_backdrop(SCREEN_UV, SCREEN_PIXEL_SIZE);
	float bl = dot(back, vec3(0.2126, 0.7152, 0.0722));
	back = mix(back, vec3(bl), 0.4);
	vec3 col = mix(back, fill.rgb, fill.a);

	// Vertical lightfall inside the pane: brighter at the top, as if a diffuse
	// source sits above the desktop. Same rig the creature is lit by, so panel
	// and pet agree about where the light is.
	float vgrad = clamp((b.y - p.y) / max(b.y * 2.0, 1.0), 0.0, 1.0);
	col *= mix(0.955, 1.055, vgrad);

	// A specular sheen hugging the top edge, ~2px deep. This is the single
	// detail that makes a flat rounded rect read as a physical pane of glass.
	float top_d = max(0.0, p.y + b.y);
	float sheen_amt = exp(-top_d / 2.4) * smoothstep(-1.0, -3.0, d);
	col = mix(col, col + sheen.rgb, sheen_amt * sheen.a);

	// Hairline. Drawn on the inside of the boundary so the AA of the fill and
	// the AA of the border never fight and leave a dark seam.
	float ring = 1.0 - smoothstep(0.0, 1.35, abs(d + 0.7));
	col = mix(col, mix(col, edge.rgb, 0.85), ring * edge.a * 3.0);

	// Dither. The gradients above are shallow enough to band visibly on an
	// 8-bit desktop, and banding on a large flat panel is the most obvious
	// "made in a hurry" artefact there is.
	col += (hash21(FRAGCOORD.xy) - 0.5) * grain;

	float alpha = inside + sh * (1.0 - inside);
	COLOR = vec4(mix(shadow.rgb, col, inside), alpha);
}
