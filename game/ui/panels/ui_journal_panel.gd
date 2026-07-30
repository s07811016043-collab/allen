class_name UIJournalPanel
extends UIPanel

## The memory of the relationship.
##
## This is the screen the whole product is arguing for. A desktop pet is trivial
## to uninstall; what makes somebody not do it is the accumulated evidence that
## something happened here — a date, a count, a picture of what they used to
## look like. So the journal is written as a diary, not as a statistics page:
## milestones are sentences, the timeline is a row of portraits rather than a
## progress bar, and nothing anywhere is expressed as a completion percentage.
##
## The one number that gets to be big is "days together". It is the only stat
## the player did not earn by clicking, and it is the one that hurts to reset.

const PANEL_SIZE := Vector2(660.0, 566.0)
const STAGE_CHIP := 74.0

var pet: UIPetView = null:
	set(v):
		pet = v
		_resync()

var _chips: Array[UISilhouette] = []
var _list: MilestoneList
var _t: float = 0.0


## The milestone feed. A child control so it can clip its own overflow — the
## panel itself must not clip, or the scrim's shadow would be cut off with it.
class MilestoneList extends Control:
	var rows: Array = []
	var now: float = 0.0
	var _scroll: float = 0.0
	var _target: float = 0.0
	var _row_h: float = 0.0

	func _ready() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_ALL
		_row_h = UITokens.s(46.0)

	func content_height() -> float:
		return float(rows.size()) * _row_h

	func _gui_input(event: InputEvent) -> void:
		var step: float = _row_h * 1.2
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_target += step
				accept_event()
			elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target -= step
				accept_event()
		elif event.is_action_pressed(&"ui_down"):
			_target += step
			accept_event()
		elif event.is_action_pressed(&"ui_up"):
			_target -= step
			accept_event()
		_target = clampf(_target, 0.0, maxf(0.0, content_height() - size.y))

	func _process(delta: float) -> void:
		var s := UIMotion.approach(_scroll, _target, 14.0, delta)
		if absf(s - _scroll) > 0.05:
			_scroll = s
			queue_redraw()

	func _draw() -> void:
		var y: float = -_scroll
		for r in rows:
			if y > size.y or y + _row_h < 0.0:
				y += _row_h
				continue
			_draw_row(r, y)
			y += _row_h
		_draw_edge_fades()

	func _draw_row(row: Dictionary, y: float) -> void:
		var e: UIMilestones.Entry = row[&"entry"]
		var at: float = row[&"at"]
		var unlocked: bool = at > 0.0
		var icon_c := Vector2(UITokens.s(21.0), y + _row_h * 0.44)
		var r := UITokens.s(15.0)

		var tint := UITokens.col(&"accent") if unlocked else UITokens.col(&"text_faint")
		var disc := tint
		disc.a = 0.16 if unlocked else 0.05
		UIDraw.fill_path(self, UIDraw.circle_path(icon_c, r, 24), disc)
		UIGlyphs.draw_glyph(self, e.glyph if unlocked else &"lock", icon_c,
			r * 1.12, tint if unlocked else UITokens.col(&"text_faint"))

		var x: float = icon_c.x + r + UITokens.s(UITokens.SPACE_MD)
		var title_col := UITokens.col(&"text") if unlocked \
			else UITokens.col(&"text_faint")
		UIDraw.text(self, Vector2(x, y + UITokens.s(6.0)), e.title,
			UIType.Role.BODY, title_col, UIType.WEIGHT_SEMI)
		# Locked entries keep their story hidden. A journal that spoils its own
		# future pages is a checklist with better typography.
		var story: String = e.story if unlocked else "Not yet."
		UIDraw.text(self, Vector2(x, y + UITokens.s(6.0)
			+ UIType.line_height(UIType.Role.BODY) + UITokens.s(1.0)), story,
			UIType.Role.MICRO, UITokens.col(&"text_faint"), -1.0,
			HORIZONTAL_ALIGNMENT_LEFT, size.x - x - UITokens.s(74.0))

		if unlocked:
			var when := UIMilestones.when_phrase(at, now)
			var w: float = UIType.width(when, UIType.Role.MICRO)
			UIDraw.text(self, Vector2(size.x - w - UITokens.s(4.0),
				y + UITokens.s(12.0)), when, UIType.Role.MICRO,
				UITokens.col(&"text_faint"))

	## Fades at the clip edges, so a cut-off row reads as "there is more" rather
	## than as a rendering bug. Stacked scanlines, since there is no gradient
	## primitive and no texture to reach for.
	func _draw_edge_fades() -> void:
		var surf := UITokens.col(&"surface")
		var h := UITokens.s(22.0)
		const STEPS := 11
		for i in STEPS:
			var t: float = float(i) / float(STEPS - 1)
			var c := surf
			c.a = surf.a * (1.0 - t) * 0.9
			var band: float = h / float(STEPS)
			if _scroll > 1.0:
				draw_rect(Rect2(0.0, t * h, size.x, band + 1.0), c)
			if _scroll < content_height() - size.y - 1.0:
				draw_rect(Rect2(0.0, size.y - t * h - band, size.x, band + 1.0), c)


func _init() -> void:
	title = "Journal"
	deep = true
	size = PANEL_SIZE * UITokens.scale


func _build() -> void:
	for i in 4:
		var s := UISilhouette.new()
		s.style = UISilhouette.Style.FLAT
		s.fill_ratio = 0.80
		s.contact_shadow = false
		s.growth = float(i)
		add_child(s)
		_chips.append(s)
	_list = MilestoneList.new()
	add_child(_list)


func _layout() -> void:
	super._layout()
	if _chips.is_empty():
		return
	var chip := UITokens.s(STAGE_CHIP)
	for i in 4:
		_chips[i].size = Vector2(chip, chip)
		_chips[i].position = _chip_center(i) - Vector2(chip, chip) * 0.5
	if _list != null:
		var top := _list_top()
		_list.position = Vector2(pad(), top)
		_list.size = Vector2(size.x - pad() * 2.0, size.y - top - pad())


func _timeline_top() -> float:
	return content_top() + UITokens.s(20.0)


func _chip_center(i: int) -> Vector2:
	var inner: float = size.x - pad() * 2.0
	var step: float = inner / 4.0
	return Vector2(pad() + step * (float(i) + 0.5),
		_timeline_top() + UITokens.s(STAGE_CHIP) * 0.5)


func _stats_top() -> float:
	return _timeline_top() + UITokens.s(STAGE_CHIP) + UITokens.s(44.0)


func _list_top() -> float:
	return _stats_top() + UITokens.s(74.0)


func _resync() -> void:
	if pet == null:
		return
	title = "The story of %s" % pet.display_name()
	subtitle = "Adopted %s · %s" % [pet.adopted_on(),
		pet.togetherness(Time.get_unix_time_from_system())]
	for i in _chips.size():
		_chips[i].species = pet.species
		_chips[i].growth = float(i)
		_chips[i].flat_color = _chip_color(i)
	if _list != null:
		_list.rows = UIMilestones.timeline(pet)
		_list.now = Time.get_unix_time_from_system()
		_list.queue_redraw()
	queue_redraw()


## Stages already lived are solid; the ones ahead are ghosted. Showing them at
## all is the point — "this is who they will become" is a reason to keep the app
## open tomorrow.
func _chip_color(i: int) -> Color:
	if pet == null:
		return UITokens.col(&"text_dim")
	var reached: bool = float(i) <= pet.growth + 0.001
	var c := UITokens.col(&"text")
	if not reached:
		c = UITokens.col(&"text_faint")
		c.a *= 0.55
	return c


func _process(delta: float) -> void:
	super._process(delta)
	_t += delta


func _draw_content() -> void:
	if pet == null:
		return
	_draw_timeline()
	_draw_stats()
	rule(_list_top() - UITokens.s(14.0))
	UIDraw.eyebrow(self, Vector2(pad(), _list_top() - UITokens.s(32.0)),
		"Moments", UITokens.col(&"text_faint"))


func _draw_timeline() -> void:
	var y: float = _chip_center(0).y
	var a := _chip_center(0)
	var b := _chip_center(3)
	# The connecting line is drawn twice: a full-length track, then the lived
	# portion over it in the accent. Growth is a road, not a bar.
	draw_line(Vector2(a.x, y + UITokens.s(STAGE_CHIP) * 0.5 + UITokens.s(9.0)),
		Vector2(b.x, y + UITokens.s(STAGE_CHIP) * 0.5 + UITokens.s(9.0)),
		UITokens.col(&"edge"), UITokens.s(2.0), true)
	var t: float = clampf(pet.growth / 3.0, 0.0, 1.0)
	draw_line(Vector2(a.x, y + UITokens.s(STAGE_CHIP) * 0.5 + UITokens.s(9.0)),
		Vector2(lerpf(a.x, b.x, t), y + UITokens.s(STAGE_CHIP) * 0.5
			+ UITokens.s(9.0)), UITokens.col(&"accent"), UITokens.s(2.0), true)

	for i in 4:
		var c := _chip_center(i)
		var reached: bool = float(i) <= pet.growth + 0.001
		var here: bool = pet.stage() == i
		var dot := Vector2(c.x, c.y + UITokens.s(STAGE_CHIP) * 0.5 + UITokens.s(9.0))
		var col: Color = UITokens.col(&"accent") if reached \
			else UITokens.col(&"edge_strong")
		if here:
			var g := col
			g.a = 0.30 + 0.18 * UIMotion.breathe(_t, 3.2)
			UIDraw.glow(self, dot, UITokens.s(13.0), g, 5)
		UIDraw.fill_path(self, UIDraw.circle_path(dot,
			UITokens.s(5.0 if here else 3.4), 14), col)

		var label: String = pet.stage_name(i)
		var lc: Color = UITokens.col(&"text") if here else (
			UITokens.col(&"text_dim") if reached else UITokens.col(&"text_faint"))
		var w: float = UIType.width(label, UIType.Role.MICRO,
			UIType.WEIGHT_SEMI if here else -1.0)
		UIDraw.text(self, Vector2(c.x - w * 0.5, dot.y + UITokens.s(10.0)),
			label, UIType.Role.MICRO, lc, UIType.WEIGHT_SEMI if here else -1.0)


## Five numbers, set large. Numbers this size are a boast on the player's
## behalf, which is the correct emotional register for a page about a pet.
func _draw_stats() -> void:
	var y := _stats_top()
	var cols := [
		{&"n": pet.days_together(Time.get_unix_time_from_system()), &"l": "days together"},
		{&"n": int(pet.stats.get(&"strokes", 0)), &"l": "strokes"},
		{&"n": int(pet.stats.get(&"meals", 0)), &"l": "meals"},
		{&"n": int(pet.stats.get(&"naps", 0)), &"l": "naps"},
		{&"n": int(pet.stats.get(&"steps", 0)), &"l": "steps taken"},
	]
	var inner: float = size.x - pad() * 2.0
	var step: float = inner / float(cols.size())
	for i in cols.size():
		var cx: float = pad() + step * (float(i) + 0.5)
		var value := _compact(int(cols[i][&"n"]))
		var w: float = UIType.width(value, UIType.Role.DISPLAY)
		# The first column is the one that matters; the rest are supporting.
		var col: Color = UITokens.col(&"accent") if i == 0 else UITokens.col(&"text")
		UIDraw.text(self, Vector2(cx - w * 0.5, y), value, UIType.Role.DISPLAY, col)
		var lw: float = UIType.width(String(cols[i][&"l"]), UIType.Role.MICRO)
		UIDraw.text(self, Vector2(cx - lw * 0.5,
			y + UIType.line_height(UIType.Role.DISPLAY) + UITokens.s(2.0)),
			String(cols[i][&"l"]), UIType.Role.MICRO, UITokens.col(&"text_faint"))


## 18,930 → "18.9k". Five digits at display size would blow the column apart,
## and nobody has ever needed the exact number of steps their cat took.
static func _compact(n: int) -> String:
	if n < 1000:
		return str(n)
	if n < 100000:
		return "%.1fk" % (float(n) / 1000.0)
	return "%dk" % int(round(float(n) / 1000.0))
