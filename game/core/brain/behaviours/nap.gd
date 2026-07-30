extends PetBehaviour

## Sleeping.
##
## Naps are the longest thing the pet does and the easiest thing to get wrong.
## Two rules keep them from feeling like the app has frozen: they are AMBIENT,
## so *anything* — a startle, a greeting, a hand reaching in — cuts them short;
## and they have a visible arc (settle, curl, deep, stir) rather than being a
## static pose held for five minutes.
##
## Rest recovers at roughly sixty times its decay rate, so one minute of napping
## buys about an hour of being awake. That ratio is what makes a pet that sleeps
## most of the day still feel like it is keeping up with you.

## Rest restored per second of sleep. `GameState.NEED_DECAY.rest` is per hour.
const REST_PER_SECOND := 0.0006

var _phase: StringName = &"settle"
var _stir_at := 0.0
var _stir_until := 0.0


func _init() -> void:
	id = &"nap"
	urgency = Urgency.AMBIENT
	min_duration = 4.0
	max_duration = 420.0
	cooldown = 20.0
	# Sleep is sticky: once down, small utilities should not lift the pet again.
	commitment = 45.0
	commit_bonus = 0.7


func score(ctx: BrainContext) -> float:
	var tired: float = BrainUtility.pressure(ctx.deficit(&"rest"))
	var drowsy: float = 1.0 - BrainUtility.circadian(ctx.hour, ctx.spec)
	var calm: float = 1.0 - ctx.stress()
	# Hunger beats sleep; nothing sleeps well starving.
	var fed: float = BrainUtility.ramp(ctx.need(&"food"), 0.1, 0.4)
	var s: float = (0.95 * tired + 0.42 * drowsy) * calm * fed
	# Being near the person is a reason to sleep, not a reason not to — pets
	# sleep where they can see you, which is most of what makes them charming.
	if ctx.player_present and ctx.distance_to(ctx.cursor) < ctx.body_pixels() * 3.0:
		s += 0.12 * ctx.affection()
	return s


func on_enter(ctx: BrainContext) -> void:
	_phase = &"settle"
	_stir_at = ctx.rng.randf_range(30.0, 90.0)
	_stir_until = 0.0
	ctx.set_pose(&"loaf")
	GameState.bump_stat(ctx.record, &"naps")
	# Where a pet chooses to sleep is a story. The taskbar one is the story.
	if ctx.ledge_kind == &"taskbar":
		GameState.unlock(ctx.record, &"first_taskbar_nap")
	elif ctx.player_present and ctx.distance_to(ctx.cursor) < ctx.body_pixels() * 2.5:
		GameState.unlock(ctx.record, &"first_nap_nearby")


func update(ctx: BrainContext, delta: float) -> bool:
	ctx.stop()
	GameState.satisfy(ctx.record, &"rest", REST_PER_SECOND * delta)
	# Sleep is when stress actually goes away.
	ctx.record.stress = maxf(0.0, ctx.record.stress - 0.05 * delta)

	if elapsed < 2.5:
		_phase = &"settle"
		ctx.set_pose(&"loaf", _phase)
		ctx.set_face(0.2, -0.1, 0.0, 0.0, 0.0, 0.45)
	elif elapsed >= _stir_at:
		# Every minute or so the pet half-wakes, resettles, and goes under
		# again. Without it a long nap is indistinguishable from a crash.
		if _stir_until <= _stir_at:
			_stir_until = elapsed + ctx.rng.randf_range(1.4, 3.0)
			if ctx.rng.randf() < 0.3:
				ctx.say(&"sigh", 0.2)
		_phase = &"stir"
		ctx.set_pose(&"loaf", _phase)
		ctx.set_face(0.25, -0.2, 0.2, 0.0, 0.0, 0.35)
		if elapsed >= _stir_until:
			# Rested enough to stay up? Otherwise schedule the next stir.
			if ctx.need(&"rest") > 0.93:
				return false
			_stir_at = elapsed + ctx.rng.randf_range(30.0, 80.0)
			_stir_until = 0.0
	else:
		_phase = &"curl"
		ctx.set_pose(&"curl", _phase)
		# Breathing is the only thing moving; the rig reads it off eye_open and
		# the pose, so keep the numbers steady and let it do the work.
		ctx.set_face(0.05, -0.6, 0.0, 0.0, 0.0, 0.02)
	return ctx.need(&"rest") < 0.995


func on_exit(ctx: BrainContext) -> void:
	# Waking up properly — the stretch — is worth as much as the sleep.
	if _phase != &"settle":
		ctx.set_pose(&"stretch")
