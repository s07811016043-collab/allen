class_name UIAdoptionPanel
extends UIPanel

## Adoption and naming.
##
## The first thirty seconds of the product. Two things have to happen in them:
## the player has to see what they are choosing between, and they have to type a
## name — because naming a thing is what turns it into a relationship. Everything
## else is deliberately absent. No colour pickers, no personality sliders, no
## tutorial. The one decision is *who*, and the one input is *what to call them*.
##
## The preview is live: it is the actual species spec at growth 0, breathing,
## with the real baby proportions. A row of static icons would let us ship a
## species whose baby looks wrong, and this screen is where that would be caught.

signal adopted(species: StringName, pet_name: String)

const PANEL_SIZE := Vector2(628.0, 486.0)
const CARD_W := 176.0
const CARD_H := 82.0
const SPECIES: Array[StringName] = [&"cat", &"dog", &"bird", &"reptile"]

## Names offered by the shuffle button. Short, soft, and none of them a joke —
## the player has to live with this on their desktop for weeks.
const SUGGESTIONS := {
	&"cat": ["Mochi", "Biscuit", "Juniper", "Pip", "Saffron", "Noodle"],
	&"dog": ["Rufus", "Barley", "Maple", "Otto", "Pepper", "Winnie"],
	&"bird": ["Kiwi", "Sprig", "Pomelo", "Wren", "Custard", "Ori"],
	&"reptile": ["Basil", "Ember", "Pebble", "Yuzu", "Cinder", "Fig"],
}

var _cards: Array[SpeciesCard] = []
var _preview: UISilhouette
var _name_field: LineEdit
var _shuffle: UIIconButton
var _confirm: UIButton
var _chosen: int = 0
var _suggest_at: int = 0


## One species option: a silhouette, a name, and a selected state that lifts.
class SpeciesCard extends UIWidget:
	var species: StringName = &"cat"
	var display: String = "Cat"
	var chosen: bool = false:
		set(v):
			chosen = v
			queue_redraw()
	var available: bool = true
	var art: UISilhouette
	var _lift := UIMotion.Spring.new(0.0, UITokens.SPRING_SNAPPY)

	func _ready() -> void:
		super._ready()
		art = UISilhouette.new()
		art.style = UISilhouette.Style.FLAT
		art.species = species
		art.growth = 0.0
		art.fill_ratio = 0.78
		art.contact_shadow = false
		add_child(art)

	func _process(delta: float) -> void:
		super._process(delta)
		_lift.target = 1.0 if chosen else 0.0
		var before := _lift.value
		_lift.step(delta)
		if absf(_lift.value - before) > 0.0005:
			queue_redraw()
		var s: float = UITokens.s(52.0)
		art.size = Vector2(s, s)
		art.position = Vector2(UITokens.s(10.0), (size.y - s) * 0.5)
		art.flat_color = UITokens.col(&"text").lerp(UITokens.col(&"accent"),
			clampf(_lift.value, 0.0, 1.0) * 0.85)
		if not available:
			art.flat_color = UITokens.col(&"text_faint")

	func focus_radius() -> float:
		return UITokens.s(UITokens.RADIUS_MD)

	func _draw() -> void:
		var lift: float = clampf(_lift.value, 0.0, 1.0)
		var r := Rect2(Vector2.ZERO, size)
		var rad := UITokens.s(UITokens.RADIUS_MD)

		var fill := UITokens.col(&"raised")
		fill.a = fill.a * (1.0 + hover * 1.6) + lift * 0.07
		UIDraw.round_rect(self, r, rad, fill)
		# Selection is carried by a border and a colour, never by a checkmark.
		# A tick in the corner of a card is a form control; this is a choice
		# about who to live with.
		var edge := UITokens.col(&"edge").lerp(UITokens.col(&"accent"), lift)
		edge.a = lerpf(edge.a, 1.0, lift * 0.8)
		UIDraw.round_rect_outline(self, r, rad, edge,
			UITokens.HAIRLINE * (1.0 + lift * 1.4))

		var x: float = UITokens.s(72.0)
		var col: Color = UITokens.col(&"text") if available \
			else UITokens.col(&"text_faint")
		UIDraw.text(self, Vector2(x, size.y * 0.5
			- UIType.line_height(UIType.Role.BODY) * 0.86), display,
			UIType.Role.BODY, col, UIType.WEIGHT_SEMI)
		var sub: String = "ready" if available else "coming soon"
		UIDraw.text(self, Vector2(x, size.y * 0.5 + UITokens.s(1.0)), sub,
			UIType.Role.MICRO, UITokens.col(&"text_faint"))
		draw_focus()


func _init() -> void:
	title = "Adopt a companion"
	subtitle = "Someone to live on your desktop."
	deep = true
	size = PANEL_SIZE * UITokens.scale


func _build() -> void:
	for i in SPECIES.size():
		var c := SpeciesCard.new()
		c.species = SPECIES[i]
		c.display = String(SPECIES[i]).capitalize()
		c.available = UISilhouette.has_species(SPECIES[i])
		c.chosen = i == 0
		add_child(c)
		_cards.append(c)
		var idx := i
		c.activated.connect(func() -> void: _choose(idx))

	_preview = UISilhouette.new()
	_preview.style = UISilhouette.Style.TINTED
	_preview.growth = 0.0
	_preview.bob_px = 7.0
	_preview.fill_ratio = 0.80
	add_child(_preview)

	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Name your friend"
	_name_field.max_length = 18
	_name_field.alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_name_field)
	_name_field.text_changed.connect(func(_s: String) -> void: _refresh_confirm())
	_name_field.text_submitted.connect(func(_s: String) -> void: _try_adopt())

	_shuffle = UIIconButton.new()
	_shuffle.glyph = &"sparkle"
	_shuffle.label = "Suggest a name"
	_shuffle.glyph_size = 15.0
	add_child(_shuffle)
	_shuffle.activated.connect(_suggest)

	_confirm = UIButton.new()
	_confirm.rank = UIButton.Rank.PRIMARY
	_confirm.text = "Bring them home"
	_confirm.glyph = &"heart"
	add_child(_confirm)
	_confirm.activated.connect(_try_adopt)

	_choose(0)


func _layout() -> void:
	super._layout()
	if _cards.is_empty():
		return
	var x := pad()
	var y := content_top()
	var cw := UITokens.s(CARD_W)
	var ch := UITokens.s(CARD_H)
	for i in _cards.size():
		_cards[i].position = Vector2(x, y + float(i) * (ch + UITokens.s(UITokens.SPACE_SM)))
		_cards[i].size = Vector2(cw, ch)

	var right_x: float = x + cw + UITokens.s(UITokens.SPACE_XL)
	var right_w: float = size.x - right_x - pad()
	var stage_h: float = UITokens.s(166.0)
	_preview.position = Vector2(right_x, y - UITokens.s(6.0))
	_preview.size = Vector2(right_w, stage_h)

	var field_h := UITokens.s(46.0)
	var shuffle_s := UITokens.s(32.0)
	var field_y: float = y + stage_h + UITokens.s(52.0)
	_name_field.position = Vector2(right_x, field_y)
	_name_field.size = Vector2(right_w - shuffle_s - UITokens.s(UITokens.SPACE_SM),
		field_h)
	_shuffle.position = Vector2(right_x + _name_field.size.x
		+ UITokens.s(UITokens.SPACE_SM), field_y + (field_h - shuffle_s) * 0.5)
	_shuffle.size = Vector2(shuffle_s, shuffle_s)

	_confirm.size = Vector2(right_w, UITokens.s(44.0))
	_confirm.position = Vector2(right_x, field_y + field_h + UITokens.s(UITokens.SPACE_LG))


func _choose(i: int) -> void:
	_chosen = clampi(i, 0, _cards.size() - 1)
	for j in _cards.size():
		_cards[j].chosen = j == _chosen
	_preview.species = SPECIES[_chosen]
	_preview.growth = 0.0
	_suggest_at = 0
	_refresh_confirm()
	queue_redraw()


func _suggest() -> void:
	var list: Array = SUGGESTIONS.get(SPECIES[_chosen], ["Pip"])
	_name_field.text = String(list[_suggest_at % list.size()])
	_suggest_at += 1
	_refresh_confirm()


func _refresh_confirm() -> void:
	var ok: bool = not _name_field.text.strip_edges().is_empty() \
		and _cards[_chosen].available
	_confirm.disabled = not ok
	queue_redraw()


func _try_adopt() -> void:
	var n := _name_field.text.strip_edges()
	if n.is_empty() or not _cards[_chosen].available:
		return
	adopted.emit(SPECIES[_chosen], n)
	close()


func _on_opened() -> void:
	_name_field.text = ""
	_refresh_confirm()
	# Focus goes to the name field, because the panel was opened by an explicit
	# player action and typing is the next thing they want to do. This is the one
	# place in the overlay where taking focus is right.
	_name_field.grab_focus()


func _draw_content() -> void:
	var cw := UITokens.s(CARD_W)
	var right_x: float = pad() + cw + UITokens.s(UITokens.SPACE_XL)
	var right_w: float = size.x - right_x - pad()

	# A well behind the preview, so the animal stands in a lit alcove instead of
	# floating in the middle of the panel.
	var stage := Rect2(right_x, content_top() - UITokens.s(6.0), right_w,
		UITokens.s(166.0))
	UIDraw.round_rect(self, stage, UITokens.s(UITokens.RADIUS_LG),
		UITokens.col(&"sunken"))
	UIDraw.round_rect_outline(self, stage, UITokens.s(UITokens.RADIUS_LG),
		UITokens.col(&"edge"), UITokens.HAIRLINE)

	var spec: Object = UISilhouette.spec_for(SPECIES[_chosen])
	var blurb := ""
	var display := String(SPECIES[_chosen]).capitalize()
	if spec != null:
		blurb = String(spec.get("blurb"))
		var dn := String(spec.get("display_name"))
		if not dn.is_empty():
			display = dn
	if blurb.is_empty():
		blurb = "Not yet written. This species is still being drawn."

	var by: float = stage.end.y + UITokens.s(10.0)
	UIDraw.text(self, Vector2(right_x, by), display, UIType.Role.HEAD,
		UITokens.col(&"text"))
	# The blurb is the species' personality in one sentence, straight from its
	# spec — the same text the journal shows, so a player never reads two
	# different descriptions of the same animal.
	UIDraw.text(self, Vector2(right_x, by + UIType.line_height(UIType.Role.HEAD)
		+ UITokens.s(2.0)), blurb, UIType.Role.MICRO,
		UITokens.col(&"text_dim"), -1.0, HORIZONTAL_ALIGNMENT_LEFT, right_w)

	UIDraw.eyebrow(self, Vector2(pad(), content_top() - UITokens.s(17.0)),
		"Choose", UITokens.col(&"text_faint"))
