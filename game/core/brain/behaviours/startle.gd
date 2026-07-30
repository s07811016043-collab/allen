extends PetBehaviour

## Jumping out of its skin.
##
## The only REFLEX in the deck, and the reason the interrupt model has tiers at
## all: a startle must be able to cut a nap, a groom, a pounce, or a greeting,
## instantly and mid-frame, because an animal that finishes its yawn before
## reacting to a slammed door is not an animal.
##
## It is short on purpose. The recovery — the freeze, the stare at whatever did
## it, the slow deflation — is where the character is, and it must not turn into
## a mood the pet is stuck in.

## Charge below this is not worth reacting to; above it, the reflex fires.
const TRIGGER := 0.32
## A charge this big overrides the cooldown, so a genuine fright is never eaten
## by the pet having already jumped once.
const OVERRIDE := 0.85

var _phase: StringName = &"flinch"
var _intensity := 0.5
var _from := Vector2.ZERO


func _init() -> void:
	id = &"startle"
	urgency = Urgency.REFLEX
	min_duration = 0.5
	max_duration = 2.4
	cooldown = 3.0
	# No commitment bonus: the recovery should give way the moment it is done.
	commitment = 0.0
	commit_bonus = 0.0


func available(ctx: BrainContext) -> bool:
	return ctx.startle_charge >= OVERRIDE or ctx.now >= ready_at


func score(ctx: BrainContext) -> float:
	if ctx.startle_charge < TRIGGER:
		return 0.0
	return 1.4 + ctx.startle_charge


func on_enter(ctx: BrainContext) -> void:
	_intensity = clampf(ctx.startle_charge, 0.0, 1.0)
	_phase = &"flinch"
	_from = ctx.cursor
	# Consuming the charge here is what stops the reflex re-triggering off its
	# own tail for as long as the cursor keeps moving.
	ctx.startle_charge = 0.0
	GameState.add_stress(ctx.record, 0.25 + 0.45 * _intensity)
	GameState.bump_stat(ctx.record, &"startles")
	EventBus.pet_startled.emit(ctx.record.id, _intensity)
	# The rig has its own recoil; firing it here keeps the physical jolt on the
	# same frame as the decision rather than a behaviour tick behind it.
	ctx.react(&"startle", 0.6 + 0.8 * _intensity)
	ctx.hear(_from, _intensity)
	if _intensity > 0.55:
		ctx.say(&"hiss" if ctx.trait_of(&"skittishness") > 0.5 else &"yelp", _intensity)


func update(ctx: BrainContext, _delta: float) -> bool:
	if elapsed < 0.22:
		# Recoil: away from whatever it was, low and fast.
		_phase = &"flinch"
		var away: float = -signf(_from.x - ctx.position.x)
		if away == 0.0:
			away = 1.0
		ctx.move_to(ctx.position + Vector2(away * ctx.body_pixels() * 0.9, 0.0),
			2.6 * _intensity + 0.6)
		ctx.set_pose(&"crouch", _phase)
		ctx.set_face(1.0, -1.0, 1.0, 0.0, 0.5 * _intensity, 1.0)
		return true

	# Freeze and stare at the source. Pupils wide, ears pinned, absolutely still.
	_phase = &"freeze" if elapsed < 0.9 + _intensity else &"recover"
	ctx.stop()
	ctx.look_at_point(_from)
	if _phase == &"freeze":
		ctx.set_pose(&"crouch", _phase)
		ctx.set_face(1.0, -0.8, 0.8, 0.2, 0.0, 1.0)
		return true

	var t: float = clampf((elapsed - (0.9 + _intensity)) / 0.8, 0.0, 1.0)
	ctx.set_pose(&"stand", _phase)
	ctx.set_face(lerpf(1.0, 0.6, t), lerpf(-0.8, -0.1, t), lerpf(0.8, 0.1, t))
	return t < 1.0
