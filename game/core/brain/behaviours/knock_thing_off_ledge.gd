extends PetBehaviour

## Pushing something off the edge while maintaining eye contact.
##
## The single most requested cat behaviour there is, and it only works if three
## things are true: there is an audience, the pet looks at *you* rather than at
## the thing, and it does not happen often enough to become a tic. Hence the
## audience check, the deliberate gaze, and the two-minute cooldown.
##
## It is scored as mischief rather than as a need: bored, energetic, curious and
## awake. A tired or hungry animal does not do this.

const DB := preload("res://autoload/desktop_bridge.gd")

var _ledge: int = -1
var _edge := Vector2.ZERO
var _phase: StringName = &"approach"
var _phase_t := 0.0
var _taps := 0


func _init() -> void:
	id = &"knock_thing_off_ledge"
	urgency = Urgency.NORMAL
	min_duration = 3.0
	max_duration = 20.0
	# A treat, not a habit.
	cooldown = 120.0
	commitment = 9.0
	commit_bonus = 0.55


func score(ctx: BrainContext) -> float:
	if ctx.mischief_ledge < 0:
		return 0.0
	# No audience, no performance.
	if not ctx.player_present:
		return 0.0
	var mischief: float = 0.40 * ctx.trait_of(&"curiosity") \
		+ 0.45 * ctx.deficit(&"play") \
		+ 0.30 * ctx.trait_of(&"energy")
	mischief *= BrainUtility.ramp(ctx.need(&"rest"), 0.25, 0.6)
	mischief *= BrainUtility.ramp(ctx.need(&"food"), 0.3, 0.6)
	mischief *= 0.4 + 0.6 * BrainUtility.circadian(ctx.hour, ctx.spec)
	# Confident animals do this; nervous ones do not.
	mischief *= 1.0 - 0.5 * ctx.trait_of(&"skittishness")
	return 0.9 * mischief


func on_enter(ctx: BrainContext) -> void:
	_ledge = ctx.mischief_ledge
	_phase = &"approach"
	_phase_t = 0.0
	_taps = 0
	var l: DB.Ledge = DesktopBridge.ledge_by_id(_ledge)
	if l == null:
		return
	# Stand at whichever end of the icon is nearer, because the drop has to be
	# visible from where the pet already is.
	var span: Vector2 = l.walk_span()
	var near_left: bool = absf(ctx.position.x - span.x) < absf(ctx.position.x - span.y)
	_edge = Vector2(span.x + 6.0 if near_left else span.y - 6.0, l.top_y())
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, delta: float) -> bool:
	var l: DB.Ledge = DesktopBridge.ledge_by_id(_ledge)
	if l == null:
		return false
	_phase_t += delta

	match _phase:
		&"approach":
			if ctx.position.distance_to(_edge) > 16.0:
				ctx.move_to(_edge, 1.0)
				ctx.look_at_point(l.rect.get_center())
				ctx.set_pose(&"stand")
				ctx.set_face(0.8, 0.4, 0.4)
				return true
			_phase = &"aim"
			_phase_t = 0.0
		&"aim":
			# The look. Not at the object — at the player.
			ctx.stop()
			ctx.look_at_point(ctx.cursor)
			ctx.set_pose(&"sit", &"stare")
			ctx.set_face(1.0, -0.2, 0.0, 0.35, 0.0, 1.0)
			if _phase_t > 1.1:
				_phase = &"tap"
				_phase_t = 0.0
		&"tap":
			# Two exploratory taps, still watching you, before the commit.
			ctx.stop()
			ctx.look_at_point(ctx.cursor)
			ctx.set_pose(&"stand", &"paw")
			ctx.set_face(1.0, 0.3 * sin(_phase_t * 9.0), 0.2, 0.3)
			if _phase_t > 0.7:
				_taps += 1
				_phase_t = 0.0
				if _taps >= 2:
					_phase = &"push"
		&"push":
			ctx.stop()
			ctx.look_at_point(ctx.cursor)
			ctx.set_pose(&"stand", &"push")
			ctx.set_face(1.0, 0.6, 0.0, 0.2, 0.2)
			if _phase_t > 0.35:
				_commit(ctx, l)
				_phase = &"admire"
				_phase_t = 0.0
		_:
			# Leaning over the edge to watch it go.
			ctx.stop()
			ctx.look_at_point(Vector2(_edge.x, _edge.y + 240.0))
			ctx.set_pose(&"crouch", &"peer")
			ctx.set_face(0.9, 0.5, 0.5)
			if _phase_t > 2.0:
				return false
	return true


func _commit(ctx: BrainContext, l: DB.Ledge) -> void:
	GameState.satisfy(ctx.record, &"play", 0.16)
	GameState.bump_stat(ctx.record, &"knocks")
	GameState.unlock(ctx.record, &"first_knock")
	EventBus.pet_knocked_off.emit(ctx.record.id, l.id, l.label)
	AudioDirector.foley(&"knock", 0.8)
	ctx.say(&"chirp", 0.4)
