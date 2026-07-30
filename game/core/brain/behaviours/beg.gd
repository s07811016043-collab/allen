extends PetBehaviour

## Asking for food.
##
## The one behaviour allowed to be a nuisance, and even then only briefly. It
## promotes itself from NORMAL to URGENT as hunger gets real, which is how a
## hungry pet earns the right to interrupt a nap without begging outranking a
## greeting. It also needs an audience: a pet alone in an empty room does not
## perform, it just gets hungrier.

var _next_call := 0.0
var _paw := 0.0


func _init() -> void:
	id = &"beg"
	urgency = Urgency.NORMAL
	min_duration = 3.0
	max_duration = 20.0
	cooldown = 25.0
	commitment = 6.0
	commit_bonus = 0.4


func score(ctx: BrainContext) -> float:
	if not ctx.player_present:
		return 0.0
	var hungry: float = BrainUtility.pressure(ctx.deficit(&"food"))
	# Self-promotion: below a fifth of a stomach this stops being a suggestion.
	urgency = Urgency.URGENT if ctx.need(&"food") < 0.2 else Urgency.NORMAL
	# A bolder pet asks sooner; a shy one waits until it is properly hungry.
	var nerve: float = 0.6 + 0.6 * ctx.trait_of(&"affection_drive") \
		- 0.3 * ctx.trait_of(&"skittishness")
	return 1.25 * hungry * maxf(nerve, 0.15)


func on_enter(ctx: BrainContext) -> void:
	_next_call = 0.0
	_paw = 0.0
	ctx.set_pose(&"beg")


func update(ctx: BrainContext, delta: float) -> bool:
	if not ctx.player_present:
		return false
	ctx.look_at_point(ctx.cursor)

	# Get within arm's reach of the cursor and then perform at it.
	var reach: float = ctx.body_pixels() * 1.2
	if ctx.distance_to(ctx.cursor) > reach * 1.4:
		var side: float = signf(ctx.cursor.x - ctx.position.x)
		ctx.move_to(Vector2(ctx.cursor.x - side * reach, ctx.position.y), 1.4)
		ctx.set_pose(&"stand")
		ctx.set_face(0.9, 0.55, 0.7)
		return ctx.need(&"food") < 0.6

	ctx.stop()
	_paw += delta
	ctx.set_pose(&"beg")
	# Big eyes, raised brows, an insistent paw. Neoteny is a lever and this is
	# the behaviour that pulls it.
	ctx.set_face(0.95, 0.6 + 0.35 * sin(_paw * 5.0), 0.9, 0.0,
		0.35 + 0.25 * sin(_paw * 3.0), 1.0)

	if elapsed >= _next_call:
		var insistence: float = clampf(0.35 + ctx.deficit(&"food"), 0.0, 1.0)
		ctx.say(&"meow", insistence)
		# The hungrier it gets the less patience it has between asks.
		_next_call = elapsed + lerpf(4.5, 1.6, ctx.deficit(&"food")) \
			* ctx.rng.randf_range(0.8, 1.25)
	return ctx.need(&"food") < 0.6


func on_exit(ctx: BrainContext) -> void:
	ctx.set_pose(&"sit")
