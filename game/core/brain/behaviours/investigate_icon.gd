extends PetBehaviour

## Going to look at the new thing.
##
## The desktop is the level design. When an icon appears, a window opens or the
## layout shifts, a curious animal should notice and go and check, and — this is
## the part that matters — should then *stop finding it interesting*. Novelty is
## remembered in the save (`known_ledges`), so the pet does not sniff the same
## Recycle Bin every launch like it has amnesia.

const DB := preload("res://autoload/desktop_bridge.gd")

var _ledge: int = -1
var _target := Vector2.ZERO
var _sniffed := 0.0


func _init() -> void:
	id = &"investigate_icon"
	urgency = Urgency.NORMAL
	min_duration = 2.5
	max_duration = 18.0
	cooldown = 6.0
	commitment = 8.0
	commit_bonus = 0.45


func score(ctx: BrainContext) -> float:
	if ctx.novel_ledge < 0:
		return 0.0
	# Curiosity is the gate; novelty is the fuel. A skittish animal investigates
	# less, and a hungry one has better things to do.
	var drive: float = ctx.trait_of(&"curiosity") * (0.35 + 0.85 * ctx.novelty)
	drive *= 1.0 - 0.45 * ctx.trait_of(&"skittishness")
	drive *= BrainUtility.ramp(ctx.need(&"food"), 0.15, 0.45)
	drive *= BrainUtility.ramp(ctx.need(&"rest"), 0.1, 0.4)
	# An icon is not going anywhere. Something the player is waving is.
	if ctx.toy_id != &"":
		drive *= 0.45
	return drive


func on_enter(ctx: BrainContext) -> void:
	_ledge = ctx.novel_ledge
	_sniffed = 0.0
	var l: DB.Ledge = DesktopBridge.ledge_by_id(_ledge)
	_target = BrainUtility.point_on_ledge(l, 0.5) if l != null else ctx.position
	ctx.set_pose(&"stand")


func update(ctx: BrainContext, delta: float) -> bool:
	var l: DB.Ledge = DesktopBridge.ledge_by_id(_ledge)
	if l == null:
		# The icon moved or the window closed mid-approach. Anticlimax is fine.
		return false

	if ctx.position.distance_to(_target) > 20.0:
		ctx.move_to(_target, 1.15)
		ctx.look_at_point(l.rect.get_center())
		ctx.set_pose(&"stand")
		ctx.set_face(0.85, 0.35, 0.5)
		return true

	_sniffed += delta
	ctx.stop()
	ctx.set_pose(&"crouch")
	ctx.look_at_point(l.rect.get_center() + Vector2(0.0, -4.0))
	ctx.set_face(0.9, 0.1, 0.6, 0.0, 0.15)
	if _sniffed < 2.2:
		return true

	# Curiosity satisfied: it is now furniture, and worth a little of the play
	# need because poking at the world is play.
	GameState.remember_ledge(ctx.record, l.label)
	GameState.satisfy(ctx.record, &"play", 0.05)
	ctx.novelty = maxf(0.0, ctx.novelty - 0.5)
	if ctx.rng.randf() < 0.35:
		ctx.say(&"chirp", 0.35)
	return false
