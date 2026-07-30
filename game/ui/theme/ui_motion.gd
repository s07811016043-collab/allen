class_name UIMotion
extends RefCounted

## Motion primitives.
##
## Nothing in this UI is on screen for long — a radial menu lives for two
## seconds, a toast for four — so motion is not decoration, it is the only
## chance the interface gets to explain where a thing came from and where it
## went. Tweens are the wrong tool for most of it: the player can re-open a menu
## mid-close, and a spring handles that by simply retargeting, where a tween has
## to be killed and restarted from a discontinuous position.
##
## Every animated path here checks `UITokens.reduced_motion`. Respecting it is
## not a matter of shortening durations: for a player who gets motion sickness,
## a fast spring is worse than none, so reduced motion snaps to the target and
## carries the same information with opacity instead.


## A single scalar under a damped harmonic spring.
##
## Semi-implicit Euler is stable enough at UI stiffnesses and is two lines; the
## substepping matters more than the integrator, because a dropped frame on a
## busy desktop would otherwise let a stiff spring explode.
class Spring:
	var value: float = 0.0
	var velocity: float = 0.0
	var target: float = 0.0
	var stiffness: float = 420.0
	var damping_ratio: float = 0.86

	func _init(initial: float = 0.0, params: Vector2 = UITokens.SPRING_SNAPPY) -> void:
		value = initial
		target = initial
		stiffness = params.x
		damping_ratio = params.y

	func configure(params: Vector2) -> void:
		stiffness = params.x
		damping_ratio = params.y

	## Jump to a value with no motion — used on open, so a panel does not
	## animate in from wherever it happened to be left last time.
	func reset(to: float) -> void:
		value = to
		target = to
		velocity = 0.0

	func step(delta: float) -> float:
		if UITokens.reduced_motion:
			value = target
			velocity = 0.0
			return value
		var damping: float = 2.0 * damping_ratio * sqrt(stiffness)
		# Cap the step so alt-tabbing back to the app does not integrate a
		# half-second gap in one go and fling everything off screen.
		var remaining: float = minf(delta, 0.1)
		while remaining > 0.0:
			var h: float = minf(remaining, 1.0 / 120.0)
			remaining -= h
			var accel: float = (target - value) * stiffness - velocity * damping
			velocity += accel * h
			value += velocity * h
		return value

	func is_settled(epsilon: float = 0.002) -> bool:
		return absf(value - target) < epsilon and absf(velocity) < epsilon * 60.0


## Two springs sharing parameters, for positions.
class Spring2:
	var x: Spring
	var y: Spring

	func _init(initial: Vector2 = Vector2.ZERO, params: Vector2 = UITokens.SPRING_SNAPPY) -> void:
		x = Spring.new(initial.x, params)
		y = Spring.new(initial.y, params)

	func set_target(t: Vector2) -> void:
		x.target = t.x
		y.target = t.y

	func reset(to: Vector2) -> void:
		x.reset(to.x)
		y.reset(to.y)

	func step(delta: float) -> Vector2:
		return Vector2(x.step(delta), y.step(delta))

	func value() -> Vector2:
		return Vector2(x.value, y.value)


# --- Easing ------------------------------------------------------------------
# Authored rather than pulled from `Tween.EASE_*` so the same curve is available
# inside `_draw`, where there is no tween to ask.

static func ease_out_cubic(t: float) -> float:
	var u: float = 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


static func ease_in_out(t: float) -> float:
	var u: float = clampf(t, 0.0, 1.0)
	return u * u * (3.0 - 2.0 * u)


## Overshoots once. Reserved for things the player just did — never for state
## that changed on its own, which should not draw the eye.
static func ease_out_back(t: float, amount: float = 1.32) -> float:
	var u: float = clampf(t, 0.0, 1.0) - 1.0
	return 1.0 + (amount + 1.0) * u * u * u + amount * u * u


## Frame-rate independent exponential approach. The workhorse for values that
## only ever need to catch up (a hover glow, a bar fill), where a spring's
## overshoot would be noise.
static func approach(current: float, goal: float, rate: float, delta: float) -> float:
	if UITokens.reduced_motion:
		return goal
	return lerpf(current, goal, 1.0 - exp(-rate * delta))


static func approach_color(current: Color, goal: Color, rate: float, delta: float) -> Color:
	if UITokens.reduced_motion:
		return goal
	return current.lerp(goal, 1.0 - exp(-rate * delta))


## Stagger offset for the nth element of a group. Deliberately sub-linear: with
## seven radial items a linear stagger makes the last one feel broken, while a
## square root keeps the whole group inside one perceptual beat.
static func stagger(index: int, count: int, span: float = 0.11) -> float:
	if count <= 1 or UITokens.reduced_motion:
		return 0.0
	return span * sqrt(float(index) / float(count - 1))


## A slow, low-amplitude breath. Used for "alive" states (a critical need, a
## happy pet) where a hard blink would read as an error dialog.
static func breathe(time: float, period: float = 2.4) -> float:
	if UITokens.reduced_motion:
		return 0.0
	return 0.5 - 0.5 * cos(TAU * time / period)
