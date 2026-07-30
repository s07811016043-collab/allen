class_name UIType
extends RefCounted

## The type scale.
##
## Petalia ships no font files, so every weight and every bit of tracking comes
## from `FontVariation` on top of Godot's built-in face. That is not a
## compromise — synthetic embolden plus per-glyph spacing is exactly the two
## axes a UI type scale actually needs, and doing it here means a heading can
## never drift from a heading somewhere else.
##
## Two rules the scale encodes:
##   * Small text needs *more* tracking, large text needs less. Below ~12px the
##     built-in face runs tight enough that letters merge at a glance; above
##     ~20px default tracking looks loose and amateur.
##   * Weight, not size, is what makes a label read as secondary. A 13px dim
##     label beside a 13px bright one is a cleaner hierarchy than 13 vs 11.

enum Role {
	DISPLAY,  ## Numbers you want the player to feel proud of. Journal stats.
	TITLE,    ## Panel titles, pet name.
	HEAD,     ## Section headings inside a panel.
	BODY,     ## Running text, blurbs, milestone descriptions.
	LABEL,    ## Control labels, need names.
	MICRO,    ## Timestamps, units, hints. Always paired with `text_dim`.
}

const WEIGHT_REGULAR := 0.0
const WEIGHT_MEDIUM := 0.22
const WEIGHT_SEMI := 0.42
const WEIGHT_BOLD := 0.68

static var _cache := {}


## Base size in design pixels for a role, before UI scale.
static func size_of(role: Role) -> int:
	match role:
		Role.DISPLAY: return 30
		Role.TITLE: return 20
		Role.HEAD: return 14
		Role.BODY: return 13
		Role.LABEL: return 12
		Role.MICRO: return 10
	return 13


## Scaled size, which is what actually goes to `draw_string`.
static func px(role: Role) -> int:
	return int(round(float(size_of(role)) * UITokens.scale))


## Default tracking for a role, in device pixels.
static func tracking_of(role: Role) -> float:
	match role:
		Role.DISPLAY: return -1.0
		Role.TITLE: return -0.5
		Role.HEAD: return 0.0
		Role.BODY: return 0.0
		Role.LABEL: return 0.4
		Role.MICRO: return 0.9
	return 0.0


## The font for a role. `weight` overrides the role's default so a single call
## site can promote a label to semibold without inventing a new role.
static func font(role: Role, weight: float = -1.0) -> Font:
	var w: float = weight
	if w < 0.0:
		w = _default_weight(role)
	return variation(w, tracking_of(role))


static func _default_weight(role: Role) -> float:
	match role:
		Role.DISPLAY: return WEIGHT_SEMI
		Role.TITLE: return WEIGHT_SEMI
		Role.HEAD: return WEIGHT_SEMI
		Role.MICRO: return WEIGHT_MEDIUM
	return WEIGHT_REGULAR


## Cached because a `FontVariation` re-shapes its base face on creation, and a
## radial menu that built one per frame would stutter on a low-end laptop.
static func variation(weight: float, tracking: float) -> Font:
	var key := "%.2f|%.2f" % [weight, tracking]
	var hit: Variant = _cache.get(key)
	if hit != null:
		return hit
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	fv.variation_embolden = weight
	# `spacing_glyph` is an integer advance nudge, so fractional tracking has to
	# round; the scale above is authored in whole pixels for that reason.
	fv.spacing_glyph = int(round(tracking))
	_cache[key] = fv
	return fv


## Measured width of `text` in a role, for laying out around a string without
## instantiating a Label.
static func width(text: String, role: Role, weight: float = -1.0) -> float:
	var f := font(role, weight)
	return f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, px(role)).x


## Baseline offset from the top of a line box, so `draw_string` calls can be
## positioned by their box rather than by their baseline.
static func ascent(role: Role) -> float:
	return font(role).get_ascent(px(role))


static func line_height(role: Role) -> float:
	var f := font(role)
	var s := px(role)
	return f.get_ascent(s) + f.get_descent(s)
