class_name UITheme
extends RefCounted

## Builds the one `Theme` resource the whole overlay runs on.
##
## Most of Petalia's interface is custom-drawn, but the moment a `Label`, a
## `LineEdit` or a scrollbar appears it inherits Godot's defaults, and Godot's
## defaults are a different design language. Assembling a theme from the same
## tokens as the drawn widgets is what keeps a text field from looking like it
## was borrowed from another application.
##
## Rebuilt rather than cached across scheme changes: the player toggles light
## and dark roughly never, and a stale style box is a bug that only shows up on
## someone else's desktop.

static func build() -> Theme:
	var t := Theme.new()
	t.default_font = UIType.font(UIType.Role.BODY)
	t.default_font_size = UIType.px(UIType.Role.BODY)

	_style_label(t)
	_style_line_edit(t)
	_style_scroll(t)
	_style_panel(t)
	_style_tooltip(t)
	return t


## A flat surface box in a token colour. `inset` pulls the box in from the
## control's rect, which is how the focus ring gets room without every caller
## adding padding.
static func box(color: Color, radius: float, border: Color = Color(0, 0, 0, 0),
		border_w: float = 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(int(round(UITokens.s(radius))))
	# Godot's rounded boxes are visibly faceted without this, and a faceted
	# corner next to a shader-drawn one is worse than no rounding at all.
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 1.0
	if border_w > 0.0:
		sb.set_border_width_all(int(round(UITokens.s(border_w))))
		sb.border_color = border
		sb.border_blend = false
	sb.content_margin_left = UITokens.s(UITokens.SPACE_MD)
	sb.content_margin_right = UITokens.s(UITokens.SPACE_MD)
	sb.content_margin_top = UITokens.s(UITokens.SPACE_SM)
	sb.content_margin_bottom = UITokens.s(UITokens.SPACE_SM)
	return sb


static func empty_box() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


static func _style_label(t: Theme) -> void:
	t.set_type_variation(&"Dim", &"Label")
	t.set_color(&"font_color", &"Label", UITokens.col(&"text"))
	t.set_color(&"font_color", &"Dim", UITokens.col(&"text_dim"))
	t.set_constant(&"line_spacing", &"Label", int(UITokens.s(4.0)))
	# No outline. An outlined label is how a HUD survives an arbitrary
	# background; a panel that has already guaranteed its own contrast does not
	# need one, and outlines at 12px turn text to mud.
	t.set_constant(&"outline_size", &"Label", 0)


static func _style_line_edit(t: Theme) -> void:
	var normal := box(UITokens.col(&"sunken"), UITokens.RADIUS_MD,
		UITokens.col(&"edge"), 1.0)
	var focused := box(UITokens.col(&"sunken"), UITokens.RADIUS_MD,
		UITokens.col(&"focus"), 2.0)
	normal.content_margin_left = UITokens.s(UITokens.SPACE_LG)
	normal.content_margin_right = UITokens.s(UITokens.SPACE_LG)
	normal.content_margin_top = UITokens.s(UITokens.SPACE_MD)
	normal.content_margin_bottom = UITokens.s(UITokens.SPACE_MD)
	focused.content_margin_left = normal.content_margin_left
	focused.content_margin_right = normal.content_margin_right
	focused.content_margin_top = normal.content_margin_top
	focused.content_margin_bottom = normal.content_margin_bottom

	t.set_stylebox(&"normal", &"LineEdit", normal)
	t.set_stylebox(&"focus", &"LineEdit", focused)
	t.set_stylebox(&"read_only", &"LineEdit", normal)
	t.set_font(&"font", &"LineEdit", UIType.font(UIType.Role.TITLE))
	t.set_font_size(&"font_size", &"LineEdit", UIType.px(UIType.Role.TITLE))
	t.set_color(&"font_color", &"LineEdit", UITokens.col(&"text"))
	t.set_color(&"font_placeholder_color", &"LineEdit", UITokens.col(&"text_faint"))
	t.set_color(&"caret_color", &"LineEdit", UITokens.col(&"accent"))
	var sel := UITokens.col(&"accent")
	sel.a = 0.30
	t.set_color(&"selection_color", &"LineEdit", sel)


static func _style_scroll(t: Theme) -> void:
	for cls in [&"VScrollBar", &"HScrollBar"]:
		t.set_stylebox(&"scroll", cls, box(UITokens.col(&"sunken"), 4.0))
		var grab := box(UITokens.col(&"edge_strong"), 4.0)
		t.set_stylebox(&"grabber", cls, grab)
		t.set_stylebox(&"grabber_highlight", cls,
			box(UITokens.col(&"accent"), 4.0))
		t.set_stylebox(&"grabber_pressed", cls,
			box(UITokens.col(&"accent"), 4.0))
	t.set_stylebox(&"panel", &"ScrollContainer", empty_box())


static func _style_panel(t: Theme) -> void:
	# Plain `Panel` is only used for internal grouping; the real panel surface
	# is `UIScrim`, which is a shader, not a style box.
	t.set_stylebox(&"panel", &"Panel", box(UITokens.col(&"raised"),
		UITokens.RADIUS_MD))
	t.set_stylebox(&"panel", &"PanelContainer", box(UITokens.col(&"raised"),
		UITokens.RADIUS_MD))


static func _style_tooltip(t: Theme) -> void:
	t.set_stylebox(&"panel", &"TooltipPanel", box(UITokens.col(&"surface_deep"),
		UITokens.RADIUS_SM, UITokens.col(&"edge"), 1.0))
	t.set_color(&"font_color", &"TooltipLabel", UITokens.col(&"text"))
	t.set_font_size(&"font_size", &"TooltipLabel", UIType.px(UIType.Role.LABEL))
