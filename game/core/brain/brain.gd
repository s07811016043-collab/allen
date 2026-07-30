class_name PetBrain
extends Node

## Utility AI: the thing that decides what the pet is doing.
##
## Every ~0.2 s each behaviour scores itself against the blackboard
## (`BrainContext`) and the winner runs. Scores come from needs, mood,
## personality, the hour of the day and what the desktop and the player have
## just done. `PetBehaviour` documents the hysteresis and interrupt rules; this
## file is the loop that applies them, plus the senses that fill the blackboard.
##
## The brain does not own a body. It publishes an `Intent` and, if the creature
## it is attached to knows how to read one, hands it over:
##
##   1. `creature.apply_intent(intent)`  — preferred: the creature does the lot.
##   2. `creature.move_to(target, speed_scale)` — motion only.
##   3. otherwise the brain integrates its own position along the ledge graph
##      and writes it to the creature's transform, so a pet still walks around
##      before the rig lands.
##
## All three are probed with `has_method`, because the creature and the rig are
## being written in parallel with this file and the build must never depend on
## which of them landed first.

const DB := preload("res://autoload/desktop_bridge.gd")
const GS := preload("res://autoload/game_state.gd")

## Order is irrelevant — selection is by score — but keeping the list roughly
## from "background" to "reflex" makes the debug overlay readable.
const BEHAVIOUR_SCRIPTS := [
	preload("res://core/brain/behaviours/idle.gd"),
	preload("res://core/brain/behaviours/wander.gd"),
	preload("res://core/brain/behaviours/groom.gd"),
	preload("res://core/brain/behaviours/nap.gd"),
	preload("res://core/brain/behaviours/investigate_icon.gd"),
	preload("res://core/brain/behaviours/follow_cursor.gd"),
	preload("res://core/brain/behaviours/play_with_toy.gd"),
	preload("res://core/brain/behaviours/knock_thing_off_ledge.gd"),
	preload("res://core/brain/behaviours/sulk.gd"),
	preload("res://core/brain/behaviours/beg.gd"),
	preload("res://core/brain/behaviours/greet_on_return.gd"),
	preload("res://core/brain/behaviours/startle.gd"),
]

## How often the utility scores are recomputed. Faster than this buys nothing —
## the commitment term dominates — and costs a score() call per behaviour.
const DECISION_INTERVAL := 0.2
## A same-tier challenger must beat the running behaviour by this much.
const SWITCH_MARGIN := 0.05
## Cursor speed (px/s) that counts as "the player is doing something sudden".
const STARTLE_SPEED := 2600.0
## ...and how close it has to happen, as a multiple of body height.
const STARTLE_RADIUS := 1.6

var ctx := BrainContext.new()
## The node this brain drives. May be null (headless tests, offline sims).
var creature: Node = null
## Set false by tests and by the capture harness so the brain does not read the
## real mouse or the real clock: the cursor fields become inputs the caller
## writes, and time advances by whatever delta is passed in. That makes a
## simulated week of behaviour exactly reproducible.
var autonomous_senses := true

var behaviours: Array[PetBehaviour] = []
var current: PetBehaviour = null

var _decision_accum := 0.0
var _hour_accum := 99.0
var _last_cursor := Vector2.ZERO
var _cursor_seen := false
var _step_accum := 0.0
var _known_ledge_count := -1


## Wire a brain to a pet. `p_creature` is optional; everything here works
## without one, which is what makes the AI testable.
func setup(record: GS.PetRecord, p_creature: Node = null) -> void:
	creature = p_creature
	ctx.record = record
	ctx.creature = p_creature
	ctx.spec = GameState.spec_for(record.species)
	ctx.personality = GameState.personality(record)
	ctx.rng.seed = record.variant_seed ^ 0x5eed
	ctx.now = Clock.now()
	ctx.greet_pending = GameState.pending_greeting(record.id)

	behaviours.clear()
	for s in BEHAVIOUR_SCRIPTS:
		var b: PetBehaviour = (s as Script).new()
		behaviours.append(b)

	# The player has just launched the app, so somebody is at the machine; the
	# greeting behaviour needs that to be true before the mouse has moved.
	ctx.cursor_idle = 0.0
	ctx.position = _default_spawn()
	if creature != null and creature is Node2D:
		(creature as Node2D).global_position = ctx.position - _window_origin()

	EventBus.desktop_topology_changed.connect(_on_topology_changed)
	_on_topology_changed()


func _default_spawn() -> Vector2:
	# Start on the widest thing the pet could plausibly be standing on, which on
	# a bare desktop is the floor and on a Windows session is the taskbar.
	var best: DB.Ledge = null
	for l in DesktopBridge.ledges:
		if l.kind == &"icon":
			continue
		if best == null or l.rect.size.x > best.rect.size.x:
			best = l
	if best == null:
		return DesktopBridge.work_area.get_center()
	return Vector2(best.rect.get_center().x, best.top_y())


func _process(delta: float) -> void:
	if ctx.record == null:
		return
	_sense(delta)
	ctx.intent.reset_frame()

	# A held pet has no say in what its body is doing; the drag simulation owns
	# it until it lands. It still senses, so it can be furious about it.
	if ctx.held:
		_finish_current()
		ctx.intent.behaviour = &"held"
		ctx.set_pose(&"dangle")
		_publish()
		return

	_decision_accum += delta
	if _decision_accum >= DECISION_INTERVAL:
		_decision_accum = 0.0
		_select()

	if current != null:
		current.elapsed += delta
		var alive: bool = current.update(ctx, delta)
		if not alive or current.elapsed >= current.max_duration:
			_finish_current()
			_select()
	if current == null:
		ctx.set_pose(&"stand")

	_integrate_motion(delta)
	_publish()


# --- Senses ------------------------------------------------------------------

func _sense(delta: float) -> void:
	ctx.dt = delta
	ctx.now = Clock.now() if autonomous_senses else ctx.now + delta

	_hour_accum += delta
	if _hour_accum >= 5.0 and autonomous_senses:
		_hour_accum = 0.0
		var d := Time.get_datetime_dict_from_system()
		ctx.hour = float(d.get("hour", 12)) + float(d.get("minute", 0)) / 60.0

	if autonomous_senses:
		var m := Vector2(DisplayServer.mouse_get_position())
		if not _cursor_seen:
			_last_cursor = m
			_cursor_seen = true
		var moved: Vector2 = m - _last_cursor
		_last_cursor = m
		ctx.cursor = m
		ctx.cursor_velocity = moved / maxf(delta, 0.0001)
		ctx.cursor_speed = ctx.cursor_velocity.length()
		if moved.length() > 1.5:
			ctx.cursor_idle = 0.0
		else:
			ctx.cursor_idle += delta
		ctx.player_present = ctx.cursor_idle < 90.0

		# Something fast going past your face is the oldest startle there is.
		var body: float = ctx.body_pixels()
		if ctx.cursor_speed > STARTLE_SPEED \
				and ctx.distance_to(ctx.cursor) < body * STARTLE_RADIUS:
			add_startle(0.5 * ctx.trait_of(&"skittishness"))

	ctx.greet_pending = GameState.pending_greeting(ctx.record.id)
	ctx.startle_charge = BrainUtility.decay(ctx.startle_charge, 1.1, delta)
	ctx.novelty = BrainUtility.decay(ctx.novelty, 26.0, delta)
	if ctx.now - ctx.toy_at > 6.0:
		ctx.toy_id = &""

	# While the pet is dangling from a cursor its position belongs to the drag
	# simulation, not to the ledge graph.
	if not ctx.held:
		_resolve_ground()
	_pick_targets()


## Which surface is the pet standing on? Until `core/nav` lands, "walk" means
## "slide along the ledge you are on and drop onto whatever is below when you
## run off the end", which is enough to look alive and enough to test against.
func _resolve_ground() -> void:
	var probe: Vector2 = ctx.position - Vector2(0.0, 1.0)
	var l: DB.Ledge = DesktopBridge.ground_below(probe)
	if l == null:
		ctx.ledge_id = -1
		ctx.ledge_kind = &""
		return
	# Only snap when the brain is the thing moving the body. Once the creature
	# owns its own locomotion, its transform is the truth and overwriting the
	# height here would just fight it every frame.
	if creature == null or not creature.has_method("move_to"):
		ctx.position.y = l.top_y()
	if l.id != ctx.ledge_id:
		ctx.ledge_id = l.id
		ctx.ledge_kind = l.kind
		EventBus.pet_reached_ledge.emit(ctx.record.id, l.id)
		if l.kind == &"icon":
			GameState.remember_ledge(ctx.record, l.label)
	ctx.ledge_kind = l.kind


## Choose the interesting bits of desktop furniture once, rather than in every
## behaviour's score(): a scoring pass must stay cheap.
func _pick_targets() -> void:
	var best_novel := -1
	var best_mischief := -1
	var best_novel_d := INF
	var best_mischief_d := INF
	for l in DesktopBridge.ledges:
		if l.kind != &"icon":
			continue
		var d: float = ctx.position.distance_to(l.rect.get_center())
		if not GameState.is_ledge_known(ctx.record, l.label) and d < best_novel_d:
			best_novel_d = d
			best_novel = l.id
		# Anything the pet is already standing next to is a candidate for being
		# pushed into the void.
		if d < best_mischief_d and d < 520.0:
			best_mischief_d = d
			best_mischief = l.id
	ctx.novel_ledge = best_novel
	ctx.mischief_ledge = best_mischief


func _on_topology_changed() -> void:
	# Only genuinely new furniture is interesting. A window resize that leaves
	# the icon count alone should not send the cat across the screen.
	var n: int = DesktopBridge.ledges.size()
	if n != _known_ledge_count:
		ctx.novelty = clampf(ctx.novelty + 0.7, 0.0, 1.0)
		_known_ledge_count = n


# --- Selection ---------------------------------------------------------------

func _select() -> void:
	var best: PetBehaviour = null
	var best_score := 0.0
	for b in behaviours:
		if b == current or not b.available(ctx):
			continue
		var s: float = b.score(ctx)
		if s > best_score:
			best_score = s
			best = b

	if current == null:
		if best != null:
			_enter(best)
		return
	if best == null:
		return

	# Tier gate: nothing beneath the running behaviour gets a say. This is the
	# rule that makes "a nap must not cut a greeting" structural rather than a
	# matter of tuning two numbers against each other.
	if best.urgency < current.urgency:
		return
	if best.urgency == current.urgency:
		if current.elapsed < current.min_duration:
			return
		var held_score: float = current.score(ctx) * current.commitment_multiplier()
		if best_score <= held_score + SWITCH_MARGIN:
			return
	_enter(best)


func _enter(b: PetBehaviour) -> void:
	var previous := &"none"
	if current != null:
		previous = current.id
		current.finish(ctx)
	current = b
	ctx.intent.behaviour = b.id
	b.begin(ctx)
	EventBus.behaviour_changed.emit(ctx.record.id, b.id, previous)


func _finish_current() -> void:
	if current == null:
		return
	current.finish(ctx)
	current = null


## Force a specific behaviour by id. Used by the touch layer, which knows things
## the scoring pass cannot infer — that the player just yanked the tail, say.
func provoke(id: StringName) -> bool:
	for b in behaviours:
		if b.id != id:
			continue
		if current != null and current.urgency > b.urgency:
			return false
		b.ready_at = 0.0
		_enter(b)
		return true
	return false


# --- Motion ------------------------------------------------------------------

func _integrate_motion(delta: float) -> void:
	if creature != null and creature.has_method("move_to"):
		# `Creature.move_to` takes a pace in [0, 1] between the species' walking
		# and running speed, and works in the window's space; the brain thinks in
		# multiples of walk speed, on the screen. Convert rather than making
		# either side compromise.
		if ctx.intent.has_move_target:
			creature.call("move_to", ctx.intent.move_target - _window_origin(),
				_pace_for(ctx.intent.speed_scale))
		elif creature.has_method("stop"):
			creature.call("stop")
		if creature is Node2D:
			ctx.position = (creature as Node2D).global_position + _window_origin()
		return
	if not ctx.intent.has_move_target:
		return

	var speed: float = 90.0
	if ctx.spec != null:
		speed = ctx.spec.walk_speed * ctx.spec.scale_at(ctx.record.growth) \
			* ctx.spec.pixels_per_unit
	speed *= maxf(ctx.intent.speed_scale, 0.0)

	# Horizontal only: vertical position is owned by whichever ledge the pet is
	# standing on, resolved next frame.
	var target := ctx.intent.move_target
	var dx: float = target.x - ctx.position.x
	var step: float = speed * delta
	if absf(dx) <= step:
		ctx.position.x = target.x
	else:
		ctx.position.x += signf(dx) * step
		ctx.facing = signf(dx)
	_step_accum += step

	var stride_px: float = 60.0
	if ctx.spec != null:
		stride_px = maxf(8.0, ctx.spec.stride * ctx.spec.scale_at(ctx.record.growth)
			* ctx.spec.pixels_per_unit)
	while _step_accum >= stride_px:
		_step_accum -= stride_px
		GameState.bump_stat(ctx.record, &"steps")

	var bounds: Rect2 = DesktopBridge.screen_rect
	ctx.position.x = clampf(ctx.position.x, bounds.position.x + 4.0, bounds.end.x - 4.0)


## Where the game window sits on the desktop. The brain, the pointer and the
## ledge graph are all in screen space; nodes are in the window's viewport.
static func _window_origin() -> Vector2:
	return Vector2(DisplayServer.window_get_position())


## Convert "multiples of walk speed" into `Creature`'s walk-to-run pace.
func _pace_for(speed_scale: float) -> float:
	if ctx.spec == null:
		return clampf(speed_scale - 1.0, 0.0, 1.0)
	var desired: float = ctx.spec.walk_speed * maxf(speed_scale, 0.0)
	var span: float = maxf(ctx.spec.run_speed - ctx.spec.walk_speed, 0.001)
	return clampf((desired - ctx.spec.walk_speed) / span, 0.0, 1.0)


func _publish() -> void:
	if creature == null:
		return
	# Preferred, if the creature ever grows a single entry point: hand it the
	# whole intent and let it decide.
	if creature.has_method("apply_intent"):
		creature.call("apply_intent", ctx.intent)
		return

	if creature.has_method("look_at_point"):
		if ctx.intent.has_look_at:
			creature.call("look_at_point", ctx.intent.look_at - _window_origin())
		elif creature.has_method("clear_look"):
			creature.call("clear_look")

	# Last resort: no motion API at all, so put the body where the brain thinks
	# it is rather than leaving the pet stuck at the origin. Skipped the moment
	# the creature can move itself, so the two never fight over the transform.
	if creature is Node2D and not creature.has_method("move_to"):
		(creature as Node2D).global_position = ctx.position - _window_origin()


# --- Pokes from the interaction layer ----------------------------------------

func add_startle(amount: float) -> void:
	if amount <= 0.0:
		return
	ctx.startle_charge = clampf(ctx.startle_charge + amount, 0.0, 1.5)


func notice_touch(region: StringName, valence: float) -> void:
	ctx.last_touch_at = ctx.now
	ctx.last_touch_region = region
	ctx.last_touch_valence = valence


func set_held(held: bool) -> void:
	ctx.held = held


## The player is waving something the pet might chase. The cursor itself counts,
## which is why a wiggled mouse pointer gets a cat out of a chair.
func offer_toy(toy_id: StringName, at: Vector2) -> void:
	ctx.toy_id = toy_id
	ctx.toy_at = ctx.now
	ctx.toy_position = at


## Teleport the body, e.g. after being dropped somewhere else.
func place_at(p: Vector2) -> void:
	ctx.position = p
	ctx.intent.body_rotation = 0.0
	_resolve_ground()


## Follow the drag simulation while carried. The brain keeps its own idea of
## where the pet is so that the moment it is put down it knows where it stands.
func place_held(p: Vector2, rotation: float) -> void:
	ctx.position = p
	ctx.intent.body_rotation = rotation
