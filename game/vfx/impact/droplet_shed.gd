class_name VfxDropletShed
extends VfxEffect

## Water leaving a wet coat on its own — the slow version.
##
## Nothing here is a burst. A wet animal sheds one or two drops at a time, from
## the low points of its silhouette, for as long as it stays wet. The effect is
## therefore parameterised by *wetness* rather than by an impact, and the
## director re-fires it on a slow timer instead of on an event.
##
## Emission is from a rectangle biased to the underside of the body, because
## water runs down before it falls off, and drops that appear along the animal's
## back read as rain rather than as shedding.

const DROPLET_SHADER := "res://vfx/particles/droplet.gdshader"

var _drops: CPUParticles2D
var _mat: ShaderMaterial


func _build() -> void:
	priority = Priority.CHATTER
	min_tier = 1
	duration = 1.4

	_drops = VfxEffect.make_emitter(load(DROPLET_SHADER) as Shader, 3, 0.85, 26.0)
	_drops.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_drops.emission_rect_extents = Vector2(30.0, 8.0)
	# Spread the drops out in time: a wet dog drips, it does not spray.
	_drops.explosiveness = 0.05
	_drops.direction = Vector2(0.0, 1.0)
	_drops.spread = 14.0
	_drops.initial_velocity_min = 6.0
	_drops.initial_velocity_max = 30.0
	_drops.gravity = Vector2(0.0, 620.0)
	_drops.damping_min = 0.0
	_drops.damping_max = 4.0
	# Aligning the quad with velocity is what turns a bead into a streak as it
	# accelerates, with no extra work anywhere.
	_drops.particle_flag_align_y = true
	_drops.scale_amount_min = 14.0
	_drops.scale_amount_max = 26.0
	_drops.lifetime_randomness = 0.5
	_mat = _drops.material as ShaderMaterial
	add_child(_drops)


func cost() -> int:
	return _drops.amount


func _restart() -> void:
	var wet: float = clampf(float(params.get("wetness", 1.0)), 0.0, 1.0)
	var width: float = float(params.get("width", 60.0))
	_drops.amount = scaled_count(maxi(1, int(round(lerpf(1.0, 4.0, wet)))))
	_drops.emission_rect_extents = Vector2(maxf(width * 0.42, 8.0), 7.0)
	_drops.scale_amount_max = lerpf(18.0, 28.0, wet)
	_drops.color = Color(1, 1, 1, clampf(0.45 + 0.55 * wet, 0.0, 1.0))

	_mat.set_shader_parameter("water_color", lit_color(0.55).lerp(
		Color(0.58, 0.72, 0.88), 0.6))
	_mat.set_shader_parameter("spec_color", lit_color(0.0))
	_mat.set_shader_parameter("key_dir", key_dir())
	# Gravity is doing the stretching; the shader only needs a bead to start
	# from, so `stretch` stays low here and high on the shake-off.
	_mat.set_shader_parameter("stretch", 0.28)
	_mat.set_shader_parameter("body_alpha", 0.18)
	_mat.set_shader_parameter("rise", 0.05)
	_mat.set_shader_parameter("settle", 0.18)

	duration = _drops.lifetime * 2.2
	_drops.restart()


func _sleep() -> void:
	_drops.emitting = false
