class_name Growth
extends RefCounted

## Continuous baby → adult body morph.
##
## Growth is not a scale factor. A kitten is not a small cat: its head is
## proportionally huge, its legs are stubby, its eyes are enormous and its tail
## is a fraction of adult length. Getting those ratios right is most of why a
## baby reads as a baby, so each part carries its own growth curve and this
## applies them.

## Rewrite `live` from `spec.parts` for the given continuous growth in [0, 3].
## `live` must already have the same length and ordering as `spec.parts`.
static func apply(spec: CreatureSpec, live: Array[SDFPart], growth: float) -> void:
	var baby: float = spec.babyness_at(growth)
	var body_scale: float = spec.scale_at(growth)
	var head_bias: float = spec.head_bias_at(growth)

	var n: int = mini(live.size(), spec.parts.size())
	for i in n:
		var src: SDFPart = spec.parts[i]
		var dst: SDFPart = live[i]
		if src == null or dst == null:
			continue

		# Per-part morph: interpolate each curve from its baby value to 1.0.
		var r_scale: float = lerpf(1.0, src.baby_radius_scale, baby)
		var l_scale: float = lerpf(1.0, src.baby_length_scale, baby)
		var offset: Vector2 = src.baby_offset * baby

		# Heads grow slower than bodies, which is what produces the top-heavy
		# newborn silhouette. Applied as an extra radial term around the part's
		# own midpoint so the head does not detach from the neck.
		var is_head: bool = _is_head_part(src.id)
		if is_head:
			r_scale *= lerpf(1.0, head_bias, baby)

		# Shorten limbs and tails toward their root rather than their midpoint,
		# so the shoulder stays attached and only the free end pulls in.
		var root: Vector2 = src.a
		var tip: Vector2 = src.b
		dst.a = root + offset
		dst.b = root + (tip - root) * l_scale + offset
		dst.radius_a = src.radius_a * r_scale
		dst.radius_b = src.radius_b * r_scale
		dst.blend = src.blend * maxf(r_scale, 0.4)
		dst.height_scale = src.height_scale
		dst.surface = src.surface
		dst.palette_index = src.palette_index
		dst.groom_angle = src.groom_angle
		dst.layer = src.layer
		# Babies are fluffier per unit of body: down is longer relative to size.
		dst.coat_length = spec.coat_length * src.coat_length * lerpf(1.0, 1.45, baby)

		# Finally apply the whole-body scale about the ground origin, so the
		# creature's feet stay planted as it grows.
		dst.a *= body_scale
		dst.b *= body_scale
		dst.radius_a *= body_scale
		dst.radius_b *= body_scale
		dst.blend *= body_scale
		dst.coat_length *= body_scale


static func _is_head_part(id: StringName) -> bool:
	var s := String(id)
	return s.begins_with("head") or s.begins_with("cheek") or s.begins_with("muzzle") \
		or s.begins_with("chin") or s.begins_with("nose") or s.begins_with("ear") \
		or s.begins_with("eye") or s.begins_with("beak") or s.begins_with("crest")
