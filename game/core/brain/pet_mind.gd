class_name PetMind
extends Node

## One line of wiring: give a pet a brain and hands.
##
## `PetBrain` and `TouchRouter` are deliberately independent — the AI is
## testable without input, and the input layer works without an AI — but in the
## running game they always come as a pair, and whoever builds the world scene
## should not have to know the order to set them up in.
##
##     var mind := PetMind.attach(creature_node, record)
##
## `creature` may be null, in which case the mind still runs: the brain keeps its
## own position on the ledge graph and publishes intent for whoever ends up
## drawing the animal.

const GS := preload("res://autoload/game_state.gd")

var brain: PetBrain = null
var router: TouchRouter = null
var record: GS.PetRecord = null


## Build a mind and parent it to `creature` (or to `parent` when there is no
## creature yet). Returns the node so the caller can hold on to it.
static func attach(creature: Node, p_record: GS.PetRecord, parent: Node = null) -> PetMind:
	var mind := PetMind.new()
	mind.name = "PetMind"
	mind.record = p_record
	var host: Node = parent if parent != null else creature
	if host == null:
		push_error("PetMind.attach needs a creature or a parent to live under")
		return mind
	host.add_child(mind)
	mind._build(creature, p_record)
	return mind


func _build(creature: Node, p_record: GS.PetRecord) -> void:
	brain = PetBrain.new()
	brain.name = "Brain"
	add_child(brain)
	brain.setup(p_record, creature)

	router = TouchRouter.new()
	router.name = "Touch"
	add_child(router)
	router.setup(p_record, creature, brain)


## Everything the debug overlay wants, in one call.
func debug_state() -> Dictionary:
	if brain == null:
		return {}
	return {
		"behaviour": brain.current.id if brain.current != null else &"none",
		"mood": record.mood if record != null else &"",
		"affection": record.affection if record != null else 0.0,
		"trust": record.trust if record != null else 0.0,
		"position": brain.ctx.position,
		"ledge": brain.ctx.ledge_kind,
		"carrying": router != null and router.is_carrying(),
	}
