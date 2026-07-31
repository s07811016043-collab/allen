class_name CreatureRenderer
extends Node2D

## Packs a creature's live implicit body into shader uniforms and draws it.
##
## The renderer owns exactly one quad. Everything visible — coat, lighting,
## eyes, contact shadow — is resolved inside `creature_body.gdshader` from the
## part array uploaded here. Keeping the CPU side to "pack floats, set uniform"
## is what lets the pet animate at high frequency without touching geometry.

## Hard ceiling on parts per creature. Three vec4 each, and GLES3 guarantees
## only 224 fragment uniform vectors, so this leaves comfortable headroom for
## the palette and lighting block.
const MAX_PARTS := 28
const MAX_PALETTE := 12
const VEC4S_PER_PART := 3
## Eyes are packed separately from parts: four `vec4` each.
const MAX_EYES := 4
const VEC4S_PER_EYE := 4
## Skeletal landmarks handed to the body shader as relief. See
## `_pack_landmarks` for why the renderer, and not the species, finds them.
const MAX_LANDMARKS := 4

## Rig-space padding added around the part bounds so coat fringe, rim light and
## contact shadow are never clipped by the quad edge.
const BOUNDS_PADDING := 0.34

@export var body_shader: Shader

var spec: CreatureSpec
## Live parts — the rig mutates these each frame. Distinct from `spec.parts`,
## which stays pristine as the bind pose.
var live_parts: Array[SDFPart] = []
## Live eye state, mutated by the rig each frame. Parallel to `spec.eyes`.
var live_eyes: Array[EyeSpec.Live] = []

var _rect: ColorRect
var _mat: ShaderMaterial
var _packed := PackedVector4Array()
var _packed_eyes := PackedVector4Array()
var _packed_landmarks := PackedVector4Array()
## Where each limb *enters* the body, parallel to `_packed_landmarks`. Distinct
## from the landmark, which is the crest of the bone up under the top line; this
## is the socket down on the side of the barrel. See `_pack_landmarks`.
var _packed_limb_roots := PackedVector4Array()
var _landmark_count := 0
## Whisker pad, packed (x, y, length, amount) in rig space. See `_pack_whiskers`.
var _whisker_pad := Vector4.ZERO
var _palette := PackedColorArray()
var _bounds_min := Vector2.ZERO
var _bounds_max := Vector2.ONE
var _pixels_per_unit := 180.0

## Shading state driven by gameplay; see `set_shading_state`.
var growth: float = 3.0
var wetness: float = 0.0
var fluff: float = 1.0
var emotion_flush: float = 0.0
## Facial expression channels, driven by the brain and written by the rig.
## Range [0, 1] unless noted.
var brow_raise: float = 0.0     ## worry / curiosity lift
var brow_furrow: float = 0.0    ## focus / annoyance
var mouth_open: float = 0.0
var cheek_puff: float = 0.0

## The lighting rig. Three sources plus two ambients, matching the terms in
## `lighting.gdshaderinc`. Defaults are the house key: warm, upper-front, on the
## side the creature faces, with a cool kicker from behind. A room the pet sits
## in can push these around (a bright window, a dim evening desktop) — that is
## the intended way to make the pet belong to the player's desktop rather than
## look pasted on top of it.
var light_dir := Vector3(0.40, -0.66, 0.64).normalized()
var key_color := Color(1.0, 0.955, 0.885)
var key_energy: float = 1.02
var rim_dir := Vector3(-0.78, -0.36, -0.50).normalized()
var rim_color := Color(0.60, 0.75, 1.0)
var rim_energy: float = 0.85
var ambient_tint := Color(0.40, 0.50, 0.68)
var ambient_energy: float = 0.26
var bounce_tint := Color(0.38, 0.27, 0.19)
var bounce_energy: float = 0.30
var exposure: float = 1.0

## Set by `PostStack` when it takes ownership of the filmic curve, so the body is
## not tonemapped twice.
var defer_tonemap: bool = false

## Diagnostic channel for `creature_body.gdshader`; see the `debug_view` uniform
## there for the list. Read once from the environment rather than plumbed through
## the capture harness, because the harness is not this agent's file and a
## diagnostic that needs a second file edited to switch on is a diagnostic nobody
## uses. Zero in every shipped run.
static var _debug_view: int = int(OS.get_environment("PETALIA_DEBUG_VIEW"))


func _ready() -> void:
	_rect = ColorRect.new()
	_rect.color = Color(1, 1, 1, 1)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	if body_shader == null:
		body_shader = load("res://shaders/creature/creature_body.gdshader") as Shader
	_mat.shader = body_shader
	_rect.material = _mat
	add_child(_rect)
	_packed.resize(MAX_PARTS * VEC4S_PER_PART)
	_packed_eyes.resize(MAX_EYES * VEC4S_PER_EYE)
	_packed_landmarks.resize(MAX_LANDMARKS)
	_packed_limb_roots.resize(MAX_LANDMARKS)
	_palette.resize(MAX_PALETTE)


## Bind a species. Copies the bind pose into `live_parts` so the rig has
## somewhere to write without corrupting the shared resource.
func setup(p_spec: CreatureSpec) -> void:
	spec = p_spec
	live_parts.clear()
	for p in spec.parts:
		if p != null:
			live_parts.append(p.duplicate_part())
	if live_parts.size() > MAX_PARTS:
		Log.warn("CreatureRenderer", "%s declares %d parts; clamping to %d"
			% [spec.species_id, live_parts.size(), MAX_PARTS])
		live_parts.resize(MAX_PARTS)
	live_eyes.clear()
	for e in spec.eyes:
		if e == null:
			continue
		var live := EyeSpec.Live.new()
		live.copy_from(e)
		live_eyes.append(live)
	if live_eyes.size() > MAX_EYES:
		live_eyes.resize(MAX_EYES)
	_pixels_per_unit = spec.pixels_per_unit
	_upload_static()


## Gameplay-facing shading knobs, called once per frame by `Creature`.
func set_shading_state(p_growth: float, p_wetness: float, p_fluff: float,
		p_flush: float) -> void:
	growth = p_growth
	wetness = p_wetness
	fluff = p_fluff
	emotion_flush = p_flush


func _upload_static() -> void:
	_palette.resize(MAX_PALETTE)
	for i in MAX_PALETTE:
		_palette[i] = spec.palette_color(i)
	_mat.set_shader_parameter("palette", _palette)
	_mat.set_shader_parameter("coat_surface", int(spec.coat_surface))
	_mat.set_shader_parameter("coat_length", spec.coat_length)
	_mat.set_shader_parameter("coat_density", spec.coat_density)
	_mat.set_shader_parameter("translucency", spec.translucency)
	_mat.set_shader_parameter("roughness", spec.roughness)
	# Lashes are a mammal feature. A bird with eyelashes reads as a cartoon, and
	# a gecko with them reads as a mistake.
	var mammal: bool = spec.coat_surface == SDFPart.Surface.FUR
	_mat.set_shader_parameter("eye_lash", 1.0 if mammal else 0.0)
	# The marking block in the body shader is the *mammal* one: countershading, a
	# saddle, points on the extremities and a mackerel tabby. It is written for a
	# pelt, and it was running at full strength on everything because nothing ever
	# set this uniform and its default is 1.0. On the bird that showed up as four
	# pale blocks across a navy wing — read as a wing geometry bug for a whole
	# round, and actually this: a tabby, drawn on feathers.
	#
	# A bird's plumage pattern and a lizard's banding are palette decisions their
	# species files already make, part by part. They do not want a second pattern
	# invented on top, so the mammal one is switched off for them entirely rather
	# than merely turned down.
	_mat.set_shader_parameter("marking_strength", 1.0 if mammal else 0.0)


func _process(_delta: float) -> void:
	if spec == null:
		return
	_recompute_bounds()
	_pack_parts()
	_pack_eyes()
	_pack_landmarks()
	_pack_whiskers()
	_upload_dynamic()


## The quad must tightly wrap the creature: too large and we pay for empty
## pixels every frame (the shader is the expensive part), too small and the
## coat gets guillotined.
func _recompute_bounds() -> void:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in live_parts:
		var r: float = maxf(p.radius_a, p.radius_b) + p.blend
		mn = mn.min(p.a - Vector2(r, r)).min(p.b - Vector2(r, r))
		mx = mx.max(p.a + Vector2(r, r)).max(p.b + Vector2(r, r))
	if not is_finite(mn.x):
		mn = Vector2.ZERO
		mx = Vector2.ONE
	var pad := Vector2(BOUNDS_PADDING, BOUNDS_PADDING) * (spec.coat_length * 8.0 + 0.5)
	_bounds_min = mn - pad
	_bounds_max = mx + pad

	var px_size: Vector2 = (_bounds_max - _bounds_min) * _pixels_per_unit
	_rect.position = _bounds_min * _pixels_per_unit
	_rect.size = px_size


func _pack_parts() -> void:
	var n: int = live_parts.size()
	for i in n:
		var p: SDFPart = live_parts[i]
		var base: int = i * VEC4S_PER_PART
		_packed[base] = Vector4(p.a.x, p.a.y, p.b.x, p.b.y)
		_packed[base + 1] = Vector4(p.radius_a, p.radius_b, p.blend, p.height_scale)
		# x packs layer and material together: layer * 16 + material. Saves a
		# whole uniform array, and both decode with one floor().
		_packed[base + 2] = Vector4(float(p.layer) * 16.0 + float(p.surface),
			float(p.palette_index), p.groom_angle, p.coat_length)
	# Parts beyond the live count are pushed far away with zero radius so the
	# shader's fixed-length loop contributes nothing for them.
	for i in range(n, MAX_PARTS):
		var base: int = i * VEC4S_PER_PART
		_packed[base] = Vector4(1e6, 1e6, 1e6, 1e6)
		_packed[base + 1] = Vector4(0.0, 0.0, 0.001, 1.0)
		_packed[base + 2] = Vector4(0.0, 0.0, 0.0, 0.0)


## eyes[i*4+0] = (center.x, center.y, radius, tilt)
## eyes[i*4+1] = (iris_ratio, pupil_ratio * pupil_scale, pupil_slit, blink)
## eyes[i*4+2] = iris rgb, socket_depth
## eyes[i*4+3] = (gaze.x, gaze.y, lid_open, limbal luminance)
func _pack_eyes() -> void:
	for i in live_eyes.size():
		var e: EyeSpec.Live = live_eyes[i]
		var b: int = i * VEC4S_PER_EYE
		_packed_eyes[b] = Vector4(e.center.x, e.center.y, e.radius, e.tilt)
		_packed_eyes[b + 1] = Vector4(e.iris_ratio,
			clampf(e.pupil_ratio * e.pupil_scale, 0.04, 0.98), e.pupil_slit,
			clampf(e.blink, 0.0, 1.0))
		_packed_eyes[b + 2] = Vector4(e.iris_color.r, e.iris_color.g,
			e.iris_color.b, e.socket_depth)
		_packed_eyes[b + 3] = Vector4(clampf(e.gaze.x, -1.0, 1.0),
			clampf(e.gaze.y, -1.0, 1.0), e.lid_open,
			e.limbal_color.get_luminance())
	for i in range(live_eyes.size(), MAX_EYES):
		var b: int = i * VEC4S_PER_EYE
		_packed_eyes[b] = Vector4(1e6, 1e6, 0.0, 0.0)
		_packed_eyes[b + 1] = Vector4.ZERO
		_packed_eyes[b + 2] = Vector4.ZERO
		_packed_eyes[b + 3] = Vector4.ZERO


## Skeletal landmarks for the body shader, packed (x, y, radius, slope) in rig
## space.
##
## Where a limb enters the body is where the skeleton shows through it: the blade
## of the scapula over the shoulder, the point of the hip over the femur head.
## The part budget is full — a cat is 28 of 28 — so those cannot be capsules, and
## the shader raises them as relief instead. It needs to be told where.
##
## They are found geometrically rather than by part name, for two reasons. A
## species should not have to declare its own anatomy twice, and the landmarks
## have to *track the rig*: a scapula that stayed put while the foreleg swung
## under it would read worse than none at all.
##
## The one invariant this leans on is the rig-space convention itself — the
## origin sits between the paws on the ground plane, so a limb is the only thing
## on the animal that hangs below the body mass. Everything else follows.
func _pack_landmarks() -> void:
	_landmark_count = 0
	var core_r := 0.0
	var core := Vector2.ZERO
	for p in live_parts:
		var r: float = maxf(p.radius_a, p.radius_b)
		if p.layer == SDFPart.Layer.BODY and r > core_r:
			core_r = r
			core = (p.a + p.b) * 0.5
	if core_r <= 0.0:
		return

	# Limb roots: the top of anything thin enough not to be a body mass that also
	# hangs below the body's centre. The second test is what keeps ears and a
	# raised tail out — both are thin, and both sit above the torso rather than
	# under it.
	# `z` carries the limb's own half-thickness, because the socket a limb makes in
	# the body is the size of the limb and not of the body: a whippet's armpit is
	# not a cat's, and scaling the shadow off the torso gives both the same one.
	var roots: Array[Vector3] = []
	for p in live_parts:
		var lr: float = maxf(p.radius_a, p.radius_b)
		if lr >= core_r * 0.62:
			continue
		if maxf(p.a.y, p.b.y) <= core.y:
			continue
		var top: Vector2 = p.a if p.a.y < p.b.y else p.b
		roots.append(Vector3(top.x, top.y, lr))

	# One landmark per limb, not per part: the near and far leg of a pair sit
	# within a torso radius of each other in x, and the fore and hind pair are
	# most of a body length apart, so a single tolerance separates them.
	var tol: float = core_r * 2.2
	var sum_x := PackedFloat32Array()
	var top_y := PackedFloat32Array()
	var limb_r := PackedFloat32Array()
	var count := PackedInt32Array()
	for root in roots:
		var hit := -1
		for i in sum_x.size():
			if absf(sum_x[i] / float(count[i]) - root.x) <= tol:
				hit = i
				break
		if hit < 0:
			if sum_x.size() >= MAX_LANDMARKS:
				continue
			sum_x.append(root.x)
			top_y.append(root.y)
			limb_r.append(root.z)
			count.append(1)
		else:
			sum_x[hit] += root.x
			top_y[hit] = minf(top_y[hit], root.y)
			# The thickest segment of the limb, which is the one at the shoulder —
			# a limb tapers toward the paw, and sizing the socket off a toe capsule
			# would put a pinprick where the armpit is.
			limb_r[hit] = maxf(limb_r[hit], root.z)
			count[hit] += 1

	for i in sum_x.size():
		var at := Vector2(sum_x[i] / float(count[i]), top_y[i])
		# The socket, before the landmark is lifted off it. A limb does not simply
		# abut the barrel, it sinks into it, and the crease it makes there is the
		# darkest thing on the underside of a standing animal — the armpit and the
		# groin. Nothing in the shader can find these on its own: the limbs live on
		# a different depth layer from the torso, so they smooth-union with nothing
		# and accumulate no crease at all, which is exactly why the belly came out
		# as one unbroken pale slab from elbow to groin.
		#
		# Pushed a little *up* into the body from the top of the limb capsule,
		# because the crease is where the two volumes meet and the limb's own top
		# cap is already inside the barrel by about its own radius.
		_packed_limb_roots[i] = Vector4(at.x,
			at.y - limb_r[i] * 0.55, maxf(limb_r[i] * 2.10, core_r * 0.46), 1.0)
		# The bone that shows is not the joint itself: the scapula blade sits
		# above and behind the shoulder, the point of the hip above and in front
		# of the femur head. Both are toward the body's centre, so nudging the
		# landmark that way covers both without needing to know which is which.
		#
		# Height is measured from the body's own spine line rather than from the
		# limb root, and that is the whole difference between a skeleton and a
		# lump. A landmark parked at the limb root lands halfway up the barrel,
		# where the surface already faces the viewer square-on — the relief there
		# is a bulge in the middle of the flank, which is the shape of a hernia,
		# not of a shoulder blade. Both of these bones ride high, just under the
		# top line, where the surface is turning away and a small tilt of the
		# normal reads as a hard edge catching the key.
		at.y = core.y - core_r * 0.52
		at.x += signf(core.x - at.x) * core_r * 0.28
		# The slope is set by the ship size, not by the close-up. A landmark is a
		# broad shape, so unlike the coat it survives the downsample intact — and
		# at 260 px a tilt tuned to read as a scapula at review zoom is a pair of
		# soft round lumps on the flank, which is the silhouette of a bruise. It
		# has to be the amount that still says "bone" when it is fifteen pixels
		# across, and that is less than it looks like at four times the size.
		_packed_landmarks[i] = Vector4(at.x, at.y, core_r * 0.58, 1.02)
	_landmark_count = sum_x.size()
	for i in range(_landmark_count, MAX_LANDMARKS):
		_packed_landmarks[i] = Vector4(1e6, 1e6, 1.0, 0.0)
		_packed_limb_roots[i] = Vector4(1e6, 1e6, 1.0, 0.0)


## Whisker pad for the body shader, packed (x, y, length, amount) in rig space.
##
## Whiskers cannot be parts — a cat is 28 of 28 — so the shader draws them, and
## it needs an anchor. Found geometrically for the same two reasons the landmarks
## are: a species should not have to describe its own face twice, and the pad has
## to track the rig, because a whisker fan that stayed put while the head turned
## would be worse than none.
##
## The one thing the rig convention guarantees is that +x is forward, so the
## frontmost point on the animal is the tip of its snout whatever species it is.
## The pad sits behind and just below that, on the muzzle, which is where a real
## one is. Only mammals get them: a bird with whiskers reads as a mistake, the
## same way a gecko with eyelashes does.
func _pack_whiskers() -> void:
	_whisker_pad = Vector4.ZERO
	if spec.coat_surface != SDFPart.Surface.FUR:
		return
	var snout := Vector2(-INF, 0.0)
	var core_r := 0.0
	for p in live_parts:
		# The far-side layer is behind the body, so its parts are never the snout
		# even when the head is turned away.
		if p.layer != SDFPart.Layer.BEHIND:
			if p.a.x + p.radius_a > snout.x:
				snout = Vector2(p.a.x + p.radius_a, p.a.y)
			if p.b.x + p.radius_b > snout.x:
				snout = Vector2(p.b.x + p.radius_b, p.b.y)
		var r: float = maxf(p.radius_a, p.radius_b)
		if p.layer == SDFPart.Layer.BODY and r > core_r:
			core_r = r
	if not is_finite(snout.x) or core_r <= 0.0:
		return
	# Both offsets are fractions of the body's own thickness rather than of the
	# snout's, because a nose is a tiny part and scaling off it makes the fan
	# collapse onto the nose leather on any species whose nose is small.
	_whisker_pad = Vector4(snout.x - core_r * 0.42, snout.y + core_r * 0.17,
		core_r * 1.60, 1.0)


func _upload_dynamic() -> void:
	_mat.set_shader_parameter("eyes", _packed_eyes)
	_mat.set_shader_parameter("eye_count", live_eyes.size())
	_mat.set_shader_parameter("parts", _packed)
	_mat.set_shader_parameter("part_count", live_parts.size())
	_mat.set_shader_parameter("landmarks", _packed_landmarks)
	_mat.set_shader_parameter("limb_roots", _packed_limb_roots)
	_mat.set_shader_parameter("landmark_count", _landmark_count)
	_mat.set_shader_parameter("whisker_pad", _whisker_pad)
	_mat.set_shader_parameter("bounds_min", _bounds_min)
	_mat.set_shader_parameter("bounds_max", _bounds_max)
	_mat.set_shader_parameter("growth", growth)
	_mat.set_shader_parameter("wetness", wetness)
	_mat.set_shader_parameter("fluff", fluff)
	_mat.set_shader_parameter("emotion_flush", emotion_flush)
	_mat.set_shader_parameter("brow_raise", brow_raise)
	_mat.set_shader_parameter("brow_furrow", brow_furrow)
	_mat.set_shader_parameter("mouth_open", mouth_open)
	_mat.set_shader_parameter("cheek_puff", cheek_puff)
	_mat.set_shader_parameter("light_dir", light_dir)
	_mat.set_shader_parameter("key_color", key_color)
	_mat.set_shader_parameter("key_energy", key_energy)
	_mat.set_shader_parameter("rim_dir", rim_dir)
	_mat.set_shader_parameter("rim_color", rim_color)
	_mat.set_shader_parameter("rim_energy", rim_energy)
	_mat.set_shader_parameter("ambient_tint", ambient_tint)
	_mat.set_shader_parameter("ambient_energy", ambient_energy)
	_mat.set_shader_parameter("bounce_tint", bounce_tint)
	_mat.set_shader_parameter("bounce_energy", bounce_energy)
	_mat.set_shader_parameter("exposure", exposure)
	_mat.set_shader_parameter("defer_tonemap", defer_tonemap)
	_mat.set_shader_parameter("debug_view", _debug_view)
	# The on-screen pixel density, not the spec's nominal one: every coat
	# level-of-detail decision keys off this, so a pet the player has scaled up
	# has to be told it is bigger or its fur stays at desktop-size frequencies.
	_mat.set_shader_parameter("px_per_unit", _pixels_per_unit * _view_scale())


## Uniform screen scale currently applied to this node by its ancestors. Godot
## allows non-uniform and skewed transforms; the coat only needs one number, so
## take the geometric mean rather than an arbitrary axis.
func _view_scale() -> float:
	var s := global_scale.abs()
	return maxf(sqrt(maxf(s.x * s.y, 1e-6)), 0.01)


## World-space (pixel) bounding rectangle, used for hit-testing and for the
## desktop navigator's collision queries.
func pixel_bounds() -> Rect2:
	return Rect2(_bounds_min * _pixels_per_unit,
		(_bounds_max - _bounds_min) * _pixels_per_unit)
