#ifndef PETALIA_LIGHTING_INC
#define PETALIA_LIGHTING_INC

// Petalia's lighting rig.
//
// A three-point rig with one job: sell a solid, grounded animal that is sitting
// in a room rather than pasted onto one. The pieces are
//
//   key     one warm source, upper-front, with a soft scattering terminator,
//   sky     a cool dome from above, occluded by the ground plane as you
//           approach it,
//   bounce  a warm reflection off the floor that dies off with height,
//   rim     a cool kicker that fires *only* where the silhouette actually turns
//           toward it. A rim that fires everywhere is a white outline, and a
//           white outline is the single most reliable tell of a cheap 2D pet.
//
// This lives in an include because the eye pass has to agree with the body
// about where the key is: a catchlight in the wrong place breaks the illusion
// faster than any amount of coat detail can rebuild it.

// Direction *toward* the key, rig space. +x forward, +y down, +z toward viewer.
uniform vec3 light_dir = vec3(0.40, -0.66, 0.64);
uniform vec4 key_color : source_color = vec4(1.0, 0.955, 0.885, 1.0);
uniform float key_energy : hint_range(0.0, 4.0) = 1.02;

// The rim sits behind and above, on the far side from the key.
uniform vec3 rim_dir = vec3(-0.78, -0.36, -0.50);
uniform vec4 rim_color : source_color = vec4(0.60, 0.75, 1.0, 1.0);
uniform float rim_energy : hint_range(0.0, 4.0) = 0.85;

uniform vec4 ambient_tint : source_color = vec4(0.40, 0.50, 0.68, 1.0);
uniform float ambient_energy : hint_range(0.0, 2.0) = 0.26;
uniform vec4 bounce_tint : source_color = vec4(0.38, 0.27, 0.19, 1.0);
uniform float bounce_energy : hint_range(0.0, 2.0) = 0.30;
uniform float exposure : hint_range(0.1, 4.0) = 1.0;


vec3 pet_key_dir() { return normalize(light_dir); }
vec3 pet_rim_dir() { return normalize(rim_dir); }


// Wrapped diffuse. `wrap` widens the terminator for materials that scatter.
// Smoothstepping the wrapped result restores the shoulder that wrapping flattens
// out, so the terminator stays soft without the whole body going milky.
float pet_wrap_diffuse(float ndl, float wrap) {
	float d = clamp((ndl + wrap) / (1.0 + wrap), 0.0, 1.0);
	return d * d * (3.0 - 2.0 * d);
}


// Key radiance arriving at the surface, with cast shadow already applied.
vec3 pet_key(vec3 n, float shadow, float wrap) {
	return key_color.rgb * key_energy
		* pet_wrap_diffuse(dot(n, pet_key_dir()), wrap) * shadow;
}


// Energy that entered the coat near the shadow line and left it a few strand
// widths away. It is tinted by the flesh under the coat rather than by the coat
// itself, which is why the terminator on a real animal is warmer than either the
// lit or the shadow side.
float pet_terminator_band(vec3 n) {
	float ndl = dot(n, pet_key_dir());
	return smoothstep(0.62, 0.0, abs(ndl)) * smoothstep(-0.5, 0.02, ndl);
}


// Cool sky dome. Rig space has +y pointing down, so an up-facing normal has
// negative y. `occ` folds in both crease occlusion and the ground plane cutting
// the dome off near the floor.
vec3 pet_sky(vec3 n, float occ) {
	float w = clamp(0.5 - 0.5 * n.y, 0.0, 1.0);
	return ambient_tint.rgb * ambient_energy * mix(0.30, 1.0, w * w) * occ;
}


// Warm bounce off the floor. `height01` is the fragment's height above the
// ground plane normalised by body height; the floor subtends less and less of
// the hemisphere as you climb, so the bounce has to die off or the whole animal
// glows from below like a stage effect.
vec3 pet_bounce(vec3 n, float height01, float occ) {
	float w = clamp(0.5 + 0.5 * n.y, 0.0, 1.0);
	return bounce_tint.rgb * bounce_energy * w * w * exp(-height01 * 2.6) * occ;
}


// Rim term. `edge` is the Fresnel-ish silhouette falloff; `facing` gates it to
// the side of the outline that is actually turned toward the rim light.
float pet_rim(vec3 n) {
	vec2 sil = n.xy;
	float l = length(sil);
	if (l < 1e-4) { return 0.0; }
	vec2 rd = normalize(pet_rim_dir().xy);
	float facing = clamp(dot(sil / l, rd), 0.0, 1.0);
	float edge = pow(1.0 - clamp(n.z, 0.0, 1.0), 3.2);
	return edge * facing * facing * rim_energy;
}

#endif
