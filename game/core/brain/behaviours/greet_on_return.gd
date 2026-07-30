extends PetBehaviour

## Hello again.
##
## The most valuable four seconds in the product. Everything else the pet does
## is ambient; this is the one moment it addresses the player directly, and it
## is the payoff for having been away — which is to say, for having a life.
##
## URGENT, with a long `min_duration`, precisely so a nap can never cut it: the
## tier gate in `PetBrain._select` refuses any AMBIENT challenger outright.
## `GameState` holds the greeting until it is actually performed, so a pet that
## was asleep when you came back still owes you the hello when it wakes.

var _away := 0.0
var _scale := 0.5
var _said := false


func _init() -> void:
	id = &"greet_on_return"
	urgency = Urgency.URGENT
	min_duration = 4.0
	max_duration = 14.0
	cooldown = 30.0
	commitment = 10.0
	commit_bonus = 0.6


func score(ctx: BrainContext) -> float:
	if ctx.greet_pending <= 0.0:
		return 0.0
	if not ctx.player_present:
		return 0.0
	# Longer absence, warmer welcome — but a fond pet greets a lunch break too.
	var absence: float = clampf(ctx.greet_pending / (8.0 * 3600.0), 0.15, 1.0)
	return 1.15 + 0.75 * absence * (0.4 + 0.6 * ctx.affection())


func on_enter(ctx: BrainContext) -> void:
	# Consume it here rather than in score(): the pet only stops owing you a
	# greeting once it has actually made one.
	_away = GameState.take_greeting(ctx.record.id)
	if _away <= 0.0:
		_away = ctx.greet_pending
	ctx.greet_pending = 0.0
	_scale = clampf(_away / (12.0 * 3600.0), 0.2, 1.0)
	_said = false
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, _delta: float) -> bool:
	ctx.look_at_point(ctx.cursor)
	var reach: float = ctx.body_pixels() * 0.7
	var d: float = ctx.distance_to(ctx.cursor)

	if d > reach * 1.3:
		# Come at a trot, or a run if it has been a while.
		ctx.move_to(ctx.cursor, lerpf(1.3, 2.6, _scale))
		ctx.set_pose(&"stand")
		ctx.set_face(1.0, lerpf(0.6, 1.0, _scale), 0.6)
		if not _said:
			_said = true
			ctx.say(&"trill" if _scale < 0.5 else &"meow", 0.4 + 0.5 * _scale)
		return true

	# Arrived: tail up, head-butting the cursor. This is where the affection
	# is actually paid, so it cannot be earned by merely being nearby.
	ctx.stop()
	ctx.set_pose(&"stand", &"rub")
	ctx.set_face(1.0, 1.0, 0.5, 0.0, 0.25 + 0.15 * sin(ctx.now * 6.0))
	if elapsed > 2.5 and _away > 0.0:
		GameState.greeted(ctx.record, _away)
		ctx.say(&"purr", 0.55)
		_away = 0.0
	return elapsed < 6.0


func on_exit(ctx: BrainContext) -> void:
	# If the greeting was cut short by something REFLEX, pay it anyway — the
	# player came back, and the pet noticing is not conditional on a clean run.
	if _away > 0.0:
		GameState.greeted(ctx.record, _away)
		_away = 0.0
	ctx.set_pose(&"sit")
