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

// One tier of strands in the groom frame (`t.x` along the hair, `t.y` across).
//
// `pitch` is strands per rig unit. The across-hair coordinate is warped by a
// slow field *before* it is quantised, which makes neighbouring lanes converge:
// that convergence is clumping, and clumping is most of the difference between
// fur and carpet. `clump` is measured in lane widths, so a tier clumps by the
// same visible amount whatever its pitch.
float pet_hair_tier(vec2 t, float pitch, float clump, float seed,
		out float dcross, out float rnd) {
	// The warp's across-frequency is tied to the pitch so every tier clumps by
	// the same *visible* amount. Too slow a warp shifts whole bands of lanes
	// together and they stay parallel; the point is for neighbours to converge.
	float w = pet_noise(vec2(t.x * pitch * 0.030 + seed * 3.7, t.y * pitch * 0.15));
	float y = t.y * pitch + w * clump;
	float lane = floor(y);
	float f = fract(y) - 0.5;
	rnd = pet_hash1(vec2(lane, seed));

	float width = mix(0.22, 0.46, rnd);
	float dprofile;
	float core = pet_ridge(abs(f) / width, dprofile);
	// Strands overlap and fade along their own length. Without this a lane is a
	// ruled line, which is exactly how combed-noise fur ends up looking like
	// wood grain.
	float seg = 0.76 + 0.24 * sin(t.x * pitch * 1.6 + rnd * PETALIA_TAU);

	dcross = dprofile * sign(f) / width * pitch * seg;
	return core * seg;
}


// The layered coat.
//
// Four scales, because a pelt has four. Clumps are the locks a hand would part
// and they are visible at every size the pet is ever drawn at; guard hairs are
// the tier the eye reads as "fur" on the desktop; the midcoat and undercoat only
// resolve when the player zooms in, and fade out below Nyquist rather than
// aliasing into sparkle. Each tier shadows the ones under it, which is where the
// depth in a real coat comes from.
Coat pet_fur(vec2 p, vec2 groom, float density, float px, float fluffy) {
	vec2 across = vec2(-groom.y, groom.x);
	vec2 t = vec2(dot(p, groom), dot(p, across));

	Coat c;

	// Locks are the one tier that must not be lanes. Real fur parts into
	// irregular clumps that merge and split; parallel lanes at this scale read as
	// wood grain no matter how they are shaded. So the lock field is a stretched
	// fractal instead, and it modulates the tiers above it rather than shading
	// directly.
	float lock = pet_fbm(vec2(t.x * 5.0, t.y * 23.0), 3);
	c.tuft = lock;

	// Real hair on a cat is a tenth of a millimetre across — sub-pixel at every
	// size the pet is ever drawn at. So the interior coat is deliberately fine
	// and low contrast, and the *silhouette* carries the visible-strand read,
	// which is exactly where you see individual hairs on a real animal. Coarse
	// high-contrast lanes across the body are what make procedural fur look like
	// straw.
	float pitch_g = 105.0 * density;
	float pitch_m = 240.0 * density;
	float pitch_u = 540.0 * density;

	// Fade a tier in as soon as its pitch clears ~2.5 px. Below that it is
	// sub-Nyquist and can only alias.
	float fg = smoothstep(2.1, 4.6, px / pitch_g);
	float fm = smoothstep(2.1, 4.6, px / pitch_m);
	float fu = smoothstep(2.1, 4.6, px / pitch_u);

	float dg = 0.0, dm = 0.0, du = 0.0;
	float rg = 0.5, rm = 0.5, ru = 0.5;
	float hg = 0.0, hm = 0.0, hu = 0.0;
	if (fg > 0.002) { hg = pet_hair_tier(t, pitch_g, 2.6, 1.0, dg, rg); }
	if (fm > 0.002) { hm = pet_hair_tier(t, pitch_m, 2.2, 7.0, dm, rm); }
	if (fu > 0.002) { hu = pet_hair_tier(t, pitch_u, 1.8, 19.0, du, ru); }

	// The coat thins where the locks part, so the shadowed undercoat shows.
	float lockmask = 0.5 + 0.5 * lock;
	float guard = hg * (0.55 + 0.45 * lockmask);

	// The finer tiers carry more weight than the coarse one, so whichever tier
	// is currently the finest resolvable is the one that dominates the read.
	float wg = 0.30 * fg;
	float wm = 0.40 * fm;
	float wu = 0.30 * fu;
	float wsum = wg + wm + wu;
	float cover = wsum > 1e-4 ? (wg * guard + wm * hm + wu * hu) / wsum : lockmask;

	// Between the strands you are looking down at shadowed skin; on a strand you
	// are looking at a lit fibre. The spread of that is the coat's contrast, and
	// it wants to stay modest — hair reads through direction and count, not
	// through how black the gaps are.
	c.occ = mix(1.0 - 0.30 * fluffy * min(wsum * 3.0, 1.0), 1.05, cover)
		* mix(0.90, 1.07, lockmask);

	// Slopes are divided by their own pitch so a fine tier does not tilt the
	// normal harder than a coarse one just for being denser.
	c.slope = across * fluffy * (0.048 * wg * dg / pitch_g
		+ 0.042 * wm * dm / pitch_m + 0.030 * wu * du / pitch_u);

	c.tint = lock * 0.60 + (rg - 0.5) * 0.22 * fg + (rm - 0.5) * 0.16 * fm;
	c.glint = rg * rg * fg;
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
		out float cover) {
	vec2 across = vec2(-grad.y, grad.x);
	// Shear the lane coordinate along the outward normal so spikes lean the way
	// the coat is groomed instead of standing up like a brush.
	float arc = dot(p, across) + dot(p, grad) * dot(groom, across) * 1.4;

	float pitch_a = 78.0 * density;
	float pitch_b = 205.0 * density;
	float fa = smoothstep(1.5, 3.6, px / pitch_a);
	float fb = smoothstep(1.5, 3.6, px / pitch_b);

	float total = 0.0;
	cover = 0.0;

	if (fa > 0.002) {
		// Warping before quantising clumps the fringe into locks, the way a
		// real coat parts along the silhouette. The warp is slow relative to the
		// lane pitch, so whole groups of hairs lean together.
		float s = arc * pitch_a + pet_noise(vec2(arc * 5.0, 3.1)) * 2.2;
		float f = fract(s) - 0.5;
		float r = pet_hash1(vec2(floor(s), 5.0));
		float w = mix(0.17, 0.40, r);
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
		float w = mix(0.20, 0.42, r);
		float taper = clamp(1.0 - abs(f) / w, 0.0, 1.0);
		total += fb * (0.08 + 0.44 * r * r) * taper * 0.5;
		cover = max(cover, taper * fb * 0.8);
	}
	// A thin continuous skirt under the spikes: real coats have down between the
	// guard hairs, and without it the silhouette reads as a saw blade.
	return total + 0.07;
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
	float r = pet_strand_lobe(tr, l, v, rough * 0.40);
	float trt = pet_strand_lobe(ttrt, l, v, rough * 1.20);
	return vec3(1.0) * r * 0.20 + tint * trt * (0.26 + glint * 0.70);
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
