class_name UIButton
extends UIWidget

## Pill button, in three ranks.
##
## Rank is the whole design: exactly one PRIMARY per panel, so the player never
## has to work out which of two filled buttons is the one they meant. GHOST
## carries destructive or dismissive actions, because a "delete my pet" button
## should require the player to look for it.

enum Rank {
	PRIMARY,  ## The one thing this panel is for. Filled with the accent.
	QUIET,    ## Secondary actions. A tinted surface, no accent.
	GHOST,    ## Dismiss, cancel, danger. Text and a hairline only.
}

@export var text: String = "":
	set(v):
		text = v
		queue_redraw()
@export var glyph: StringName = &"":
	set(v):
		glyph = v
		queue_redraw()
@export var rank: Rank = Rank.QUIET:
	set(v):
		rank = v
		queue_redraw()
## Danger recolours GHOST toward the alert hue without promoting it to a filled
## button; loud styling on a destructive action is how people delete things.
@export var danger: bool = false


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(UITokens.s(96.0), UITokens.s(38.0))


func focus_radius() -> float:
	return size.y * 0.5


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	# Press pulls the pill in by a pixel rather than scaling it: scaling a
	# rounded rect at this size visibly changes the corner, and the eye reads
	# that as the button wobbling instead of being pushed.
	var sink: float = press * UITokens.s(1.5)
	r = r.grow(-sink)

	var accent := UITokens.col(&"accent")
	var label_col := UITokens.col(&"text")

	match rank:
		Rank.PRIMARY:
			var fill := accent
			if disabled:
				fill = UITokens.col(&"raised")
			else:
				fill = fill.lightened(hover * 0.12).darkened(press * 0.10)
			# A shadow tinted by the button's own colour rather than by black,
			# stacked into a falloff. Coloured contact shadows are most of why a
			# filled control looks lit rather than stuck on.
			if not disabled:
				for i in 4:
					var t: float = float(i) / 3.0
					var halo := accent
					halo.a = 0.16 * (1.0 - t) * (0.45 + hover * 0.55)
					var spread: float = UITokens.s(2.0 + 6.0 * t) * (0.6 + hover * 0.4)
					UIDraw.capsule(self, Rect2(
						r.position + Vector2(0.0, UITokens.s(2.0)), r.size)
						.grow(spread), halo)
			UIDraw.capsule(self, r, fill)
			label_col = UITokens.col(&"on_accent")
			if disabled:
				label_col = UITokens.col(&"text_faint")
		Rank.QUIET:
			var base := UITokens.col(&"raised")
			base.a = base.a + hover * 0.06 + press * 0.04
			UIDraw.capsule(self, r, base)
			UIDraw.round_rect_outline(self, r, r.size.y * 0.5,
				UITokens.col(&"edge"), UITokens.HAIRLINE)
			if disabled:
				label_col = UITokens.col(&"text_faint")
		Rank.GHOST:
			if hover > 0.01 or press > 0.01:
				var wash := UITokens.col(&"raised")
				wash.a *= hover * 0.9 + press * 0.4
				UIDraw.capsule(self, r, wash)
			label_col = UITokens.col(&"alert") if danger else UITokens.col(&"text_dim")
			if hover > 0.01:
				label_col = label_col.lerp(UITokens.col(&"text"), hover * 0.5) \
					if not danger else label_col

	var gap: float = UITokens.s(UITokens.SPACE_SM)
	var gsize: float = UITokens.s(17.0)
	var tw: float = UIType.width(text, UIType.Role.LABEL, UIType.WEIGHT_SEMI)
	var total: float = tw + (gsize + gap if glyph != &"" else 0.0)
	var x: float = r.get_center().x - total * 0.5
	if glyph != &"":
		UIGlyphs.draw_glyph(self, glyph,
			Vector2(x + gsize * 0.5, r.get_center().y), gsize, label_col)
		x += gsize + gap
	var f := UIType.font(UIType.Role.LABEL, UIType.WEIGHT_SEMI)
	var px := UIType.px(UIType.Role.LABEL)
	draw_string(f, Vector2(x, r.get_center().y + f.get_ascent(px) * 0.5
		- f.get_descent(px) * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px,
		label_col)

	draw_focus()
