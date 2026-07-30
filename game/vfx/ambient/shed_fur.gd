class_name VfxShedFur
extends VfxEffect

## One hair, occasionally, drifting down.
##
## The cheapest effect here and one of the most valuable: a single strand
## tumbling out of frame every twenty seconds is a small, constant reminder that
## the thing on the desktop is made of hair. It costs two particles.
##
## The physics that matter are drag and tumble. A hair falls slowly, wanders
## sideways as it turns, and never accelerates the way a droplet does — so the
## gravity here is a tenth of the shed-water value and the damping is high
## enough that terminal velocity arrives almost immediately.

const HAIR_SHADER := "res://vfx/particles/hair.gdshader"

var _hair: CPUParticles2D
var _mat: ShaderMaterial


func _build() -> void:
	priority = Priority.CHATTER
	min_tier = 1
	duration = 4.5

	_hair = VfxEffect.make_emitter(load(HAIR_SHADER) as Shader, 1, 3.4, 30.0)
	_hair.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_hair.emission_rect_extents = Vector2(34.0, 16.0)
	_hair.explosiveness = 0.35
	_hair.direction = Vector2(0.0, 1.0)
	_hair.spread = 55.0
	_hair.initial_velocity_min = 4.0
	_hair.initial_velocity_max = 22.0
	_hair.gravity = Vector2(0.0, 26.0)
	_hair.damping_min = 8.0
	_hair.damping_max = 18.0
	# A slow tumble. Fast rotation reads as a spark.
	_hair.angular_velocity_min = -46.0
	_hair.angular_velocity_max = 46.0
	_hair.scale_amount_min = 30.0
	_hair.scale_amount_max = 50.0
	_hair.lifetime_randomness = 0.5
	_mat = _hair.material as ShaderMaterial
	add_child(_hair)


func cost() -> int:
	return _hair.amount


func _restart() -> void:
	var coat: Color = params.get("coat", Color(0.44, 0.35, 0.29))
	var width: float = float(params.get("width", 70.0))
	_hair.emission_rect_extents = Vector2(maxf(width * 0.42, 10.0), 14.0)
	_hair.amount = 1 if tier <= 1 else 2
	_hair.color = Color(1, 1, 1, 0.9)
	_mat.set_shader_parameter("hair_color", coat.lerp(shadow_color(), 0.3))
	_mat.set_shader_parameter("sheen_color", lit_color(0.1))
	_mat.set_shader_parameter("key_dir", key_dir())
	# A single hair is one or two pixels wide; below that the anti-aliasing eats
	# it and the effect stops existing. The thickness is set so the strand is
	# never thinner than about two pixels at the quad sizes above.
	_mat.set_shader_parameter("thickness", 0.055)
	_mat.set_shader_parameter("curl", 0.30)
	_mat.set_shader_parameter("rise", 0.05)
	_mat.set_shader_parameter("settle", 0.30)
	duration = _hair.lifetime * 1.7
	_hair.restart()


func _sleep() -> void:
	_hair.emitting = false
