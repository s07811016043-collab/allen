class_name UIWidget
extends Control

## Base for every interactive control in the overlay.
##
## Godot's `BaseButton` family would give us pressed/hover states for free, but
## not the three things this UI actually needs: continuous hover and press
## values to drive drawing (not booleans, which produce the on/off flicker that
## makes an interface feel cheap), a focus indicator that survives an unknown
## desktop behind it, and one place where "activate" means the same thing for a
## mouse click, the space bar and the enter key.
##
## Keyboard parity is not a bonus feature here. A desktop pet must not steal
## focus, which means the player often reaches it from a keyboard shortcut with
## their hands already on the keys; a control that can only be clicked is a
## control they will not use.

signal activated()

## Continuous state, [0,1]. Read these from `_draw`; never read `is_hovered()`.
var hover: float = 0.0
var press: float = 0.0
var focus_glow: float = 0.0
var disabled: bool = false:
	set(v):
		disabled = v
		mouse_default_cursor_shape = Control.CURSOR_ARROW if v else Control.CURSOR_POINTING_HAND
		queue_redraw()

var _hovered := false
var _held := false
## Rise and fall rates. Hover leaves faster than it arrives, so a cursor
## sweeping across a row of controls does not leave a comet trail of glows.
const HOVER_IN := 16.0
const HOVER_OUT := 11.0
const PRESS_RATE := 30.0


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func() -> void: _hovered = true)
	mouse_exited.connect(func() -> void:
		_hovered = false
		_held = false)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _process(delta: float) -> void:
	var want_hover: float = 0.0 if disabled or not _hovered else 1.0
	var want_press: float = 1.0 if _held else 0.0
	var want_focus: float = 1.0 if has_focus() else 0.0
	var rate: float = HOVER_IN if want_hover > hover else HOVER_OUT
	var h := UIMotion.approach(hover, want_hover, rate, delta)
	var p := UIMotion.approach(press, want_press, PRESS_RATE, delta)
	var f := UIMotion.approach(focus_glow, want_focus, 18.0, delta)
	if absf(h - hover) > 0.001 or absf(p - press) > 0.001 \
			or absf(f - focus_glow) > 0.001:
		hover = h
		press = p
		focus_glow = f
		queue_redraw()
	else:
		hover = want_hover
		press = want_press
		focus_glow = want_focus


func _gui_input(event: InputEvent) -> void:
	if disabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_held = true
			# Focus follows the click so a subsequent Tab continues from where
			# the player's attention already is.
			grab_focus()
			accept_event()
		elif _held:
			_held = false
			accept_event()
			_fire()
		queue_redraw()
	elif event.is_action_pressed(&"ui_accept"):
		_held = true
		queue_redraw()
		accept_event()
	elif event.is_action_released(&"ui_accept"):
		if _held:
			_held = false
			queue_redraw()
			accept_event()
			_fire()


func _fire() -> void:
	activated.emit()


## Convenience for subclasses: the rect a focus ring should hug, which is
## usually inset from the control's full rect so adjacent rings do not touch.
func focus_rect() -> Rect2:
	return Rect2(Vector2.ZERO, size)


func focus_radius() -> float:
	return UITokens.s(UITokens.RADIUS_MD)


func draw_focus() -> void:
	UIDraw.focus_ring(self, focus_rect(), focus_radius(), focus_glow)
