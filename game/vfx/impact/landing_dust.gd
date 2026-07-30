class_name VfxLandingDust
extends VfxEffect

## Dust thrown out by a landing.
##
## Two emitters, one per side, rather than one radial burst. Radial bursts
## always look like an explosion: the dust leaves at every angle equally,
## including straight up, which no landing does. Real landing dust runs *along*
## the floor, and it runs further on the side the animal was travelling towards
## because that momentum has to go somewhere.
##
## So each side is weighted independently by the horizontal component of the
## impact velocity. Land straight down and it is symmetric; land out of a sprint
## and nearly all of it goes forward. That asymmetry is the whole effect.

const DUST_SHADER := "res://vfx/particles/dust.gdshader"

var _left: CPUParticles2D
var _right: CPUParticles2D
var _left_mat: ShaderMaterial
var _right_mat: ShaderMaterial


func _build() -> void:
	priority = Priority.NORMAL
	duration = 1.6
	_left = _make_side(-1.0)
	_right = _make_side(1.0)
	_left_mat = _left.material as ShaderMaterial
	_right_mat = _right.material as ShaderMaterial
	add_child(_left)
	add_child(_right)


func _make_side(sx: float) -> CPUParticles2D:
	var p := VfxEffect.make_emitter(load(DUST_SHADER) as Shader, 8, 1.05, 40.0)
	# Dust comes off the whole width of the contact, not off a point.
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(14.0, 3.0)
	p.explosiveness = 0.94
	# A shallow angle above the floor. Anything steeper reads as a bomb.
	p.direction = Vector2(sx, -0.24).normalized()
	p.spread = 20.0
	p.initial_velocity_min = 60.0
	p.initial_velocity_max = 210.0
	# Strong drag and a little lift: the cloud runs out, slows, and then rises
	# on its own turbulence instead of falling back like sand.
	p.damping_min = 130.0
	p.damping_max = 210.0
	p.gravity = Vector2(0.0, -26.0)
	p.scale_amount_min = 26.0
	p.scale_amount_max = 70.0
	p.lifetime_randomness = 0.4
	return p


func cost() -> int:
	return _left.amount + _right.amount


func _restart() -> void:
	# `impact` is the vertical speed at contact, normalised so 1.0 is a fall the
	# player would call heavy.
	var impact: float = clampf(float(params.get("impact", 1.0)), 0.05, 2.0)
	var vel: Vector2 = params.get("velocity", Vector2.ZERO)
	var width: float = float(params.get("width", 28.0))
	var bias: float = clampf(vel.x / 260.0, -1.0, 1.0)

	var base: int = int(round(lerpf(3.0, 10.0, minf(impact, 1.0))))
	var k := key_dir()
	var ground: Color = params.get("ground", Color(0.46, 0.42, 0.38))

	_configure(_left, _left_mat, base, impact, 1.0 - bias, width, k, ground)
	_configure(_right, _right_mat, base, impact, 1.0 + bias, width, k, ground)

	duration = _left.lifetime * 1.6 + 0.2
	_left.restart()
	_right.restart()


func _configure(p: CPUParticles2D, m: ShaderMaterial, base: int, impact: float,
		weight: float, width: float, k: Vector2, ground: Color) -> void:
	p.amount = scaled_count(maxi(1, int(round(float(base) * clampf(weight, 0.15, 2.0)))))
	p.emission_rect_extents = Vector2(maxf(width * 0.5, 6.0), 3.0)
	p.initial_velocity_min = 50.0 * impact * weight
	p.initial_velocity_max = 210.0 * impact * clampf(weight, 0.3, 2.0)
	p.scale_amount_max = lerpf(44.0, 84.0, minf(impact, 1.0))
	p.color = Color(1, 1, 1, clampf(0.6 + 0.4 * impact, 0.0, 1.0))
	m.set_shader_parameter("lit_color", lit_color(0.22))
	m.set_shader_parameter("shade_color", shadow_color().lerp(ground, 0.55))
	m.set_shader_parameter("key_dir", k)
	# Landing dust is the loudest thing this layer does, and it still lives
	# under a third opacity. The read comes from the shape and the speed.
	m.set_shader_parameter("density", clampf(0.20 + 0.14 * impact, 0.0, 0.34)
		* (1.0 - night() * 0.3))
	m.set_shader_parameter("softness", 0.58)
	m.set_shader_parameter("breakup", 0.68)
	m.set_shader_parameter("expand", 2.6)
	m.set_shader_parameter("rise", 0.045)
	m.set_shader_parameter("settle", 0.7)


func _sleep() -> void:
	_left.emitting = false
	_right.emitting = false
