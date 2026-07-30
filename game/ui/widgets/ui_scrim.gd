class_name UIScrim
extends Control

## The backdrop every Petalia panel sits on.
##
## A `Control` rather than a `Panel` because the shadow has to spill outside the
## panel's own rectangle: the shader node is inflated by `PAD` on every side and
## the layout rect stays honest, so children can anchor to the visible edge
## without doing shadow arithmetic.
##
## Kept separate from the panels themselves so there is exactly one place that
## decides what a Petalia surface looks like. Change the radius here and the
## radial menu, the journal and a toast all change together.

## Room for the largest shadow in the elevation scale, plus slack for the
## reveal animation's overshoot.
const PAD := 56.0

const SHADER_PATH := "res://ui/theme/scrim.gdshader"

## Deeper, more opaque fill for surfaces the player is meant to read a lot of
## text on (journal, settings) versus transient ones (toasts, the radial ring).
@export var deep: bool = false
@export var corner_radius: float = UITokens.RADIUS_XL
@export var elevation: Vector3 = UITokens.ELEV_FLOATING
@export var blur_px: float = 16.0

var _rect: ColorRect
var _mat: ShaderMaterial
var _reveal: float = 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_rect = ColorRect.new()
	_rect.color = Color.WHITE
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.show_behind_parent = true
	_mat = ShaderMaterial.new()
	var sh: Shader = load(SHADER_PATH) as Shader
	_mat.shader = sh
	_rect.material = _mat
	add_child(_rect)
	move_child(_rect, 0)
	_sync()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _rect != null:
		_sync()


## 0 → 1 while the owning panel opens. Drives the box grow and the shadow, so a
## panel appears to inflate into place rather than fade in flat.
func set_reveal(v: float) -> void:
	_reveal = clampf(v, 0.0, 1.0)
	if _mat != null:
		_mat.set_shader_parameter("reveal", _reveal)


## Re-read the palette. Called on scheme change rather than every frame.
func restyle() -> void:
	if _mat != null:
		_sync()


func _sync() -> void:
	var pad: float = UITokens.s(PAD)
	_rect.position = Vector2(-pad, -pad)
	_rect.size = size + Vector2(pad * 2.0, pad * 2.0)
	_mat.set_shader_parameter("panel_size", size)
	_mat.set_shader_parameter("pad", pad)
	_mat.set_shader_parameter("radius", UITokens.s(corner_radius))
	_mat.set_shader_parameter("fill",
		UITokens.col(&"surface_deep" if deep else &"surface"))
	_mat.set_shader_parameter("edge", UITokens.col(&"edge"))
	_mat.set_shader_parameter("sheen", UITokens.col(&"sheen"))
	_mat.set_shader_parameter("shadow", UITokens.shadow_for(elevation))
	_mat.set_shader_parameter("shadow_px", UITokens.s(elevation.x))
	_mat.set_shader_parameter("shadow_lift", UITokens.s(elevation.y))
	_mat.set_shader_parameter("blur_px", UITokens.s(blur_px))
	_mat.set_shader_parameter("reveal", _reveal)
