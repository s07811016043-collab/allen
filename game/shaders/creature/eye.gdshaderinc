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
// `par` is this eye's offset from the centre of the pair, in units of its own
// radius. Two eyes sit at different places on a curved face and therefore see
// the same lamp from different angles, so the reflection of it cannot land in
// the same spot on both. Without that the catchlights are identical on every
// eye of every creature, which reads as two stickers rather than two wet
// spheres — and it is the first thing a viewer notices, because it is the only
// part of a face that is expected to be asymmetric.
vec4 pet_shade_eye(vec4 e0, vec4 e1, vec4 e2, vec4 e3, vec2 p, float unit_px,
		vec2 par) {
	float R = e0.z;
	if (R <= 1e-5) { return vec4(0.0); }

	vec2 qr = p - e0.xy;
	float ct = cos(e0.w);
	float st = sin(e0.w);
	vec2 q = vec2(qr.x * ct - qr.y * st, qr.x * st + qr.y * ct);
	par = vec2(par.x * ct - par.y * st, par.x * st + par.y * ct);

	float r = length(q);
	float aa = max(unit_px * 0.8, R * 0.006);
	float ball = smoothstep(aa, -aa, r - R);

	// Lids first: the lash band reaches above the ball, so alpha has to be able
	// to exist outside it.
	float open = clamp(e3.z * (1.0 - e1.w), 0.0, 1.0);
	// Rig space has +y down, so the upper lid lives at negative y.
	//
	// The lid is placed against the *iris*, not against the ball, and that is the
	// whole fix for the stare. Every resting mammal carries its upper lid over the
	// top of the iris; an iris that clears the lid completely is a full circle of
	// colour, and a full circle of colour is the face of something that has just
	// been startled. Held permanently, it is the difference between a cat and a
	// cartoon. Roughly the top sixth of the iris disappears under the lid at rest,
	// which is 30% of the iris radius measured from its top edge.
	//
	// Floored against the ball so a species with a small iris — a bird, a
	// gecko — is not squinted shut by a rule written for a cat.
	float iris_top = R * e1.x;
	float upper = -mix(R * 0.02, max(iris_top * 0.70, R * 0.55), open)
		+ brow_raise * R * 0.13 - brow_furrow * R * 0.17;
	float lower = R * mix(-0.02, 0.90, open);
	// Lids are arcs, not horizontal cuts. A straight lid line crossed with a
	// circle gives the faceted, vaguely hexagonal eye that betrays every cheap
	// procedural face; both lids have to sag toward the corners. The upper bow is
	// gentler than it was because the lid now starts lower down the ball, and the
	// two together would otherwise shut the eye at the corners.
	float bow = (q.x / R) * (q.x / R);
	upper += R * 0.46 * bow;
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

	// Catchlight. The reflection of the key in a wet sphere: where it sits is set
	// by the mirror direction, and what shape it is comes out of how the sphere
	// curves underneath it.
	//
	// The shape is the part that was wrong. A rounded rectangle of constant size,
	// stamped at the same offset on both eyes, is a decal on glass — it does not
	// move with the ball, it does not foreshorten, and having it identical on the
	// pair is the single loudest "this was drawn once and pasted twice" signal a
	// face can send. What a sphere actually returns is an ellipse: the further the
	// highlight lies from the centre, the more surface each pixel of it covers, so
	// it squashes along the radius while keeping its width across it.
	vec3 V = vec3(0.0, 0.0, 1.0);
	vec2 keyp = (normalize(L + V).xy + par * 0.26) * R * 0.72;
	vec2 kd = (q - keyp) / R;
	float rr = clamp(length(keyp) / R, 0.0, 0.98);
	vec2 rdir = rr > 1e-4 ? normalize(keyp) : vec2(0.0, -1.0);
	float k_rad = dot(kd, rdir) / (0.150 * sqrt(max(1.0 - rr * rr, 0.06)));
	float k_tan = dot(kd, vec2(-rdir.y, rdir.x)) / 0.185;
	float ell = length(vec2(k_rad, k_tan));
	// Two lobes, because a real catchlight has a core and a bloom around it, and
	// the bloom is what stops the core reading as a cut-out hole.
	col += key_color.rgb * smoothstep(1.7, 0.35, ell) * 0.80;
	col += vec3(1.0) * smoothstep(0.95, 0.10, ell) * 0.95;
	// A broad, dim reflection of the sky fills the upper dome.
	float sky = smoothstep(0.9, 0.0, length((q - vec2(-R * 0.22, -R * 0.30)) / R) / 0.7);
	col += ambient_tint.rgb * sky * 0.20;
	// Total internal reflection piles a faint bright ring up at the limbus.
	col += key_color.rgb * smoothstep(0.80, 1.0, r / R) * (1.0 - smoothstep(0.97, 1.0, r / R)) * 0.22;

	// Upper lid contact shadow. A lid is a fold of skin lying *on* a wet sphere,
	// not a hole cut in one, and there is always a band of shadow under it —
	// deepest right at the margin, gone by the middle of the iris. Keyed to the
	// lid's own arc rather than to a fixed height on the ball, so it follows the
	// lid as it blinks and as the brow moves instead of sliding out from under it.
	col *= mix(1.0, 0.30, smoothstep(R * 0.62, 0.0, q.y - upper));
	// And the socket's own falloff on top, which is about the ball, not the lid.
	col *= mix(1.0, 0.72, smoothstep(R * 0.35, -R * 0.95, q.y));

	// The tear duct. A cat's inner canthus is a small bare pink notch where the
	// two lid margins meet, and it is worth its cost for one reason: it is the
	// only asymmetry on an eye. A perfectly symmetric eye is a stamped shape
	// however good its interior is. The rig convention puts forward at +x, so the
	// nasal corner is always the +x one and no species has to say so.
	float nx = q.x / R;
	float duct = smoothstep(0.40, 0.86, nx) * smoothstep(0.46, 0.08, abs(q.y / R - 0.12));
	col = mix(col, mix(vec3(0.55, 0.30, 0.29), col, 0.30), duct * 0.80);

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
