class_name VfxTouchDust
extends VfxEffect

## Dust and loose hairs lifting off a coat that has just been touched.
##
## Two emitters rather than one, because they obey different physics and mixing
## them into a single system is how this ends up looking like a generic puff:
##
## * Dust is light. It is thrown clear of the hand, loses its velocity almost
##   immediately to drag, and then hangs in the air being lit.
## * Hairs are heavy enough to fall and long enough to tumble. They leave along
##   the stroke, arc over, and drop out of frame.
##
## Counts are deliberately small. Real hands do not raise a cloud, and this runs
## every time the player moves the cursor across a sleeping animal.

const DUST_SHADER := "res://vfx/particles/dust.gdshader"
const HAIR_SHADER := "res://vfx/particles/hair.gdshader"

var _dust: CPUParticles2D
var _hair: CPUParticles2D
var _dust_mat: ShaderMaterial
var _hair_mat: ShaderMaterial
var _base_dust := 9
var _base_hair := 3


func _build() -> void:
	priority = Priority.CHATTER
	duration = 1.7

	_dust = VfxEffect.make_emitter(load(DUST_SHADER) as Shader, _base_dust, 0.95, 30.0)
	# A hand covers an area; emitting from a point makes the burst read as a
	# firework going off under the fur.
	_dust.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_dust.emission_sphere_radius = 16.0
	_dust.explosiveness = 0.82
	_dust.spread = 46.0
	_dust.initial_velocity_min = 26.0
	_dust.initial_velocity_max = 78.0
	# Heavy drag plus almost no gravity: dust stops where it was thrown and then
	# just sits in the light, which is what dust does.
	_dust.damping_min = 55.0
	_dust.damping_max = 95.0
	_dust.gravity = Vector2(0.0, 16.0)
	_dust.scale_amount_min = 20.0
	_dust.scale_amount_max = 44.0
	_dust_mat = _dust.material as ShaderMaterial
	add_child(_dust)

	_hair = VfxEffect.make_emitter(load(HAIR_SHADER) as Shader, _base_hair, 1.6, 34.0)
	_hair.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_hair.emission_sphere_radius = 13.0
	_hair.explosiveness = 0.7
	_hair.spread = 38.0
	_hair.initial_velocity_min = 55.0
	_hair.initial_velocity_max = 130.0
	_hair.damping_min = 26.0
	_hair.damping_max = 44.0
	_hair.gravity = Vector2(0.0, 150.0)
	_hair.angular_velocity_min = -220.0
	_hair.angular_velocity_max = 220.0
	_hair.scale_amount_min = 32.0
	_hair.scale_amount_max = 54.0
	_hair.lifetime_randomness = 0.45
	_hair_mat = _hair.material as ShaderMaterial
	add_child(_hair)


func cost() -> int:
	return _dust.amount + _hair.amount


func _restart() -> void:
	var strength: float = clampf(float(params.get("strength", 1.0)), 0.0, 1.5)
	var dir: Vector2 = params.get("dir", Vector2(-1.0, -0.4))
	if dir.length_squared() < 1e-6:
		dir = Vector2(-1.0, -0.4)
	dir = dir.normalized()
	# Everything leaves at a shallow angle above the stroke: material lifted off
	# a surface goes up, not straight out sideways.
	var away := (dir + Vector2(0.0, -0.55)).normalized()

	var coat: Color = params.get("coat", Color(0.44, 0.35, 0.29))
	var k := key_dir()

	_dust.amount = scaled_count(int(round(float(_base_dust) * (0.5 + strength * 0.6))))
	_dust.direction = away
	_dust.initial_velocity_max = lerpf(48.0, 96.0, strength)
	_dust.color = Color(1, 1, 1, clampf(0.55 + 0.35 * strength, 0.0, 1.0))
	_dust_mat.set_shader_parameter("lit_color", lit_color(0.18))
	_dust_mat.set_shader_parameter("shade_color", shadow_color().lerp(coat, 0.45))
	_dust_mat.set_shader_parameter("key_dir", k)
	_dust_mat.set_shader_parameter("density", lerpf(0.16, 0.30, strength) * (1.0 - night() * 0.35))
	_dust_mat.set_shader_parameter("softness", 0.70)
	_dust_mat.set_shader_parameter("breakup", 0.55)
	_dust_mat.set_shader_parameter("expand", 2.1)
	_dust_mat.set_shader_parameter("rise", 0.08)
	_dust_mat.set_shader_parameter("settle", 0.72)

	# Hairs are the detail people actually notice, so they survive to tier 0 —
	# but only one or two of them.
	_hair.amount = scaled_count(maxi(1, int(round(float(_base_hair) * strength))))
	_hair.direction = away
	_hair.initial_velocity_max = lerpf(90.0, 165.0, strength)
	_hair.color = Color(1, 1, 1, 1)
	_hair_mat.set_shader_parameter("hair_color", coat.lerp(shadow_color(), 0.25))
	_hair_mat.set_shader_parameter("sheen_color", lit_color(0.1))
	_hair_mat.set_shader_parameter("key_dir", k)
	_hair_mat.set_shader_parameter("thickness", 0.055)
	_hair_mat.set_shader_parameter("curl", 0.26)

	duration = maxf(_dust.lifetime, _hair.lifetime) * 1.5 + 0.15
	_dust.restart()
	_hair.restart()


func _sleep() -> void:
	_dust.emitting = false
	_hair.emitting = false
