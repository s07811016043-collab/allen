class_name UICarePanel
extends UIPanel

## The pet's state, at a glance.
##
## The trap this panel exists to avoid is the chore list. Four labelled bars
## with percentages turns a companion into a maintenance schedule, and people
## abandon maintenance schedules. So the composition puts the *animal* first —
## a portrait, at the largest element size on the panel, with its growth wrapped
## around it — and the needs second, as four small dials arranged in a block
## rather than stacked in a column. A block of dials reads as a status; a column
## of bars reads as a to-do list, and that difference is the whole design.
##
## Numbers are still available: hovering a dial reveals its percentage. They are
## just not the first thing the eye lands on.
##
## Layout, in design pixels:
##
##   ┌──────────────────────────────────┐
##   │ Mochi                       [x]  │
##   │ Teen kitten · four days together │
##   │  ╭────╮      ◔  ◔                │
##   │  │ 🐈 │      ◑  ◕                │
##   │  ╰────╯   food play rest clean   │
##   │  Teen → Cat                      │
##   │  ══════════════════════ Devoted  │
##   │  "Mochi is in a playful mood."   │
##   └──────────────────────────────────┘

const PANEL_SIZE := Vector2(392.0, 344.0)
const PORTRAIT_R := 52.0
const NEED_R := 26.0

var pet: UIPetView = null:
	set(v):
		pet = v
		_resync()

## Hours per stage, read from the species spec so the estimate is honest.
var hours_per_stage: float = 24.0

var _portrait: UISilhouette
## Animated need values. Meters chase their target rather than jumping, so a
## feed action is visible as the dial filling — the feedback *is* the animation.
var _need_anim := {&"food": 0.0, &"play": 0.0, &"rest": 0.0, &"clean": 0.0}
var _affection_anim: float = 0.0
var _growth_anim: float = 0.0
var _need_hover := {&"food": 0.0, &"play": 0.0, &"rest": 0.0, &"clean": 0.0}
var _hover_need: StringName = &""
var _t: float = 0.0


func _init() -> void:
	title = "Mochi"
	subtitle = ""
	size = PANEL_SIZE * UITokens.scale


func _build() -> void:
	_portrait = UISilhouette.new()
	_portrait.style = UISilhouette.Style.TINTED
	_portrait.fill_ratio = 0.74
	_portrait.bob_px = 5.0
	_portrait.contact_shadow = false
	add_child(_portrait)


func _layout() -> void:
	super._layout()
	if _portrait == null:
		return
	var r := UITokens.s(PORTRAIT_R)
	_portrait.size = Vector2(r * 1.72, r * 1.72)
	_portrait.position = _portrait_center() - _portrait.size * 0.5


func _portrait_center() -> Vector2:
	return Vector2(pad() + UITokens.s(PORTRAIT_R) + UITokens.s(6.0),
		content_top() + UITokens.s(PORTRAIT_R) + UITokens.s(4.0))


func _resync() -> void:
	if pet == null:
		return
	title = pet.display_name()
	subtitle = "%s · %s" % [pet.stage_name(), pet.togetherness(_now())]
	if _portrait != null:
		_portrait.species = pet.species
		_portrait.growth = pet.growth
	queue_redraw()


func _on_opened() -> void:
	_resync()
	# Meters start empty and fill on open. Two hundred milliseconds of the bars
	# arriving is what makes the panel feel like it was drawn for you rather
	# than uncovered.
	if UITokens.reduced_motion:
		_snap_meters()
	else:
		for k in _need_anim:
			_need_anim[k] = 0.0
		_affection_anim = 0.0
		_growth_anim = 0.0


func _snap_meters() -> void:
	if pet == null:
		return
	for k in UIPetView.NEED_ORDER:
		_need_anim[k] = pet.need(k)
	_affection_anim = pet.affection
	_growth_anim = pet.stage_progress()


func _now() -> float:
	# `Clock` is the time authority, but the panel must still draw in the
	# preview harness where no autoload has been through a full boot.
	if Engine.has_singleton("Clock"):
		return Time.get_unix_time_from_system()
	return Time.get_unix_time_from_system()


func _process(delta: float) -> void:
	super._process(delta)
	_t += delta
	if pet == null:
		return
	for k in UIPetView.NEED_ORDER:
		_need_anim[k] = UIMotion.approach(float(_need_anim[k]), pet.need(k), 6.5, delta)
		var want: float = 1.0 if _hover_need == k else 0.0
		_need_hover[k] = UIMotion.approach(float(_need_hover[k]), want, 14.0, delta)
	_affection_anim = UIMotion.approach(_affection_anim, pet.affection, 5.0, delta)
	_growth_anim = UIMotion.approach(_growth_anim, pet.stage_progress(), 5.5, delta)


func _gui_input(event: InputEvent) -> void:
	super._gui_input(event)
	if event is InputEventMouseMotion:
		var local := (event as InputEventMouseMotion).position
		var found: StringName = &""
		for i in UIPetView.NEED_ORDER.size():
			if local.distance_to(_need_center(i)) < UITokens.s(NEED_R) * 1.25:
				found = UIPetView.NEED_ORDER[i]
				break
		if found != _hover_need:
			_hover_need = found
			queue_redraw()


## Dials in a 2x2 block to the right of the portrait.
func _need_center(i: int) -> Vector2:
	var r := UITokens.s(NEED_R)
	var gap := UITokens.s(20.0)
	var origin := Vector2(
		_portrait_center().x + UITokens.s(PORTRAIT_R) + UITokens.s(38.0) + r,
		content_top() + r + UITokens.s(2.0))
	return origin + Vector2(float(i % 2) * (r * 2.0 + gap),
		float(i / 2) * (r * 2.0 + gap + UITokens.s(13.0)))


func _draw_content() -> void:
	if pet == null:
		return
	_draw_portrait_ring()
	_draw_needs()
	_draw_growth()
	_draw_affection()
	_draw_mood_line()


func _draw_portrait_ring() -> void:
	var c := _portrait_center()
	var r := UITokens.s(PORTRAIT_R)
	# A recessed well for the portrait, so the animal sits *in* the panel rather
	# than on top of it.
	UIDraw.fill_path(self, UIDraw.circle_path(c, r, 40), UITokens.col(&"sunken"))
	UIDraw.stroke_path(self, UIDraw.circle_path(c, r, 40),
		UITokens.col(&"edge"), UITokens.HAIRLINE, true)
	UIMeters.growth_arc(self, c, r + UITokens.s(11.0), _growth_anim,
		pet.is_fully_grown())


func _draw_needs() -> void:
	var r := UITokens.s(NEED_R)
	for i in UIPetView.NEED_ORDER.size():
		var key: StringName = UIPetView.NEED_ORDER[i]
		var c := _need_center(i)
		var v: float = float(_need_anim[key])
		var hov: float = float(_need_hover[key])
		# Critical needs breathe. Slow, low-amplitude, and only below a third —
		# an interface that pulses at you constantly is one you stop looking at.
		var urgency: float = smoothstep(0.34, 0.10, pet.need(key))
		var pulse: float = urgency * UIMotion.breathe(_t, 2.6)
		UIMeters.need_ring(self, c, r, key, v, pulse, hov)

		var label_y: float = c.y + r + UITokens.s(9.0)
		var name_col := UITokens.col(&"text_faint")
		if urgency > 0.35 or hov > 0.05:
			name_col = UITokens.col(&"text_dim").lerp(
				UITokens.need_col_at(key, v), maxf(urgency, hov) * 0.8)
		var label := String(key).capitalize()
		# The number appears only under the cursor. Available, not shouted.
		if hov > 0.5:
			label = "%d%%" % int(round(v * 100.0))
		var w: float = UIType.width(label, UIType.Role.MICRO)
		UIDraw.text(self, Vector2(c.x - w * 0.5, label_y), label,
			UIType.Role.MICRO, name_col)


func _draw_growth() -> void:
	var c := _portrait_center()
	var y: float = c.y + UITokens.s(PORTRAIT_R) + UITokens.s(26.0)
	var text := "%s → %s" % [pet.stage_name(), pet.stage_name(pet.stage() + 1)]
	if pet.is_fully_grown():
		text = "Fully grown"
	var w: float = UIType.width(text, UIType.Role.MICRO, UIType.WEIGHT_SEMI)
	UIDraw.text(self, Vector2(c.x - w * 0.5, y), text, UIType.Role.MICRO,
		UITokens.col(&"text_dim"), UIType.WEIGHT_SEMI)

	var hrs := pet.hours_to_next_stage(hours_per_stage)
	if hrs > 0.0:
		var when := "about %d hours away" % maxi(1, int(round(hrs)))
		if hrs > 36.0:
			when = "about %d days away" % maxi(1, int(round(hrs / 24.0)))
		var w2: float = UIType.width(when, UIType.Role.MICRO)
		UIDraw.text(self, Vector2(c.x - w2 * 0.5,
			y + UIType.line_height(UIType.Role.MICRO) + UITokens.s(1.0)), when,
			UIType.Role.MICRO, UITokens.col(&"text_faint"))


func _draw_affection() -> void:
	var y: float = size.y - pad() - UITokens.s(46.0)
	var x := pad()
	var w: float = size.x - pad() * 2.0

	var glyph_x: float = x + UITokens.s(8.0)
	# The heart beats faster the stronger the bond. It is a tiny thing and it is
	# the single most anthropomorphic detail in the interface.
	var rate: float = lerpf(1.9, 1.1, _affection_anim)
	var thump: float = 0.0
	if not UITokens.reduced_motion:
		var ph: float = fposmod(_t / rate, 1.0)
		thump = exp(-ph * 14.0) * 0.16 + exp(-fposmod(ph + 0.72, 1.0) * 18.0) * 0.08
	UIGlyphs.draw_glyph(self, &"heart", Vector2(glyph_x, y + UITokens.s(3.0)),
		UITokens.s(17.0) * (1.0 + thump), UITokens.col(&"affection"))

	UIDraw.text(self, Vector2(glyph_x + UITokens.s(16.0), y - UITokens.s(4.0)),
		pet.bond_word(), UIType.Role.LABEL, UITokens.col(&"text"),
		UIType.WEIGHT_SEMI)

	var bar := Rect2(x, y + UITokens.s(16.0), w, UITokens.s(9.0))
	var beat: float = fposmod(_t / 3.4, 1.0)
	UIMeters.affection_ribbon(self, bar, _affection_anim, beat)


## One sentence, in the pet's own terms. It is the line that stops the panel
## being a dashboard: a number tells you the state, a sentence tells you there
## is somebody in there.
func _draw_mood_line() -> void:
	var y: float = size.y - pad() - UITokens.s(14.0)
	var line := "%s is %s." % [pet.display_name(), pet.mood_phrase()]
	var pressing := pet.most_pressing_need()
	if pressing != &"":
		const WANTS := {
			&"food": "and would very much like something to eat",
			&"play": "and is bored",
			&"rest": "and could do with a nap",
			&"clean": "and needs a wash",
		}
		line = "%s is %s, %s." % [pet.display_name(), pet.mood_phrase(),
			String(WANTS.get(pressing, "and needs something"))]
	UIDraw.text(self, Vector2(pad(), y), line, UIType.Role.MICRO,
		UITokens.col(&"text_dim"), -1.0, HORIZONTAL_ALIGNMENT_LEFT,
		size.x - pad() * 2.0)
