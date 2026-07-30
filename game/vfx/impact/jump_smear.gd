class_name VfxJumpSmear
extends VfxEffect

## The stretch on a takeoff.
##
## Short by design: 150 ms, which is two or three frames of screen time at the
## speeds a desktop pet jumps at. A smear that lasts long enough to be examined
## stops being a smear and starts being a ghost.
##
## Reads the back buffer, so it is the one effect gated behind the high quality
## tier — but it is also pure garnish, and losing it costs the player nothing
## except a little snap.

const SHADER_PATH := "res://vfx/impact/jump_smear.gdshader"
const BASE_SIZE := 150.0

var _bbc: BackBufferCopy
var _rect: ColorRect
var _mat: ShaderMaterial
var _strength: float = 0.7


func _build() -> void:
	priority = Priority.CHATTER
	min_tier = 2
	duration = 0.15

	_bbc = BackBufferCopy.new()
	_bbc.copy_mode = BackBufferCopy.COPY_MODE_RECT
	add_child(_bbc)

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
	_bbc.rect = Rect2(Vector2(-s * 1.1, -s * 1.1), Vector2(s * 2.2, s * 2.2))


func _restart() -> void:
	var vel: Vector2 = params.get("velocity", Vector2(120.0, -300.0))
	var speed: float = vel.length()
	var dir: Vector2 = vel.normalized() if speed > 1.0 else Vector2(0.0, -1.0)
	# Body radius in pixels, so the quad wraps the creature rather than a fixed
	# box that clips a big dog and wastes fill on a chick.
	var body: float = maxf(float(params.get("radius", 70.0)), 24.0)
	_resize(body * 2.1)

	_strength = clampf(remap(speed, 120.0, 900.0, 0.15, 0.85), 0.0, 0.85)
	if calm:
		# Reduced motion still wants the weight cue, just not the streak.
		_strength *= 0.4

	var vp: Vector2 = get_viewport_rect().size
	# The shader works in screen UV, so a pixel length has to be divided by the
	# viewport. Using the width for both axes keeps the trail from skewing on a
	# non-square window.
	var len_uv: float = clampf(body * 1.5 / maxf(vp.x, 1.0), 0.0, 0.25)
	_mat.set_shader_parameter("travel", Vector2(dir.x, dir.y))
	_mat.set_shader_parameter("smear_len", len_uv)
	_mat.set_shader_parameter("tint", lit_color(0.2))
	_mat.set_shader_parameter("taper", 0.72)
	duration = 0.15 * (1.4 if calm else 1.0)


func _tick(t: float, _delta: float) -> void:
	# Full strength on the first frame, then straight out. A smear that fades in
	# has already missed the moment it exists to describe.
	_mat.set_shader_parameter("strength", _strength * (1.0 - VfxEffect.ease_in_cubic(t)))
