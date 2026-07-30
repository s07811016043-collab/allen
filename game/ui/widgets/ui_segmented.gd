class_name UISegmented
extends UIWidget

## A segmented control: a small closed set of options, all visible at once.
##
## Used for the quality preset. A dropdown would hide three of the four choices
## behind a click, and quality is exactly the setting a player wants to *scan* —
## "which one am I on, and what is next to it" — before committing. Four visible
## options also make the trade-off legible in a way a menu never does.
##
## The selection indicator is one sliding pill on a spring, not four boxes
## changing colour. Motion between two states is what tells the eye that these
## are the same thing in different positions.

signal selected(index: int)

@export var label: String = ""
@export var hint: String = ""
@export var options: PackedStringArray = PackedStringArray():
	set(v):
		options = v
		queue_redraw()
@export var index: int = 0:
	set(v):
		index = clampi(v, 0, maxi(options.size() - 1, 0))
		_pill.target = float(index)
		queue_redraw()

const BAR_H := 34.0

var _pill := UIMotion.Spring.new(0.0, UITokens.SPRING_SNAPPY)
var _hover_index: int = -1


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(0.0, UITokens.s(64.0))
	_pill.reset(float(index))


func set_index_silent(i: int) -> void:
	index = i
	_pill.reset(float(index))
	queue_redraw()


func _bar_rect() -> Rect2:
	var h := UITokens.s(BAR_H)
	return Rect2(0.0, size.y - h, size.x, h)


func _seg_rect(i: int) -> Rect2:
	var bar := _bar_rect()
	var n: float = maxf(float(options.size()), 1.0)
	var w: float = bar.size.x / n
	return Rect2(bar.position.x + w * float(i), bar.position.y, w, bar.size.y)


func focus_rect() -> Rect2:
	return _bar_rect()


func focus_radius() -> float:
	return _bar_rect().size.y * 0.5


func _process(delta: float) -> void:
	super._process(delta)
	var before := _pill.value
	_pill.step(delta)
	if absf(_pill.value - before) > 0.0004:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseMotion:
		var mp := (event as InputEventMouseMotion).position
		var found := -1
		for i in options.size():
			if _seg_rect(i).has_point(mp):
				found = i
				break
		if found != _hover_index:
			_hover_index = found
			queue_redraw()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			grab_focus()
			for i in options.size():
				if _seg_rect(i).has_point(mb.position):
					_pick(i)
					break
			accept_event()
			return
	elif event.is_action_pressed(&"ui_right"):
		_pick(mini(index + 1, options.size() - 1))
		accept_event()
		return
	elif event.is_action_pressed(&"ui_left"):
		_pick(maxi(index - 1, 0))
		accept_event()
		return
	super._gui_input(event)


func _pick(i: int) -> void:
	if i == index or i < 0:
		return
	index = i
	selected.emit(i)


func _draw() -> void:
	if not label.is_empty():
		UIDraw.text(self, Vector2.ZERO, label, UIType.Role.BODY,
			UITokens.col(&"text"), UIType.WEIGHT_MEDIUM)
	if not hint.is_empty():
		var hw: float = UIType.width(hint, UIType.Role.MICRO)
		UIDraw.text(self, Vector2(size.x - hw, UITokens.s(2.0)), hint,
			UIType.Role.MICRO, UITokens.col(&"text_faint"))

	var bar := _bar_rect()
	UIDraw.round_rect(self, bar, UITokens.s(UITokens.RADIUS_SM),
		UITokens.col(&"sunken"))
	UIDraw.round_rect_outline(self, bar, UITokens.s(UITokens.RADIUS_SM),
		UITokens.col(&"edge"), UITokens.HAIRLINE)

	if options.is_empty():
		return

	# One pill, slid to a fractional index. Because it rides the spring's raw
	# value it is briefly between two segments, which is the whole effect.
	var inset := UITokens.s(3.0)
	var pill := _seg_rect(0).grow(-inset)
	if options.size() > 1:
		pill.position.x += (_seg_rect(1).position.x - _seg_rect(0).position.x) \
			* _pill.value
	UIDraw.round_rect(self, pill, UITokens.s(UITokens.RADIUS_SM) - inset * 0.5,
		UITokens.col(&"accent"))

	for i in options.size():
		var r := _seg_rect(i)
		var on: float = clampf(1.0 - absf(_pill.value - float(i)), 0.0, 1.0)
		var col: Color = UITokens.col(&"text_dim").lerp(
			UITokens.col(&"on_accent"), on)
		if i == _hover_index and on < 0.5:
			col = UITokens.col(&"text")
		var text := options[i]
		var w: float = UIType.width(text, UIType.Role.LABEL, UIType.WEIGHT_SEMI)
		var f := UIType.font(UIType.Role.LABEL, UIType.WEIGHT_SEMI)
		var px := UIType.px(UIType.Role.LABEL)
		draw_string(f, Vector2(r.get_center().x - w * 0.5,
			r.get_center().y + f.get_ascent(px) * 0.5 - f.get_descent(px) * 0.4),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px, col)

	draw_focus()
