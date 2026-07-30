#ifndef PETALIA_EYE_INC
#define PETALIA_EYE_INC

#include "res://shaders/creature/noise.gdshaderinc"
#include "res://shaders/creature/lighting.gdshaderinc"

// The eye pass.
//
// Two small discs carry everything a player reads as "alive", so this is the one
// place in the renderer where cost is not the deciding argument. What is being
// built, from the back forward:
//
//   sclera   a translucent sphere, not a white disc — warm where it thins into
//            the canthi, cool where the socket shadows it,
//   iris     fibres, crypts, a collarette and a limbal ring, plus the crescent
//            of backscatter that appears opposite the key light,
//   pupil    an aperture with a lit margin, slitting for cats and geckos,
//   cornea   a lens with real refraction: the iris behind it is displaced and
//            magnified, which is the whole difference between glass over a
//            living sphere and a sticker,
//   tear     a wet meniscus where each lid meets the ball,
//   lids     with a cast shadow, and lashes where the species has them.

uniform vec4 sclera_color : source_color = vec4(0.93, 0.92, 0.90, 1.0);
uniform float brow_raise : hint_range(0.0, 1.0) = 0.0;
uniform float brow_furrow : hint_range(0.0, 1.0) = 0.0;
// Mammals get lashes; birds and reptiles do not. Set per species.
uniform float eye_lash : hint_range(0.0, 1.0) = 1.0;


// Strands indexed along the lid, exactly like the coat fringe, so each lash is a
// separate tapered spike rather than a smudge along the edge.
float pet_eye_lashes(vec2 q, float R, float upper, float amount) {
	float h = (upper - q.y) / (R * 0.44);
	if (h <= 0.0 || h >= 1.0) { return 0.0; }
	float x = q.x / R;
	// Lashes splay outward from the middle of the lid and curl as they rise.
	float lane = (x + h * (0.28 * sign(x) + x * 0.5)) * 7.0;
	float f = fract(lane) - 0.5;
	float r = pet_hash1(vec2(floor(lane), 23.0));
	float len = 0.42 + 0.58 * r;
	if (h > len) { return 0.0; }
	float w = mix(0.32, 0.14, h / len);
	float dp;
	float core = pet_ridge(abs(f) / w, dp);
	return core * (1.0 - h / len) * smoothstep(1.10, 0.72, abs(x)) * amount;
}


// eyes[i*4+0] = (center.xy, radius, tilt)
// eyes[i*4+1] = (iris_ratio, pupil_ratio, pupil_slit, blink)
// eyes[i*4+2] = (iris.rgb, socket_depth)
// eyes[i*4+3] = (gaze.xy, lid_open, limbal_luminance)
vec4 pet_shade_eye(vec4 e0, vec4 e1, vec4 e2, vec4 e3, vec2 p, float unit_px) {
	float R = e0.z;
	if (R <= 1e-5) { return vec4(0.0); }

	vec2 qr = p - e0.xy;
	float ct = cos(e0.w);
	float st = sin(e0.w);
	vec2 q = vec2(qr.x * ct - qr.y * st, qr.x * st + qr.y * ct);

	float r = length(q);
	float aa = max(unit_px * 0.8, R * 0.006);
	float ball = smoothstep(aa, -aa, r - R);

	// Lids first: the lash band reaches above the ball, so alpha has to be able
	// to exist outside it.
	float open = clamp(e3.z * (1.0 - e1.w), 0.0, 1.0);
	// Rig space has +y down, so the upper lid lives at negative y. Fully open
	// still crops the ball slightly — an eye with no lid overlap reads as a
	// startled cartoon, not as a resting animal.
	float upper = -R * mix(0.02, 0.82, open) + brow_raise * R * 0.13 - brow_furrow * R * 0.17;
	float lower = R * mix(-0.02, 0.90, open);
	// Lids are arcs, not horizontal cuts. A straight lid line crossed with a
	// circle gives the faceted, vaguely hexagonal eye that betrays every cheap
	// procedural face; both lids have to sag toward the corners.
	float bow = (q.x / R) * (q.x / R);
	upper += R * 0.62 * bow;
	lower -= R * 0.52 * bow;
	float lash = eye_lash > 0.002 && open > 0.2
		? pet_eye_lashes(q, R, upper, eye_lash * smoothstep(0.2, 0.6, open))
		: 0.0;

	if (ball <= 0.001 && lash <= 0.002) { return vec4(0.0); }

	vec3 L = pet_key_dir();

	// --- cornea -------------------------------------------------------------
	// The cornea is a second, tighter dome sitting on the eyeball over the iris,
	// and it travels with the gaze.
	vec2 gc = e3.xy * (1.0 - e1.x * 0.35) * R * 0.5;
	float CR = R * clamp(e1.x * 0.80 + 0.26, 0.2, 0.98);
	vec2 cq = q - gc;
	float cn = clamp(length(cq) / CR, 0.0, 1.0);

	float bz = sqrt(max(1.0 - clamp(r / R, 0.0, 1.0) * clamp(r / R, 0.0, 1.0), 1e-4));
	vec3 nb = normalize(vec3(q / max(R, 1e-5), bz));
	float czz = sqrt(max(1.0 - cn * cn, 1e-4));
	vec3 nc_raw = normalize(vec3(cq / max(CR, 1e-5) * 0.78, czz));
	// Blend the corneal dome back into the sphere at the limbus.
	vec3 n = normalize(mix(nb, nc_raw, smoothstep(1.0, 0.62, cn)));

	// --- corneal refraction -------------------------------------------------
	// The iris sits behind roughly a third of a radius of aqueous humour, so the
	// view ray bends before it reaches the iris: the iris reads displaced and
	// slightly magnified against the ball as the gaze swings.
	vec3 rd = refract(vec3(0.0, 0.0, -1.0), n, 1.0 / 1.336);
	vec2 iq = cq + rd.xy * (R * 0.34) / max(-rd.z, 0.25);

	float shift = length(gc) / max(R, 1e-5);
	float iris_r = R * e1.x * mix(1.0, 0.88, shift);
	float ir = length(iq / vec2(mix(1.0, 0.92, abs(e3.x)), 1.0));
	float t = clamp(ir / max(iris_r, 1e-5), 0.0, 1.0);
	float ang = atan(iq.y, iq.x);

	// --- sclera -------------------------------------------------------------
	vec3 col = sclera_color.rgb;
	// A sclera is a thin translucent shell over dark tissue: it warms toward the
	// canthi where it thins, and cools in the socket's shadow.
	float canthus = smoothstep(0.45, 1.0, abs(q.x) / R);
	col = mix(col, col * vec3(1.06, 0.80, 0.74), canthus * 0.55);
	col *= mix(0.52, 1.0, smoothstep(-R * 0.25, R * 0.85, -q.y));
	col *= mix(1.0, 0.70, e2.w);
	// Vessels, only near the corners, only just visible. Any more reads as gore.
	float vein = pet_fbm(vec2(q.x / R * 7.0, q.y / R * 2.2), 3);
	col = mix(col, col * vec3(1.0, 0.72, 0.68), canthus * clamp(vein, 0.0, 1.0) * 0.30);

	// --- iris ---------------------------------------------------------------
	float iris_mask = smoothstep(aa, -aa, ir - iris_r);
	if (iris_mask > 0.002) {
		// Radial fibres, plus crypts: the irregular pits between fibre bundles
		// that give a real iris its depth.
		float fibre = pet_fbm(vec2(ang * 11.0, t * 5.5), 3);
		vec2 crypt = pet_worley(vec2(ang * 8.5, t * 7.0));
		float pits = smoothstep(0.0, 0.55, crypt.y - crypt.x);

		vec3 iris = e2.rgb * mix(0.66, 1.34, fibre * 0.5 + 0.5);
		iris *= mix(0.84, 1.07, pits);
		// Collarette: the scalloped ridge where the pupillary zone meets the
		// ciliary zone. Brightest single feature inside the iris.
		float coll = smoothstep(0.10, 0.0, abs(t - (0.40 + 0.05 * fibre)));
		iris *= 1.0 + coll * 0.55;
		// Limbal ring: soft on the inside, hard on the outside.
		iris *= mix(1.16, 0.16, smoothstep(0.66, 1.0, t));
		// Pupillary ruff, the dark collar right at the aperture.
		iris = mix(iris * 0.40, iris, smoothstep(0.0, 0.30, t));
		// Backscatter: light through the pupil lights the far wall of the iris,
		// so a crescent opposite the key glows. This is the tell that the eye is
		// a volume and not a printed disc.
		vec2 ld = length(L.xy) > 1e-4 ? normalize(L.xy) : vec2(0.0, -1.0);
		float bs = clamp(dot(ir > 1e-6 ? iq / ir : vec2(0.0), -ld), 0.0, 1.0);
		iris += e2.rgb * pow(bs, 2.2) * (1.0 - smoothstep(0.35, 0.95, t)) * 0.85;

		col = mix(col, iris, iris_mask);
	}

	// --- pupil --------------------------------------------------------------
	float pr = iris_r * e1.y;
	vec2 pq = iq;
	pq.x /= max(mix(1.0, 0.16 + 0.5 * e1.y, e1.z), 0.05);
	float pd = length(pq) - pr;
	float pupil = smoothstep(aa, -aa, pd);
	col = mix(col, vec3(0.010, 0.010, 0.014), pupil);
	// The aperture margin catches a sliver of light on its lit side.
	col += e2.rgb * smoothstep(aa * 2.0, 0.0, abs(pd) - aa) * 0.18;

	// --- cornea shading -----------------------------------------------------
	float ndl = max(dot(n, L), 0.0);
	col *= mix(0.58, 1.18, ndl);

	// Catchlights. The primary sits where the sphere mirrors the key, which is
	// the half-vector direction — so it tracks the rig instead of being pinned.
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec2 keyp = normalize(L + V).xy * R * 0.86;
	vec2 kd = (q - keyp) / R;
	// A softly rounded rectangle reads as a window; a disc reads as a bead.
	float win = 1.0 - clamp((pow(abs(kd.x) / 0.19, 3.0) + pow(abs(kd.y) / 0.14, 3.0)), 0.0, 1.0);
	col += key_color.rgb * smoothstep(0.0, 0.55, win) * 1.15;
	col += vec3(1.0) * smoothstep(0.35, 0.95, win) * 0.9;
	// A broad, dim reflection of the sky fills the upper dome.
	float sky = smoothstep(0.9, 0.0, length((q - vec2(-R * 0.22, -R * 0.30)) / R) / 0.7);
	col += ambient_tint.rgb * sky * 0.20;
	// Total internal reflection piles a faint bright ring up at the limbus.
	col += key_color.rgb * smoothstep(0.80, 1.0, r / R) * (1.0 - smoothstep(0.97, 1.0, r / R)) * 0.22;

	// Upper lid contact shadow on the ball. A wet sphere set into a socket is
	// always darkest right under the lid, and the gradient is what tells the eye
	// it is looking at a sphere rather than a disc.
	col *= mix(1.0, 0.30, smoothstep(R * 0.35, -R * 0.85, q.y));

	// --- lids and tear film -------------------------------------------------
	float lid = smoothstep(-aa, aa, q.y - upper) * smoothstep(aa, -aa, q.y - lower);
	float alpha = ball * lid;

	// The meniscus: the tear film piles up in the corner where lid meets ball.
	// Upper is a dark wet line in shadow, lower catches the key and is the
	// brightest thing on the whole eye after the catchlight.
	float mu = smoothstep(R * 0.13, 0.0, abs(q.y - upper));
	float ml = smoothstep(R * 0.11, 0.0, abs(q.y - lower));
	col *= mix(1.0, 0.22, mu * 0.9);
	col = mix(col, col * 0.55, ml * 0.4);
	col += key_color.rgb * smoothstep(R * 0.075, R * 0.015, abs(q.y - lower + R * 0.045))
		* 0.55 * smoothstep(0.25, 0.6, open);

	// --- lashes -------------------------------------------------------------
	if (lash > 0.002) {
		vec3 lash_col = vec3(0.05, 0.042, 0.040);
		col = mix(col, lash_col, clamp(lash, 0.0, 1.0));
		alpha = max(alpha, clamp(lash, 0.0, 1.0) * 0.95);
	}

	// --- socket -------------------------------------------------------------
	// The eye sits *in* the head. Without a ring of shadowed lid skin hugging
	// the ball, the disc reads as a bead glued to the face however good its
	// interior is — and the ring has to be drawn here, in the eye pass, because
	// only here is the ball's exact edge known. Deepest under the brow, where a
	// real orbit overhangs.
	float socket = smoothstep(R * 1.34, R * 0.94, r) * (1.0 - ball);
	float overhang = mix(0.35, 1.0, smoothstep(R * 0.6, -R * 0.9, q.y));
	float sa = socket * overhang * mix(0.30, 0.62, e2.w);

	vec3 out_rgb = mix(vec3(0.055, 0.040, 0.035), col, alpha);
	float out_a = alpha + sa * (1.0 - alpha);
	return vec4(out_rgb, clamp(out_a, 0.0, 1.0));
}

#endif
