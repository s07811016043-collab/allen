#ifndef PETALIA_TONEMAP_INC
#define PETALIA_TONEMAP_INC

// The one filmic curve the whole game agrees on.
//
// It lives in its own include because two places apply it: the creature body
// shader when it renders standalone, and the post stack when it is enabled. If
// they disagreed, switching post on would change the pet's colour, not just add
// glow — and the desktop overlay has to look identical either way.

// Narkowicz's ACES fit. Cheap, and its shoulder rolls hot rim light off instead
// of clipping it to a flat white edge.
vec3 pet_tonemap(vec3 c) {
	c = max(c, vec3(0.0));
	return clamp((c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14),
		vec3(0.0), vec3(1.0));
}

#endif
