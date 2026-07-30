// Petalia — shared VFX shader helpers.
//
// Deliberately self-contained rather than including the creature's noise
// header: that file lives in a directory this layer does not own, and a VFX
// shader that stops compiling because someone else is mid-edit would take the
// whole presentation layer down with it. The cost is one duplicated hash; the
// benefit is that game/vfx/ builds on its own.
//
// PER-PARTICLE DATA. `INSTANCE_CUSTOM` is a *vertex-only* built-in in
// canvas_item shaders, so every particle shader here forwards it through a
// varying. Measured on Godot 4.5 / CPUParticles2D, the channels carry:
//
//   .x  always 0
//   .y  normalised age: 0 at birth, 1 at death        <- the animation clock
//   .z  `anim_offset`, random in [anim_offset_min, max]
//   .w  lifetime scale from `lifetime_randomness`
//
// Nothing else consumes `anim_offset` when there is no sprite sheet, so we
// spend it as the per-particle random seed. Without it a canvas_item shader has
// no way to tell two particles apart, and untextured particles that are all
// identical read instantly as a screensaver rather than as dust.

const float VFX_TAU = 6.28318530718;

// --- hashing -----------------------------------------------------------------

float vfx_hash11(float x) {
	return fract(sin(x * 127.1 + 3.71) * 43758.5453123);
}

float vfx_hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

vec2 vfx_hash22(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453123) * 2.0 - 1.0;
}

// Gradient noise in [-1, 1], quintic interpolation so the derivative stays
// smooth where we use the field to bend a displacement vector.
float vfx_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = dot(vfx_hash22(i), f);
	float b = dot(vfx_hash22(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0));
	float c = dot(vfx_hash22(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0));
	float d = dot(vfx_hash22(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) * 1.4;
}

// Three octaves is the ceiling anywhere in this layer. These shaders run on a
// machine that is doing someone's actual work; a dust puff is not allowed to
// cost what the creature body costs.
float vfx_fbm3(vec2 p) {
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	float s = vfx_noise(p) * 0.5;
	p = rot * p * 2.03;
	s += vfx_noise(p) * 0.25;
	p = rot * p * 2.01;
	s += vfx_noise(p) * 0.125;
	return s / 0.875;
}

// --- 2D distance fields ------------------------------------------------------

mat2 vfx_rot(float a) {
	float c = cos(a);
	float s = sin(a);
	return mat2(vec2(c, -s), vec2(s, c));
}

float vfx_smin(float a, float b, float k) {
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

float vfx_sd_circle(vec2 p, float r) {
	return length(p) - r;
}

// Round capsule: the workhorse for every stroked glyph here. Strokes built from
// capsules keep constant weight at any scale, which is what makes the emotion
// set survive being drawn at 24 px.
float vfx_sd_seg(vec2 p, vec2 a, vec2 b, float r) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

// Tapered capsule (iq's rounded cone). Exact, so it stays sharp when a hair or
// a droplet is one pixel wide.
float vfx_sd_cone(vec2 p, vec2 a, vec2 b, float ra, float rb) {
	vec2 ba = b - a;
	float l2 = dot(ba, ba);
	float rr = ra - rb;
	float a2 = l2 - rr * rr;
	float il2 = 1.0 / l2;
	vec2 pa = p - a;
	float y = dot(pa, ba);
	float z = y - l2;
	vec2 w = pa * l2 - ba * y;
	float x2 = dot(w, w);
	float y2 = y * y * l2;
	float z2 = z * z * l2;
	float k = sign(rr) * rr * rr * x2;
	if (sign(z) * a2 * z2 > k) {
		return sqrt(x2 + z2) * il2 - rb;
	}
	if (sign(y) * a2 * y2 < k) {
		return sqrt(x2 + y2) * il2 - ra;
	}
	return (sqrt(x2 * a2 * il2) + y * rr) * il2 - ra;
}

// Thick arc centred on the origin, symmetric about +y, with the gap facing -y.
// `sc` is (sin, cos) of the half-aperture.
float vfx_sd_arc(vec2 p, vec2 sc, float ra, float rb) {
	p.x = abs(p.x);
	float d = (sc.y * p.x > sc.x * p.y) ? length(p - sc * ra) : abs(length(p) - ra);
	return d - rb;
}

// --- easing and envelopes ----------------------------------------------------

float vfx_ease_out(float t) {
	float u = 1.0 - clamp(t, 0.0, 1.0);
	return 1.0 - u * u * u;
}

float vfx_ease_in(float t) {
	float u = clamp(t, 0.0, 1.0);
	return u * u * u;
}

// Asymmetric 0 -> 1 -> 0 envelope. `rise` and `fall` are the fractions of the
// span spent opening and closing; the plateau between them is what stops a
// puff from looking like a sine pulse.
float vfx_env(float t, float rise, float fall) {
	float up = vfx_ease_out(clamp(t / max(rise, 1e-4), 0.0, 1.0));
	float dn = 1.0 - vfx_ease_in(clamp((t - (1.0 - fall)) / max(fall, 1e-4), 0.0, 1.0));
	return up * dn;
}

// Soft round blob with a feathered rim, used everywhere a particle needs to be
// a puff rather than a disc. `soft` in [0,1]: 0 is a hard dot, 1 is pure haze.
float vfx_blob(vec2 p, float r, float soft) {
	float d = length(p) / max(r, 1e-4);
	return pow(clamp(1.0 - d, 0.0, 1.0), mix(0.7, 3.2, clamp(soft, 0.0, 1.0)));
}
