class_name Growth
extends RefCounted

## Continuous baby → adult body morph.
##
## Growth is not a scale factor. A kitten is not a small cat: its head is
## proportionally huge, its legs are stubby, its eyes are enormous and its tail
## is a fraction of adult length. Getting those ratios right is most of why a
## baby reads as a baby, so each part carries its own growth curve and this
## applies them.
##
## The output is the *bind pose* the rig is then fitted to, which imposes two
## requirements the raw per-part morph does not satisfy on its own: limb and tail
## segments must stay joined end to end after being shortened, and the feet must
## still be on the ground. Both are fixed up here rather than in the rig, so the
## bind pose is always a valid animal on its own terms.

const RigBones := preload("res://core/rig/bone_map.gd")


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
		dst.id = src.id
		dst.bone_a = src.bone_a
		dst.bone_b = src.bone_b
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

	_relink_chains(spec, live)

	# Finally apply the whole-body scale about the ground origin, so the
	# creature's feet stay planted as it grows.
	for i in n:
		var dst: SDFPart = live[i]
		if dst == null:
			continue
		dst.a *= body_scale
		dst.b *= body_scale
		dst.radius_a *= body_scale
		dst.radius_b *= body_scale
		dst.blend *= body_scale
		dst.coat_length *= body_scale

	_ground(live)


## Grow the live eye state to match the body. `live_parts` must be the output of
## `apply` for the same growth value: the eyes ride wherever the skull ended up,
## which after the re-link and grounding passes is not simply `center * scale`.
##
## `stage_eye_bias` is the species-wide neoteny curve and `EyeSpec.baby_radius_
## scale` is the per-eye deviation from it; multiplying both raw would double the
## effect, so the per-eye value is normalised against the property's own default.
## An eye that leaves `baby_radius_scale` alone therefore follows the species
## curve exactly, and one that raises it stands proud of its neighbour.
static func apply_eyes(spec: CreatureSpec, live: Array, growth: float,
		live_parts: Array[SDFPart]) -> void:
	const DEFAULT_BABY_EYE := 1.55
	var baby: float = spec.babyness_at(growth)
	var body_scale: float = spec.scale_at(growth)
	var species_bias: float = spec.eye_bias_at(growth)
	# The skull is the frame of reference: find where it was authored and where
	# it now sits, and carry the eyes across by the same transform.
	var head_src := _head_centre(spec.parts)
	var head_dst := _head_centre(live_parts)
	var head_grow: float = body_scale * lerpf(1.0, spec.head_bias_at(growth), baby)

	for i in mini(live.size(), spec.eyes.size()):
		var src: EyeSpec = spec.eyes[i]
		var dst: EyeSpec.Live = live[i]
		if src == null or dst == null:
			continue
		dst.copy_from(src)
		dst.center = head_dst + (src.center - head_src) * head_grow
		var per_eye: float = lerpf(1.0, src.baby_radius_scale / DEFAULT_BABY_EYE, baby)
		dst.radius = src.radius * species_bias * per_eye * body_scale
		dst.pupil_ratio = clampf(src.pupil_ratio * lerpf(1.0, src.baby_pupil_scale, baby),
			0.05, 0.98)
		# A slit pupil rounds out in a young animal; kittens do not get the adult
		# vertical slit for weeks, and it is a strong "this is a baby" read.
		dst.pupil_slit = src.pupil_slit * lerpf(1.0, 0.45, baby)


## Radius-weighted centre of the skull parts, or the whole body if a species has
## no part the classifier recognises as a head.
static func _head_centre(parts: Array[SDFPart]) -> Vector2:
	var sum := Vector2.ZERO
	var w := 0.0
	var any := Vector2.ZERO
	var any_w := 0.0
	for p in parts:
		if p == null:
			continue
		var r: float = maxf(p.radius_a + p.radius_b, 1e-4)
		any += (p.a + p.b) * 0.5 * r
		any_w += r
		if RigBones.classify(p.id, int(p.layer)).slot != RigBones.Slot.HEAD:
			continue
		sum += (p.a + p.b) * 0.5 * r
		w += r
	if w > 0.0:
		return sum / w
	return any / any_w if any_w > 0.0 else Vector2.ZERO


## Re-join the segments of every limb and tail after they have been shortened.
##
## The per-part morph pulls each segment toward its own root, which leaves gaps
## between them; walking each chain from the body outward and sliding every
## segment onto the previous one's tip restores a continuous limb without
## changing any authored length.
static func _relink_chains(spec: CreatureSpec, live: Array[SDFPart]) -> void:
	var n: int = mini(live.size(), spec.parts.size())
	var tags: Array = []
	var body := Vector2.ZERO
	var body_w := 0.0
	for i in n:
		var tag = RigBones.classify(live[i].id, int(live[i].layer))
		tags.append(tag)
		if tag.slot in [RigBones.Slot.PELVIS, RigBones.Slot.SPINE, RigBones.Slot.CHEST]:
			var w: float = maxf(live[i].radius_a + live[i].radius_b, 1e-4)
			body += (live[i].a + live[i].b) * 0.5 * w
			body_w += w
	if body_w > 0.0:
		body /= body_w

	# One group per limb and one per tail-like chain. Everything else is rigid.
	var groups := {}
	for i in n:
		var tag = tags[i]
		var key := ""
		match tag.slot:
			RigBones.Slot.LIMB, RigBones.Slot.WING:
				key = "%d_%d_%d" % [tag.slot, int(tag.fore), int(tag.far)]
			RigBones.Slot.TAIL, RigBones.Slot.CREST, RigBones.Slot.WATTLE:
				key = "%d" % tag.slot
			_:
				continue
		if not groups.has(key):
			groups[key] = []
		groups[key].append(i)

	for key in groups:
		var members: Array = groups[key]
		if members.size() < 2:
			continue
		members.sort_custom(func(x: int, y: int) -> bool:
			return _chain_key(live[x], tags[x], body) < _chain_key(live[y], tags[y], body))
		var cursor := Vector2.INF
		for i in members:
			var p: SDFPart = live[i]
			var a_first: bool = true
			if cursor == Vector2.INF:
				a_first = p.a.distance_to(body) <= p.b.distance_to(body)
				cursor = p.a if a_first else p.b
			else:
				a_first = p.a.distance_to(cursor) <= p.b.distance_to(cursor)
				var shift: Vector2 = cursor - (p.a if a_first else p.b)
				p.a += shift
				p.b += shift
			cursor = p.b if a_first else p.a


static func _chain_key(p: SDFPart, tag, body: Vector2) -> float:
	if tag.seg >= 0:
		return float(tag.seg)
	return 10.0 + minf(p.a.distance_to(body), p.b.distance_to(body))


## Put the feet back on y = 0.
##
## Shortening a limb lifts its foot clear of the ground, and rig space defines
## the origin as sitting between the paws on the ground plane — every ground
## contact, contact shadow and foot plant in the game depends on that holding at
## every life stage, not just at adult.
static func _ground(live: Array[SDFPart]) -> void:
	var lowest := -INF
	var any_limb := false
	for p in live:
		if p == null:
			continue
		var tag = RigBones.classify(p.id, int(p.layer))
		if tag.slot != RigBones.Slot.LIMB and tag.slot != RigBones.Slot.WING:
			continue
		any_limb = true
		lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
	if not any_limb:
		# Legless species (snakes, fish): rest the whole body on the plane.
		for p in live:
			if p != null:
				lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
	if not is_finite(lowest) or absf(lowest) < 1e-5:
		return
	for p in live:
		if p == null:
			continue
		p.a.y -= lowest
		p.b.y -= lowest


static func _is_head_part(id: StringName) -> bool:
	var s := String(id)
	return s.begins_with("head") or s.begins_with("cheek") or s.begins_with("muzzle") \
		or s.begins_with("chin") or s.begins_with("nose") or s.begins_with("ear") \
		or s.begins_with("eye") or s.begins_with("beak") or s.begins_with("crest")
