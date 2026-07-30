class_name UIStage
extends Control

## Composes one reviewable arrangement of the interface for the preview
## harness.
##
## Separate from `ui_preview.gd` so the harness owns only the fake desktop and
## the PNG, while the question of *what a good shot of this UI looks like* stays
## with the UI. Each shot is a scene a real player could actually be looking at
## — a panel over a wallpaper, at its real size — rather than a component
## gallery, because components in isolation always look fine.

var shot := "board"
var viewport_size := Vector2(1600.0, 1000.0)

var _pet: UIPetView
var _toasts: UIToastHost


func _ready() -> void:
	size = viewport_size
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UITheme.build()
	_pet = UIPetView.demo()

	match shot:
		"board": _board()
		"care": _single(_care_panel())
		"journal": _single(_journal_panel())
		"adopt": _single(_adoption_panel())
		"settings": _single(_settings_panel())
		"radial": _radial_only()
		"toasts": _toasts_only()
		"system": _system_specimen()
		_: _board()


# --- Shots -------------------------------------------------------------------

## Everything at once, over the worst-case backdrop: the radial menu open on the
## pet, the care panel straddling the white/black seam, and two toasts.
func _board() -> void:
	var pet_at := Vector2(viewport_size.x * 0.245, viewport_size.y * 0.52)
	_place_pet(pet_at)

	var radial := UIRadialMenu.new()
	radial.pet_name = _pet.display_name()
	add_child(radial)
	radial.open_at(pet_at)
	# Park the pointer on an item so the shot shows a hover state; a radial menu
	# photographed at rest hides the half of the design that matters.
	radial._apply_selection(4, false)
	radial._keyboard_mode = true

	var care := _care_panel()
	add_child(care)
	care.position = Vector2(viewport_size.x * 0.585, viewport_size.y * 0.30).round()
	care.open()

	_spawn_toasts()


func _single(panel: UIPanel) -> void:
	add_child(panel)
	panel.position = ((viewport_size - panel.size) * 0.5).round()
	panel.open()


func _radial_only() -> void:
	var at := viewport_size * 0.5
	_place_pet(at)
	var radial := UIRadialMenu.new()
	radial.pet_name = _pet.display_name()
	add_child(radial)
	radial.open_at(at)
	radial._apply_selection(0, false)
	radial._keyboard_mode = true


func _toasts_only() -> void:
	_place_pet(Vector2(viewport_size.x * 0.28, viewport_size.y * 0.62))
	_spawn_toasts()


func _place_pet(at: Vector2) -> void:
	var s := UISilhouette.new()
	s.species = _pet.species
	s.growth = _pet.growth
	s.style = UISilhouette.Style.TINTED
	s.bob_px = 0.0
	s.fill_ratio = 0.9
	var box := UITokens.s(150.0)
	s.size = Vector2(box * 1.4, box)
	s.position = at - s.size * 0.5
	add_child(s)


func _spawn_toasts() -> void:
	_toasts = UIToastHost.new()
	add_child(_toasts)
	_toasts.size = viewport_size
	_toasts.notify(&"stage_2", "Mochi is a teen now.", &"star",
		UIToast.Tone.MILESTONE)
	_toasts.notify(&"food", "Mochi keeps wandering back to the bowl.", &"food",
		UIToast.Tone.NEED)


# --- Panel builders ----------------------------------------------------------

func _care_panel() -> UICarePanel:
	var p := UICarePanel.new()
	p.pet = _pet
	var spec: Object = UISilhouette.spec_for(_pet.species)
	if spec != null:
		p.hours_per_stage = float(spec.get("hours_per_stage"))
	return p


func _journal_panel() -> UIJournalPanel:
	var p := UIJournalPanel.new()
	p.pet = _pet
	return p


func _adoption_panel() -> UIAdoptionPanel:
	return UIAdoptionPanel.new()


func _settings_panel() -> UISettingsPanel:
	return UISettingsPanel.new()


# --- Design system specimen --------------------------------------------------

## Not a shot of the product: a shot of the *system*. Type scale, colour roles
## and the icon set on one surface, at the sizes they are really used, so a
## regression in any of them is visible without opening five panels.
func _system_specimen() -> void:
	var card := UIScrim.new()
	card.deep = true
	card.size = viewport_size - Vector2(UITokens.s(120.0), UITokens.s(90.0))
	card.position = Vector2(UITokens.s(60.0), UITokens.s(45.0))
	add_child(card)
	var sheet := SpecimenSheet.new()
	sheet.size = card.size
	card.add_child(sheet)


class SpecimenSheet extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var pad := UITokens.s(UITokens.SPACE_XXL)
		var y := pad
		UIDraw.text(self, Vector2(pad, y), "Petalia interface system",
			UIType.Role.TITLE, UITokens.col(&"text"))
		y += UIType.line_height(UIType.Role.TITLE) + UITokens.s(6.0)
		UIDraw.text(self, Vector2(pad, y),
			"One type scale, one palette, one icon set. Everything else is drawn from these.",
			UIType.Role.MICRO, UITokens.col(&"text_dim"))
		y += UITokens.s(38.0)

		UIDraw.eyebrow(self, Vector2(pad, y), "Type", UITokens.col(&"text_faint"))
		y += UITokens.s(20.0)
		const SAMPLES := [
			[UIType.Role.DISPLAY, "412", "display"],
			[UIType.Role.TITLE, "The story of Mochi", "title"],
			[UIType.Role.HEAD, "Moments", "head"],
			[UIType.Role.BODY, "You reached out. They leaned in.", "body"],
			[UIType.Role.LABEL, "Bring them home", "label"],
			[UIType.Role.MICRO, "four days together", "micro"],
		]
		for s in SAMPLES:
			var role: UIType.Role = s[0]
			UIDraw.text(self, Vector2(pad, y), String(s[1]), role,
				UITokens.col(&"text"))
			UIDraw.text(self, Vector2(pad + UITokens.s(340.0), y + UITokens.s(4.0)),
				"%s · %dpx" % [String(s[2]), UIType.px(role)], UIType.Role.MICRO,
				UITokens.col(&"text_faint"))
			y += UIType.line_height(role) + UITokens.s(10.0)

		var right := UITokens.s(470.0)
		var cy := pad + UITokens.s(58.0)
		UIDraw.eyebrow(self, Vector2(right, cy - UITokens.s(20.0)), "Colour",
			UITokens.col(&"text_faint"))
		const ROLES: Array[StringName] = [&"accent", &"affection", &"food",
			&"play", &"rest", &"clean", &"positive", &"alert", &"focus",
			&"text", &"text_dim", &"edge_strong"]
		for i in ROLES.size():
			var col: int = i % 4
			var row: int = i / 4
			var box := Rect2(right + float(col) * UITokens.s(104.0),
				cy + float(row) * UITokens.s(58.0), UITokens.s(92.0),
				UITokens.s(30.0))
			UIDraw.round_rect(self, box, UITokens.s(UITokens.RADIUS_SM),
				UITokens.col(ROLES[i]))
			UIDraw.text(self, Vector2(box.position.x, box.end.y + UITokens.s(4.0)),
				String(ROLES[i]), UIType.Role.MICRO, UITokens.col(&"text_faint"))

		var gy := cy + UITokens.s(200.0)
		UIDraw.eyebrow(self, Vector2(right, gy - UITokens.s(20.0)), "Icons",
			UITokens.col(&"text_faint"))
		const GLYPHS: Array[StringName] = [&"feed", &"play", &"pet", &"sleep",
			&"journal", &"settings", &"adopt", &"clean", &"heart", &"star",
			&"sparkle", &"check", &"close", &"clock", &"lock"]
		for i in GLYPHS.size():
			var col2: int = i % 8
			var row2: int = i / 8
			var c := Vector2(right + UITokens.s(20.0) + float(col2) * UITokens.s(52.0),
				gy + UITokens.s(20.0) + float(row2) * UITokens.s(58.0))
			UIGlyphs.draw_glyph(self, GLYPHS[i], c, UITokens.s(26.0),
				UITokens.col(&"text"))
			var w: float = UIType.width(String(GLYPHS[i]), UIType.Role.MICRO)
			UIDraw.text(self, Vector2(c.x - w * 0.5, c.y + UITokens.s(18.0)),
				String(GLYPHS[i]), UIType.Role.MICRO, UITokens.col(&"text_faint"))

		# Elevation and meters, at their real sizes.
		var my := size.y - UITokens.s(150.0)
		UIDraw.eyebrow(self, Vector2(pad, my - UITokens.s(20.0)), "Meters",
			UITokens.col(&"text_faint"))
		for i in 4:
			var keys: Array[StringName] = [&"food", &"play", &"rest", &"clean"]
			UIMeters.need_ring(self, Vector2(pad + UITokens.s(32.0)
				+ float(i) * UITokens.s(84.0), my + UITokens.s(34.0)),
				UITokens.s(26.0), keys[i], [0.28, 0.62, 0.86, 1.0][i], 0.0, 0.0)
		UIMeters.affection_ribbon(self, Rect2(pad + UITokens.s(370.0),
			my + UITokens.s(28.0), UITokens.s(280.0), UITokens.s(10.0)), 0.68, 0.4)
		UIMeters.growth_arc(self, Vector2(pad + UITokens.s(720.0),
			my + UITokens.s(34.0)), UITokens.s(30.0), 0.62, false)
