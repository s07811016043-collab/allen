class_name VfxBreathVapour
extends VfxEffect

## Visible breath, for cold moods.
##
## One exhale per play. The shape is the whole point: a breath leaves narrow and
## fast, then slows, expands and disperses, so the emitter fires a short cone
## with heavy drag while the dust shader does the expansion. A puff that keeps
## its size while it fades looks like smoke from a machine.
##
## Gated on `VfxTimeOfDay.chill` by the director rather than here, so a designer
## can also trigger it deliberately — a sigh in a warm room is a legitimate
## thing to want.

const DUST_SHADER := "res://vfx/particles/dust.gdshader"

var _puff: CPUParticles2D
var _mat: ShaderMaterial


func _build() -> void:
	priority = Priority.CHATTER
	min_tier = 1
	duration = 1.9

	_puff = VfxEffect.make_emitter(load(DUST_SHADER) as Shader, 5, 1.25, 34.0)
	_puff.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_puff.emission_sphere_radius = 3.0
	# Released over a fraction of a second, not all at once: an exhale has a
	# front and a tail.
	_puff.explosiveness = 0.55
	_puff.spread = 15.0
	_puff.initial_velocity_min = 34.0
	_puff.initial_velocity_max = 86.0
	# Drag kills the forward motion quickly; the gentle negative gravity is warm
	# air rising once it has stopped.
	_puff.damping_min = 60.0
	_puff.damping_max = 95.0
	_puff.gravity = Vector2(0.0, -22.0)
	_puff.scale_amount_min = 22.0
	_puff.scale_amount_max = 48.0
	_puff.lifetime_randomness = 0.4
	_mat = _puff.material as ShaderMaterial
	add_child(_puff)


func cost() -> int:
	return _puff.amount


func _restart() -> void:
	var facing: float = signf(float(params.get("facing", 1.0)))
	var strength: float = clampf(float(params.get("strength", 1.0)), 0.2, 1.5)
	_puff.direction = Vector2(facing, -0.30).normalized()
	_puff.amount = scaled_count(int(round(lerpf(3.0, 6.0, minf(strength, 1.0)))))
	_puff.initial_velocity_max = lerpf(60.0, 110.0, minf(strength, 1.0))
	_puff.color = Color(1, 1, 1, 1)

	# Vapour is lit by everything and blocks nothing, so it takes the ambient
	# almost neat rather than the key.
	_mat.set_shader_parameter("lit_color", lit_color(0.6).lerp(Color.WHITE, 0.35))
	_mat.set_shader_parameter("shade_color", lit_color(0.9) * 0.8)
	_mat.set_shader_parameter("key_dir", key_dir())
	_mat.set_shader_parameter("density", clampf(0.26 * strength, 0.0, 0.34))
	_mat.set_shader_parameter("softness", 0.92)
	_mat.set_shader_parameter("breakup", 0.30)
	_mat.set_shader_parameter("expand", 3.4)
	_mat.set_shader_parameter("rise", 0.16)
	_mat.set_shader_parameter("settle", 0.78)

	duration = _puff.lifetime * 1.9
	_puff.restart()


func _sleep() -> void:
	_puff.emitting = false
