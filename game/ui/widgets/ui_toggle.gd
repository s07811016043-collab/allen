class_name UIToggle
extends UIWidget

## A labelled switch row: title, one line of explanation, and a switch.
##
## The explanation is not optional. Every toggle in this app changes how the pet
## behaves on the player's *desktop* — whether clicks pass through it, whether
## it floats over full-screen windows — and a bare label like "Click-through"
## means nothing to somebody who has never written a compositor.

signal toggled(on: bool)

@export var label: String = ""
@export var hint: String = ""
@export var value: bool = false:
	set(v):
		value = v
		queue_redraw()

const SWITCH_W := 46.0
const SWITCH_H := 26.0

var _knob := UIMotion.Spring.new(0.0, UITokens.SPRING_SNAPPY)


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(0.0, UITokens.s(52.0))
	_knob.reset(1.0 if value else 0.0)
	activated.connect(_flip)


func _flip() -> void:
	value = not value
	_knob.target = 1.0 if value else 0.0
	toggled.emit(value)


func set_value_silent(v: bool) -> void:
	value = v
	_knob.reset(1.0 if v else 0.0)
	queue_redraw()


func _process(delta: float) -> void:
	super._process(delta)
	var before := _knob.value
	_knob.step(delta)
	if absf(_knob.value - before) > 0.0005:
		queue_redraw()


func _switch_rect() -> Rect2:
	var w := UITokens.s(SWITCH_W)
	var h := UITokens.s(SWITCH_H)
	return Rect2(size.x - w, (size.y - h) * 0.5 - UITokens.s(4.0), w, h)


func focus_rect() -> Rect2:
	return _switch_rect().grow(UITokens.s(2.0))


func focus_radius() -> float:
	return UITokens.s(SWITCH_H) * 0.5 + UITokens.s(2.0)


func _draw() -> void:
	var on: float = clampf(_knob.value, 0.0, 1.0)
	UIDraw.text(self, Vector2(0.0, UITokens.s(2.0)), label, UIType.Role.BODY,
		UITokens.col(&"text"), UIType.WEIGHT_MEDIUM)
	if not hint.is_empty():
		UIDraw.text(self, Vector2(0.0, UITokens.s(2.0)
			+ UIType.line_height(UIType.Role.BODY) + UITokens.s(1.0)), hint,
			UIType.Role.MICRO, UITokens.col(&"text_faint"), -1.0,
			HORIZONTAL_ALIGNMENT_LEFT, size.x - UITokens.s(SWITCH_W) - UITokens.s(18.0))

	var r := _switch_rect()
	var track := UITokens.col(&"sunken").lerp(UITokens.col(&"accent"), on)
	UIDraw.capsule(self, r, track)
	UIDraw.round_rect_outline(self, r, r.size.y * 0.5,
		UITokens.col(&"edge"), UITokens.HAIRLINE)

	var pad := UITokens.s(3.0)
	var kr: float = (r.size.y - pad * 2.0) * 0.5
	var kx: float = lerpf(r.position.x + pad + kr, r.end.x - pad - kr, on)
	var kc := Vector2(kx, r.get_center().y)
	# The knob squashes along its travel while moving. Four pixels of anticipation
	# is the difference between a switch and a rectangle changing colour.
	var squash: float = 1.0 + absf(_knob.velocity) * 0.0016
	for i in 3:
		var k: float = float(i) / 2.0
		var sc := UITokens.col(&"shadow")
		sc.a = 0.16 * (1.0 - k)
		UIDraw.fill_path(self, UIDraw.circle_path(kc + Vector2(0.0, UITokens.s(1.5)),
			kr * lerpf(1.0, 1.3, k), 18, Vector2(squash, 1.0 / squash)), sc)
	var knob_col := Color(1, 1, 1, 0.96)
	if UITokens.scheme == UITokens.Scheme.LIGHT:
		knob_col = Color(1, 1, 1, 1.0)
	UIDraw.fill_path(self, UIDraw.circle_path(kc, kr * (1.0 + hover * 0.05), 22,
		Vector2(squash, 1.0 / squash)), knob_col)

	draw_focus()
