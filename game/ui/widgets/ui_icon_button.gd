class_name UIIconButton
extends UIWidget

## A round icon-only button: panel close, journal paging, "surprise me".
##
## Icon-only controls are a liability for accessibility, so every one of these
## carries a tooltip *and* an accessible name, and the hit area is padded out to
## 32px even when the glyph inside is 16. Fitts's law does not care that the
## drawing is small.

@export var glyph: StringName = &"close":
	set(v):
		glyph = v
		queue_redraw()
@export var glyph_size: float = 16.0
## Shown on hover and read by assistive tooling; never optional.
@export var label: String = "":
	set(v):
		label = v
		tooltip_text = v


func _ready() -> void:
	super._ready()
	custom_minimum_size = Vector2(UITokens.s(32.0), UITokens.s(32.0))
	size = custom_minimum_size


func focus_radius() -> float:
	return minf(size.x, size.y) * 0.5


func _draw() -> void:
	var c := size * 0.5
	var r: float = minf(size.x, size.y) * 0.5
	if hover > 0.01 or press > 0.01:
		var wash := UITokens.col(&"raised")
		wash.a = wash.a * (1.0 + hover * 2.4) + press * 0.05
		UIDraw.fill_path(self, UIDraw.circle_path(c, r * lerpf(0.88, 1.0, hover), 24),
			wash)
	var col := UITokens.col(&"text_dim").lerp(UITokens.col(&"text"), hover)
	if disabled:
		col = UITokens.col(&"text_faint")
	UIGlyphs.draw_glyph(self, glyph, c + Vector2(0.0, press * UITokens.s(0.8)),
		UITokens.s(glyph_size), col)
	draw_focus()
