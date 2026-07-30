class_name SquashStretch
extends RefCounted

## Volume-preserving body deformation for impacts, take-offs and startles.
##
## Squash and stretch is the oldest trick in character animation and it survives
## into a AAA context for a simple reason: it is how a viewer reads mass. A body
## that changes silhouette on contact has weight; one that keeps its proportions
## is a rigid prop being translated.
##
## The state is one scalar driven by an underdamped spring — deliberately
## underdamped, because the single overshoot after a landing (compress, rebound
## slightly past neutral, settle) is most of the effect. Critically damping this
## makes an impact feel like landing in mud.
##
## Volume is preserved exactly in 2D: the vertical factor is `s`, the horizontal
## is `1/s`. In an implicit body that matters more than usual — the capsule radii
## ride the same deformation, so a squashed creature genuinely bulges instead of
## just being drawn shorter.

const SUBSTEP := 1.0 / 240.0
const MAX_SUBSTEPS := 24

## +1 fully stretched, -1 fully squashed.
var value := 0.0
var velocity := 0.0
## Natural frequency squared. High enough that a landing resolves in ~0.25 s.
var stiffness := 190.0
## Under 1.0 on purpose: one visible rebound, then gone.
var damping := 0.42
## How far `value` is allowed to translate into actual scale.
var amplitude := 0.16
var _limit := 1.0


## Species with more give — a plump reptile, a fledgling — deform further.
func setup(spec: CreatureSpec) -> void:
	amplitude = lerpf(0.11, 0.20, spec.energy)
	stiffness = lerpf(150.0, 240.0, spec.energy)


## A foot hit the ground. Compresses the body, then rebounds.
func land(force: float) -> void:
	velocity -= clampf(force, 0.0, 2.0) * 5.2


## Push-off: the body extends before it leaves the ground.
func jump(force: float) -> void:
	velocity += clampf(force, 0.0, 2.0) * 6.4


## A startle is a fast tall-and-thin snap — the animal gathers upward before it
## has decided which way to run.
func startle(force: float) -> void:
	velocity += clampf(force, 0.0, 2.0) * 4.4
	value = maxf(value, clampf(force, 0.0, 1.0) * 0.45)


func settle() -> void:
	value = 0.0
	velocity = 0.0


func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	var steps: int = clampi(int(ceil(dt / SUBSTEP)), 1, MAX_SUBSTEPS)
	var h := dt / float(steps)
	var c := 2.0 * damping * sqrt(maxf(stiffness, 1e-4))
	for _s in steps:
		velocity += (-stiffness * value - c * velocity) * h
		value = clampf(value + velocity * h, -_limit, _limit)


## Scale to apply at the body root: tall and narrow when stretched, short and
## wide when squashed, with the product held at 1.
func scale_vector() -> Vector2:
	var s: float = 1.0 + clampf(value, -1.0, 1.0) * amplitude
	return Vector2(1.0 / s, s)
