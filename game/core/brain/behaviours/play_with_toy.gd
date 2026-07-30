extends PetBehaviour

## Chasing something.
##
## The toy is usually the cursor. That is not a shortcut — a mouse pointer
## dragged across a screen is exactly the stimulus a laser pointer or a string
## provides, and a pet that stalks it is doing the real behaviour. A stalk has
## to have a shape: crouch, wiggle, freeze, pounce, miss, reset. A pet that
## simply walks at the cursor reads as a pathfinder, not a predator.

## Play restored per second of a bout, ~1700x its decay rate: fifteen seconds of
## proper play covers most of a day's boredom.
const PLAY_PER_SECOND := 0.02

## Cursor speeds that read as "being waved about" rather than "being used".
const WIGGLE_MIN := 260.0
const WIGGLE_MAX := 2200.0

var _toy := Vector2.ZERO
var _phase: StringName = &"stalk"
var _phase_t := 0.0
var _pounce_from := Vector2.ZERO
var _pounces := 0


func _init() -> void:
	id = &"play_with_toy"
	urgency = Urgency.NORMAL
	min_duration = 3.0
	max_duration = 24.0
	cooldown = 8.0
	commitment = 8.0
	commit_bonus = 0.5


func score(ctx: BrainContext) -> float:
	var bored: float = BrainUtility.pressure(ctx.deficit(&"play"))
	var fit: float = ctx.trait_of(&"energy") * BrainUtility.ramp(ctx.need(&"rest"), 0.15, 0.5)
	fit *= BrainUtility.ramp(ctx.need(&"food"), 0.12, 0.4)
	# The hour biases play but cannot veto it: a toy waved under a sleepy cat's
	# nose still gets batted at.
	var awake: float = 0.55 + 0.45 * BrainUtility.circadian(ctx.hour, ctx.spec)

	var lure := 0.0
	if ctx.toy_id != &"":
		lure = 1.1
	elif ctx.player_present:
		# A wiggled cursor is a toy. Too slow is a person working; too fast is
		# alarming rather than inviting.
		lure = BrainUtility.bell(ctx.cursor_speed, (WIGGLE_MIN + WIGGLE_MAX) * 0.5,
			(WIGGLE_MAX - WIGGLE_MIN) * 0.6)
		lure *= BrainUtility.ramp(ctx.body_pixels() * 6.0 - ctx.distance_to(ctx.cursor),
			0.0, ctx.body_pixels() * 2.0)
	if lure <= 0.02:
		return 0.0
	return (0.35 + 1.05 * bored) * fit * awake * lure


func on_enter(ctx: BrainContext) -> void:
	_toy = ctx.toy_position if ctx.toy_id != &"" else ctx.cursor
	_phase = &"stalk"
	_phase_t = 0.0
	_pounces = 0
	ctx.set_pose(&"crouch", _phase)


func update(ctx: BrainContext, delta: float) -> bool:
	_phase_t += delta
	_toy = ctx.toy_position if ctx.toy_id != &"" else ctx.cursor
	ctx.look_at_point(_toy)
	GameState.satisfy(ctx.record, &"play", PLAY_PER_SECOND * delta)
	GameState.satisfy(ctx.record, &"rest", -PLAY_PER_SECOND * 0.25 * delta)

	match _phase:
		&"stalk":
			# Close to just outside pouncing range, low to the ground.
			var reach: float = ctx.body_pixels() * 1.1
			var d: float = ctx.distance_to(_toy)
			ctx.set_pose(&"crouch", _phase)
			ctx.set_face(1.0, -0.4, 0.0, 0.55, 0.0, 1.0)
			if d > reach:
				var side: float = signf(_toy.x - ctx.position.x)
				ctx.move_to(Vector2(_toy.x - side * reach * 0.8, ctx.position.y), 1.3)
			else:
				ctx.stop()
				if _phase_t > ctx.rng.randf_range(0.5, 1.3):
					_phase = &"wiggle"
					_phase_t = 0.0
		&"wiggle":
			# The back-end wiggle before the launch. Pure charm, no mechanics.
			ctx.stop()
			ctx.set_pose(&"crouch", _phase)
			ctx.set_face(1.0, 0.9 * sin(_phase_t * 22.0), 0.0, 0.6)
			if _phase_t > 0.55:
				_phase = &"pounce"
				_phase_t = 0.0
				_pounce_from = ctx.position
		&"pounce":
			ctx.set_pose(&"pounce", _phase)
			ctx.set_face(1.0, 0.2, 0.3, 0.2, 0.4)
			ctx.move_to(Vector2(_toy.x, ctx.position.y), 3.0)
			if _phase_t > 0.45 or ctx.position.distance_to(Vector2(_toy.x, ctx.position.y)) < 12.0:
				_land(ctx)
				_phase = &"reset"
				_phase_t = 0.0
		_:
			ctx.stop()
			ctx.set_pose(&"sit", _phase)
			ctx.set_face(0.8, 0.5)
			if _phase_t > ctx.rng.randf_range(0.6, 1.6):
				_phase = &"stalk"
				_phase_t = 0.0

	# Play stops when the toy does. Give it a moment first, because a person
	# pausing to change grip is not a person who has stopped playing.
	if ctx.toy_id == &"" and ctx.cursor_idle > 3.5:
		return false
	return ctx.need(&"play") < 0.99


## Landing a pounce is the beat that pays for the whole sequence.
func _land(ctx: BrainContext) -> void:
	_pounces += 1
	var caught: bool = ctx.position.distance_to(Vector2(_toy.x, ctx.position.y)) < 26.0
	if not caught:
		return
	GameState.bump_stat(ctx.record, &"plays")
	GameState.unlock(ctx.record, &"first_play")
	# Playing with the *player* builds the bond; batting at a dust mote does not.
	if ctx.player_present:
		GameState.add_affection(ctx.record, 0.006, &"play")
		GameState.add_trust(ctx.record, 0.004)
		EventBus.pet_played_with.emit(ctx.record.id,
			ctx.toy_id if ctx.toy_id != &"" else &"cursor")
	ctx.say(&"chirp", 0.5)


func on_exit(ctx: BrainContext) -> void:
	if _pounces > 0:
		ctx.set_pose(&"sit")
