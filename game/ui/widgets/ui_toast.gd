class_name UIToast
extends Control

## One self-dismissing notification.
##
## The hardest constraint in the whole interface. A desktop pet that interrupts
## you is a desktop pet you uninstall, so a toast has to be noticeable *only if
## you happen to look*. Concretely, that means:
##
##   * it never takes focus and never accepts a click that could be meant for
##     the window underneath — the only interactive area is the dismiss zone,
##     and even that just hides it early,
##   * it enters by sliding a short distance and fading, with no bounce and no
##     sound,
##   * it holds for a few seconds and leaves on its own,
##   * it is small and low-contrast relative to a panel: this is the one surface
##     in the design allowed to be quieter than the contrast guarantee, because
##     nothing in it is load-bearing. Anything a player must read lives in a
##     panel they opened.
##
## The tone matters as much as the timing. "Food is at 20%" is a nag. "Mochi
## keeps looking at the bowl" is a pet.

signal expired(toast: UIToast)

enum Tone {
	NOTE,       ## Something happened. The default.
	MILESTONE,  ## A memory was made. Warmer, and lasts a beat longer.
	NEED,       ## A request. Never repeated for the same need.
}

const WIDTH := 296.0
const MIN_HEIGHT := 56.0
## Life, in seconds, before it starts leaving.
const HOLD := 4.6
const HOLD_MILESTONE := 6.2

var glyph: StringName = &"paw"
var message: String = ""
var tone: Tone = Tone.NOTE

var _age: float = 0.0
var _in := UIMotion.Spring.new(0.0, UITokens.SPRING_SOFT)
var _leaving := false
var _hovered := false
var _lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	# Pass-through by default: the toast is scenery. It becomes clickable only
	# where the dismiss affordance is, which `_has_point` narrows to the toast's
	# own rounded body.
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	mouse_entered.connect(func() -> void: _hovered = true)
	mouse_exited.connect(func() -> void: _hovered = false)
	# Width first: `_measure` wraps against it, and wrapping against a zero
	# width breaks every line after the first word.
	size.x = UITokens.s(WIDTH)
	size.y = _measure()
	_in.reset(0.0)
	_in.target = 1.0


func _measure() -> float:
	# Wrapped by hand so the height is known before the first draw; a toast that
	# resizes after appearing shoves the whole stack around.
	_lines = _wrap(message, size.x - UITokens.s(66.0))
	var h: float = UITokens.s(UITokens.SPACE_MD) * 2.0 \
		+ float(_lines.size()) * UIType.line_height(UIType.Role.LABEL)
	return maxf(UITokens.s(MIN_HEIGHT), h + UITokens.s(6.0))


static func _wrap(text: String, width: float) -> PackedStringArray:
	var out := PackedStringArray()
	var line := ""
	for word in text.split(" ", false):
		var probe: String = word if line.is_empty() else line + " " + word
		if UIType.width(probe, UIType.Role.LABEL) > width and not line.is_empty():
			out.append(line)
			line = word
			# Two lines is the ceiling. A third line is a paragraph, and a
			# paragraph in the corner of somebody's screen is an interruption.
			if out.size() >= 2:
				line = ""
				break
		else:
			line = probe
	if not line.is_empty():
		out.append(line)
	return out


func dismiss() -> void:
	if _leaving:
		return
	_leaving = true
	_in.target = 0.0


func _process(delta: float) -> void:
	_age += delta
	# Hovering pauses the clock. Somebody reading a toast has, by definition,
	# decided it was worth reading.
	if not _hovered and not _leaving:
		var hold: float = HOLD_MILESTONE if tone == Tone.MILESTONE else HOLD
		if _age > hold:
			dismiss()
	_in.step(delta)
	queue_redraw()
	if _leaving and _in.value < 0.01:
		expired.emit(self)
		queue_free()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		accept_event()
		dismiss()


func _draw() -> void:
	var t: float = clampf(_in.value, 0.0, 1.0)
	if t < 0.004:
		return
	var e := UIMotion.ease_out_cubic(t)
	# Slides in from the right by its own width's worth of easing distance. No
	# overshoot: a bouncing notification demands attention, and this one is
	# explicitly not allowed to.
	var dx: float = (1.0 - e) * UITokens.s(26.0)
	draw_set_transform(Vector2(dx, 0.0), 0.0, Vector2(1.0, 1.0))

	var r := Rect2(Vector2.ZERO, size)
	var rad := UITokens.s(UITokens.RADIUS_LG)

	for i in 4:
		var k: float = float(i) / 3.0
		var sc := UITokens.col(&"shadow")
		sc.a = 0.11 * (1.0 - k) * t
		UIDraw.round_rect(self, Rect2(r.position + Vector2(0.0, UITokens.s(3.0)),
			r.size).grow(UITokens.s(2.0 + 8.0 * k)), rad + UITokens.s(8.0 * k), sc)

	var fill := UITokens.col(&"surface_deep")
	fill.a *= t
	UIDraw.round_rect(self, r, rad, fill)
	var edge := UITokens.col(&"edge")
	edge.a *= t
	UIDraw.round_rect_outline(self, r, rad, edge, UITokens.HAIRLINE)

	var accent := _tone_color()
	# A short colour bar on the leading edge instead of a coloured background.
	# It tells you the kind of message from the corner of your eye without
	# putting body text on a tinted field.
	var bar := Rect2(UITokens.s(1.0), r.size.y * 0.24, UITokens.s(3.0),
		r.size.y * 0.52)
	var bc := accent
	bc.a *= t
	UIDraw.capsule(self, bar, bc)

	var icon_c := Vector2(UITokens.s(30.0), r.size.y * 0.5)
	var ic := accent
	ic.a *= t
	UIGlyphs.draw_glyph(self, glyph, icon_c, UITokens.s(19.0), ic)

	var x: float = UITokens.s(50.0)
	var lh := UIType.line_height(UIType.Role.LABEL)
	var y: float = (r.size.y - lh * float(maxi(_lines.size(), 1))) * 0.5
	var tc := UITokens.col(&"text")
	tc.a *= t
	for line in _lines:
		UIDraw.text(self, Vector2(x, y), line, UIType.Role.LABEL, tc)
		y += lh

	# A hairline countdown along the bottom edge, visible only on hover. It
	# answers "how long have I got" for the one player in a hundred who wonders,
	# and stays invisible for the other ninety-nine.
	if _hovered and not _leaving:
		var hold: float = HOLD_MILESTONE if tone == Tone.MILESTONE else HOLD
		var left: float = clampf(1.0 - _age / hold, 0.0, 1.0)
		var pc := UITokens.col(&"text_faint")
		pc.a *= t * 0.7
		draw_rect(Rect2(rad, r.size.y - UITokens.s(2.0),
			(r.size.x - rad * 2.0) * left, UITokens.s(1.5)), pc)


func _tone_color() -> Color:
	match tone:
		Tone.MILESTONE: return UITokens.col(&"accent")
		Tone.NEED: return UITokens.col(&"alert")
	return UITokens.col(&"text_dim")
