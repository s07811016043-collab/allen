shader_type canvas_item;
render_mode blend_mix, unshaded;

// Stand-in desktop wallpaper, used only by `ui_preview.tscn`.
//
// The UI's whole contrast argument is about surviving an unknown backdrop, so
// reviewing it against a flat colour would prove nothing. This produces the
// two things a real wallpaper has and a swatch does not: large saturated colour
// fields, and high-frequency detail for the panel blur to eat.

uniform float dark = 1.0;
uniform float seed = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p + 19.19);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	vec3 a = mix(vec3(0.98, 0.90, 0.78), vec3(0.055, 0.075, 0.145), dark);
	vec3 b = mix(vec3(0.86, 0.72, 0.86), vec3(0.13, 0.09, 0.20), dark);
	vec3 c = mix(vec3(1.00, 0.97, 0.92), vec3(0.02, 0.12, 0.16), dark);

	float diag = clamp((uv.x * 0.7 + uv.y * 0.9), 0.0, 1.0);
	vec3 col = mix(a, b, diag);
	col = mix(col, c, smoothstep(0.35, 1.0, length(uv - vec2(0.18, 0.86))));

	// Bokeh. Big soft discs are what makes a wallpaper feel photographic, and
	// they are the worst case for a translucent panel: a bright disc drifting
	// under body text is exactly the failure a scrim has to prevent.
	for (int i = 0; i < 7; i++) {
		float fi = float(i) + seed;
		vec2 p = vec2(fract(sin(fi * 12.9898) * 43758.5453),
			fract(sin(fi * 78.233) * 12345.6789));
		float r = 0.06 + 0.11 * fract(sin(fi * 3.14) * 999.0);
		float d = length((uv - p) * vec2(1.6, 1.0));
		float m = smoothstep(r, r * 0.15, d);
		col += mix(vec3(0.9, 0.75, 0.55), vec3(0.35, 0.55, 0.85), dark) * m * 0.16;
	}

	// Fine diagonal weave: pure high-frequency detail. If the blur is working
	// this vanishes under a panel; if it is not, it is immediately obvious.
	float w = sin((uv.x * 900.0 + uv.y * 640.0)) * 0.5 + 0.5;
	col += (w - 0.5) * 0.022;
	col += (hash21(FRAGCOORD.xy) - 0.5) * 0.012;

	COLOR = vec4(col, 1.0);
}
