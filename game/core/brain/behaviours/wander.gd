extends PetBehaviour

## Going somewhere for no reason.
##
## The difference between a pet and a widget is that a pet occupies the desktop
## rather than a spot on it. Wander picks a destination on the ledge graph and
## strolls there, at a pace set by how awake the animal is meant to be at this
## hour — the same cat ambles at 3pm and sprints at 6am.

const DB := preload("res://autoload/desktop_bridge.gd")

var _target := Vector2.ZERO
var _pace := 1.0
var _dwell := 0.0


func _init() -> void:
	id = &"wander"
	urgency = Urgency.AMBIENT
	min_duration = 2.0
	max_duration = 16.0
	cooldown = 2.5
	commitment = 7.0
	commit_bonus = 0.4


func score(ctx: BrainContext) -> float:
	# Too tired to bother is the dominant term: an exhausted animal does not
	# pace, it lies down.
	var rested: float = BrainUtility.ramp(ctx.need(&"rest"), 0.12, 0.5)
	var awake: float = BrainUtility.circadian(ctx.hour, ctx.spec)
	var restless: float = 0.30 * ctx.trait_of(&"energy") + 0.22 * ctx.deficit(&"play")
	return (0.16 + restless) * rested * (0.45 + 0.55 * awake)


func on_enter(ctx: BrainContext) -> void:
	_target = _pick_destination(ctx)
	_dwell = 0.0
	var awake: float = BrainUtility.circadian(ctx.hour, ctx.spec)
	# Zoomies are a real thing and they are almost entirely a function of the
	# hour and the animal's energy, not of anything the player did.
	var frisky: bool = ctx.rng.randf() < 0.18 * ctx.trait_of(&"energy") * awake
	_pace = ctx.rng.randf_range(0.55, 0.85) if not frisky else ctx.rng.randf_range(2.2, 3.0)
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, delta: float) -> bool:
	if ctx.position.distance_to(_target) <= 16.0:
		# Arrive, have a look around, then decide whether to keep going.
		_dwell += delta
		ctx.stop()
		ctx.set_pose(&"stand")
		ctx.set_face(0.55, 0.2)
		if _dwell < 1.2:
			return true
		if ctx.rng.randf() < 0.45:
			return false
		_target = _pick_destination(ctx)
		_dwell = 0.0
		return true

	ctx.move_to(_target, _pace)
	ctx.set_pose(&"stand")
	ctx.look_at_point(_target)
	ctx.set_face(0.45 + 0.3 * clampf(_pace - 1.0, 0.0, 1.0), 0.15)
	return true


## Prefer a different ledge to the one we are on — a pet that shuffles back and
## forth on the same icon looks broken — but fall back to a nudge along the
## current surface when there is nowhere else to be.
func _pick_destination(ctx: BrainContext) -> Vector2:
	var options: Array = []
	for l in DesktopBridge.ledges:
		if l.id == ctx.ledge_id:
			continue
		if ctx.position.distance_to(l.rect.get_center()) > 700.0:
			continue
		options.append(l)
	if options.is_empty():
		var span_x: float = ctx.rng.randf_range(-260.0, 260.0)
		return Vector2(ctx.position.x + span_x, ctx.position.y)
	var pick: DB.Ledge = options[ctx.rng.randi_range(0, options.size() - 1)]
	return BrainUtility.point_on_ledge(pick, ctx.rng.randf())
