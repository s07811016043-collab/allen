extends PetBehaviour

## Being cross with you.
##
## Fires after a touch the pet hated — a yanked tail, a belly it had not offered
## — or after being dropped. The pet stalks a short distance away, sits with its
## back to the cursor, and refuses to look at you.
##
## Two things stop this being a punishment mechanic, which would be miserable in
## a product about affection. It is short, and it ends with a glance back: the
## animal checks whether you are still there. That glance is the entire point of
## the behaviour, and it is why sulking makes the pet feel *more* attached
## rather than less.

var _spot := Vector2.ZERO
var _glance := false


func _init() -> void:
	id = &"sulk"
	urgency = Urgency.NORMAL
	min_duration = 4.0
	max_duration = 22.0
	cooldown = 60.0
	commitment = 10.0
	commit_bonus = 0.5


func score(ctx: BrainContext) -> float:
	if ctx.last_touch_valence >= -0.2:
		return 0.0
	# The grievance is freshest in the first few seconds and fades over half a
	# minute; how badly it stings scales with how much the pet minded.
	var fresh: float = BrainUtility.ramp(30.0 - ctx.seconds_since_touch(), 0.0, 12.0)
	var sting: float = clampf(-ctx.last_touch_valence, 0.0, 1.0)
	# A well-bonded pet forgives faster. It still makes the point.
	var grudge: float = 1.0 - 0.35 * ctx.affection()
	return 1.05 * fresh * sting * grudge


func on_enter(ctx: BrainContext) -> void:
	_glance = false
	var away: float = -signf(ctx.cursor.x - ctx.position.x)
	if away == 0.0:
		away = -1.0
	_spot = ctx.position + Vector2(away * ctx.body_pixels() * 2.4, 0.0)
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, _delta: float) -> bool:
	if ctx.position.distance_to(_spot) > 18.0 and elapsed < 4.0:
		ctx.move_to(_spot, 0.9)
		ctx.set_pose(&"stand")
		# Ears back, tail low and flicking: leaving in a huff, not fleeing.
		ctx.set_face(0.5, -0.55 + 0.25 * sin(ctx.now * 6.0), 0.0, 0.5)
		return true

	ctx.stop()
	ctx.set_pose(&"loaf")
	# Deliberately looking anywhere but at the cursor.
	var facing_away: Vector2 = ctx.position + Vector2(
		signf(ctx.position.x - ctx.cursor.x) * 200.0, -20.0)
	ctx.look_at_point(facing_away)
	ctx.set_face(0.35, -0.4 + 0.3 * sin(ctx.now * 4.5), 0.0, 0.45, 0.0, 0.7)

	# The look back. Everything above exists to set this up.
	if elapsed > max_duration - 2.5 or (elapsed > 6.0 and ctx.seconds_since_touch() > 25.0):
		_glance = true
	if _glance:
		ctx.look_at_point(ctx.cursor)
		ctx.set_face(0.55, -0.1, 0.35, 0.1, 0.0, 1.0)
		if elapsed > 7.0:
			return false
	return true


func on_exit(ctx: BrainContext) -> void:
	# Grievance discharged; the touch memory stops counting against the player
	# so the pet cannot sulk twice about the same thing.
	ctx.last_touch_valence = 0.0
	ctx.set_pose(&"sit")
