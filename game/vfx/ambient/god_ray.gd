class_name VfxGodRay
extends VfxEffect

## A shaft of light lying across the pet when it settles somewhere bright.
##
## Fades itself in and out over seconds rather than switching, and refuses to
## exist at all unless three conditions hold: the day is bright, the key is
## raking rather than overhead, and the caller says the pet is actually sitting
## in a lit spot. A god ray that appears wherever the pet stands is a filter,
## not a light.

const SHADER_PATH := "res://vfx/ambient/god_ray.gdshader"
const BASE_SIZE := 260.0

var _rect: ColorRect
var _mat: ShaderMaterial
var _gain: float = 0.0


func _build() -> void:
	priority = Priority.CHATTER
	# Ambience with a real fill cost; it is the first thing a low tier drops.
	min_tier = 2
	looping = true
	duration = 1e9

	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.color = Color.WHITE
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH) as Shader
	_rect.material = _mat
	add_child(_rect)
	_resize(BASE_SIZE)


func _resize(s: float) -> void:
	_rect.position = Vector2(-s, -s)
	_rect.size = Vector2(s * 2.0, s * 2.0)


func _restart() -> void:
	_resize(float(params.get("radius", 130.0)) * 2.1)
	_mat.set_shader_parameter("width", 0.30)
	_mat.set_shader_parameter("bands", 4.2)
	_mat.set_shader_parameter("drift", 0.05)
	_mat.set_shader_parameter("feather", 0.52)


func _tick(_t: float, delta: float) -> void:
	# `exposure` is the caller's claim about how bright this spot is: the
	# navigator knows whether the pet is on a bright patch of wallpaper or under
	# a window, and this layer should not be guessing at it.
	var exposure: float = clampf(float(params.get("exposure", 1.0)), 0.0, 1.0)
	var rake: float = 1.0
	var day: float = 1.0
	var beam := Vector2(0.55, 0.83)
	if light != null:
		var k := light.light_dir_2d()
		beam = -k
		# A shaft only exists when the light comes in at an angle; straight down
		# produces no visible beam, only a bright floor.
		rake = clampf(absf(k.x) * 2.0 - 0.15, 0.0, 1.0)
		day = clampf((light.brightness - 0.35) / 0.5, 0.0, 1.0)
	var target: float = 0.21 * rake * day * exposure * (0.55 if calm else 1.0)
	# A second and a half of time constant. Long enough that the player never
	# catches it switching on, short enough that a pet which settles in a bright
	# spot is lit by the time it has finished settling.
	_gain = lerpf(_gain, target, clampf(delta / 1.5, 0.0, 1.0))
	_mat.set_shader_parameter("gain", _gain)
	_mat.set_shader_parameter("beam_dir", beam)
	_mat.set_shader_parameter("tint", lit_color(0.12))


func _sleep() -> void:
	_gain = 0.0
	_mat.set_shader_parameter("gain", 0.0)
