class_name UITokens
extends RefCounted

## Design tokens — the one place a colour, a gap, a radius or a duration is
## decided. Every panel reads from here; nothing below `theme/` hardcodes a
## constant a designer would want to move.
##
## The constraint that shapes all of it: this UI does not own the pixels behind
## it. It floats over whatever wallpaper, terminal or spreadsheet the player
## happens to have open, so it cannot inherit contrast from a background it
## controls — it has to manufacture its own. Every surface token is therefore a
## *scrim*: opaque enough that the worst-case backdrop (pure white, pure black)
## still leaves body text far above the 4.5:1 floor once composited. Fashionable
## 40%-alpha "glass" fails that test the instant someone sets a photo wallpaper,
## which is why it is not on offer here.
##
## Two schemes exist not for taste but for placement: a pet that lives on a pale
## desktop wants a light chrome so it does not punch a black hole in the screen.

enum Scheme { DARK, LIGHT }

# --- Spacing -----------------------------------------------------------------
## A 4px grid. Everything is a multiple of it, so panels authored months apart
## still line up when they sit side by side on the same desktop.
const SPACE_XS := 4.0
const SPACE_SM := 8.0
const SPACE_MD := 12.0
const SPACE_LG := 18.0
const SPACE_XL := 26.0
const SPACE_XXL := 36.0

## Corner radii. Small controls take smaller radii than their container,
## otherwise nested rounding reads as sloppy rather than soft.
const RADIUS_SM := 7.0
const RADIUS_MD := 11.0
const RADIUS_LG := 16.0
const RADIUS_XL := 22.0

## Hairline width. Kept at 1.0 device pixel at every UI scale — a scaled-up
## border stops looking like an edge and starts looking like a frame.
const HAIRLINE := 1.0

# --- Motion ------------------------------------------------------------------
## Durations, in seconds. Anything the player triggered should resolve inside
## DUR_BASE; anything the app initiated (a toast) may take DUR_SLOW so it does
## not read as an alarm.
const DUR_INSTANT := 0.08
const DUR_FAST := 0.14
const DUR_BASE := 0.24
const DUR_SLOW := 0.40
const DUR_PANEL := 0.44

## Spring constants, expressed as (stiffness, damping ratio). Panels are
## slightly under-damped so they settle with one almost-imperceptible overshoot;
## anything the player is reading (a value, a label) is critically damped so it
## never wobbles under text.
const SPRING_SNAPPY := Vector2(420.0, 0.86)
const SPRING_SOFT := Vector2(180.0, 0.92)
const SPRING_READABLE := Vector2(260.0, 1.0)

# --- Elevation ---------------------------------------------------------------
## (blur px, y-offset px, alpha). Elevation is how the overlay separates from
## the desktop; without a real shadow a panel looks pasted on rather than
## floating above the wallpaper.
const ELEV_RESTING := Vector3(18.0, 6.0, 0.30)
const ELEV_FLOATING := Vector3(34.0, 12.0, 0.42)
const ELEV_LIFTED := Vector3(52.0, 20.0, 0.50)

## Current scheme and UI scale. Mirrored into statics by `refresh()` so the
## token accessors stay static and cheap — they are called from `_draw`, which
## runs for every widget every frame it changes.
static var scheme: Scheme = Scheme.DARK
static var scale: float = 1.0
static var reduced_motion: bool = false

static var _dark := {
	&"surface": Color(0.068, 0.064, 0.086, 0.90),
	&"surface_deep": Color(0.046, 0.043, 0.060, 0.94),
	&"raised": Color(1.0, 0.98, 1.0, 0.055),
	&"sunken": Color(0.0, 0.0, 0.02, 0.30),
	&"edge": Color(1.0, 0.98, 1.0, 0.11),
	&"edge_strong": Color(1.0, 0.98, 1.0, 0.22),
	&"sheen": Color(1.0, 0.99, 1.0, 0.16),
	&"shadow": Color(0.010, 0.006, 0.020, 1.0),
	&"text": Color(0.965, 0.958, 0.980),
	&"text_dim": Color(0.965, 0.958, 0.980, 0.68),
	&"text_faint": Color(0.965, 0.958, 0.980, 0.40),
	&"accent": Color(1.00, 0.702, 0.435),
	&"accent_dim": Color(1.00, 0.702, 0.435, 0.22),
	&"on_accent": Color(0.140, 0.086, 0.048),
	&"focus": Color(0.560, 0.820, 1.000),
	&"food": Color(0.965, 0.686, 0.353),
	&"play": Color(0.976, 0.549, 0.639),
	&"rest": Color(0.612, 0.663, 0.949),
	&"clean": Color(0.435, 0.831, 0.769),
	&"affection": Color(1.000, 0.612, 0.694),
	&"alert": Color(0.937, 0.412, 0.502),
	&"positive": Color(0.549, 0.878, 0.667),
}

static var _light := {
	&"surface": Color(0.988, 0.980, 0.972, 0.90),
	&"surface_deep": Color(0.965, 0.953, 0.945, 0.95),
	&"raised": Color(0.180, 0.110, 0.150, 0.050),
	&"sunken": Color(0.180, 0.110, 0.150, 0.105),
	&"edge": Color(0.180, 0.110, 0.150, 0.135),
	&"edge_strong": Color(0.180, 0.110, 0.150, 0.280),
	&"sheen": Color(1.0, 1.0, 1.0, 0.55),
	&"shadow": Color(0.180, 0.100, 0.070, 1.0),
	&"text": Color(0.126, 0.106, 0.145),
	&"text_dim": Color(0.126, 0.106, 0.145, 0.70),
	&"text_faint": Color(0.126, 0.106, 0.145, 0.45),
	&"accent": Color(0.839, 0.404, 0.180),
	&"accent_dim": Color(0.839, 0.404, 0.180, 0.16),
	&"on_accent": Color(1.0, 0.976, 0.960),
	&"focus": Color(0.129, 0.435, 0.780),
	&"food": Color(0.847, 0.510, 0.118),
	&"play": Color(0.855, 0.318, 0.443),
	&"rest": Color(0.365, 0.420, 0.792),
	&"clean": Color(0.086, 0.545, 0.494),
	&"affection": Color(0.878, 0.322, 0.435),
	&"alert": Color(0.804, 0.180, 0.290),
	&"positive": Color(0.184, 0.596, 0.365),
}


## Re-read anything the player can change. Called by `UIRoot` on start and on
## every `settings_changed`, so the static accessors never have to touch an
## autoload from a static context.
static func refresh(ui_scale: float, dark: bool, reduce: bool) -> void:
	scale = clampf(ui_scale, 0.75, 2.0)
	scheme = Scheme.DARK if dark else Scheme.LIGHT
	reduced_motion = reduce


static func col(role: StringName) -> Color:
	var table: Dictionary = _dark if scheme == Scheme.DARK else _light
	return table.get(role, Color.MAGENTA)


## Colour for a need id, so a need row never has to know its own hue.
static func need_col(need: StringName) -> Color:
	match need:
		&"food": return col(&"food")
		&"play": return col(&"play")
		&"rest": return col(&"rest")
		&"clean": return col(&"clean")
	return col(&"accent")


## A need's colour bent toward alarm as it empties. Colour carries the state so
## the player can read four meters in one glance without parsing four numbers,
## and the shift is gradual — a bar that flips to red at a threshold trains
## people to ignore everything above the threshold.
static func need_col_at(need: StringName, value: float) -> Color:
	var base := need_col(need)
	var worry: float = smoothstep(0.55, 0.12, clampf(value, 0.0, 1.0))
	return base.lerp(col(&"alert"), worry * 0.85)


## Scale a design-space length into device pixels.
static func s(px: float) -> float:
	return px * scale


## Shadow colour for an elevation level, already carrying its alpha.
static func shadow_for(elev: Vector3) -> Color:
	var c := col(&"shadow")
	c.a = elev.z
	return c
