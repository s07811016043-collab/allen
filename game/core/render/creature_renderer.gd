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
var light_dir := Vector3(-0.42, -0.62, 0.66).normalized()
var ambient_tint := Color(0.62, 0.68, 0.82)
var bounce_tint := Color(0.30, 0.28, 0.26)


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


func _process(_delta: float) -> void:
	if spec == null:
		return
	_recompute_bounds()
	_pack_parts()
	_pack_eyes()
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


func _upload_dynamic() -> void:
	_mat.set_shader_parameter("eyes", _packed_eyes)
	_mat.set_shader_parameter("eye_count", live_eyes.size())
	_mat.set_shader_parameter("parts", _packed)
	_mat.set_shader_parameter("part_count", live_parts.size())
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
	_mat.set_shader_parameter("ambient_tint", ambient_tint)
	_mat.set_shader_parameter("bounce_tint", bounce_tint)
	_mat.set_shader_parameter("px_per_unit", _pixels_per_unit)


## World-space (pixel) bounding rectangle, used for hit-testing and for the
## desktop navigator's collision queries.
func pixel_bounds() -> Rect2:
	return Rect2(_bounds_min * _pixels_per_unit,
		(_bounds_max - _bounds_min) * _pixels_per_unit)
