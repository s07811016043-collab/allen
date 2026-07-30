class_name VfxFootfallPuff
extends VfxEffect

## The small puff under a paw.
##
## This fires once per step, which on a walking quadruped is roughly four times
## a second, all day. It is therefore the most budget-sensitive effect in the
## layer and the one most likely to become visual noise, so it obeys two rules:
##
## * Below a walking speed it does not exist at all. A cat padding slowly across
##   a desk does not raise dust, and drawing one anyway is the single fastest
##   way to make a pet look cheap.
## * Everything scales with speed together — count, size, opacity and how far
##   the puff is kicked backwards — so a trot and a sprint differ in kind, not
##   just in amount.

const DUST_SHADER := "res://vfx/particles/dust.gdshader"
## Normalised speed below which a step raises nothing.
const SPEED_FLOOR := 0.22

var _dust: CPUParticles2D
var _mat: ShaderMaterial


func _build() -> void:
	priority = Priority.CHATTER
	# Pure garnish: the first thing to go when the machine is busy.
	min_tier = 1
	duration = 0.9

	_dust = VfxEffect.make_emitter(load(DUST_SHADER) as Shader, 3, 0.55, 26.0)
	_dust.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_dust.emission_sphere_radius = 5.0
	_dust.explosiveness = 0.9
	_dust.spread = 34.0
	_dust.damping_min = 90.0
	_dust.damping_max = 150.0
	_dust.gravity = Vector2(0.0, -14.0)
	_dust.lifetime_randomness = 0.35
	_mat = _dust.material as ShaderMaterial
	add_child(_dust)


func cost() -> int:
	return _dust.amount


func _restart() -> void:
	var speed: float = clampf(float(params.get("speed", 0.5)), 0.0, 1.5)
	var facing: float = signf(float(params.get("facing", 1.0)))
	# The puff is kicked backwards, opposite the direction of travel.
	_dust.direction = Vector2(-facing, -0.42).normalized()

	var over: float = clampf((speed - SPEED_FLOOR) / (1.0 - SPEED_FLOOR), 0.0, 1.2)
	_dust.amount = scaled_count(1 + int(round(over * 3.0)))
	_dust.initial_velocity_min = 18.0 + 40.0 * over
	_dust.initial_velocity_max = 40.0 + 130.0 * over
	_dust.scale_amount_min = lerpf(14.0, 24.0, over)
	_dust.scale_amount_max = lerpf(26.0, 52.0, over)
	_dust.lifetime = lerpf(0.42, 0.7, over)
	_dust.color = Color(1, 1, 1, 1)

	var ground: Color = params.get("ground", Color(0.46, 0.42, 0.38))
	_mat.set_shader_parameter("lit_color", lit_color(0.25))
	_mat.set_shader_parameter("shade_color", shadow_color().lerp(ground, 0.55))
	_mat.set_shader_parameter("key_dir", key_dir())
	_mat.set_shader_parameter("density", clampf(0.10 + 0.16 * over, 0.0, 0.26)
		* (1.0 - night() * 0.3))
	_mat.set_shader_parameter("softness", 0.66)
	_mat.set_shader_parameter("breakup", 0.6)
	_mat.set_shader_parameter("expand", 2.2)
	_mat.set_shader_parameter("rise", 0.06)
	_mat.set_shader_parameter("settle", 0.68)

	duration = _dust.lifetime * 1.6
	_dust.restart()


## Steps below the floor speed are refused outright rather than spawned at zero
## opacity, so they never take a slot in the director's budget.
static func wanted(speed: float) -> bool:
	return speed > SPEED_FLOOR


func _sleep() -> void:
	_dust.emitting = false
