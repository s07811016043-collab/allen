class_name PostStack
extends CanvasLayer

## Full-frame post pass: bloom, lens aberration and colour grading.
##
## Petalia has no 3D environment and no WorldEnvironment to hang effects off, so
## the stack is one canvas layer sitting above everything with a back-buffer copy
## feeding `post_stack.gdshader`. Add it as a child of whatever owns the frame —
## `CreatureRenderer` does this by default — and it composites over the whole
## viewport.
##
## The hard requirement is window transparency. Petalia's window is see-through
## and the player's desktop is behind it, so the pass works in premultiplied
## alpha throughout and writes coverage rather than assuming an opaque frame. A
## post stack that quietly fills alpha with 1.0 turns the pet into a grey
## rectangle on the desktop, which is a shipping-blocker rather than a bug.

const SHADER_PATH := "res://shaders/post/post_stack.gdshader"

## Layer index. High enough to sit over the creature and any UI that should be
## graded with it; UI that must stay untouched goes above this.
@export var layer_index: int = 64:
	set(value):
		layer_index = value
		layer = value

@export_group("Bloom")
@export_range(0.0, 2.0, 0.01) var bloom_intensity: float = 0.42
@export_range(0.0, 1.5, 0.01) var bloom_threshold: float = 0.68
@export_range(0.01, 0.6, 0.01) var bloom_knee: float = 0.22
@export_range(0.0, 0.12, 0.001) var bloom_radius: float = 0.022
## Coverage the glow carries. Above roughly a third, the halo starts reading as
## haze on the desktop instead of as light coming off the pet.
@export_range(0.0, 1.0, 0.01) var bloom_alpha: float = 0.30

@export_group("Lens")
@export_range(0.0, 0.02, 0.0001) var aberration: float = 0.0035

@export_group("Grade")
@export_range(0.0, 4.0, 0.01) var exposure_post: float = 1.0
@export_range(0.0, 2.0, 0.01) var contrast: float = 1.06
@export_range(0.0, 2.0, 0.01) var saturation: float = 1.10
@export var shadow_tint: Color = Color(0.48, 0.52, 0.62)
@export var highlight_tint: Color = Color(1.0, 0.97, 0.90)
@export_range(0.0, 1.0, 0.01) var tint_strength: float = 0.16
## Only true when the viewport is an HDR render target. Under `gl_compatibility`
## the canvas is 8-bit, so anything above 1.0 is clipped before this pass could
## see it and the filmic curve has to live in the creature shader instead.
@export var hdr_input: bool = false

var _rect: ColorRect
var _mat: ShaderMaterial
var _size := Vector2.ZERO


func _ready() -> void:
	layer = layer_index
	# The back-buffer copy is what `hint_screen_texture` reads. Copying the whole
	# viewport once is cheaper than the per-item copies Godot would otherwise
	# schedule, and it guarantees the creature is already in the buffer.
	var bb := BackBufferCopy.new()
	bb.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(bb)

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH) as Shader
	_rect = ColorRect.new()
	_rect.color = Color.WHITE
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.material = _mat
	add_child(_rect)
	_apply()


func _process(_delta: float) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var s: Vector2 = vp.get_visible_rect().size
	if s != _size:
		_size = s
		_rect.position = Vector2.ZERO
		_rect.size = s
		_mat.set_shader_parameter("screen_size", s)


## Push every knob at once. Called on ready and whenever a caller retunes the
## look — a dim evening desktop wants less bloom than a bright one.
func _apply() -> void:
	_mat.set_shader_parameter("bloom_intensity", bloom_intensity)
	_mat.set_shader_parameter("bloom_threshold", bloom_threshold)
	_mat.set_shader_parameter("bloom_knee", bloom_knee)
	_mat.set_shader_parameter("bloom_radius", bloom_radius)
	_mat.set_shader_parameter("bloom_alpha", bloom_alpha)
	_mat.set_shader_parameter("aberration", aberration)
	_mat.set_shader_parameter("exposure_post", exposure_post)
	_mat.set_shader_parameter("contrast", contrast)
	_mat.set_shader_parameter("saturation", saturation)
	_mat.set_shader_parameter("shadow_tint", shadow_tint)
	_mat.set_shader_parameter("highlight_tint", highlight_tint)
	_mat.set_shader_parameter("tint_strength", tint_strength)
	_mat.set_shader_parameter("hdr_input", hdr_input)


## Re-read the exported values after changing them from code.
func refresh() -> void:
	if _mat != null:
		_apply()
