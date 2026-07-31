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
	// How much fibre structure the frame can hold, 0..1, and how sharply it is
	// being sampled. Reported out because the *specular* has to know: a lobe
	// narrow enough to resolve one fibre, run over a pixel that contains thirty
	// of them pointing thirty ways, is a mirror where there should be a scatter —
	// and on a long thin capsule a mirror draws a bar. See where `crisp` widens
	// the hair roughness in `creature_body.gdshader`.
	float res;
	float crisp;
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
// only alias. Being timid about this threshold is what empties the coat at the
// small end: a desktop pet is often drawn at only 150 screen pixels to the rig
// unit, and a cutoff at four or five pixels a lane removes every rung it has and
// leaves nothing but the clump field — which is exactly the smooth-clay read.
float pet_tier_fade(float px_per_lane) {
	return smoothstep(1.25, 2.55, px_per_lane);
}

// How much of a tier the sampler can actually *resolve*, which is not the same
// question as how much of it belongs on screen — and conflating the two is what
// produced the wood grain. A lane two pixels wide has to stay: take it away and
// the coat is smooth clay. But its bright core is a third of a lane, so it is a
// third of a pixel, and point-sampling a sub-pixel ridge is moire by
// construction — long wavy filaments that are the beat between the lane pitch
// and the pixel grid, not hair. So a barely-resolved rung is drawn with a wider,
// flatter profile and less contrast, which is what a mip level would have done
// for it if this coat came out of a texture.
float pet_tier_crisp(float px_per_lane) {
	return smoothstep(2.0, 5.4, px_per_lane);
}


// One tier of fibres in the groom frame (`t.x` along the hair, `t.y` across).
//
// `pitch` is fibres per rig unit and `aspect` is how long each one is in units
// of its own width. That second number decides whether the coat reads as hair or
// as timber: a pelt is seen tip-on, so what reaches the eye is a dense field of
// short dashes, never the full length of any one hair. Much past six and each
// lane is a ribbon, and a field of wavy ribbons is wood grain whatever colour it
// is painted.
//
// `soft` is 1 when the tier is at the sampling limit. It widens and flattens the
// fibre profile so the feature is never narrower than a pixel; see
// `pet_tier_crisp`. It also *shortens* the fibre, and that second job is the one
// that was missing. Aspect is a ratio, so a barely-resolved lane two pixels wide
// still draws a dash six lanes long — twelve screen pixels, on an animal that is
// only two hundred pixels from nose to rump. Six per cent of the body per stroke
// is not hair, it is planking, and it is precisely what the ship-size read
// collapsed into. A lane that cannot be resolved gets short dashes instead.
float pet_fibre_tier(vec2 t, float pitch, float clump, float aspect, float seed,
		float soft, out float dcross, out float rnd, out float lean) {
	// Measured at ship size: a desktop cat is drawn at 118 screen pixels to the rig
	// unit and the carrying lane lands at about 2.4 px. At the old 0.55 the dash was
	// still 3.3 lanes — eight screen pixels, four per cent of the animal, laid down
	// parallel to its neighbours, which is a plank however wide the profile is. Cut
	// to two lanes the dash is about as long as it is wide, and a field of stubby
	// marks with no long axis cannot beat into a stripe whatever contrast it is
	// given. That is what buys back the contrast raised in `pet_fur` below: the same
	// coat energy, spent on tooth instead of on length.
	aspect = max(aspect * mix(1.0, 0.30, soft), 1.0);
	// The warp has to *diverge* between neighbouring lanes, not shift them as a
	// block: a warp that changes slowly along the hair slides whole bands of
	// parallel lanes sideways in formation, and parallel lines with a slow wave
	// in them are the definition of wood grain. So both octaves run far faster
	// across the lanes than along them, and the along-hair amplitude is kept to a
	// fraction of a lane. What is left is lanes merging into their neighbours,
	// which is clumping, and almost no lateral travel, which is what a coat
	// combed in one direction actually looks like.
	float w = 0.58 * pet_noise(vec2(t.x * pitch * 0.028 + seed * 3.7, t.y * pitch * 0.30))
		+ 0.42 * pet_noise(vec2(t.x * pitch * 0.105 + seed, t.y * pitch * 0.66));
	float y = t.y * pitch + w * clump;
	float lane = floor(y);
	float f = fract(y) - 0.5;
	rnd = pet_hash1(vec2(lane, seed));

	float width = mix(mix(0.15, 0.33, rnd), 0.46, soft);
	float dprofile;
	float core = pet_ridge(abs(f) / width, dprofile);

	// A fibre is a finite object, and a lane left running forever is a ruled
	// line. So each lane is chopped into fibre-length cells, and the phase of
	// the chop is offset per lane so neighbours start and end at different
	// places instead of forming a seam across the coat. Each cell draws its own
	// length from the hash: some fibres lie flat against the next one, some end
	// in a clear gap. The floor under `seg` has to stay near zero — any real
	// floor is a lane that never stops, and a lane that never stops is a wire.
	float span = t.x * pitch / max(aspect, 1.0) + rnd * 11.0;
	float cell = floor(span);
	float rc = pet_hash1(vec2(cell, lane * 0.61 + seed));
	float dseg;
	float seg = 0.05 + 0.95
		* pet_ridge(abs(fract(span) - 0.5) / mix(0.32, 0.60, rc), dseg);

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
// A ladder of strand rungs plus a clump field, and the whole thing is arranged
// so that at every size the pet is ever drawn there is a rung landing at two or
// three screen pixels a lane. That is the entire design: a short coat has no
// resolvable individual hairs at any of these magnifications, so what the eye is
// actually given is a *grain*, and a grain only reads if its pitch stays near
// the resolution limit. Let it coarsen and the animal wears corduroy; let it
// vanish and the animal is clay.
//
// Contrast is handled separately from pitch, and separating them is the fix for
// the wood grain this replaces. The old coat drew a two-pixel lane at the same
// contrast as a six-pixel one, so its sub-pixel bright core beat against the
// pixel grid into long wavy filaments. Here the finest present rung still
// carries the coat, but `amp` and the profile width below back its contrast off
// as it approaches the limit — the same trade a mip level makes.
//
// The clump is not a fixed rig-space frequency. A lock is "about eight hairs
// across", and which rung is currently standing in for a hair changes with the
// zoom, so the clump pitch is derived from the rungs that are actually carrying
// the coat. That holds the lock-to-strand ratio — the relationship the eye reads
// as a coat rather than as a texture — constant from a taskbar icon to a head
// close-up. The cost is that the clump field is not rigidly nailed to rig space
// while the pet is being resized; its amplitude is small enough that this is the
// cheaper of the two errors, and the alternative is locks the size of the whole
// animal as soon as anyone zooms in.
//
// `t` arrives already in the groom frame — (along the hair, across the hair), in
// rig-space *surface* arc length — because the caller is the only thing that
// knows the shape of the body the hair is lying on. See the groom-frame block in
// `creature_body.gdshader`: building `t` by projecting a position onto one
// authored direction, which is what this used to do, is what ran every strand on
// the animal parallel to every other and put sawn timber on the flank.
// `across_s` is the same across-hair axis expressed as a *screen* direction, for
// the normal perturbation, and `px` is screen pixels per rig unit measured
// across the hair, which on a barrel is not the same number as along it.
Coat pet_fur(vec2 t, vec2 across_s, float density, float px, float fluffy) {
	vec2 across = across_s;

	// Four rungs, and the count is forced rather than chosen. A desktop pet is
	// drawn anywhere from about 150 to about 1100 screen pixels to the rig unit —
	// a taskbar-sized cat up to a head close-up — which is a range of seven, and a
	// ladder stepping by 2.15 covers 2.15^3 ≈ 10. Three rungs cover 4.6, and the
	// bottom of the range is exactly where they fail: at 150 px per unit a ladder
	// anchored for body scale has no rung resolved at all, and the pet at the size
	// it actually lives at is bare clay. That is not a subtle loss — it is the
	// whole coat, at the one size that matters most.
	float pitch0 = 48.0 * density;
	float pitch1 = pitch0 * 2.15;
	float pitch2 = pitch0 * 4.62;
	float pitch3 = pitch0 * 9.94;

	float f0 = pet_tier_fade(px / pitch0);
	float f1 = pet_tier_fade(px / pitch1);
	float f2 = pet_tier_fade(px / pitch2);
	float f3 = pet_tier_fade(px / pitch3);
	float k0 = pet_tier_crisp(px / pitch0);
	float k1 = pet_tier_crisp(px / pitch1);
	float k2 = pet_tier_crisp(px / pitch2);
	float k3 = pet_tier_crisp(px / pitch3);

	float d0 = 0.0, d1 = 0.0, d2 = 0.0, d3 = 0.0;
	float r0 = 0.5, r1 = 0.5, r2 = 0.5, r3 = 0.5;
	float n0 = 0.0, n1 = 0.0, n2 = 0.0, n3 = 0.0;
	float h0 = 0.0, h1 = 0.0, h2 = 0.0, h3 = 0.0;
	if (f0 > 0.002) { h0 = pet_fibre_tier(t, pitch0, 0.90, 6.0, 1.0, 1.0 - k0, d0, r0, n0); }
	if (f1 > 0.002) { h1 = pet_fibre_tier(t, pitch1, 0.90, 6.5, 7.0, 1.0 - k1, d1, r1, n1); }
	if (f2 > 0.002) { h2 = pet_fibre_tier(t, pitch2, 0.90, 7.0, 19.0, 1.0 - k2, d2, r2, n2); }
	if (f3 > 0.002) { h3 = pet_fibre_tier(t, pitch3, 0.90, 7.5, 43.0, 1.0 - k3, d3, r3, n3); }

	// Each rung hands most of its weight down as soon as the next one is *present*,
	// not once it is crisp, so the coat is always carried by the finest grain the
	// frame can hold — which is what keeps the apparent hair density the same at
	// every zoom instead of coarsening as the pet shrinks. The moire that rule
	// used to cause is dealt with where it belongs, in `amp` and in the profile
	// width, rather than by refusing to draw the fine rung at all.
	float w0 = f0 * (1.0 - 0.72 * f1);
	float w1 = f1 * (1.0 - 0.72 * f2);
	float w2 = f2 * (1.0 - 0.72 * f3);
	float w3 = f3;
	float wsum = w0 + w1 + w2 + w3;
	float inv = 1.0 / max(wsum, 1e-4);
	// How much resolvable fibre structure there is at all. Every fibre-derived
	// term fades toward its neutral value with this, so a pet shrunk to a taskbar
	// icon loses its coat cleanly instead of dissolving into low-frequency mush.
	float res = min(wsum, 1.0);
	// How sharply the coat is being sampled, which is what every contrast term
	// below is scaled by. The strands stay on screen at body scale; they stop
	// shouting. Getting this backwards — full contrast on an unresolved rung — is
	// the whole of the wood-grain failure.
	float crisp = (w0 * k0 + w1 * k1 + w2 * k2 + w3 * k3) * inv;
	// The floor here is the single number that decides whether the ship-size pet
	// wears hair or timber. A rung sampled at two and a bit pixels a lane cannot
	// carry contrast: whatever value swing it is given lands on the pixel grid as
	// a beat, and a beat between two near-equal frequencies is a long, slow,
	// perfectly straight streak. Held at 0.72 the coat kept three quarters of its
	// contrast at the one size where it can resolve none of its structure, which
	// is why every review at 640 px passed a build that reads as carved wood at
	// 260. The strokes stay — they are what stops it being clay — they just stop
	// shouting until there are pixels to say it in.
	//
	// Held at 0.22 it was throttling the coat a *second* time, and that is the
	// regression. `pet_fibre_tier` has already mip-filtered this rung — wider
	// profile, lower contrast per fibre, and now a dash two lanes long — so what
	// arrives here is a feature the frame can hold. Multiplying an already
	// prefiltered feature by another 0.22 is not anti-aliasing, it is deletion, and
	// the measurement says so: at ship size `crisp` is 0.205 on this cat's torso,
	// which took the coat's whole occlusion swing to plus or minus three per cent.
	// Three per cent is a hairless Sphynx, which is exactly what the blind reviewer
	// called it. The floor now backs the contrast off by a third at the limit
	// instead of by four fifths.
	float amp = mix(0.62, 1.0, crisp);
	// How much of the fibre structure is allowed to *show*, which is a different
	// question from how much of it is present, and the one that actually decides
	// the ship-size read.
	//
	// A rung drawn at two and a bit pixels a lane sits right on the sampling
	// limit. The structure is genuinely there — that is what `res` says — but
	// every scrap of contrast put into it comes back as the *beat* between the
	// lane pitch and the pixel grid, and the beat of a 2.4 px pattern on a 1 px
	// grid is a band about twelve pixels wide. Long, straight, evenly spaced,
	// running the length of the animal. That is the plank grain, and it arrives by
	// a route that no amount of tuning inside the fibre tier can close, because
	// the tier is not what is wrong: the sampling is.
	//
	// So the coat's *display* fades over the same window `pet_tier_crisp` uses.
	// That is the only lever that fixes 260 px without emptying 720 px, where
	// there are four pixels to a lane, nothing beats, and the coat has to be
	// entirely present — which is the trade every previous attempt got backwards.
	// Measured: 0.18 put `show` at 0.42 on the ship-size torso, and with `amp`
	// throttling the endpoints as well the product was a three per cent value swing
	// across the whole flank. The plank grain that floor was defending against is
	// not a contrast problem, it is a *shape* problem — long parallel strokes — and
	// it is fixed where it is made, in the dash length above. What is left here is
	// the honest mip trade: a barely-resolved rung keeps most of its energy and
	// loses a little of its bite.
	float show = res * mix(0.70, 1.0, smoothstep(0.06, 0.46, crisp));
	// The specular break-up gets its own, lower weight, and the asymmetry is the
	// point. Occlusion is a bounded multiply on albedo, so an unresolved fibre
	// averages honestly to the mean and the coat simply gets smoother. A specular is
	// a product with the key and its bright half clips, so an unresolved fibre
	// highlight does not average to the mean, it averages to a smear — and run at
	// the occlusion's weight the dog's flank came back wearing a bright greasy lens
	// where it should have had a coat. Half is what a lobe can carry at the limit.
	float show_spec = res * mix(0.42, 1.0, smoothstep(0.06, 0.46, crisp));
	// The normal perturbation gets a harder gate again, because it is the term
	// that aliases worst. A tint of a few per cent at sub-pixel pitch averages
	// away; a six-degree tilt of the normal under a directional key does not — it
	// swings the whole width of the diffuse falloff. Relief is the last thing a
	// coat should be drawn in when there is no room to draw it.
	float relief = res * mix(0.10, 1.0, smoothstep(0.06, 0.46, crisp));

	float strand = (w0 * h0 + w1 * h1 + w2 * h2 + w3 * h3) * inv;
	float lean = (w0 * n0 + w1 * n1 + w2 * n2 + w3 * n3) * inv;
	float rnd = (w0 * r0 + w1 * r1 + w2 * r2 + w3 * r3) * inv;

	// The lock: some eight strands across and stubby, four times as long as it is
	// wide, because a lock is a stubby thing and a long one is only corduroy at a
	// bigger scale. It is a fibre tier rather than a blob of fractal noise for
	// one reason — fractal noise has no strands in it, so it can only ever be
	// soft blotches, and soft blotches on a brown animal look like wet clay.
	// Guarded, because the weighted mean is 0/0 once the pet is small enough that
	// no rung resolves at all — and an unguarded zero pitch is a division by zero
	// inside the tier, i.e. a screenful of NaN on the one size a desktop pet
	// spends most of its life at.
	//
	// The pitch tracks the carrying rung, but only downward. A lock is a physical
	// object — a few millimetres of matted hair — so it has a size in rig space,
	// and letting the carrying rung set it in *both* directions is what made the
	// ship size fail. As the pet shrinks the carrying rung coarsens, the lock
	// coarsens with it, and at the 130 px per unit a desktop pet actually lives at
	// the "locks" came out a third of the animal long. Nothing that big is a lock;
	// it is plank grain, drawn at exactly the frequency the eye reads as sawn
	// timber. Floored against the finest authored rung, the lock keeps the same
	// size on the animal from a taskbar icon to a head close-up.
	float pitch_c = max((wsum > 1e-3
		? (w0 * pitch0 + w1 * pitch1 + w2 * pitch2 + w3 * pitch3) * inv
		: pitch0) * 0.13, pitch0 * 0.26);
	float fc = pet_tier_fade(px / pitch_c);
	float dc = 0.0, rc = 0.5, nc = 0.0, lock = 0.0;
	if (fc > 0.002) {
		lock = pet_fibre_tier(t, pitch_c, 0.75, 4.0, 31.0,
			1.0 - pet_tier_crisp(px / pitch_c), dc, rc, nc);
	}
	// The coat parts along the locks, so the strands thin out where a lock edge
	// runs. Modulating *coverage* is what gives the coat its second scale of
	// structure, and unlike a lock drawn in albedo it costs nothing in pigment.
	//
	// A lock is a *grouping* of strands, so it can only say as much as the
	// strands under it can. Once none of them resolve there is nothing left for
	// the lock to be a grouping of, and a third of a stop of coverage swing at
	// lock pitch is then just a set of broad stripes down the animal — which,
	// with the grain running the same way, is the second half of the plank read.
	// The lock keeps a harder gate than the strands do, and for a reason that is
	// specific to it: a lock is a *grouping*, its pitch is several strands, and
	// several strands at the sampling limit is a broad stripe. Raised only as far as
	// the strands under it can now justify — with real tooth beneath it the lock
	// reads as the coat parting rather than as banding.
	float lock_amp = mix(0.30, 1.0, crisp);
	float part = mix(1.0 - 0.34 * lock_amp, 1.0, lock);

	Coat c;
	c.tuft = lock;
	c.res = res;
	c.crisp = crisp;

	// Between the fibres you are looking down at shadowed skin; on one you are
	// looking at a lit fibre. The mean of `strand` sits near a fifth, not a half —
	// narrow fibres with gaps between them — so the endpoints are chosen to
	// average out near unity. Getting that wrong is not a subtle bug: it darkens
	// the whole animal by a fifth and every value in the lighting rig then has to
	// be re-tuned around a coat.
	c.occ = mix(1.0, mix(1.0 - 0.17 * amp, 1.0 + 0.24 * amp, strand * part),
		fluffy * show);

	// Slopes are divided by their own pitch so a fine rung does not tilt the
	// normal harder than a coarse one just for being denser. The lock gets a
	// quarter of the strands' amplitude: a lock is a parting in the coat, not a
	// ridge in the flesh, and given real relief it becomes a row of sausages.
	c.slope = across * fluffy * relief * inv
		* (0.034 * w0 * d0 / pitch0 + 0.032 * w1 * d1 / pitch1
			+ 0.030 * w2 * d2 / pitch2 + 0.028 * w3 * d3 / pitch3)
		+ across * fluffy * 0.009 * fc * lock_amp * dc / max(pitch_c, 1e-3);

	// Albedo carries almost none of the coat. Real hair is one pigment: what
	// changes from fibre to fibre is which way it points, not what colour it is.
	// Painting the variation into albedo is what produced the soft blotches that
	// made the animal look wet, so the strand read lives in `spec` and `tilt`
	// below and this is left as the faint pigment drift a lock has.
	c.tint = (rnd - 0.5) * 0.42 * show;

	// The visible structure of a short coat is specular. Each fibre is a tiny
	// cylinder: the highlight breaks across it, dies in the gap to the next one,
	// and comes back. `spec` is that break, `tilt` deflects the fibre tangent so
	// neighbours catch the key at slightly different angles, and `glint` drives
	// the tinted second lobe. The lock only shades it — a lock lying against the
	// light is duller than one standing away from it — it never sets its scale.
	c.glint = mix(0.25, rnd * rnd, show_spec);
	c.spec = mix(1.0, mix(1.0 - 0.58 * amp, 1.0 + 1.30 * amp, strand), show_spec)
		* mix(1.0 - 0.20 * lock_amp, 1.0 + 0.16 * lock_amp, lock) * part;
	c.tilt = lean * 0.34 * show_spec;
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

	// The outline is the one place on the animal where the field is not smoothed
	// by anything, so it is also the one place a missing tier is unmissable: with
	// no spikes the silhouette is an exact analytic curve, and an exact analytic
	// curve around a limb is what a lathe makes. Authored at a fixed rig pitch the
	// coarse tier stops resolving below about 240 px per unit — which is every
	// size the pet actually ships at — so the desktop cat has been wearing a
	// machined outline and nobody caught it at review zoom, where the tier is
	// present.
	//
	// So the coarse pitch is capped by what the frame can hold: spikes land about
	// every two and a half pixels however small the pet is drawn. That is not a
	// cheat about hair size, it is what a pelt does — shrink an animal far enough
	// and what breaks its outline is no longer single hairs but the clumps they
	// lie in, and clumps are exactly what a coarser tier draws. The cap only ever
	// bites downward, so a head close-up still gets the authored frequency.
	float pitch_a = min(92.0 * density, px / 3.30);
	// The fine tier is *not* capped, and that is the black stipple.
	//
	// Capped to `px / 1.15` it put a spike every one and a bit pixels — below the
	// sampling limit, not near it — so what it drew on the outline was a random
	// number per pixel. Along the underside, where the coat sits in the darkest
	// part of the animal, a random number per pixel is a row of hard black dots
	// against the desktop, which is exactly the stipple the review found beside the
	// belly seam on all four species. A cap is the right tool for the coarse tier,
	// whose job is to keep breaking the outline however small the pet is drawn; it
	// is the wrong tool here, because the fine tier's job is to add detail that only
	// exists at close-up zoom. Left uncapped it simply fades out at ship size, which
	// is what it should always have done.
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


// ---------------------------------------------------------------------------
// Whiskers
// ---------------------------------------------------------------------------

// A cat without whiskers is not a cat, and there is no part budget left to make
// them geometry — the species is at 28 capsules of 28. So they are drawn here,
// off the muzzle, and they are the only feature in the renderer allowed to leave
// the body's silhouette entirely.
//
// What actually reaches the eye from a real whisker is not a drawn line. It is
// the specular streak off a cylinder a tenth of a millimetre across: thin,
// bright, and mostly transparent, fading against a bright background rather than
// drawing over it. Rendered as opaque dark strokes — the obvious first attempt —
// a fan of them looks like cut wire glued to the face, which is worse than
// having none at all.
//
// `pad` is (x, y, length, amount) in rig space. `CreatureRenderer` finds it from
// the frontmost part rather than making a species declare its own muzzle twice.
float pet_whiskers(vec2 p, vec4 pad, float unit_px) {
	if (pad.w <= 0.002) { return 0.0; }
	float len = pad.z;
	vec2 q = p - pad.xy;
	// Cheap reject first: the fan occupies a small box in front of the muzzle and
	// this function is otherwise evaluated over the whole quad.
	if (q.x < -len * 0.30 || q.x > len * 1.15 || abs(q.y) > len * 0.85) {
		return 0.0;
	}
	// One pixel is the floor on width. Drawn thinner, the line breaks into a
	// dashed row of aliased dots that crawls whenever the head turns, which is
	// far more distracting than a whisker slightly too fat. Hold the width and
	// take the contrast out instead — which is what a sub-pixel highlight does in
	// a real camera anyway.
	float w0 = max(unit_px * 1.15, len * 0.006);
	float faint = clamp(len * 0.006 / w0, 0.26, 1.0);

	float cov = 0.0;
	for (int i = 0; i < 10; i++) {
		float fi = float(i);
		float r = pet_hash1(vec2(fi, 17.0));
		// Two rows about the muzzle line. A real pad is arranged in rows, the
		// upper row carries the long ones, and the fan opens further above the
		// line than below it.
		float row = mod(fi, 2.0) * 2.0 - 1.0;
		float k = floor(fi * 0.5) * 0.25;
		// Roots are spread across the pad, not stacked on one point. A whisker pad
		// is a patch of skin with rows of follicles in it; collapse them all onto
		// one origin and what comes out is a starburst, which is the shape of a
		// broom, not of a face. The upper rows also sit further back, which is
		// what opens the fan out instead of letting it radiate.
		vec2 root = vec2(-len * (0.04 + 0.26 * k),
			row * len * (0.045 + 0.075 * k) - len * 0.015);
		vec2 qq = q - root;
		float ang = row * (0.14 + 0.60 * k) - 0.06;
		float span = len * (0.60 + 0.40 * r) * (1.0 - 0.22 * k);
		vec2 d = vec2(cos(ang), sin(ang));
		float s = dot(qq, d);
		if (s < 0.0 || s > span) { continue; }
		float t = dot(qq, vec2(-d.y, d.x));
		// Every whisker bows: it leaves the pad stiff and sags along its length,
		// and ten perfectly straight rays read as a compass rose.
		t -= (0.18 + 0.30 * r) * row * s * s / span;
		float u = s / span;
		float w = w0 * (1.0 - 0.72 * u);
		cov = max(cov, smoothstep(w, w * 0.35, abs(t))
			* smoothstep(1.0, 0.70, u) * (0.55 + 0.45 * r));
	}
	return cov * pad.w * faint;
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

// Contour feathers: discrete overlapping plumes, each with its own rachis, laid
// in staggered rows over the body.
//
// The discreteness is the whole point, and getting it wrong is what put a
// topographic map on the bird. One continuous barb field indexed off the body's
// own coordinates draws a single unbroken family of curves across the entire
// animal — which is, precisely, what a contour line is. Real plumage never reads
// that way, because a bird is not covered in barbs, it is covered in *feathers*:
// a few hundred lens-shaped objects, each a couple of centimetres long, each
// overlapping the one behind it. The barbs inside one of them run for a
// centimetre and stop at its edge.
//
// So this tiles first and draws barbs second, the same way `pet_scale` tiles
// plates. Two frequencies fall out of that, and they fade independently: the
// feather is a body-sized detail that survives the downsample, the barbs are a
// close-up detail that does not. At 260 px the bird keeps its plumage and loses
// its barbs, which is the right trade and is what a photograph of a bird at that
// size looks like.
//
// `arc` runs along the body, `v` is the signed depth out to the vane edge and
// `u` is `|v|/R`. Rows follow `v`, which means they follow the body's own
// contour — that part was right, and pterylae really do run that way; the error
// was letting the *barbs* follow it too.
Surf pet_feather(float arc, float v, float u, float density, float px) {
	Surf s;
	// One feather, in rig units. Sized so an adult songbird carries roughly
	// fifteen of them nose to tail, which is about nine screen pixels each at
	// desktop size — small enough to read as plumage, large enough to survive.
	// Capped by the frame, the same way the scale plate and the fringe spike are.
	// Measured at ship size the bird is drawn at 129 screen pixels to the rig unit,
	// which put the authored feather at 3.0 px and the old gate at 0.13 — thirteen
	// per cent of a plumage, i.e. a smooth navy blob with a beak. A feather is a
	// body-scale object and it is the thing that has to survive; the barbs inside it
	// are not and do not.
	float fl = max(0.023 / max(density, 0.05), 3.1 / max(px, 1.0));
	float fw = fl * 0.55;
	float px_plume = px * fl;
	float plume_fade = smoothstep(1.9, 3.4, px_plume);
	// How sharply the plume is sampled, as distinct from whether it is there. The
	// shingle step and the vane keep their full weight at the limit; the relief
	// backs off, because a normal tilt at two and a bit pixels is the term that
	// beats against the grid.
	float plume_crisp = smoothstep(3.1, 7.0, px_plume);
	// Barbs are an order finer, so they get their own gate. About seven to a
	// feather. No cap here on purpose: a barb genuinely cannot be resolved on a
	// desktop-sized bird, and faking one is how a plumage becomes a contour map.
	float barb_px = px * fl / 7.0;
	float fade = smoothstep(1.7, 4.0, barb_px) * plume_fade;

	vec2 cell = vec2(arc / fl, v / fw);
	float row = floor(cell.y);
	// Half a feather of stagger per row, so the tips of one row sit over the gaps
	// of the next instead of forming a seam down the bird.
	// Plus a slow warp along each row. A tract of skin is not a printed grid, and
	// a stagger this regular reads as basket weave at the size the plumage is
	// actually drawn — which is a different wrong answer from contour lines, not a
	// right one.
	cell.x += fract(row * 0.5) + pet_hash1(vec2(row, 3.0)) * 0.30
		+ pet_noise(vec2(cell.x * 0.20, row * 0.85)) * 0.50;
	vec2 g = fract(cell) - 0.5;
	float rnd = pet_hash1(vec2(floor(cell.x), row));

	// Shingling. A feather's tip points caudally and lies *over* the feather
	// behind it, so height ramps from the buried quill at +g.x to the exposed tip
	// at -g.x and then falls off the edge. That step is the single strongest cue
	// that the surface is made of separate objects.
	float shingle = smoothstep(0.5, -0.34, g.x);
	float lip = smoothstep(0.5, 0.30, abs(g.x));

	// The vane: a lens, wider at the quill end and drawn to a point at the tip.
	float half_w = (0.50 - 0.28 * smoothstep(-0.1, 0.5, -g.x)) * mix(0.86, 1.0, rnd);
	float vane = 1.0 - clamp(abs(g.y) / max(half_w, 1e-3), 0.0, 1.0);

	// The rachis runs the length of the feather, not the length of the bird.
	float rachis = smoothstep(0.22, 0.0, abs(g.y)) * vane;

	// Barbs, *inside* this feather. They leave the rachis at an angle and sweep
	// toward the tip, so the lane index mixes the two cell axes; both terms are
	// per-cell, so a barb cannot outlive the feather it belongs to.
	float lane = (abs(g.y) * 1.35 - g.x * 0.55) * 7.0 + rnd * 3.0;
	float f = fract(lane) - 0.5;
	float dp;
	float barb = pet_ridge(abs(f) / 0.40, dp) * fade * vane;
	// Barbs unzip toward the vane edge: coverage falls away and the gaps open,
	// which is what stops the outline of each feather being a drawn line.
	barb *= 1.0 - smoothstep(0.55, 1.0, abs(g.y) / max(half_w, 1e-3))
		* (0.35 + 0.65 * rnd);

	// Relief: mostly the shingle step, with the barbs as a fine ripple on top.
	// The step is along the cell's `arc` axis, which is `across` in the caller.
	s.slope = vec2((shingle - 0.5) * plume_fade * 0.42 * mix(0.55, 1.0, plume_crisp)
		+ dp * sign(f) * fade * 0.055, 0.0);
	s.occ = mix(1.0, mix(0.72, 1.06, shingle) * mix(0.86, 1.0, lip), plume_fade)
		* mix(1.0 - 0.12 * fade, 1.05, barb) * mix(1.0, 1.08, rachis);
	s.tint = (rnd - 0.5) * 0.26 * plume_fade + rachis * 0.14
		+ (barb - 0.5) * 0.10 * fade;
	s.spec = mix(1.0, mix(0.62, 1.45, shingle * mix(0.5, 1.0, vane)), plume_fade)
		* mix(1.0, 1.25, barb);
	// Iridescence is strongest on the smooth exposed face of the vane and dies in
	// the gaps and under the overlaps, so it tracks the shingle rather than being
	// painted flat.
	s.extra = mix(0.35, 1.0, shingle) * vane * (1.0 - rachis * 0.5);
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
	// The plate size is capped by what the frame can hold, exactly the way
	// `pet_fur_fringe` caps its spike pitch and for the same reason: shrink a
	// reptile far enough and what breaks its surface up is no longer the single
	// scale but the group of scales, and a group is what a coarser tiling draws.
	//
	// Without the cap this family was not merely coarse, it was *absent*. Measured
	// at ship size the lizard is drawn at 40 screen pixels to the rig unit — a third
	// of what the mammals get, because a lizard is four units long and the frame is
	// square — so an authored 0.030 plate is 1.2 px and the old gate returned
	// exactly zero. Every term below then collapsed to its neutral value and what
	// was left on screen was a bare GGX lobe over a smooth capsule, which is a
	// polished brass ornament and is precisely what the blind reviewer called it.
	float size = max(0.030 / max(density, 0.05), 2.9 / max(px, 1.0));
	// Present, therefore, at every size the pet ships at. What varies instead is how
	// *sharply* it is sampled, which is the same split fur makes between `res` and
	// `crisp`: a plate held at the resolution limit keeps its shingle step and its
	// broken specular and gives up its dome relief, because the dome is the term
	// that swings a normal under a directional key and it is the one that aliases.
	float px_plate = px * size;
	float fade = smoothstep(1.7, 3.0, px_plate);
	float crisp = smoothstep(2.9, 6.5, px_plate);

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

	// The dome's own relief is the aliasing term — it is a normal tilt under a hard
	// key — so it rides `crisp`. The shingle step is a *height* step between two
	// plates, which survives a downsample the way any silhouette-scale feature does,
	// so it rides `fade` and stays.
	s.slope = vec2(-dp * 1.35 * sign(g.x), -dp * 1.35 * sign(g.y) * 0.55)
		* crisp * 0.9 + vec2(shingle - 0.5, 0.0) * fade * 0.55;
	s.occ = mix(1.0, mix(0.62, 1.08, shingle) * mix(0.80, 1.0, lip), fade);
	s.tint = (rnd - 0.5) * 0.30 * fade + (dome - 0.5) * 0.22 * crisp;
	// Speculars break at every plate boundary, which is what makes a lizard
	// glitter instead of gleam — and it is the term that has to survive furthest
	// down, because an unbroken lobe on a smooth capsule is the entire brass read.
	// Driven by the shingle rather than by the dome once the plate is at the limit:
	// the dome is sub-pixel down there, the step between plates is not.
	s.spec = mix(1.0, mix(0.35, 1.9, mix(shingle, dome * shingle, crisp)), fade);
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
