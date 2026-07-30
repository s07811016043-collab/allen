extends PetBehaviour

## Doing nothing, on purpose.
##
## Idle is the floor of the utility function: it wins when nothing else wants to
## and it must never be the *reason* the pet looks dead. So it is not one pose,
## it is a small deck of them — sit, loaf, stand and look about, have a stretch —
## dealt by personality, with the odd glance at whatever the player is doing.

const POSES: Array[StringName] = [&"sit", &"loaf", &"stand", &"stretch"]

var _pose: StringName = &"sit"
var _next_glance := 0.0
var _glance_until := 0.0


func _init() -> void:
	id = &"idle"
	urgency = Urgency.AMBIENT
	min_duration = 1.4
	max_duration = 8.0
	commitment = 3.0
	commit_bonus = 0.22


func score(ctx: BrainContext) -> float:
	# Placid animals idle more, energetic ones less. The constant is low enough
	# that any real urge outranks it and high enough that the pet settles.
	return 0.15 + 0.10 * (1.0 - ctx.trait_of(&"energy"))


func on_enter(ctx: BrainContext) -> void:
	# A tired pet loafs, an alert one sits up, and a stretch is the reward for
	# having just got up from something.
	if ctx.need(&"rest") < 0.45:
		_pose = &"loaf"
	elif ctx.trait_of(&"energy") > 0.6 and ctx.rng.randf() < 0.4:
		_pose = &"stand"
	else:
		_pose = POSES[ctx.rng.randi_range(0, POSES.size() - 1)]
	_next_glance = ctx.rng.randf_range(0.6, 2.4)
	_glance_until = 0.0
	ctx.set_pose(_pose)


func update(ctx: BrainContext, _delta: float) -> bool:
	ctx.set_pose(_pose)
	ctx.stop()

	var alert: float = lerpf(0.25, 0.6, ctx.record.mood_arousal)
	var tail: float = lerpf(-0.1, 0.35, ctx.affection()) * (0.6 + 0.4 * sin(ctx.now * 0.7))
	ctx.set_face(alert, tail, 0.0, 0.0, 0.0, lerpf(0.6, 1.0, ctx.record.mood_arousal))

	# The glance is the whole trick: an animal that never looks at you is
	# furniture. Frequency scales with how much it likes you.
	if ctx.player_present and elapsed >= _next_glance:
		_glance_until = elapsed + ctx.rng.randf_range(0.6, 1.6)
		_next_glance = _glance_until + ctx.rng.randf_range(1.5, 4.5) \
			* (1.6 - ctx.trait_of(&"affection_drive"))
	if elapsed < _glance_until:
		ctx.look_at_point(ctx.cursor)
	return true
