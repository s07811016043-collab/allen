extends PetBehaviour

## Washing.
##
## Two reasons a pet grooms, and the second is the interesting one. The first is
## that the `clean` need has sagged. The second is that you just touched it —
## animals groom the spot a hand has been, and doing that a beat after a stroke
## is one of the strongest "it noticed me" signals available for free.
##
## Grooming is also a displacement behaviour: a mildly stressed animal that has
## nothing to run from will wash instead. That falls out of the scoring below
## without needing a special case.

## Clean restored per second of grooming: a twelve-second wash undoes most of a
## day's grime, which is what keeps this a bout and not a background process.
const CLEAN_PER_SECOND := 0.012

const SPOTS: Array[StringName] = [&"paw", &"flank", &"chest", &"tail", &"ear"]

var _spot: StringName = &"paw"
var _next_spot := 0.0


func _init() -> void:
	id = &"groom"
	urgency = Urgency.AMBIENT
	min_duration = 3.0
	max_duration = 16.0
	cooldown = 30.0
	commitment = 6.0
	commit_bonus = 0.4


func score(ctx: BrainContext) -> float:
	var dirty: float = BrainUtility.pressure(ctx.deficit(&"clean"))
	# The post-touch wash: strongest in the twenty seconds after a good touch,
	# and it fades rather than switching off.
	var touched: float = 0.0
	if ctx.last_touch_valence > 0.1:
		touched = 0.55 * BrainUtility.ramp(20.0 - ctx.seconds_since_touch(), 0.0, 8.0)
	# Displacement: a bit wound up, nothing to do about it.
	var fret: float = 0.35 * ctx.stress() * BrainUtility.ramp(0.6 - ctx.startle_charge, 0.0, 0.4)
	var awake: float = BrainUtility.ramp(ctx.need(&"rest"), 0.05, 0.35)
	return (0.85 * dirty + touched + fret) * awake


func on_enter(ctx: BrainContext) -> void:
	_spot = _pick_spot(ctx)
	_next_spot = ctx.rng.randf_range(2.5, 5.0)
	ctx.set_pose(&"groom", _spot)


func update(ctx: BrainContext, delta: float) -> bool:
	ctx.stop()
	ctx.set_pose(&"groom", _spot)
	GameState.satisfy(ctx.record, &"clean", CLEAN_PER_SECOND * delta)
	ctx.record.stress = maxf(0.0, ctx.record.stress - 0.02 * delta)
	# Head down, eyes half shut, tail still: the posture is most of the read.
	ctx.set_face(0.3, -0.15, 0.0, 0.1, 0.35, 0.35)

	if elapsed >= _next_spot:
		_spot = _pick_spot(ctx)
		_next_spot = elapsed + ctx.rng.randf_range(2.5, 5.0)
	if ctx.need(&"clean") > 0.985:
		GameState.bump_stat(ctx.record, &"grooms")
		return false
	return true


func on_exit(ctx: BrainContext) -> void:
	GameState.bump_stat(ctx.record, &"grooms")
	ctx.set_pose(&"sit")


## The spot the rig should aim the head at. Right after a touch it is whichever
## region the hand was on, which is the whole point.
func _pick_spot(ctx: BrainContext) -> StringName:
	if ctx.seconds_since_touch() < 20.0 and ctx.last_touch_region != &"":
		return ctx.last_touch_region
	return SPOTS[ctx.rng.randi_range(0, SPOTS.size() - 1)]
