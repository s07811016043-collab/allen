class_name UIRoot
extends CanvasLayer

## The overlay's front door.
##
## Owns the radial menu, the four panels and the toast stack, and is the only
## place that talks to `EventBus`, `Settings` and `GameState`. Panels stay
## ignorant of the game; the game stays ignorant of the panels.
##
## Three rules this node exists to enforce, all of them consequences of living
## on somebody else's desktop rather than inside a window:
##
##   * **Never steal focus.** Focus is grabbed only along keyboard-initiated
##     paths and in the naming field, which the player opened in order to type.
##     Everything else is reachable by pointer without the OS ever moving the
##     active window.
##   * **Be invisible until wanted.** Nothing is on screen at rest. The layer
##     reports the rectangles it actually occupies through `interactive_rects`,
##     so the window layer can keep the rest of the overlay click-through and
##     let the desktop underneath receive the cursor.
##   * **One thing at a time.** Opening a panel closes the others and mutes
##     toasts. A desktop pet with three floating windows open is not a pet.

signal action_requested(action: StringName, pet_id: StringName)
signal adoption_requested(species: StringName, pet_name: String)
## Emitted when the set of rectangles this overlay wants the cursor for changes,
## so the window layer can update its click-through region.
signal interaction_region_changed()

var pet: UIPetView = null

var _layer: Control
var _radial: UIRadialMenu
var _care: UICarePanel
var _journal: UIJournalPanel
var _adopt: UIAdoptionPanel
var _settings: UISettingsPanel
var _toasts: UIToastHost
var _panels: Array[UIPanel] = []
var _theme: Theme


func _ready() -> void:
	layer = 100
	_pull_settings()
	_theme = UITheme.build()

	_layer = Control.new()
	_layer.name = "UILayer"
	_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Ignore, not stop: the empty regions of the overlay must not eat a click
	# that was aimed at the desktop.
	_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.theme = _theme
	add_child(_layer)

	# The scrim shader samples the screen texture, which in 2D is only written
	# by an explicit back-buffer copy. One at the bottom of this layer gives
	# every panel a blurred backdrop of whatever the game drew underneath.
	var bbc := BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_layer.add_child(bbc)

	_toasts = UIToastHost.new()
	_layer.add_child(_toasts)

	_care = UICarePanel.new()
	_journal = UIJournalPanel.new()
	_adopt = UIAdoptionPanel.new()
	_settings = UISettingsPanel.new()
	_panels = [_care, _journal, _adopt, _settings]
	for p in _panels:
		_layer.add_child(p)
		p.closed.connect(_on_panel_closed)
		p.opened.connect(_on_panel_opened)
	_adopt.adopted.connect(func(sp: StringName, n: String) -> void:
		adoption_requested.emit(sp, n))

	_radial = UIRadialMenu.new()
	_layer.add_child(_radial)
	_radial.action_chosen.connect(_on_radial_action)
	_radial.dismissed.connect(func() -> void: interaction_region_changed.emit())

	_connect_bus()
	refresh_pet()


# --- Settings and scheme ----------------------------------------------------

func _pull_settings() -> void:
	var s := get_node_or_null(^"/root/Settings")
	var ui_scale := 1.0
	var reduced := false
	if s != null and s.has_method("get_value"):
		ui_scale = float(s.get_value(&"ui_scale", 1.0))
		reduced = bool(s.get_value(&"reduced_motion", false))
	UITokens.refresh(ui_scale, _prefers_dark(), reduced)


## Which scheme to wear. The overlay sits on the player's wallpaper, so it takes
## its cue from the OS where the OS will tell us, and defaults to dark — a dark
## chrome disappears against more desktops than a light one does, and the scrim
## guarantees contrast either way.
func _prefers_dark() -> bool:
	var s := get_node_or_null(^"/root/Settings")
	if s != null and s.has_method("get_value"):
		var pref: Variant = s.get_value(&"ui_light_scheme", null)
		if pref != null:
			return not bool(pref)
	if DisplayServer.has_method("is_dark_mode_supported") \
			and DisplayServer.is_dark_mode_supported():
		return DisplayServer.is_dark_mode()
	return true


## Rebuild the theme and re-lay everything out. Called when the UI scale or the
## colour scheme changes; both invalidate measurements taken at draw time.
func restyle() -> void:
	_pull_settings()
	_theme = UITheme.build()
	_layer.theme = _theme
	for p in _panels:
		p.scrim.restyle()
		p.size = p.size  # re-triggers NOTIFICATION_RESIZED and the layout pass
		p.queue_redraw()
	_place_panels()
	_radial.queue_redraw()


# --- Event bus ---------------------------------------------------------------

## Everything here is guarded: the bus is shared with systems that are still
## being written, and a signal that does not exist yet must not stop the
## interface from loading.
func _connect_bus() -> void:
	var bus := get_node_or_null(^"/root/EventBus")
	if bus == null:
		return
	if bus.has_signal(&"milestone_unlocked"):
		bus.milestone_unlocked.connect(_on_milestone)
	if bus.has_signal(&"need_critical"):
		bus.need_critical.connect(_on_need_critical)
	if bus.has_signal(&"stage_advanced"):
		bus.stage_advanced.connect(_on_stage_advanced)
	if bus.has_signal(&"settings_changed"):
		bus.settings_changed.connect(_on_settings_changed)
	if bus.has_signal(&"game_loaded"):
		bus.game_loaded.connect(refresh_pet)


func _on_settings_changed(key: StringName) -> void:
	if key == &"ui_scale" or key == &"reduced_motion" or key == &"ui_light_scheme":
		restyle()


## Pull the active pet out of `GameState`. Called on load and whenever the
## player adopts; the panels hold a view, not the record, so this is the only
## coupling point.
func refresh_pet() -> void:
	var gs := get_node_or_null(^"/root/GameState")
	if gs == null:
		return
	var pets: Variant = gs.get("pets")
	if typeof(pets) == TYPE_ARRAY and not (pets as Array).is_empty():
		set_pet(UIPetView.from_record((pets as Array)[0]))


func set_pet(view: UIPetView) -> void:
	pet = view
	_care.pet = view
	_journal.pet = view
	if view != null:
		_radial.pet_name = view.display_name()
		_radial.pet_species = view.species
		_radial.pet_growth = view.growth
		var spec: Object = UISilhouette.spec_for(view.species)
		if spec != null:
			_care.hours_per_stage = float(spec.get("hours_per_stage"))


func _on_milestone(_pet_id: StringName, milestone_id: StringName) -> void:
	var e := UIMilestones.by_id(milestone_id)
	if e == null:
		return
	_toasts.notify(milestone_id, e.title + " — " + e.story, e.glyph,
		UIToast.Tone.MILESTONE)


## Needs are phrased as observations of the animal, never as instructions to the
## player. "Feed your cat" is a task; "Mochi keeps looking at the bowl" is a cat.
func _on_need_critical(_pet_id: StringName, need: StringName) -> void:
	if pet == null:
		return
	const LINES := {
		&"food": "%s keeps wandering back to the bowl.",
		&"play": "%s has started batting at the cursor again.",
		&"rest": "%s is having trouble keeping their eyes open.",
		&"clean": "%s has been grooming the same spot for a while.",
	}
	var template := String(LINES.get(need, "%s wants something."))
	_toasts.notify(need, template % pet.display_name(), need, UIToast.Tone.NEED)


func _on_stage_advanced(_pet_id: StringName, stage: int) -> void:
	if pet == null:
		return
	_toasts.notify(StringName("stage_%d" % stage),
		"%s is a %s now." % [pet.display_name(), pet.stage_name(stage).to_lower()],
		&"star", UIToast.Tone.MILESTONE)


# --- Invocation --------------------------------------------------------------

## Summon the radial menu at a screen point — normally the pet's head.
func summon_radial(at: Vector2, keyboard: bool = false) -> void:
	_close_all_panels()
	_radial.open_at(at, keyboard)
	interaction_region_changed.emit()


func _on_radial_action(action: StringName) -> void:
	var from := _radial._center
	match action:
		&"journal": _open(_journal, from)
		&"settings": _open(_settings, from)
		&"adopt": _open(_adopt, from)
		&"feed", &"play", &"pet", &"sleep":
			# Care actions are the game's business, not the interface's. The
			# care panel opens alongside so the player sees the meter move,
			# which is the entire feedback for the action.
			action_requested.emit(action, pet.id if pet != null else &"")
			_open(_care, from)
		_:
			action_requested.emit(action, pet.id if pet != null else &"")


func open_panel(id: StringName, from: Vector2 = Vector2.INF) -> void:
	match id:
		&"care": _open(_care, from)
		&"journal": _open(_journal, from)
		&"adopt": _open(_adopt, from)
		&"settings": _open(_settings, from)


func _open(panel: UIPanel, from: Vector2) -> void:
	for p in _panels:
		if p != panel:
			p.close()
	_place_panels()
	panel.open(from)
	interaction_region_changed.emit()


func _on_panel_opened() -> void:
	# Silence while the player is reading. Anything worth saying is already on
	# the panel in front of them.
	_toasts.muted = true


func _on_panel_closed() -> void:
	for p in _panels:
		if p.is_open():
			return
	_toasts.muted = false
	interaction_region_changed.emit()


func _close_all_panels() -> void:
	for p in _panels:
		p.close()


## Panels are centred on the work area rather than anchored to a screen corner:
## the overlay window spans the whole desktop, and a floating panel pinned to a
## corner would read as part of the OS rather than as part of the pet.
func _place_panels() -> void:
	var vp := _layer.size
	for p in _panels:
		p.position = ((vp - p.size) * 0.5).round()
		p._base_pos = p.position


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_place_panels()


# --- Click-through -----------------------------------------------------------

## The screen rectangles the overlay currently wants the cursor for. The window
## layer unions this with the pet's own hit area to build the click-through
## region, so everywhere else on the desktop keeps working normally while the
## pet is on screen.
func interactive_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for p in _panels:
		if p.is_open():
			out.append(Rect2(p.position, p.size))
	if _radial.is_open():
		var r: float = UITokens.s(UIRadialMenu.RING_RADIUS
			+ UIRadialMenu.ITEM_RADIUS * 2.0)
		out.append(Rect2(_radial._center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)))
	return out


## True while the overlay is showing something the player can interact with.
func wants_mouse() -> bool:
	return not interactive_rects().is_empty()


func toasts() -> UIToastHost:
	return _toasts


func _unhandled_input(event: InputEvent) -> void:
	# Right-click anywhere the game did not already claim opens the menu on the
	# pet. The world layer handles the on-pet case and consumes the event first;
	# this is the fallback so the menu is never unreachable.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT and not _radial.is_open():
			summon_radial(mb.position)
			get_viewport().set_input_as_handled()
