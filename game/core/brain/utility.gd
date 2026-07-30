class_name BrainUtility
extends RefCounted

## Scoring primitives shared by every behaviour.
##
## Utility AI lives or dies on the shape of its curves. A need that rises
## linearly produces a pet that fidgets between eating and playing at 50%
## satisfaction; a need that stays quiet and then climbs steeply produces one
## that gets on with its life and then decisively goes to the bowl. These are
## the handful of shapes that turned out to be worth naming.

## Autoload scripts are preloaded rather than referenced through the singleton
## name because a singleton is a node, not a type: `DesktopBridge.Ledge` only
## resolves as an annotation through the script resource.
const DB := preload("res://autoload/desktop_bridge.gd")


## Smooth 0 → 1 ramp. `lo` may be greater than `hi` for a falling ramp.
static func ramp(x: float, lo: float, hi: float) -> float:
	if is_equal_approx(lo, hi):
		return 1.0 if x >= hi else 0.0
	return clampf(smoothstep(lo, hi, x), 0.0, 1.0)


## Bell centred on `centre`, reaching ~0 at `centre ± width`.
static func bell(x: float, centre: float, width: float) -> float:
	var t: float = clampf(absf(x - centre) / maxf(width, 0.0001), 0.0, 1.0)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## Bell over a 24-hour clock, wrapping across midnight. Everything circadian —
## naps, dawn zoomies, the 3am parkour — is expressed with this.
static func hour_bell(hour: float, centre: float, width: float) -> float:
	var d: float = absf(fposmod(hour - centre + 12.0, 24.0) - 12.0)
	var t: float = clampf(d / maxf(width, 0.0001), 0.0, 1.0)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## Turn a need deficit into an urge. Deliberately flat until the need is
## genuinely low, then steep: this is what stops the pet flip-flopping between
## three half-met needs.
static func pressure(deficit: float) -> float:
	var d: float = clampf(deficit, 0.0, 1.0)
	return d * d * (0.35 + 0.65 * d)


## Exponential approach that is frame-rate independent. `rate` is roughly how
## many e-folds happen per second.
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerpf(current, target, 1.0 - exp(-maxf(rate, 0.0) * delta))


## Decay a charge toward zero with a given half-life in seconds.
static func decay(value: float, halflife: float, delta: float) -> float:
	if halflife <= 0.0:
		return 0.0
	return value * pow(0.5, delta / halflife)


## How awake this species should be at this hour, in [0, 1].
##
## Derived from the spec rather than from a new authored field: a climber that
## walks on four legs is a cat and is crepuscular, a flier is diurnal and
## switches off hard at dusk, a sprawler basks at noon. Getting this right is a
## surprising amount of what makes a pet feel like an animal rather than a
## screensaver — the cat that goes mad at 6am is a real cat.
static func circadian(hour: float, spec: CreatureSpec) -> float:
	if spec == null:
		return 0.7
	if spec.can_fly:
		# Birds: up at dawn, asleep the moment it is properly dark.
		return clampf(0.12 + 0.95 * hour_bell(hour, 9.5, 7.0), 0.0, 1.0)
	if spec.locomotion == CreatureSpec.Locomotion.SPRAWLING:
		# Reptiles follow the warmth, not the light.
		return clampf(0.10 + 0.9 * hour_bell(hour, 13.5, 6.5), 0.0, 1.0)
	if spec.can_climb:
		# Crepuscular: two peaks, and never fully off at night.
		return clampf(0.28 + 0.72 * maxf(hour_bell(hour, 6.5, 3.4),
			hour_bell(hour, 20.0, 4.0)), 0.0, 1.0)
	# Dogs and the rest: awake with the household.
	return clampf(0.20 + 0.85 * hour_bell(hour, 13.0, 8.5), 0.0, 1.0)


## Random point on a ledge's walkable top, inset from the ends so the pet does
## not stand with half a paw in the void.
static func point_on_ledge(ledge: DB.Ledge, t: float) -> Vector2:
	var span: Vector2 = ledge.walk_span()
	var inset: float = minf(14.0, ledge.rect.size.x * 0.3)
	return Vector2(lerpf(span.x + inset, span.y - inset, clampf(t, 0.0, 1.0)),
		ledge.top_y())
