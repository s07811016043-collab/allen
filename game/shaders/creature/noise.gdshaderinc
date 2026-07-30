#ifndef PETALIA_NOISE_INC
#define PETALIA_NOISE_INC

// Shared procedural noise for Petalia's coat, skin and VFX shaders.
//
// Everything here is hash-based and texture-free on purpose: the pet ships as a
// single small binary with no art assets, and a fur coat that is *computed*
// stays razor sharp when the player scales the pet from 40px to 400px.

const float PETALIA_TAU = 6.28318530718;

vec2 pet_hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123) * 2.0 - 1.0;
}

float pet_hash1(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// Gradient noise in [-1, 1]. Quintic interpolation keeps the second derivative
// continuous, which matters because we differentiate this for coat normals.
float pet_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = dot(pet_hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0));
	float b = dot(pet_hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
	float c = dot(pet_hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
	float d = dot(pet_hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}

// Fractal sum. `oct` is a compile-time-ish small constant everywhere we call it
// so the loop unrolls on every driver we care about.
float pet_fbm(vec2 p, int oct) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	// A slight rotation per octave breaks up the axis-aligned grid artifacts
	// that otherwise show as a faint plaid in flat-lit fur.
	mat2 rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 6; i++) {
		if (i >= oct) { break; }
		sum += amp * pet_noise(p);
		norm += amp;
		p = rot * p * 2.03;
		amp *= 0.5;
	}
	return sum / max(norm, 1e-5);
}

// Worley / cellular noise. Returns (F1, F2): distance to nearest and second
// nearest feature point. F2 - F1 draws the cell borders, which is how scales,
// feather barbs and skin pores get their structure.
vec2 pet_worley(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float f1 = 8.0;
	float f2 = 8.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = pet_hash2(i + g) * 0.5 + 0.5;
			float d = length(g + o - f);
			if (d < f1) { f2 = f1; f1 = d; }
			else if (d < f2) { f2 = d; }
		}
	}
	return vec2(f1, f2);
}

// Anisotropic strand field: noise stretched along `dir`, which is what makes
// fur read as combed rather than as static.
float pet_strands(vec2 p, vec2 dir, float freq, float stretch) {
	vec2 t = vec2(dot(p, dir), dot(p, vec2(-dir.y, dir.x)));
	t.x /= max(stretch, 0.01);
	return pet_fbm(t * freq, 3);
}

// Smooth unit ridge with an analytic derivative. Every strand, barb and scale
// edge in the renderer is drawn with this profile: `x` is the normalised
// distance across the feature, `value` peaks at 1 and reaches 0 at x = 1, and
// `slope` is d(value)/dx. Differentiating the profile instead of finite
// differencing a noise field is what keeps coat normals free of aliasing.
float pet_ridge(float x, out float slope) {
	float t = clamp(x, 0.0, 1.0);
	slope = -6.0 * t * (1.0 - t);
	return 1.0 - t * t * (3.0 - 2.0 * t);
}

// Cheap ordered dither, applied at the very end of shading. Eight-bit output
// over a slow gradient bands visibly on large soft bodies; a sub-LSB dither
// costs nothing and removes it entirely.
float pet_dither(vec2 frag) {
	return (pet_hash1(floor(frag)) - 0.5) / 255.0;
}

#endif
