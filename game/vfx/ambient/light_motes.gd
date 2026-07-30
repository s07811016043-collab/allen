class_name VfxLightMotes
extends VfxEffect

## Dust motes hanging in the air near the pet.
##
## The only continuously-emitting effect in the layer, and the one with the
## strictest budget, because it is on screen for hours. Twelve particles at
## default quality, each a couple of pixels of additive light.
##
## Two things keep it from reading as a sparkle filter. First, motes are only
## visible when they are near the key light's path, so the emission box is
## offset towards the light rather than centred on the animal. Second, the
## brightness follows `VfxTimeOfDay`: motes are strongest in the raking light of
## late afternoon, almost gone at noon when there is no contrast to catch, and
## gone entirely at night.

const MOTE_SHADER := "res://vfx/particles/mote.gdshader"

var _motes: CPUParticles2D
var _mat: ShaderMaterial
var _gain: float = 0.2
var _area := Vector2(180.0, 140.0)


func _build() -> void:
	priority = Priority.CHATTER
	min_tier = 1
	looping = true
	duration = 1e9

	_motes = VfxEffect.make_emitter(load(MOTE_SHADER) as Shader, 12, 5.5, 16.0)
	_motes.one_shot = false
	_motes.explosiveness = 0.0
	_motes.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_motes.emission_rect_extents = _area * 0.5
	# Motes do not fall, they wander. Almost no gravity, tiny velocities and a
	# little tangential acceleration is the whole simulation.
	_motes.direction = Vector2(0.0, -1.0)
	_motes.spread = 180.0
	_motes.initial_velocity_min = 2.0
	_motes.initial_velocity_max = 11.0
	_motes.gravity = Vector2(0.0, -3.5)
	_motes.tangential_accel_min = -6.0
	_motes.tangential_accel_max = 6.0
	_motes.damping_min = 0.0
	_motes.damping_max = 1.5
	_motes.scale_amount_min = 10.0
	_motes.scale_amount_max = 22.0
	_motes.lifetime_randomness = 0.6
	_mat = _motes.material as ShaderMaterial
	add_child(_motes)


func cost() -> int:
	return _motes.amount


func _restart() -> void:
	_area = params.get("area", Vector2(190.0, 150.0))
	_motes.emission_rect_extents = _area * 0.5
	# Push the box towards the light: a mote only exists visually where a beam
	# is passing, and the beam comes from the key.
	_motes.position = key_dir() * (_area.y * 0.28)
	_motes.amount = scaled_count(int(params.get("count", 12)))
	_motes.color = Color(1, 1, 1, 1)
	# A mote is three or four pixels of light with a halo around it. Smaller
	# than that and the anti-aliasing dims it below the point of existing;
	# larger and it stops being dust and starts being a firefly.
	_mat.set_shader_parameter("core_size", 0.16)
	_mat.set_shader_parameter("halo_size", 0.58)
	_mat.set_shader_parameter("twinkle", 0.62)
	_mat.set_shader_parameter("twinkle_hz", 0.42)
	_motes.emitting = true


func _tick(_t: float, delta: float) -> void:
	# Raking light makes motes; overhead light and darkness do not. The curve
	# peaks around golden hour and bottoms out at both ends of the day.
	var rake: float = 1.0
	var day: float = 1.0
	if light != null:
		var d := light.light_dir_2d()
		# |x| is large when the sun is low, which is exactly when motes show.
		rake = clampf(absf(d.x) * 1.7 + 0.15, 0.0, 1.0)
		day = clampf(light.brightness * 1.4, 0.0, 1.0)
	var target: float = 0.46 * rake * day * float(params.get("gain", 1.0))
	# Smoothed, because this tracks the time of day and must never be caught
	# changing.
	_gain = lerpf(_gain, target, clampf(delta * 0.5, 0.0, 1.0))
	_mat.set_shader_parameter("gain", _gain)
	_mat.set_shader_parameter("mote_color", lit_color(0.15))


func _sleep() -> void:
	_motes.emitting = false
