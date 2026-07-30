class_name UIRadialMenu
extends Control

## The radial menu, summoned by right-clicking the pet.
##
## A desktop pet has no window chrome and no menu bar, and the player's cursor
## is already on the animal when they decide to do something to it. A radial
## menu is the only pattern that costs zero travel: every action is the same
## short distance away, in a direction the hand can learn. That is why this and
## not a context list.
##
## Three things carry the quality:
##
##   * **Spring physics, not tweens.** Items fly out from the pet on a spring
##     with a sub-linear stagger, so the menu unfurls as one gesture. Re-opening
##     mid-close simply retargets, which a tween cannot do without a visible
##     jump.
##   * **A centre label that crossfades.** Icons alone are a memory test. The
##     label is the affordance; it changes on hover with an opacity crossfade
##     rather than a hard swap, so the eye is never yanked to the middle.
##   * **It never covers the pet.** The ring's inner radius is sized so the
##     animal you are acting on stays visible inside it. Obscuring the subject
##     of the menu is the classic radial-menu mistake.
##
## Keyboard: arrows or Tab step around the ring, Enter activates, Escape closes.
## The selection is a real focus state, drawn with the same ring as every other
## control in the game.

signal action_chosen(action: StringName)
signal dismissed()

class Item:
	var id: StringName
	var label: String
	var glyph: StringName
	var hint: String
	var enabled: bool = true
	## Live animation state.
	var spring: UIMotion.Spring
	var hover: float = 0.0
	var pos := Vector2.ZERO

	func _init(p_id: StringName, p_label: String, p_glyph: StringName,
			p_hint: String) -> void:
		id = p_id
		label = p_label
		glyph = p_glyph
		hint = p_hint
		spring = UIMotion.Spring.new(0.0, UITokens.SPRING_SNAPPY)

## Geometry, in design pixels.
const RING_RADIUS := 122.0
const ITEM_RADIUS := 29.0
const HUB_RADIUS := 52.0

var pet_name: String = "your pet"
var pet_species: StringName = &"cat"
var pet_growth: float = 3.0

var _items: Array[Item] = []
var _selected: int = -1
## The label currently shown and the one fading out under it.
var _label_now: String = ""
var _label_prev: String = ""
var _label_fade: float = 1.0
var _hint_now: String = ""
var _open: bool = false
var _reveal := UIMotion.Spring.new(0.0, UITokens.SPRING_SOFT)
var _t: float = 0.0
## True while the player is driving with the keyboard, which suppresses the
## pointer-angle selection so the two input methods cannot fight.
var _keyboard_mode := false
## Screen point the ring is centred on. The control itself always covers the
## whole viewport — a zero-sized Control receives no mouse events, and a menu
## that only listens inside its own ring cannot be dismissed by clicking away
## from it.
var _center := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	visible = false
	_build_items()
	set_process(false)


func _build_items() -> void:
	_items = [
		Item.new(&"feed", "Feed", &"feed", "something to eat"),
		Item.new(&"play", "Play", &"play", "chase and pounce"),
		Item.new(&"pet", "Pet", &"pet", "just be nearby"),
		Item.new(&"sleep", "Rest", &"sleep", "settle down"),
		Item.new(&"journal", "Journal", &"journal", "your story so far"),
		Item.new(&"settings", "Settings", &"settings", "size, sound, behaviour"),
		Item.new(&"adopt", "Adopt", &"adopt", "bring home another"),
	]


## Open centred on `at` (the pet's screen position). The menu is nudged so it
## always fits on screen — a radial menu that opens half off the edge of the
## display is worse than a list.
func open_at(at: Vector2, keyboard: bool = false) -> void:
	var margin: float = UITokens.s(RING_RADIUS + ITEM_RADIUS + 34.0)
	var bounds := get_viewport_rect()
	position = Vector2.ZERO
	size = bounds.size
	_center = Vector2(
		clampf(at.x, bounds.position.x + margin, bounds.end.x - margin),
		clampf(at.y, bounds.position.y + margin, bounds.end.y - margin))

	_open = true
	_keyboard_mode = keyboard
	_selected = 0 if keyboard else -1
	visible = true
	set_process(true)
	_reveal.reset(0.0)
	_reveal.target = 1.0
	for i in _items.size():
		var it := _items[i]
		it.spring.reset(0.0)
		it.spring.target = 1.0
		it.hover = 0.0
	_set_label(_default_label(), "")
	# Focus is only taken when the player arrived by keyboard. A desktop
	# companion that steals focus from the window you were typing in is a
	# desktop companion that gets uninstalled by lunchtime.
	if keyboard:
		grab_focus()
		_apply_selection(0, true)
	queue_redraw()


func close() -> void:
	if not _open:
		return
	_open = false
	_reveal.target = 0.0
	for it in _items:
		it.spring.target = 0.0
	release_focus()
	dismissed.emit()


func is_open() -> bool:
	return _open


func _default_label() -> String:
	return pet_name


func _set_label(next: String, hint: String) -> void:
	if next == _label_now:
		return
	_label_prev = _label_now
	_label_now = next
	_hint_now = hint
	_label_fade = 0.0


func _process(delta: float) -> void:
	_t += delta
	var rev := _reveal.step(delta)
	for i in _items.size():
		var it := _items[i]
		# The stagger is applied by holding each item's target at zero until its
		# slot in the sequence arrives, which keeps every item on the same
		# spring rather than on a per-item tween with its own timing.
		it.spring.step(delta)
		var want: float = 1.0 if _selected == i and it.enabled else 0.0
		it.hover = UIMotion.approach(it.hover, want, 15.0, delta)
	_label_fade = UIMotion.approach(_label_fade, 1.0, 14.0, delta)

	if not _keyboard_mode and _open:
		_track_pointer()

	queue_redraw()
	if not _open and rev < 0.004:
		visible = false
		set_process(false)


## Angular hit-testing rather than rectangular. The dead zone in the middle is
## what makes "flick and release" work: a small movement from the centre is not
## yet a choice, so the player can open the menu and think.
func _track_pointer() -> void:
	var local := get_local_mouse_position() - _center
	var dist := local.length()
	var dead: float = UITokens.s(HUB_RADIUS) * 0.86
	var outer: float = UITokens.s(RING_RADIUS + ITEM_RADIUS * 1.9)
	if dist < dead or dist > outer:
		_apply_selection(-1, false)
		return
	var a: float = fposmod(atan2(local.y, local.x) + PI * 0.5, TAU)
	var idx: int = int(round(a / TAU * float(_items.size()))) % _items.size()
	_apply_selection(idx, false)


func _apply_selection(idx: int, _from_key: bool) -> void:
	if idx == _selected:
		return
	_selected = idx
	if idx < 0:
		_set_label(_default_label(), "")
	else:
		_set_label(_items[idx].label, _items[idx].hint)


func _item_angle(i: int) -> float:
	# First item straight up. Up is the direction a hand flicks most reliably,
	# so the most-used action (feed) goes there.
	return -PI * 0.5 + TAU * float(i) / float(_items.size())


func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			accept_event()
			if _selected >= 0:
				_choose(_selected)
			else:
				close()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			accept_event()
			close()
	elif event is InputEventMouseMotion:
		# Any pointer movement hands control back to the pointer.
		_keyboard_mode = false
	elif event.is_action_pressed(&"ui_cancel"):
		accept_event()
		close()
	elif event.is_action_pressed(&"ui_accept"):
		accept_event()
		if _selected >= 0:
			_choose(_selected)
	elif event.is_action_pressed(&"ui_right") or event.is_action_pressed(&"ui_down") \
			or event.is_action_pressed(&"ui_focus_next"):
		accept_event()
		_step_selection(1)
	elif event.is_action_pressed(&"ui_left") or event.is_action_pressed(&"ui_up") \
			or event.is_action_pressed(&"ui_focus_prev"):
		accept_event()
		_step_selection(-1)


func _step_selection(dir: int) -> void:
	_keyboard_mode = true
	var n := _items.size()
	var idx: int = 0 if _selected < 0 else (_selected + dir + n) % n
	_apply_selection(idx, true)


func _choose(idx: int) -> void:
	if idx < 0 or idx >= _items.size() or not _items[idx].enabled:
		return
	action_chosen.emit(_items[idx].id)
	close()


func _draw() -> void:
	var rev: float = clampf(_reveal.value, 0.0, 1.0)
	if rev < 0.003:
		return
	# Everything below is authored around the origin; one transform puts the
	# whole ring over the pet without threading a centre through every call.
	draw_set_transform(_center, 0.0, Vector2.ONE)
	var ring_r: float = UITokens.s(RING_RADIUS)
	var item_r: float = UITokens.s(ITEM_RADIUS)
	var hub_r: float = UITokens.s(HUB_RADIUS)

	_draw_hub(hub_r, rev)

	for i in _items.size():
		var it := _items[i]
		# Per-item reveal: the shared spring value delayed by this item's slot,
		# remapped so the last item still finishes inside the same beat.
		var lead: float = UIMotion.stagger(i, _items.size(), 0.55)
		var t: float = clampf((it.spring.value - lead) / maxf(1.0 - lead, 0.05),
			0.0, 1.0)
		if UITokens.reduced_motion:
			t = rev
		var a: float = _item_angle(i)
		var dir := Vector2(cos(a), sin(a))
		# Items travel out from the hub, not from the ring — the motion has to
		# say "these came from the pet".
		it.pos = dir * lerpf(hub_r * 0.35, ring_r, t)
		_draw_item(it, item_r * lerpf(0.45, 1.0, t), t, i == _selected)

	_draw_label(hub_r, rev)


## The hub, drawn as a *soft-edged* disc rather than a hard one.
##
## The pet is underneath. A crisp scrim circle would hide the animal the menu is
## about, which is the classic radial-menu mistake; a hard-edged transparent one
## would leave the label sitting on wallpaper. Stacking concentric discs at low
## alpha builds coverage toward the centre, so the label lands on solid ground
## and the creature fades back into view at the rim.
func _draw_hub(hub_r: float, rev: float) -> void:
	var r: float = hub_r * lerpf(0.72, 1.0, UIMotion.ease_out_cubic(rev))
	var fill := UITokens.col(&"surface")
	const RINGS := 9
	for i in RINGS:
		var k: float = float(i) / float(RINGS - 1)
		var c := fill
		c.a = fill.a * rev * 0.235
		UIDraw.fill_path(self, UIDraw.circle_path(Vector2.ZERO,
			r * lerpf(1.20, 0.34, k), 40), c)


func _draw_item(it: Item, r: float, t: float, selected: bool) -> void:
	if t < 0.01:
		return
	var c := it.pos
	var lift: float = it.hover
	var rr: float = r * lerpf(1.0, 1.13, lift)

	# Selected items get a coloured halo rather than a bigger circle alone:
	# scale on its own is easy to miss in peripheral vision, colour is not.
	if lift > 0.01:
		var halo := UITokens.col(&"accent")
		halo.a = 0.26 * lift * t
		UIDraw.glow(self, c, rr * 2.05, halo, 6)

	for i in 4:
		var k: float = float(i) / 3.0
		var sc := UITokens.col(&"shadow")
		sc.a = 0.13 * (1.0 - k) * t
		UIDraw.fill_path(self, UIDraw.circle_path(c + Vector2(0.0, UITokens.s(3.0)),
			rr * lerpf(1.0, 1.35, k), 22), sc)

	var fill := UITokens.col(&"surface")
	fill = fill.lerp(UITokens.col(&"accent"), lift * 0.90)
	fill.a = UITokens.col(&"surface").a * t
	UIDraw.fill_path(self, UIDraw.circle_path(c, rr, 30), fill)

	var edge := UITokens.col(&"edge").lerp(UITokens.col(&"accent"), lift)
	edge.a *= t * (1.0 + lift * 2.0)
	UIDraw.stroke_path(self, UIDraw.circle_path(c, rr, 30), edge,
		UITokens.HAIRLINE * (1.0 + lift), true)

	var ink := UITokens.col(&"text_dim").lerp(UITokens.col(&"on_accent"), lift)
	ink.a *= t
	UIGlyphs.draw_glyph(self, it.glyph, c, rr * 0.86, ink)

	if selected and _keyboard_mode:
		# Only under keyboard control. With a pointer the hover state already
		# says which item is live, and a focus ring on top of it is noise; with
		# a keyboard it is the only thing that does.
		var box := Rect2(c - Vector2(rr, rr), Vector2(rr * 2.0, rr * 2.0))
		UIDraw.focus_ring(self, box, rr, lift)


## Centre label with a real crossfade: the outgoing string keeps its place and
## fades under the incoming one, which reads as the label *changing* rather than
## as two labels flickering.
func _draw_label(hub_r: float, rev: float) -> void:
	var fade: float = UIMotion.ease_out_cubic(_label_fade)
	var have_hint: bool = not _hint_now.is_empty() and _selected >= 0
	var y: float = -UIType.line_height(UIType.Role.HEAD) * (0.75 if have_hint else 0.5)

	# The label field is wider than the hub. Text is allowed past the disc's
	# rim: it stays legible over the pet because it is a heavier weight on a
	# soft field, and constraining it to the hub would truncate every hint.
	var max_w: float = hub_r * 3.4

	if fade < 0.999 and not _label_prev.is_empty():
		var out_col := UITokens.col(&"text")
		out_col.a *= (1.0 - fade) * rev
		# The outgoing label drifts up a hair as it leaves. Two pixels; enough
		# for the eye to register a direction, not enough to notice.
		UIDraw.text(self, Vector2(-max_w * 0.5,
			y - UITokens.s(2.0) * fade), _label_prev, UIType.Role.HEAD, out_col,
			UIType.WEIGHT_SEMI, HORIZONTAL_ALIGNMENT_CENTER, max_w)

	var col := UITokens.col(&"text")
	col.a *= fade * rev
	UIDraw.text(self, Vector2(-max_w * 0.5,
		y + UITokens.s(2.0) * (1.0 - fade)), _label_now, UIType.Role.HEAD, col,
		UIType.WEIGHT_SEMI, HORIZONTAL_ALIGNMENT_CENTER, max_w)

	if have_hint:
		var hc := UITokens.col(&"text_faint")
		hc.a *= fade * rev
		UIDraw.text(self, Vector2(-max_w * 0.5,
			y + UIType.line_height(UIType.Role.HEAD) + UITokens.s(1.0)),
			_hint_now, UIType.Role.MICRO, hc, -1.0,
			HORIZONTAL_ALIGNMENT_CENTER, max_w)
