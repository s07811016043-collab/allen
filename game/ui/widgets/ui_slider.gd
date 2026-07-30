class_name UISlider
extends UIWidget

## A labelled slider row.
##
## Custom-drawn rather than a themed `HSlider` because Godot's grabber is a
## texture, and this project has no textures. Building it here also lets the
## fill carry the meaning: the volume sliders fill in the accent, the UI-scale
## slider fills in a neutral, so a glance at the settings panel separates "how
## loud" from "how big" without reading a word.

signal value_changed(v: float)

@export var label: String = ""
@export var hint: String = ""
@export var min_value: float = 0.0
@export var max_value: float = 1.0
## Snap increment. Zero means continuous.
@export var step: float = 0.0
@export var value: float = 0.5:
	set(v):
		value = _snap(clampf(v, min_value, max_value))
		queue_redraw()
## Formats the value for the right-hand readout. Set by the owning panel so a
## percentage, a multiplier and a preset name all share one control.
var formatter: Callable = func(v: float) -> String:
	return "%d%%" % int(round(v * 100.0))
@export var fill_color: Color = Color(0, 0, 0, 0)

const TRACK_H := 6.0
const KNOB_R := 9.0

var _dragging := false
var _anim: float = 0.0


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(0.0, UITokens.s(56.0))
	_anim = _ratio()


func _snap(v: float) -> float:
	if step <= 0.0:
		return v
	return snappedf(v, step)


func _ratio() -> float:
	var span: float = maxf(max_value - min_value, 0.0001)
	return clampf((value - min_value) / span, 0.0, 1.0)


func set_value_silent(v: float) -> void:
	value = v
	_anim = _ratio()
	queue_redraw()


func _track_rect() -> Rect2:
	var h := UITokens.s(TRACK_H)
	var inset := UITokens.s(KNOB_R)
	return Rect2(inset, size.y - h - UITokens.s(10.0), size.x - inset * 2.0, h)


func focus_rect() -> Rect2:
	return _track_rect().grow(UITokens.s(KNOB_R) * 0.9)


func focus_radius() -> float:
	return UITokens.s(KNOB_R) * 1.4


func _process(delta: float) -> void:
	super._process(delta)
	var a := UIMotion.approach(_anim, _ratio(), 22.0, delta)
	if absf(a - _anim) > 0.0004:
		_anim = a
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				grab_focus()
				_set_from_x(mb.position.x)
			else:
				_dragging = false
			accept_event()
			queue_redraw()
			return
	elif event is InputEventMouseMotion and _dragging:
		_set_from_x((event as InputEventMouseMotion).position.x)
		accept_event()
		return
	# Keyboard: a single arrow press moves by the step, or by 5% when the
	# slider is continuous. Holding shift moves by a tenth of that, because
	# "set the volume to exactly 30%" is a real thing people want.
	var inc: float = step if step > 0.0 else (max_value - min_value) * 0.05
	if Input.is_key_pressed(KEY_SHIFT):
		inc *= 0.2
	if event.is_action_pressed(&"ui_right", true):
		value = value + inc
		value_changed.emit(value)
		accept_event()
	elif event.is_action_pressed(&"ui_left", true):
		value = value - inc
		value_changed.emit(value)
		accept_event()
	else:
		super._gui_input(event)


func _set_from_x(x: float) -> void:
	var t := _track_rect()
	var f: float = clampf((x - t.position.x) / maxf(t.size.x, 1.0), 0.0, 1.0)
	var v := lerpf(min_value, max_value, f)
	if not is_equal_approx(v, value):
		value = v
		value_changed.emit(value)


func _draw() -> void:
	UIDraw.text(self, Vector2(0.0, 0.0), label, UIType.Role.BODY,
		UITokens.col(&"text"), UIType.WEIGHT_MEDIUM)
	var read: String = String(formatter.call(value))
	var w: float = UIType.width(read, UIType.Role.LABEL, UIType.WEIGHT_SEMI)
	# The readout is dim until the control is being used. A settings page where
	# every number is at full contrast has no hierarchy at all.
	var read_col := UITokens.col(&"text_faint").lerp(UITokens.col(&"accent"),
		maxf(hover, focus_glow))
	UIDraw.text(self, Vector2(size.x - w, UITokens.s(1.0)), read,
		UIType.Role.LABEL, read_col, UIType.WEIGHT_SEMI)

	var t := _track_rect()
	var col := fill_color if fill_color.a > 0.0 else UITokens.col(&"accent")
	if disabled:
		col = UITokens.col(&"text_faint")
	UIMeters.track(self, t, _anim, col)

	var kx: float = t.position.x + t.size.x * _anim
	var kc := Vector2(kx, t.get_center().y)
	var kr: float = UITokens.s(KNOB_R) * lerpf(1.0, 1.14, maxf(hover, press))
	if hover > 0.01 or focus_glow > 0.01:
		var g := col
		g.a = 0.28 * maxf(hover, focus_glow)
		UIDraw.glow(self, kc, kr * 2.4, g, 5)
	for i in 3:
		var k: float = float(i) / 2.0
		var sc := UITokens.col(&"shadow")
		sc.a = 0.18 * (1.0 - k)
		UIDraw.fill_path(self, UIDraw.circle_path(kc + Vector2(0.0, UITokens.s(1.5)),
			kr * lerpf(1.0, 1.35, k), 18), sc)
	UIDraw.fill_path(self, UIDraw.circle_path(kc, kr, 24), Color(1, 1, 1, 0.97))

	if not hint.is_empty():
		UIDraw.text(self, Vector2(0.0, UIType.line_height(UIType.Role.BODY)
			+ UITokens.s(1.0)), hint, UIType.Role.MICRO,
			UITokens.col(&"text_faint"))
	draw_focus()
