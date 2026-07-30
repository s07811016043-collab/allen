extends PetBehaviour

## Keeping the player company.
##
## The clearest signal a pet can send that it likes you. It scales with both
## `affection_drive` (species: a clingy dog vs an aloof cat) and earned
## affection, so early on the pet keeps its distance and after a week it is
## sitting on your cursor. Standoff distance is a function of trust for exactly
## that reason.

var _standoff := 90.0


func _init() -> void:
	id = &"follow_cursor"
	urgency = Urgency.NORMAL
	min_duration = 2.0
	max_duration = 26.0
	cooldown = 4.0
	commitment = 6.0
	commit_bonus = 0.35


func score(ctx: BrainContext) -> float:
	if not ctx.player_present:
		return 0.0
	var bond: float = 0.25 + 0.75 * ctx.affection()
	var drive: float = ctx.trait_of(&"affection_drive") * bond
	# Only worth crossing the room if the player is actually doing something.
	var active: float = BrainUtility.ramp(ctx.cursor_speed, 30.0, 300.0)
	active = maxf(active, BrainUtility.ramp(6.0 - ctx.cursor_idle, 0.0, 4.0) * 0.6)
	# ...and only if we are not already there.
	var far: float = BrainUtility.ramp(ctx.distance_to(ctx.cursor),
		ctx.body_pixels() * 0.8, ctx.body_pixels() * 3.5)
	# A jumpy animal near a fast cursor keeps away instead.
	var nerve: float = 1.0 - 0.7 * ctx.trait_of(&"skittishness") \
		* BrainUtility.ramp(ctx.cursor_speed, 900.0, 2400.0)
	return 0.85 * drive * active * far * maxf(nerve, 0.0) \
		* BrainUtility.ramp(ctx.need(&"rest"), 0.1, 0.4)


func on_enter(ctx: BrainContext) -> void:
	# Trust buys proximity: a pet that does not trust you keeps a body length
	# and a half between you, one that does will lean on the cursor.
	_standoff = ctx.body_pixels() * lerpf(1.5, 0.45, ctx.trust())
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, _delta: float) -> bool:
	if not ctx.player_present:
		return false
	var d: float = ctx.distance_to(ctx.cursor)
	ctx.look_at_point(ctx.cursor)
	ctx.set_face(0.75, lerpf(0.1, 0.75, ctx.affection()), 0.35)

	if d > _standoff * 1.25:
		var side: float = signf(ctx.cursor.x - ctx.position.x)
		ctx.move_to(Vector2(ctx.cursor.x - side * _standoff, ctx.position.y),
			1.0 + 0.7 * ctx.trait_of(&"affection_drive"))
		ctx.set_pose(&"stand")
		return true

	# Arrived. Sit and watch — and, if the bond is real, say something.
	ctx.stop()
	ctx.set_pose(&"sit")
	if elapsed > 3.0 and ctx.affection() > 0.5 and ctx.rng.randf() < 0.004:
		ctx.say(&"trill", 0.4)
	return d < ctx.body_pixels() * 4.0
