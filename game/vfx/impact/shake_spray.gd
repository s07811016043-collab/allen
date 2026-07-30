class_name VfxShakeSpray
extends VfxEffect

## The full-body shake — the loudest thing a wet animal does.
##
## The reason a shake reads as a shake and not as an explosion is that the spray
## *sweeps*. The animal rotates two or three times, and the fan of water follows
## it round. So this emitter is deliberately not explosive: it releases over
## roughly a third of a second while `_tick` rotates its direction back and
## forth, which produces the arcs across the fan for free.
##
## A second, much softer emitter puts a haze of fine mist behind the droplets.
## Without it the drops read as individually launched objects; with it they read
## as one mass of water leaving one animal.

const DROPLET_SHADER := "res://vfx/particles/droplet.gdshader"
const DUST_SHADER := "res://vfx/particles/dust.gdshader"

var _drops: CPUParticles2D
var _mist: CPUParticles2D
var _drop_mat: ShaderMaterial
var _mist_mat: ShaderMaterial
var _sweeps: float = 2.5
var _facing: float = 1.0


func _build() -> void:
	priority = Priority.NORMAL
	duration = 1.3

	_drops = VfxEffect.make_emitter(load(DROPLET_SHADER) as Shader, 22, 0.62, 26.0)
	_drops.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_drops.emission_sphere_radius = 22.0
	# Emission spread over most of the cycle; this is what lets the sweep exist.
	_drops.explosiveness = 0.12
	_drops.spread = 26.0
	_drops.initial_velocity_min = 190.0
	_drops.initial_velocity_max = 430.0
	_drops.gravity = Vector2(0.0, 900.0)
	_drops.damping_min = 30.0
	_drops.damping_max = 70.0
	_drops.particle_flag_align_y = true
	_drops.scale_amount_min = 16.0
	_drops.scale_amount_max = 30.0
	_drops.lifetime_randomness = 0.45
	_drop_mat = _drops.material as ShaderMaterial
	add_child(_drops)

	_mist = VfxEffect.make_emitter(load(DUST_SHADER) as Shader, 6, 0.7, 54.0)
	_mist.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	_mist.emission_sphere_radius = 26.0
	_mist.explosiveness = 0.25
	_mist.spread = 60.0
	_mist.initial_velocity_min = 40.0
	_mist.initial_velocity_max = 150.0
	_mist.damping_min = 120.0
	_mist.damping_max = 200.0
	_mist.gravity = Vector2(0.0, 60.0)
	_mist.scale_amount_min = 40.0
	_mist.scale_amount_max = 90.0
	_mist_mat = _mist.material as ShaderMaterial
	add_child(_mist)


func cost() -> int:
	return _drops.amount + _mist.amount


func _restart() -> void:
	var power: float = clampf(float(params.get("power", 1.0)), 0.2, 1.5)
	var radius: float = maxf(float(params.get("radius", 34.0)), 10.0)
	_facing = signf(float(params.get("facing", 1.0)))
	_sweeps = 2.5 if not calm else 1.5

	_drops.amount = scaled_count(int(round(lerpf(10.0, 26.0, power))))
	_drops.emission_sphere_radius = radius * 0.7
	_drops.initial_velocity_max = lerpf(280.0, 480.0, power) * (0.6 if calm else 1.0)
	_drops.color = Color(1, 1, 1, 1)
	_drop_mat.set_shader_parameter("water_color", lit_color(0.5).lerp(
		Color(0.62, 0.76, 0.9), 0.55))
	_drop_mat.set_shader_parameter("spec_color", lit_color(0.0))
	_drop_mat.set_shader_parameter("key_dir", key_dir())
	# Fast water is a streak, not a bead.
	_drop_mat.set_shader_parameter("stretch", 0.78)
	_drop_mat.set_shader_parameter("body_alpha", 0.16)
	_drop_mat.set_shader_parameter("rise", 0.04)
	_drop_mat.set_shader_parameter("settle", 0.26)

	_mist.amount = scaled_count(int(round(lerpf(3.0, 7.0, power))))
	_mist.emission_sphere_radius = radius * 0.85
	_mist.color = Color(1, 1, 1, 1)
	_mist_mat.set_shader_parameter("lit_color", lit_color(0.15))
	_mist_mat.set_shader_parameter("shade_color", Color(0.42, 0.50, 0.60))
	_mist_mat.set_shader_parameter("key_dir", key_dir())
	_mist_mat.set_shader_parameter("density", 0.16 * (1.0 - night() * 0.35))
	_mist_mat.set_shader_parameter("softness", 0.9)
	_mist_mat.set_shader_parameter("breakup", 0.35)
	_mist_mat.set_shader_parameter("expand", 2.4)
	_mist_mat.set_shader_parameter("rise", 0.1)
	_mist_mat.set_shader_parameter("settle", 0.7)

	duration = _drops.lifetime * 2.4
	_drops.restart()
	_mist.restart()


func _tick(t: float, _delta: float) -> void:
	# The animal twists back and forth; the fan of water follows. Emission only
	# happens over the first part of the life, so the sweep is compressed into
	# that window rather than spread across the whole effect.
	var emit_phase: float = clampf(t / 0.42, 0.0, 1.0)
	var swing: float = sin(emit_phase * TAU * _sweeps)
	# Water leaves roughly perpendicular to the body, so the fan sits around
	# horizontal and rocks through about 50 degrees.
	var ang: float = swing * 0.44
	_drops.direction = Vector2(_facing * cos(ang), -0.35 + sin(ang) * 0.6).normalized()
	_mist.direction = _drops.direction


func _sleep() -> void:
	_drops.emitting = false
	_mist.emitting = false
