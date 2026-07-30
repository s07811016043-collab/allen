class_name VfxStrokeRipple
extends VfxEffect

## Fur displacement and bloom under a touch or a stroke.
##
## Owns a BackBufferCopy because the displacement re-samples the frame the
## creature shader already drew. The copy is a rect, not the viewport: a stroke
## disturbs a patch of coat the size of a hand, and copying 1280x800 to move
## forty pixels of fur would be the most expensive thing in the program.

const SHADER_PATH := "res://vfx/touch/stroke_ripple.gdshader"

## How wide the disturbance is, in screen pixels, at strength 1.
const BASE_RADIUS := 86.0

var _bbc: BackBufferCopy
var _rect: ColorRect
var _mat: ShaderMaterial
var _radius: float = BASE_RADIUS
var _strength: float = 1.0


func _build() -> void:
	priority = Priority.NORMAL
	duration = 0.62

	_bbc = BackBufferCopy.new()
	_bbc.copy_mode = BackBufferCopy.COPY_MODE_RECT
	add_child(_bbc)

	_rect = ColorRect.new()
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH) as Shader
	_rect.material = _mat
	_rect.color = Color.WHITE
	add_child(_rect)
	_resize(BASE_RADIUS)


func _resize(r: float) -> void:
	_radius = r
	_rect.position = Vector2(-r, -r)
	_rect.size = Vector2(r * 2.0, r * 2.0)
	# Comfortably larger than the quad: a sample displaced outward past the edge
	# of the copied rect reads stale back buffer, which shows up as a hard
	# straight seam through the effect.
	_bbc.rect = Rect2(Vector2(-r * 1.4, -r * 1.4), Vector2(r * 2.8, r * 2.8))


func _restart() -> void:
	_strength = clampf(float(params.get("strength", 1.0)), 0.0, 1.5)
	_resize(BASE_RADIUS * lerpf(0.62, 1.15, clampf(_strength, 0.0, 1.0))
		* float(params.get("scale", 1.0)))

	var dir: Vector2 = params.get("dir", Vector2.ZERO)
	if dir.length_squared() < 1e-6:
		# A tap has no direction, but the coat still has to go somewhere; push
		# it along the groom direction, which for every species here is aft.
		dir = Vector2(-1.0, 0.0)
	_mat.set_shader_parameter("stroke_dir", dir.normalized())
	_mat.set_shader_parameter("seed", randf() * 10.0)
	_mat.set_shader_parameter("strands", float(params.get("strands", 17.0)))

	# Tier 0 drops the back buffer copy and keeps only the bloom, so the pet
	# still acknowledges being touched on a machine that cannot afford the read.
	var screen: bool = tier >= 1
	_bbc.copy_mode = BackBufferCopy.COPY_MODE_RECT if screen else BackBufferCopy.COPY_MODE_DISABLED
	_mat.set_shader_parameter("use_screen", 1.0 if screen else 0.0)

	# Reduced motion keeps the displacement but halves it and stretches the
	# relaxation, which reads as a gentler hand rather than as a disabled effect.
	var motion: float = 0.5 if calm else 1.0
	duration = 0.62 * (1.35 if calm else 1.0)
	_mat.set_shader_parameter("amp", 0.0135 * _strength * motion)
	_mat.set_shader_parameter("parting", 0.46 * _strength)
	_mat.set_shader_parameter("reach", 0.86)

	# The bloom is the pet's warmth showing through disturbed fur, so it takes
	# the bounce colour rather than a UI accent.
	var warm: Color = lit_color(0.15).lerp(Color(1.0, 0.72, 0.58), 0.45)
	_mat.set_shader_parameter("bloom_color", warm)
	_mat.set_shader_parameter("alpha_gate", 1.0)


func _tick(t: float, _delta: float) -> void:
	_mat.set_shader_parameter("phase", t)
	# The bloom leads the displacement: contact is felt before the coat has
	# finished moving. Peaks at 18% of the life and is gone by 70%.
	var b: float = VfxEffect.beat(t, 0.0, 0.18)
	var f: float = 1.0 - VfxEffect.ease_in_cubic(VfxEffect.beat(t, 0.18, 0.72))
	_mat.set_shader_parameter("bloom", VfxEffect.ease_out_cubic(b) * f
		* 0.55 * _strength * (1.0 - night() * 0.4))
