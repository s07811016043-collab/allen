shader_type canvas_item;
render_mode blend_premul_alpha, unshaded;

// Petalia — the emotion set.
//
// These are the only things in the game that carry literal meaning, and they
// have to survive being 24 px tall on top of an arbitrary wallpaper. Every
// decision here follows from those two facts:
//
// * Every glyph is built from capsules and arcs with a *constant stroke
//   weight*. Stroke weight is what fails first at small sizes; a shape scaled
//   down keeps its proportions but loses its strokes.
// * Every glyph is drawn as a physical sticker: a soft cast shadow, a dark
//   keyline, a lit fill with a top-to-bottom gradient, and one specular. The
//   keyline is not decoration — it is the only thing guaranteeing contrast
//   against a wallpaper we know nothing about.
// * Anti-aliasing is `fwidth`-based, so the same glyph is crisp at 24 px and at
//   240 px without a second asset.
//
// Composited premultiplied, back to front, so four translucent layers stack
// without the fringing that straight-alpha `mix` chains produce.

#include "res://vfx/vfx_common.gdshaderinc"

const int GLYPH_HEART = 0;
const int GLYPH_SLEEP = 1;
const int GLYPH_QUESTION = 2;
const int GLYPH_EXCLAIM = 3;
const int GLYPH_SWEAT = 4;
const int GLYPH_NOTE = 5;
const int GLYPH_NOTE_PAIR = 6;

uniform int glyph = 0;
uniform vec4 fill_top : source_color = vec4(1.00, 0.46, 0.52, 1.0);
uniform vec4 fill_bottom : source_color = vec4(0.82, 0.20, 0.32, 1.0);
uniform vec4 edge_color : source_color = vec4(0.16, 0.06, 0.10, 1.0);
uniform vec4 spec_color : source_color = vec4(1.0, 0.96, 0.92, 1.0);
/// Screen-space direction towards the key light.
uniform vec2 key_dir = vec2(-0.55, -0.83);
/// Keyline half-width in glyph units. Scaled by the caller so it holds up at
/// small sizes without swallowing the shape at large ones.
uniform float outline : hint_range(0.0, 0.12) = 0.045;
uniform float shadow_dist : hint_range(0.0, 0.3) = 0.075;
uniform float shadow_alpha : hint_range(0.0, 0.6) = 0.26;
/// Arrival flash: brightens the fill and rings the keyline for a few frames.
uniform float flash : hint_range(0.0, 1.0) = 0.0;
uniform float master_alpha : hint_range(0.0, 1.0) = 1.0;

// Premultiplied source-over.
vec4 vfx_over(vec4 src, vec4 dst) {
	return src + dst * (1.0 - src.a);
}

float sd_ellipse(vec2 p, vec2 r) {
	// Cheap and slightly conservative, which is invisible once the shape is
	// filled and keeps the whole glyph pass branch-free.
	return (length(p / r) - 1.0) * min(r.x, r.y);
}

float sd_heart(vec2 p) {
	p.y -= 0.06;
	float d = vfx_sd_cone(p, vec2(0.0, -0.84), vec2(0.0, 0.22), 0.03, 0.50);
	d = vfx_smin(d, vfx_sd_circle(p - vec2(-0.35, 0.34), 0.39), 0.13);
	d = vfx_smin(d, vfx_sd_circle(p - vec2(0.35, 0.34), 0.39), 0.13);
	return d;
}

float sd_sleep(vec2 p) {
	// A hair of italic. Upright it reads as a letter; slanted it reads as a
	// sound leaving a sleeping animal.
	p.x -= p.y * 0.17;
	float w = 0.125;
	float d = vfx_sd_seg(p, vec2(-0.36, 0.50), vec2(0.40, 0.50), w);
	d = min(d, vfx_sd_seg(p, vec2(0.40, 0.50), vec2(-0.36, -0.44), w));
	d = min(d, vfx_sd_seg(p, vec2(-0.36, -0.44), vec2(0.40, -0.44), w));
	return d;
}

float sd_question(vec2 p) {
	// Bowl: a 270-degree arc whose gap faces down-left, which is where a
	// question mark's stroke actually starts. Ends at bottom-centre, where the
	// tail takes over.
	vec2 c = p - vec2(0.0, 0.28);
	c = vfx_rot(-0.7854) * c;
	float d = vfx_sd_arc(c, vec2(0.7071, -0.7071), 0.36, 0.132);
	d = min(d, vfx_sd_seg(p, vec2(0.0, -0.08), vec2(0.0, -0.24), 0.132));
	d = min(d, vfx_sd_circle(p - vec2(0.0, -0.60), 0.155));
	return d;
}

float sd_exclaim(vec2 p) {
	float d = vfx_sd_cone(p, vec2(0.0, 0.70), vec2(0.0, -0.16), 0.175, 0.105);
	d = min(d, vfx_sd_circle(p - vec2(0.0, -0.58), 0.165));
	return d;
}

float sd_sweat(vec2 p) {
	// Tilted, because a drop that hangs perfectly vertical looks like a pin.
	p = vfx_rot(0.16) * p;
	return vfx_sd_cone(p, vec2(0.0, 0.74), vec2(0.0, -0.26), 0.02, 0.44);
}

float sd_note(vec2 p) {
	float d = sd_ellipse(vfx_rot(0.38) * (p - vec2(-0.20, -0.44)), vec2(0.31, 0.225));
	d = min(d, vfx_sd_seg(p, vec2(0.10, -0.40), vec2(0.10, 0.60), 0.068));
	// The flag, as two capsules: one leaving the stem, one curling back in.
	d = min(d, vfx_sd_cone(p, vec2(0.10, 0.62), vec2(0.38, 0.32), 0.085, 0.070));
	d = min(d, vfx_sd_cone(p, vec2(0.38, 0.32), vec2(0.31, 0.08), 0.070, 0.045));
	return d;
}

float sd_note_pair(vec2 p) {
	float d = sd_ellipse(vfx_rot(0.38) * (p - vec2(-0.46, -0.46)), vec2(0.27, 0.195));
	d = min(d, vfx_sd_seg(p, vec2(-0.20, -0.42), vec2(-0.20, 0.48), 0.062));
	d = min(d, sd_ellipse(vfx_rot(0.38) * (p - vec2(0.16, -0.30)), vec2(0.27, 0.195)));
	d = min(d, vfx_sd_seg(p, vec2(0.42, -0.26), vec2(0.42, 0.62), 0.062));
	d = min(d, vfx_sd_seg(p, vec2(-0.20, 0.48), vec2(0.42, 0.62), 0.088));
	return d;
}

float sd_glyph(vec2 p) {
	if (glyph == GLYPH_SLEEP) { return sd_sleep(p); }
	if (glyph == GLYPH_QUESTION) { return sd_question(p); }
	if (glyph == GLYPH_EXCLAIM) { return sd_exclaim(p); }
	if (glyph == GLYPH_SWEAT) { return sd_sweat(p); }
	if (glyph == GLYPH_NOTE) { return sd_note(p); }
	if (glyph == GLYPH_NOTE_PAIR) { return sd_note_pair(p); }
	return sd_heart(p);
}

void fragment() {
	// Glyph space: +y up, so the shapes above read the way they are written.
	vec2 p = vec2((UV.x - 0.5) * 2.0, (0.5 - UV.y) * 2.0);
	vec2 gkey = normalize(vec2(key_dir.x, -key_dir.y) + vec2(1e-5));

	float d = sd_glyph(p);
	float aa = max(fwidth(d), 1e-4);

	float inside = 1.0 - smoothstep(-aa, aa, d);
	float ring = 1.0 - smoothstep(-aa, aa, d - outline);
	float cast_d = sd_glyph(p + gkey * shadow_dist);
	// The cast shadow is deliberately softer than the glyph: two extra pixels
	// of feather is what stops it reading as a second outline.
	float cast_s = 1.0 - smoothstep(-aa * 3.0, aa * 3.0, cast_d - outline * 1.1);

	// Fill: lit from the top, with the keyline colour bleeding into the bottom
	// so the shape has a base rather than floating.
	float up = clamp(0.5 + 0.5 * p.y, 0.0, 1.0);
	vec3 fill = mix(fill_bottom.rgb, fill_top.rgb, up * up);
	// Contact shading: darken the last sliver inside the silhouette on the side
	// away from the light. Cheap volume.
	float lit_side = clamp(0.5 + 0.5 * dot(normalize(p + vec2(1e-5)), gkey), 0.0, 1.0);
	float edge_in = 1.0 - clamp(-d / 0.22, 0.0, 1.0);
	fill = mix(fill, fill * 0.72, edge_in * (1.0 - lit_side) * 0.85);
	fill = mix(fill, fill_top.rgb * 1.15 + vec3(0.06), flash * 0.7);

	// One specular, pushed towards the light and held inside the silhouette.
	float spec = vfx_blob(p - gkey * 0.34, 0.30, 1.1) * inside;

	vec4 acc = vec4(0.0);
	acc = vfx_over(vec4(vec3(0.02, 0.02, 0.04) * cast_s * shadow_alpha,
		cast_s * shadow_alpha), acc);
	vec3 key_rgb = mix(edge_color.rgb, spec_color.rgb, flash * 0.55);
	acc = vfx_over(vec4(key_rgb * ring, ring), acc);
	acc = vfx_over(vec4(fill * inside, inside), acc);
	acc = vfx_over(vec4(spec_color.rgb * spec * 0.55, spec * 0.55), acc);

	COLOR = acc * master_alpha * COLOR;
}
