class_name UISettingsPanel
extends UIPanel

## Settings.
##
## Grouped by *what the player is trying to fix*, not by which subsystem owns
## the value: somebody opens this panel because the pet is too big, too loud, in
## the way, or moving too much. Hence four short sections instead of one long
## list, and a plain-language hint under every control that touches the desktop,
## since "click-through" and "always on top" are compositor jargon that a person
## should never have to have learned.
##
## Every change is written straight through to `Settings`, which persists it and
## fans out a `settings_changed`. No Apply button: an overlay that makes you
## confirm a volume change has misunderstood what it is.

const PANEL_SIZE := Vector2(452.0, 596.0)

var _scale: UISlider
var _quality: UISegmented
var _master: UISlider
var _voice: UISlider
var _ambience: UISlider
var _click_through: UIToggle
var _on_top: UIToggle
var _reduced: UIToggle
var _rows: Array[Control] = []
## Section headings, as (y-anchor row index, text) resolved at layout time.
var _sections: Array = []


func _init() -> void:
	title = "Settings"
	subtitle = "Changes apply immediately"
	deep = true
	size = PANEL_SIZE * UITokens.scale


func _build() -> void:
	_scale = _slider("Interface size", "How large panels and menus are drawn.",
		0.75, 1.5, 0.05, func(v: float) -> String: return "%d%%" % int(round(v * 100.0)))
	_scale.fill_color = UITokens.col(&"text_dim")

	_quality = UISegmented.new()
	_quality.label = "Rendering quality"
	_quality.hint = "lower uses less battery"
	_quality.options = PackedStringArray(["Low", "Medium", "High", "Ultra"])
	add_child(_quality)
	_rows.append(_quality)
	_quality.selected.connect(func(i: int) -> void: _write(&"quality", i))

	_master = _slider("Master volume", "", 0.0, 1.0, 0.0, Callable())
	_voice = _slider("Voice", "Meows, chirps, purrs.", 0.0, 1.0, 0.0, Callable())
	_ambience = _slider("Ambience", "Footsteps and rustling.", 0.0, 1.0, 0.0, Callable())

	_click_through = _toggle("Let clicks pass through",
		"You can click the icons underneath your pet; it only catches the cursor when you aim at it.")
	_on_top = _toggle("Keep above other windows",
		"Your pet stays visible when you switch apps.")
	_reduced = _toggle("Reduce motion",
		"Panels and menus appear without animation. Everything still says what it said.")

	_sections = [
		{&"before": _scale, &"text": "Appearance"},
		{&"before": _master, &"text": "Sound"},
		{&"before": _click_through, &"text": "Desktop"},
		{&"before": _reduced, &"text": "Accessibility"},
	]
	pull_from_settings()


func _slider(label: String, hint: String, lo: float, hi: float, step: float,
		fmt: Callable) -> UISlider:
	var s := UISlider.new()
	s.label = label
	s.hint = hint
	s.min_value = lo
	s.max_value = hi
	s.step = step
	if fmt.is_valid():
		s.formatter = fmt
	add_child(s)
	_rows.append(s)
	return s


func _toggle(label: String, hint: String) -> UIToggle:
	var t := UIToggle.new()
	t.label = label
	t.hint = hint
	add_child(t)
	_rows.append(t)
	return t


func _layout() -> void:
	super._layout()
	if _rows.is_empty():
		return
	var x := pad()
	var w: float = size.x - pad() * 2.0
	var y := content_top()
	for r in _rows:
		if _section_before(r) != "":
			y += UITokens.s(UITokens.SPACE_LG)
		r.position = Vector2(x, y)
		r.size = Vector2(w, r.custom_minimum_size.y)
		y += r.size.y + UITokens.s(UITokens.SPACE_SM)


func _section_before(row: Control) -> String:
	for s in _sections:
		if s[&"before"] == row:
			return String(s[&"text"])
	return ""


## Read the live settings into the controls without emitting change signals —
## otherwise opening the panel would rewrite every value it just read.
func pull_from_settings() -> void:
	_scale.set_value_silent(_read(&"ui_scale", 1.0))
	_quality.set_index_silent(int(_read(&"quality", 2)))
	_master.set_value_silent(_read(&"master_volume", 0.8))
	_voice.set_value_silent(_read(&"voice_volume", 1.0))
	_ambience.set_value_silent(_read(&"ambience_volume", 0.5))
	_click_through.set_value_silent(bool(_read(&"click_through", true)))
	_on_top.set_value_silent(bool(_read(&"always_on_top", true)))
	_reduced.set_value_silent(bool(_read(&"reduced_motion", false)))

	# Connected after the first pull so the initial write-back never happens.
	if not _scale.value_changed.is_connected(_on_scale):
		_scale.value_changed.connect(_on_scale)
		_master.value_changed.connect(func(v: float) -> void: _write(&"master_volume", v))
		_voice.value_changed.connect(func(v: float) -> void: _write(&"voice_volume", v))
		_ambience.value_changed.connect(func(v: float) -> void: _write(&"ambience_volume", v))
		_click_through.toggled.connect(func(v: bool) -> void: _write(&"click_through", v))
		_on_top.toggled.connect(func(v: bool) -> void: _write(&"always_on_top", v))
		_reduced.toggled.connect(_on_reduced)


func _on_scale(v: float) -> void:
	_write(&"ui_scale", v)
	UITokens.scale = clampf(v, 0.75, 2.0)
	# Relayout the whole overlay, not just this panel: the scale token is read
	# at draw time by every widget, so they all need a fresh measure.
	var root := get_parent()
	if root != null and root.has_method("restyle"):
		root.restyle()
	else:
		_relayout_self()


func _on_reduced(v: bool) -> void:
	_write(&"reduced_motion", v)
	UITokens.reduced_motion = v
	queue_redraw()


func _relayout_self() -> void:
	size = PANEL_SIZE * UITokens.scale
	_layout()
	queue_redraw()


## `Settings` is an autoload; the preview harness runs the same panel without a
## booted game, so both reads and writes tolerate its absence.
func _read(key: StringName, fallback: Variant) -> Variant:
	var s := get_node_or_null(^"/root/Settings")
	if s != null and s.has_method("get_value"):
		return s.get_value(key, fallback)
	return fallback


func _write(key: StringName, value: Variant) -> void:
	var s := get_node_or_null(^"/root/Settings")
	if s != null and s.has_method("set_value"):
		s.set_value(key, value)


func _draw_content() -> void:
	for s in _sections:
		var row: Control = s[&"before"]
		if row == null:
			continue
		UIDraw.eyebrow(self, Vector2(pad(),
			row.position.y - UITokens.s(16.0)), String(s[&"text"]),
			UITokens.col(&"text_faint"))
		if row != _rows[0]:
			var c := UITokens.col(&"edge")
			c.a *= 0.6
			draw_rect(Rect2(pad(), row.position.y - UITokens.s(26.0),
				size.x - pad() * 2.0, UITokens.HAIRLINE), c)
