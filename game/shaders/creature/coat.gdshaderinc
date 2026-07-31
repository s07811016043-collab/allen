#ifndef PETALIA_COAT_INC
#define PETALIA_COAT_INC

#include "res://shaders/creature/noise.gdshaderinc"

// Surface families for Petalia's implicit creatures.
//
// Every one of these is built from *shapes*, never from a blob of noise. A coat
// made of fbm reads as a fuzzy brown cloud no matter how much you tune it,
// because the eye is looking for strands and fbm has none. So: fur is lanes of
// strands with their own widths, lengths and phases; feathers are barbs indexed
// off the rachis; scales are shingled plates with a leading edge.
//
// Two rules make all of it hold together.
//
// 1. Detail is authored at fixed frequencies in *rig space* and each tier fades
//    in only once its pitch is a few pixels wide. That is what lets the same
//    coat read as hair at 200 px and at 800 px without shimmering at either.
// 2. Feature profiles use `pet_ridge`, whose derivative is analytic, so surface
//    normals come out of algebra rather than out of finite-differencing noise.
//    Differenced noise is where the "muddy" look in soft-lit fur comes from.

struct Coat {
	float occ;    // strand-level self-shadowing; gaps between hairs are dark
	vec2  slope;  // rig-space normal perturbation
	float tint;   // per-strand albedo modulation, signed
	float glint;  // per-strand sparkle, drives the TRT lobe
	float spec;   // per-strand multiplier on the whole hair lobe
	float tilt;   // per-strand deflection of the strand tangent, radians
	float tuft;   // low-frequency clump mask, hand-sized
};

// Generic per-family micro-surface result, for everything that is not fur.
struct Surf {
	vec2  slope;
	float occ;
	float tint;
	float spec;   // multiplier on the specular lobe
	float extra;  // family-specific: iridescence weight, wetness, tip mask
};


// ---------------------------------------------------------------------------
// Fur
// ---------------------------------------------------------------------------

// A lane tier is honest down to roughly two pixels per lane; below that it can
// only alias. Being timid about this threshold is what emptied the coat at body
// scale: at ~330 px per rig unit the guard tier is under three pixels a lane, so
// a cutoff at four or five removes every tier the body has and leaves nothing
// but the clump field — which is exactly the smooth-clay read.
float pet_tier_fade(float px_per_lane) {
	return smoothstep(1.25, 2.55, px_per_lane);
}


// One tier of fibres in the groom frame (`t.x` along the hair, `t.y` across).
//
// `pitch` is fibres per rig unit and `aspect` is how long each one is in units
// of its own width — a guard hair is roughly fifteen times as long as it is
// wide, a lock only four or five. The across-hair coordinate is warped *before*
// it is quantised, which makes neighbouring lanes converge, and that convergence
// is clumping. `clump` is measured in lane widths so a tier clumps by the same
// visible amount whatever its pitch.
float pet_fibre_tier(vec2 t, float pitch, float clump, float aspect, float seed,
		out float dcross, out float rnd, out float lean) {
	// The warp has to *diverge* between neighbouring lanes, not shift them as a
	// block: a low-frequency warp with a large amplitude slides whole bands of
	// parallel lanes together, and smoothly wavy parallel lines are wood grain.
	// Two octaves, the finer one only a few lanes across, is what makes lanes
	// merge into each other instead of travelling in formation.
	float w = pet_noise(vec2(t.x * pitch * 0.055 + seed * 3.7, t.y * pitch * 0.11))
		+ 0.45 * pet_noise(vec2(t.x * pitch * 0.20 + seed, t.y * pitch * 0.34));
	float y = t.y * pitch + w * clump;
	float lane = floor(y);
	float f = fract(y) - 0.5;
	rnd = pet_hash1(vec2(lane, seed));

	float width = mix(0.20, 0.42, rnd);
	float dprofile;
	float core = pet_ridge(abs(f) / width, dprofile);

	// A fibre is a finite object, and a lane left running forever is a ruled
	// line. So each lane is chopped into fibre-length cells, and the phase of
	// the chop is offset per lane so neighbours start and end at different
	// places instead of forming a seam across the coat. Each cell draws its own
	// length from the hash: some fibres lie flat against the next one, some end
	// in a clear gap.
	float span = t.x * pitch / max(aspect, 1.0) + rnd * 11.0;
	float cell = floor(span);
	float rc = pet_hash1(vec2(cell, lane * 0.61 + seed));
	float dseg;
	float seg = 0.22 + 0.78
		* pet_ridge(abs(fract(span) - 0.5) / mix(0.30, 0.58, rc), dseg);

	// No two hairs point exactly the same way, and that scatter is the whole
	// reason a coat glitters instead of gleaming: it splits one broad sheen into
	// hundreds of individual fibre highlights. Half of it is per-strand and half
	// follows the clump, so locks catch the key as groups the way a real one
	// does. Returned unscaled; the caller decides the angle.
	lean = (rnd - 0.5) * 2.0 + w * 0.9;

	dcross = dprofile * sign(f) / width * pitch * seg;
	return core * seg;
}


// The layered coat.
//
// Four scales, because a pelt has four, and the ladder is anchored at the top by
// physics rather than by taste. A cat's guard hair is about a tenth of a
// millimetre across on an animal a quarter of a metre tall, so an individual
// hair is sub-pixel at every size a desktop pet is ever drawn at: at body scale
// it is not the hair the eye resolves, it is the *lock* — a few dozen hairs
// travelling together, roughly ten hairs wide. That fixes the coarsest tier at a
// tenth of the guard pitch, and everything finer arrives only as the player
// zooms in.
//
// The lock tier is what makes or breaks the body-scale read, and it is a fibre
// tier rather than a blob of fractal noise for one reason: fractal noise has no
// strands in it, so it can only ever be soft blotches, and soft blotches on a
// brown animal look like wet clay. But it is a *short* fibre — four or five
// times as long as it is wide, not fifteen — because a lock is a stubby thing,
// and long ones would just be corduroy at a bigger scale.
Coat pet_fur(vec2 p, vec2 groom, float density, float px, float fluffy) {
	vec2 across = vec2(-groom.y, groom.x);
	vec2 t = vec2(dot(p, groom), dot(p, across));

	Coat c;

	float pitch_g = 135.0 * density;
	float pitch_c = pitch_g * 0.10;
	float pitch_m = 340.0 * density;
	float pitch_u = 810.0 * density;

	float fc = pet_tier_fade(px / pitch_c);
	float fg = pet_tier_fade(px / pitch_g);
	float fm = pet_tier_fade(px / pitch_m);
	float fu = pet_tier_fade(px / pitch_u);

	float dc = 0.0, dg = 0.0, dm = 0.0, du = 0.0;
	float rc = 0.5, rg = 0.5, rm = 0.5, ru = 0.5;
	float lc = 0.0, lg = 0.0, lm = 0.0, lu = 0.0;
	float hc = 0.0, hg = 0.0, hm = 0.0, hu = 0.0;
	if (fc > 0.002) { hc = pet_fibre_tier(t, pitch_c, 1.6, 4.5, 31.0, dc, rc, lc); }
	if (fg > 0.002) { hg = pet_fibre_tier(t, pitch_g, 2.6, 15.0, 1.0, dg, rg, lg); }
	if (fm > 0.002) { hm = pet_fibre_tier(t, pitch_m, 2.2, 17.0, 7.0, dm, rm, lm); }
	if (fu > 0.002) { hu = pet_fibre_tier(t, pitch_u, 1.8, 19.0, 19.0, du, ru, lu); }

	// The coat parts along the locks, so the finer tiers thin out where a lock
	// edge runs. Modulating *coverage* like this is what gives the coat a second
	// scale of structure, and it costs nothing in albedo.
	float lockmask = 0.35 + 0.65 * hc;
	c.tuft = hc;

	// Whichever tier is currently the finest resolvable is the one the eye
	// should be reading, so each tier hands most of its weight to the next one
	// down as that one arrives. Holding every tier at a fixed share is what
	// leaves coarse brush-strokes sitting on top of a close-up.
	float wc = fc * (1.0 - 0.70 * fg);
	float wg = fg * (1.0 - 0.70 * fm) * mix(0.55, 1.0, lockmask);
	float wm = fm * (1.0 - 0.70 * fu) * mix(0.55, 1.0, lockmask);
	float wu = fu * mix(0.55, 1.0, lockmask);
	float wsum = wc + wg + wm + wu;
	float inv = 1.0 / max(wsum, 1e-4);
	// How much resolvable fibre structure there is at all. Every fibre-derived
	// term fades toward its neutral value with this, so a pet shrunk to a taskbar
	// icon loses its coat cleanly instead of dissolving into low-frequency mush.
	float res = min(wsum, 1.0);

	float cover = (wc * hc + wg * hg + wm * hm + wu * hu) * inv;

	// The hair tiers are kept apart from the lock tier for everything specular.
	// Blending them into one coverage figure lets the lock — which outweighs them
	// whenever the pet is small — set the frequency of the highlight break-up
	// too, and a highlight breaking at lock scale is a set of broad soft bands,
	// which is the smooth-clay read wearing a different hat. The diffuse can have
	// the blend; the gloss has to be at fibre frequency or it says nothing.
	float wf = wg + wm + wu;
	float finv = 1.0 / max(wf, 1e-4);
	float fine = (wg * hg + wm * hm + wu * hu) * finv;
	float lean = (wg * lg + wm * lm + wu * lu) * finv;
	float rnd = (wg * rg + wm * rm + wu * ru) * finv;
	float fres = min(wf, 1.0);

	// Between the fibres you are looking down at shadowed skin; on one you are
	// looking at a lit fibre. The mean of `cover` sits near a fifth, not a half —
	// narrow fibres with gaps between them — so the endpoints are chosen to
	// average out near unity. Getting that wrong is not a subtle bug: it darkens
	// the whole animal by a fifth and every value in the lighting rig then has to
	// be re-tuned around a coat.
	c.occ = mix(1.0, mix(0.86, 1.30, cover), fluffy * res);

	// Slopes are divided by their own pitch so a fine tier does not tilt the
	// normal harder than a coarse one just for being denser.
	c.slope = across * fluffy * inv * (0.045 * wc * dc / pitch_c
		+ 0.055 * wg * dg / pitch_g + 0.050 * wm * dm / pitch_m
		+ 0.040 * wu * du / pitch_u);

	// Albedo now carries almost none of the coat. Real hair is one pigment: what
	// changes from fibre to fibre is which way it points, not what colour it is.
	// Painting the variation into albedo is what produced the soft blotches that
	// made the animal look wet, so the strand read lives in `spec` and `tilt`
	// below and this is left as the faint pigment drift a lock has.
	c.tint = (rnd - 0.5) * 0.50 * mix(0.35, 1.0, fres);

	// The visible structure of a short coat is specular. Each fibre is a tiny
	// cylinder: the highlight breaks across it, dies in the gap to the next one,
	// and comes back. `spec` is that break, `tilt` deflects the fibre tangent so
	// neighbours catch the key at slightly different angles, and `glint` drives
	// the tinted second lobe. The lock only shades it — a lock lying against the
	// light is duller than one standing away from it — it never sets its scale.
	c.glint = rnd * rnd;
	c.spec = mix(1.0, mix(0.26, 2.90, fine), fres) * mix(0.82, 1.16, hc);
	c.tilt = lean * 0.30 * fres;
	return c;
}


// Silhouette fringe.
//
// Strands are indexed by *arc position along the outline*, so every hair is a
// separate pointed spike with its own length, and the gaps between them let the
// base silhouette show through. Displacing the field by a blob of noise instead
// is what produces the blurred-edge look this replaces.
//
// Returns the outward displacement in units of coat length; `cover` reports how
// strongly the pixel belongs to a spike rather than to the body proper, so the
// caller can make hair tips translucent.
float pet_fur_fringe(vec2 p, vec2 grad, vec2 groom, float density, float px,
		float sharp, out float cover) {
	vec2 across = vec2(-grad.y, grad.x);
	// Shear the lane coordinate along the outward normal so spikes lean the way
	// the coat is groomed instead of standing up like a brush.
	float arc = dot(p, across) + dot(p, grad) * dot(groom, across) * 1.4;

	float pitch_a = 92.0 * density;
	float pitch_b = 230.0 * density;
	float fa = pet_tier_fade(px / pitch_a) * sharp;
	float fb = pet_tier_fade(px / pitch_b) * sharp;

	float total = 0.0;
	cover = 0.0;

	if (fa > 0.002) {
		// Warping before quantising clumps the fringe into locks, the way a
		// real coat parts along the silhouette. The warp is slow relative to the
		// lane pitch, so whole groups of hairs lean together.
		float s = arc * pitch_a + pet_noise(vec2(arc * 5.0, 3.1)) * 2.2;
		float f = fract(s) - 0.5;
		float r = pet_hash1(vec2(floor(s), 5.0));
		// Narrow spikes with real gaps between them. Wide ones overlap into a
		// continuous skirt, and a continuous skirt is a blurred outline — which
		// is the thing this whole function exists to avoid.
		float w = mix(0.13, 0.32, r);
		float taper = clamp(1.0 - abs(f) / w, 0.0, 1.0);
		// Squaring the length keeps most hairs short with a few standing proud.
		// A flat distribution reads as a comb.
		total += fa * (0.10 + 0.90 * r * r) * taper * (1.0 - 0.45 * fb);
		cover = max(cover, taper * fa);
	}
	if (fb > 0.002) {
		float s = arc * pitch_b + pet_noise(vec2(arc * 14.0, 8.7)) * 1.6;
		float f = fract(s) - 0.5;
		float r = pet_hash1(vec2(floor(s), 11.0));
		float w = mix(0.15, 0.34, r);
		float taper = clamp(1.0 - abs(f) / w, 0.0, 1.0);
		total += fb * (0.08 + 0.44 * r * r) * taper * 0.5;
		cover = max(cover, taper * fb * 0.8);
	}
	// A thin continuous skirt under the spikes: real coats have down between the
	// guard hairs, and without it the silhouette reads as a saw blade. It stays
	// thin, though — every unit of skirt is a unit of blur on the outline.
	return total + 0.045;
}


// Marschner-style hair specular.
//
// R is the reflection off the outside of the fibre: tight, white, and shifted
// toward the root. TRT has passed through the hair twice, so it comes back
// broader, tinted by the coat's own pigment, shifted toward the tip, and broken
// up into glints by the fibre's irregular cross-section. Having both is why a
// real coat has gloss *structure* rather than a uniform sheen.
float pet_strand_lobe(vec3 tangent, vec3 l, vec3 v, float rough) {
	float tl = dot(tangent, l);
	float tv = dot(tangent, v);
	float s = sqrt(max(0.0, 1.0 - tl * tl)) * sqrt(max(0.0, 1.0 - tv * tv)) - tl * tv;
	return pow(clamp(s, 0.0, 1.0), max(1.0, 2.0 / max(rough * rough, 1e-3)));
}

vec3 pet_hair_spec(vec3 tangent, vec3 n, vec3 l, vec3 v, float rough,
		vec3 tint, float glint) {
	vec3 tr = normalize(tangent + n * 0.10);
	vec3 ttrt = normalize(tangent - n * 0.16);
	// The R lobe has to stay *broad*. Narrowed to a mirror it only fires where
	// the key happens to sit at the reflection angle, which on a side-on animal
	// is nowhere on the flank — so the per-fibre break-up that this whole model
	// exists to produce would be invisible across the entire torso.
	float r = pet_strand_lobe(tr, l, v, rough * 0.62);
	float trt = pet_strand_lobe(ttrt, l, v, rough * 1.20);
	return vec3(1.0) * r * 0.24 + tint * trt * (0.26 + glint * 0.70);
}


// ---------------------------------------------------------------------------
// Feather
// ---------------------------------------------------------------------------

// Barbs indexed off the rachis. `arc` runs along the shaft and `v` is the signed
// distance out to the vane edge, both in rig units, so barbs wrap the part's
// spine instead of being stamped in screen space. Barbs lean toward the tip and
// separate into distinct points near the trailing edge — the separations are
// what stop a wing reading as a painted shell.
Surf pet_feather(float arc, float v, float u, float density, float px) {
	Surf s;
	float pitch = 150.0 * density;
	float fade = smoothstep(1.8, 4.2, px / pitch);

	float lane = (arc + abs(v) * 1.6) * pitch;
	float f = fract(lane) - 0.5;
	float r = pet_hash1(vec2(floor(lane), 4.0));
	float w = mix(0.28, 0.46, r);
	float dp;
	float barb = pet_ridge(abs(f) / w, dp) * fade;

	// Barbs unzip toward the vane edge: coverage falls away and the gaps open.
	float unzip = smoothstep(0.55, 1.0, u);
	barb *= 1.0 - unzip * (0.35 + 0.65 * r);

	// The rachis is a raised shaft along the spine of the part.
	float rachis = smoothstep(0.30, 0.0, u);

	s.slope = vec2(dp * sign(f) / w * pitch * fade * 0.0016, 0.0);
	s.occ = mix(1.0 - 0.30 * fade, 1.04, barb) * mix(1.0, 1.10, rachis);
	s.tint = (r - 0.5) * 0.35 * fade + rachis * 0.18;
	s.spec = mix(0.7, 1.35, barb);
	// Iridescence is strongest on the smooth outer face of the vane and dies in
	// the gaps, so it tracks barb coverage rather than being painted flat.
	s.extra = barb * (1.0 - rachis * 0.6);
	return s;
}


// ---------------------------------------------------------------------------
// Scale
// ---------------------------------------------------------------------------

// Overlapping keratin plates. Rows run along the part's spine and are staggered
// half a plate per row; each plate's leading edge (toward +arc, i.e. toward the
// head) sits over the plate behind it, so the trailing edge carries a hard
// occlusion line and the leading edge carries a sharp specular.
//
// `parallax` shifts the tiling by the body normal, which makes the plates look
// like they have thickness as the body curves away — the cheapest honest
// parallax available when the view vector is constant.
Surf pet_scale(float arc, float v, vec2 parallax, float density, float px) {
	Surf s;
	float size = 0.030 / max(density, 0.05);
	float fade = smoothstep(2.5, 6.0, px * size);

	vec2 cell = vec2(arc, v) / size + parallax * 0.55;
	float row = floor(cell.y);
	cell.x += fract(row * 0.5);

	vec2 g = fract(cell) - 0.5;
	float rnd = pet_hash1(vec2(floor(cell.x), row));

	// Rounded-diamond plate: a lens shape reads far more like keratin than a
	// square, and its long axis running along the body matches real squamation.
	float plate = 1.0 - clamp(abs(g.x) * 1.55 + abs(g.y) * 2.1, 0.0, 1.0);
	float dp;
	float dome = pet_ridge(1.0 - clamp(plate * 1.35, 0.0, 1.0), dp);

	// Shingling: height ramps from the buried trailing edge to the exposed
	// leading edge, then drops off a cliff at the plate boundary.
	float shingle = smoothstep(-0.5, 0.35, g.x);
	float lip = smoothstep(0.5, 0.36, abs(g.x));

	s.slope = vec2(-dp * 1.35 * sign(g.x), -dp * 1.35 * sign(g.y) * 0.55)
		* fade * 0.9 + vec2(shingle - 0.5, 0.0) * fade * 0.55;
	s.occ = mix(1.0, mix(0.62, 1.08, shingle) * mix(0.80, 1.0, lip), fade);
	s.tint = (rnd - 0.5) * 0.30 * fade + (dome - 0.5) * 0.22 * fade;
	// Speculars break at every plate boundary, which is what makes a lizard
	// glitter instead of gleam.
	s.spec = mix(1.0, mix(0.35, 1.9, dome * shingle), fade);
	s.extra = dome * fade;
	return s;
}


// ---------------------------------------------------------------------------
// Skin
// ---------------------------------------------------------------------------

// Bare hide: nose leather, paw pads, bellies. Two scales of pebbling with a
// crease network between the pebbles, plus a wet film. Noses are wet and paw
// pads are not, and the caller distinguishes them by part radius — a nose is
// always the smallest skin volume on the animal.
Surf pet_skin(vec2 p, float density, float px, float wet) {
	Surf s;
	float pitch = 210.0 * density;
	float fade = smoothstep(2.0, 5.0, px / pitch);

	vec2 w1 = pet_worley(p * pitch);
	float crease = smoothstep(0.0, 0.22, w1.y - w1.x);
	vec2 w2 = pet_worley(p * pitch * 2.7 + 13.0);
	float fine = smoothstep(0.0, 0.30, w2.y - w2.x);

	float pebble = mix(crease, crease * 0.6 + fine * 0.4, 0.5);
	// Creases are the only thing here with real depth, so they drive the normal;
	// the pebbles themselves are almost flat on real leather. The amplitude has
	// to stay small: a difference-of-worley gradient is enormous at the cell
	// walls, and left unbounded it turns nose leather into a net of black wire.
	float e = 1.0 / max(pitch, 1.0);
	vec2 wx = pet_worley((p + vec2(e, 0.0)) * pitch);
	vec2 wy = pet_worley((p + vec2(0.0, e)) * pitch);
	float cx = smoothstep(0.0, 0.22, wx.y - wx.x);
	float cy = smoothstep(0.0, 0.22, wy.y - wy.x);

	s.slope = clamp(vec2(cx - crease, cy - crease) * 3.5, vec2(-0.28), vec2(0.28)) * fade;
	s.occ = mix(1.0, mix(0.80, 1.04, pebble), fade);
	s.tint = (pebble - 0.5) * 0.20 * fade;
	// A wet nose is a mirror with a rough edge: hot narrow highlight, and the
	// albedo underneath goes darker and more saturated as the film soaks it.
	s.spec = mix(1.0, 3.4, wet) * mix(0.9, 1.15, pebble);
	s.extra = wet;
	return s;
}


// ---------------------------------------------------------------------------
// Claw
// ---------------------------------------------------------------------------

// Hard translucent keratin. A claw is a lens: light enters the side, pipes along
// the fibre and leaves at the tip, so the tip is brighter and warmer than the
// base while the base carries the dark quick. `u` is 0 at the spine and 1 at the
// silhouette; `tip01` is 0 at the root and 1 at the point.
Surf pet_claw(float u, float tip01) {
	Surf s;
	// A crisp ridge runs along the top of the claw and catches the key.
	float ridge = smoothstep(0.45, 0.0, u);
	s.slope = vec2(0.0);
	s.occ = mix(0.86, 1.06, ridge);
	// The quick: darker, pinker keratin at the root, fading out before the tip.
	s.tint = -0.30 * smoothstep(0.35, 0.0, tip01) + 0.12 * ridge;
	s.spec = mix(0.9, 2.6, ridge);
	// Light piping toward the point.
	s.extra = smoothstep(0.25, 1.0, tip01);
	return s;
}

#endif
