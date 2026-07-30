class_name UIPanel
extends Control

## Base class for the overlay's floating panels.
##
## Owns the things every panel must get right and none of them should decide
## for itself: the scrim, the header, the open and close motion, the escape
## key, and where the content area begins. A panel subclass supplies a title, a
## size and a `_draw_content`.
##
## The open motion is deliberately *directional* — panels grow out of the point
## the player invoked them from (the pet, or the radial item they picked) rather
## than fading in at their final position. On a desktop with no window chrome
## there is no other cue about where a floating rectangle came from, and without
## one the interface feels like it is teleporting things at the player.

signal closed()
signal opened()

@export var title: String = ""
@export var subtitle: String = ""
## Panels the player reads a lot of text in take the deeper, more opaque scrim.
@export var deep: bool = false
@export var closable: bool = true

var scrim: UIScrim
var _reveal := UIMotion.Spring.new(0.0, UITokens.SPRING_SOFT)
var _open := false
var _from := Vector2.ZERO
## Layout position, kept apart from `position` so the open animation can offset
## the panel without the layout ever reading back its own animated value.
var _base_pos := Vector2.ZERO
var _close_btn: UIIconButton


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	visible = false
	clip_contents = false
	scrim = UIScrim.new()
	scrim.deep = deep
	scrim.elevation = UITokens.ELEV_LIFTED
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# A child is drawn *after* its parent, so without this the scrim would
	# paint over everything `_draw_content` puts down. Ordering, not z-index:
	# the panel's own drawing has to land on top of its own backdrop.
	scrim.show_behind_parent = true
	add_child(scrim)
	move_child(scrim, 0)
	scrim.position = Vector2.ZERO
	scrim.size = size

	if closable:
		_close_btn = UIIconButton.new()
		_close_btn.glyph = &"close"
		_close_btn.label = "Close"
		_close_btn.glyph_size = 13.0
		add_child(_close_btn)
		_close_btn.activated.connect(close)
	_build()
	_layout()
	set_process(false)


## Subclasses build their child controls here. Called once, after the scrim
## exists and before the first layout pass.
func _build() -> void:
	pass


## Subclasses position their child controls here. Called on every resize and
## whenever the UI scale changes.
func _layout() -> void:
	if scrim != null:
		scrim.size = size
	if _close_btn != null:
		var s: float = UITokens.s(30.0)
		_close_btn.size = Vector2(s, s)
		_close_btn.position = Vector2(size.x - s - UITokens.s(UITokens.SPACE_MD),
			UITokens.s(UITokens.SPACE_MD))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


## Top of the content area: below the header, or at the top padding when the
## panel has no title.
func content_top() -> float:
	if title.is_empty():
		return UITokens.s(UITokens.SPACE_LG)
	var h := UITokens.s(UITokens.SPACE_XL) + UIType.line_height(UIType.Role.TITLE)
	if not subtitle.is_empty():
		h += UIType.line_height(UIType.Role.MICRO) + UITokens.s(2.0)
	return h + UITokens.s(UITokens.SPACE_LG)


func pad() -> float:
	return UITokens.s(UITokens.SPACE_XL)


func content_rect() -> Rect2:
	var p := pad()
	return Rect2(Vector2(p, content_top()),
		Vector2(size.x - p * 2.0, size.y - content_top() - p))


## `from` is the screen point the panel should appear to come from — usually the
## pet, occasionally the control that opened it.
func open(from: Vector2 = Vector2.INF, keyboard: bool = false) -> void:
	_from = from
	_open = true
	visible = true
	set_process(true)
	_reveal.reset(0.0)
	_reveal.target = 1.0
	_base_pos = position
	pivot_offset = size * 0.5
	# Focus is only taken on a keyboard invocation; see `UIRadialMenu.open_at`
	# for why an overlay must not grab it uninvited.
	if keyboard:
		grab_focus()
	_on_opened()
	opened.emit()
	queue_redraw()


func close() -> void:
	if not _open:
		return
	_open = false
	_reveal.target = 0.0
	release_focus()
	_on_closing()
	closed.emit()


func is_open() -> bool:
	return _open


func _on_opened() -> void:
	pass


func _on_closing() -> void:
	pass


func _process(delta: float) -> void:
	var t := _reveal.step(delta)
	var e: float = clampf(t, 0.0, 1.0)
	modulate.a = clampf(e * 1.35, 0.0, 1.0)
	# Scale and offset are small on purpose. A panel that flies 200px across the
	# screen is a demo; two per cent of scale and a dozen pixels of travel is a
	# product.
	var k: float = lerpf(0.965, 1.0, e)
	scale = Vector2(k, k)
	# Drift toward the invocation point while opening. Applied to `position`
	# rather than to the draw transform so child controls (the close button, a
	# text field) travel with the panel instead of sliding across it.
	var drift := Vector2.ZERO
	if _from.is_finite():
		drift = (_from - (_base_pos + size * 0.5)).normalized() \
			* UITokens.s(16.0) * (1.0 - e)
	position = _base_pos + drift
	if scrim != null:
		scrim.set_reveal(e)
	queue_redraw()
	if not _open and t < 0.004:
		visible = false
		set_process(false)


func _draw() -> void:
	_draw_header()
	_draw_content()


func _draw_header() -> void:
	if title.is_empty():
		return
	var x := pad()
	var y := UITokens.s(UITokens.SPACE_XL)
	UIDraw.text(self, Vector2(x, y), title, UIType.Role.TITLE,
		UITokens.col(&"text"))
	if not subtitle.is_empty():
		UIDraw.text(self, Vector2(x, y + UIType.line_height(UIType.Role.TITLE)
			+ UITokens.s(2.0)), subtitle, UIType.Role.MICRO,
			UITokens.col(&"text_dim"))


## Subclasses draw here, in panel-local coordinates.
func _draw_content() -> void:
	pass


func _gui_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and closable:
		accept_event()
		close()


## A horizontal rule between sections. One hairline at low alpha; a heavier
## divider turns a panel into a form.
func rule(y: float) -> void:
	var c := UITokens.col(&"edge")
	c.a *= 0.75
	draw_rect(Rect2(pad(), y, size.x - pad() * 2.0, UITokens.HAIRLINE), c)
