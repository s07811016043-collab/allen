class_name Navigator
extends RefCounted

## One pet's journey across the desktop: owns the graph, the plan, and the
## traversal that is currently playing.
##
## The hard part of a desktop pet is not the search — it is that the world moves
## while you are walking through it. The user drags an icon, closes the window
## you were about to jump onto, plugs in a second monitor. A navigator that
## re-solved from scratch every time would visibly stutter; one that ignored the
## change would walk into empty space. So this keeps a *stable* plan and only
## disturbs it when the change actually invalidates it, never mid-arc.
##
## Driven explicitly rather than as a node: the creature already sequences a
## brain, a rig and a renderer, and a nav system that ticked itself would race
## that ordering.

## Emitted when the pet reaches the end of its plan.
signal arrived(ledge_id: int)
## No route exists, or the goal stopped existing. `reason` is &"no_route",
## &"no_goal", &"no_ground" or &"no_world".
signal path_failed(reason: StringName)
## The plan was rebuilt underneath the pet. Carries the new segment count.
signal replanned(segments: int)
## A new move started. `move` is a `NavSegment.Move`.
signal segment_started(move: int, segment: NavSegment)
## The pet finished a move and is now standing on `ledge_id`.
signal ledge_reached(ledge_id: int)

## How long after a re-plan before another one is allowed. Windows resize in a
## flurry of events; without this a dragged window re-plans sixty times a second.
const REPLAN_COOLDOWN := 0.35
## A destination ledge that moved less than this is still the same destination,
## and the plan is patched rather than rebuilt.
const GOAL_DRIFT_TOLERANCE := 24.0
## Cap on segments consumed in one frame, so a path made of many tiny hops
## cannot spin the update loop.
const MAX_SEGMENTS_PER_FRAME := 8

var mobility: NavMobility = null
var graph := LedgeGraph.new()
var traversal := Traversal.new()

var position: Vector2 = Vector2.ZERO
var facing: float = 1.0
## Ledge the pet is standing on right now, or -1 while airborne/unplaced.
var current_ledge: int = -1
## Rescan-stable identity of `current_ledge`, because ids are renumbered by
## every desktop scan and a stale id silently points at someone else's icon.
var current_key: String = ""

## Anything exposing `get_ledges()`/`get_topology_revision()`, or plain
## `ledges`/`topology_revision` members. Defaults to the DesktopBridge autoload;
## the tests inject a synthetic desktop here.
var world: Object = null

var path: Array[NavSegment] = []
var index: int = -1

var _goal_key := ""
var _goal_point := Vector2.ZERO
var _goal_ledge := -1
var _pending_replan := false
var _replan_cooldown := 0.0
var _known_revision := -1


## Point the navigator at a species at a given age. Cheap enough to call on
## every growth tick — the graph is only rebuilt when something actually moved.
func configure(spec: Object, growth: float = 3.0, ui_scale: float = 1.0) -> void:
	mobility = NavMobility.from_spec(spec, growth, ui_scale)
	# A grown cat jumps further than a kitten, so the reachability of every edge
	# changed. Force a rebuild rather than trusting the cached one.
	graph.revision = -1


func set_mobility(mob: NavMobility) -> void:
	mobility = mob
	graph.revision = -1


func set_world(w: Object) -> void:
	world = w
	graph.revision = -1
	_known_revision = -1


## Place the pet on a surface without animating: adoption, save-load, the player
## dropping it. Snaps to whatever is under `point` when `ledge_id` is not given.
func place(point: Vector2, ledge_id: int = -1) -> void:
	_ensure_graph()
	position = point
	stop()
	var l: NavLedge = null
	if ledge_id >= 0:
		l = graph.ledge(ledge_id)
	if l == null:
		l = graph.ledge_under(point)
	if l == null:
		l = graph.nearest_standable(point)
	if l != null:
		position = l.surface_point(point.x, 0.0)
		current_ledge = l.id
		current_key = l.key
	else:
		current_ledge = -1
		current_key = ""


func is_travelling() -> bool:
	return index >= 0 and index < path.size()


func stop() -> void:
	path.clear()
	index = -1
	_pending_replan = false
	traversal.finished = true


## Walk/jump/climb to a fraction along a named ledge.
func travel_to_ledge(ledge_id: int, frac: float = 0.5) -> bool:
	_ensure_graph()
	var goal: NavLedge = graph.ledge(ledge_id)
	if goal == null:
		path_failed.emit(&"no_goal")
		return false
	return _plan_to(goal, goal.point_at(frac))


## Walk to an arbitrary screen point; the pet lands on whatever surface owns it.
func travel_to_point(point: Vector2) -> bool:
	_ensure_graph()
	var goal := graph.ledge_under(point)
	if goal == null:
		goal = graph.nearest_standable(point)
	if goal == null:
		path_failed.emit(&"no_goal")
		return false
	return _plan_to(goal, goal.surface_point(point.x))


## Pick somewhere the pet can actually get to and go there. Returns false when
## the desktop offers nowhere new, which the brain should treat as "settle down"
## rather than as an error.
func wander(rng: RandomNumberGenerator = null) -> bool:
	_ensure_graph()
	if current_ledge < 0:
		var here := graph.ledge_under(position)
		if here == null:
			here = graph.nearest_standable(position)
		if here == null:
			path_failed.emit(&"no_ground")
			return false
		current_ledge = here.id
		current_key = here.key
	var options := graph.reachable_from(current_ledge)
	if options.size() <= 1:
		return false
	var r := rng if rng != null else RandomNumberGenerator.new()
	for attempt in 6:
		var pick: int = options[r.randi_range(0, options.size() - 1)]
		if pick == current_ledge:
			continue
		var l: NavLedge = graph.ledge(pick)
		if l == null or not l.is_standable():
			continue
		return travel_to_ledge(pick, r.randf_range(0.2, 0.8))
	return false


## The player let go of the pet in mid-air. Fall to whatever is underneath
## instead of snapping onto it — being dropped is a moment worth animating.
func fall_to_ground() -> bool:
	_ensure_graph()
	var below := graph.ledge_under(position, 24.0)
	if below == null:
		below = graph.nearest_standable(position)
	if below == null:
		path_failed.emit(&"no_ground")
		return false
	var landing := below.surface_point(position.x)
	if landing.y <= position.y + 1.0:
		place(landing, below.id)
		arrived.emit(below.id)
		return true
	var seg := NavSegment.make(NavSegment.Move.DROP, position, landing)
	seg.from_ledge = current_ledge
	seg.to_ledge = below.id
	seg.to_key = below.key
	path.clear()
	path.append(seg)
	index = 0
	_goal_key = below.key
	_goal_point = landing
	_goal_ledge = below.id
	_start_segment()
	return true


## Advance the journey. Returns true while the pet is still moving.
func step(delta: float) -> bool:
	if mobility == null:
		mobility = NavMobility.new()
	_replan_cooldown = maxf(0.0, _replan_cooldown - delta)

	# Poll rather than subscribe: a signal from the (long-lived) desktop bridge
	# to a (per-pet) navigator would keep freed pets alive.
	var rev := _world_revision()
	if rev != _known_revision:
		_known_revision = rev
		graph.revision = -1
		if is_travelling():
			_pending_replan = true

	if _pending_replan and _replan_cooldown <= 0.0 and not traversal.is_committed():
		_pending_replan = false
		_replan()

	if not is_travelling():
		return false

	var remaining := delta
	var guard := 0
	while remaining > 0.0 and is_travelling() and guard < MAX_SEGMENTS_PER_FRAME:
		guard += 1
		# Feed the traversal only what it can use, so a segment boundary does not
		# swallow the rest of the frame and stall a path of short hops.
		var slice: float = minf(remaining, maxf(traversal.time_remaining(), 0.0))
		if slice <= 0.0:
			slice = remaining
		var still_running := traversal.advance(slice)
		remaining -= slice
		position = traversal.position
		facing = traversal.facing
		if still_running:
			break
		var seg := path[index]
		if seg.to_ledge >= 0:
			current_key = seg.to_key
			# Resolve by key first: a rescan between planning and arriving
			# renumbers every ledge, and a stale id silently names someone else's
			# icon. The id in the segment is only a fallback.
			var landed_on: NavLedge = graph.ledge_by_key(current_key)
			current_ledge = landed_on.id if landed_on != null else seg.to_ledge
			ledge_reached.emit(current_ledge)
		index += 1
		if index >= path.size():
			var reached := current_ledge
			stop()
			arrived.emit(reached)
			return false
		_start_segment()
	return is_travelling()


## Hand the current pose to a creature/rig. Every call inside is guarded, so a
## creature that has not grown its nav hooks yet simply ignores this.
func apply_to(target: Object) -> void:
	traversal.apply_to(target)


## Human-readable plan, for the diagnostics overlay and the nav tests.
func path_summary() -> String:
	var parts := PackedStringArray()
	for s in path:
		parts.append(NavSegment.move_name(s.move))
	return "|".join(parts)


func remaining_time() -> float:
	if not is_travelling():
		return 0.0
	var t := traversal.time_remaining()
	for i in range(index + 1, path.size()):
		t += path[i].duration
	return t


## Explicit poke for callers that already have the bridge's signal wired up.
func notify_topology_changed() -> void:
	graph.revision = -1
	if is_travelling():
		_pending_replan = true


# --- Internals ---------------------------------------------------------------

func _plan_to(goal: NavLedge, goal_point: Vector2) -> bool:
	var from_l: NavLedge = graph.ledge(current_ledge)
	if from_l == null:
		from_l = graph.ledge_under(position)
	if from_l == null:
		from_l = graph.nearest_standable(position)
	if from_l == null:
		path_failed.emit(&"no_ground")
		return false
	current_ledge = from_l.id
	current_key = from_l.key
	_goal_key = goal.key
	_goal_point = goal_point
	_goal_ledge = goal.id
	var plan := graph.find_path(position, from_l.id, goal.id, goal_point.x)
	if plan.is_empty():
		stop()
		if from_l.id == goal.id and absf(position.x - goal_point.x) < mobility.body_width:
			# Already standing where it was asked to go. That is a success with
			# no work in it, not a routing failure — the brain would otherwise
			# read "cannot reach my own feet" and pick a different desire.
			position.y = goal_point.y
			arrived.emit(goal.id)
			return true
		path_failed.emit(&"no_route")
		return false
	path = plan
	index = 0
	_start_segment()
	return true


func _start_segment() -> void:
	var seg := path[index]
	# Stitch the segment onto where the pet actually is. A re-plan, a rounding
	# drift or a landing a pixel short would otherwise show up as a visible snap
	# at every segment boundary.
	if seg.from.distance_squared_to(position) > 0.25:
		seg.from = position
	traversal.begin(seg, mobility)
	facing = traversal.facing
	segment_started.emit(seg.move, seg)


func _replan() -> void:
	_replan_cooldown = REPLAN_COOLDOWN
	_ensure_graph()
	if graph.ledge_count() == 0:
		stop()
		path_failed.emit(&"no_world")
		return

	# Re-anchor the goal by identity, not by id: ids are renumbered every scan.
	var goal: NavLedge = graph.ledge_by_key(_goal_key)
	if goal == null:
		goal = graph.nearest_standable(_goal_point)
		if goal == null:
			stop()
			path_failed.emit(&"no_goal")
			return
	var goal_point := goal.surface_point(_goal_point.x)

	if _path_intact(goal, goal_point):
		# Nothing that mattered moved. Keep walking; re-planning here would show
		# up as a needless hesitation every time an unrelated window resized.
		_goal_ledge = goal.id
		_goal_point = goal_point
		return

	var from_l: NavLedge = graph.ledge_by_key(current_key)
	if from_l == null or not from_l.contains_x(position.x, mobility.body_width):
		from_l = graph.ledge_under(position, 12.0)
	if from_l == null:
		from_l = graph.nearest_standable(position)
	if from_l == null:
		stop()
		path_failed.emit(&"no_ground")
		return
	current_ledge = from_l.id
	current_key = from_l.key
	# Snap the pet onto the surface it is actually standing on now — an icon
	# dragged 20 px down should carry the pet with it, not leave it hovering.
	if not traversal.airborne:
		position.y = from_l.top_y()

	var plan := graph.find_path(position, from_l.id, goal.id, goal_point.x)
	if plan.is_empty():
		stop()
		path_failed.emit(&"no_route")
		return
	path = plan
	index = 0
	_goal_key = goal.key
	_goal_ledge = goal.id
	_goal_point = goal_point
	_start_segment()
	replanned.emit(path.size())


## Is the rest of the current plan still playable against the new topology?
## Every remaining destination has to still exist, at about the height the plan
## assumed. Small drifts are absorbed by nudging the segment endpoints, which is
## what keeps a pet walking smoothly across an icon the user is dragging.
func _path_intact(goal: NavLedge, goal_point: Vector2) -> bool:
	if not is_travelling():
		return false
	if goal.key != _goal_key:
		return false
	if goal_point.distance_to(_goal_point) > GOAL_DRIFT_TOLERANCE:
		return false
	for i in range(index, path.size()):
		var seg := path[i]
		if seg.to_key == "":
			continue
		var l: NavLedge = graph.ledge_by_key(seg.to_key)
		if l == null:
			return false
		var landing := l.surface_point(seg.to.x)
		if landing.distance_to(seg.to) > GOAL_DRIFT_TOLERANCE:
			return false
		# Absorb the drift: the plan stays, the endpoints follow the furniture.
		# The segment currently playing is left alone except for its id — moving
		# its target under a running traversal would shift the pet by the whole
		# drift in one frame. It finishes at most `GOAL_DRIFT_TOLERANCE` short,
		# and `_start_segment` stitches the next move onto where it really is.
		seg.to_ledge = l.id
		if i > index:
			seg.to = landing
			if i + 1 < path.size():
				path[i + 1].from = landing
	return true


func _ensure_graph() -> void:
	if mobility == null:
		mobility = NavMobility.new()
	var rev := _world_revision()
	if graph.revision == rev and graph.ledge_count() > 0 and graph.mobility == mobility:
		return
	graph.build(_world_ledges(), mobility, rev)
	_known_revision = rev


func _resolve_world() -> Object:
	if world != null and is_instance_valid(world):
		return world
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root: Window = (loop as SceneTree).root
		if root != null:
			world = root.get_node_or_null(^"DesktopBridge")
	return world


func _world_ledges() -> Array:
	var w := _resolve_world()
	if w == null:
		return []
	if w.has_method("get_ledges"):
		var got: Variant = w.call("get_ledges")
		return got if typeof(got) == TYPE_ARRAY else []
	var v: Variant = w.get("ledges")
	if typeof(v) == TYPE_ARRAY:
		return v
	return []


func _world_revision() -> int:
	var w := _resolve_world()
	if w == null:
		return 0
	if w.has_method("get_topology_revision"):
		return int(w.call("get_topology_revision"))
	var v: Variant = w.get("topology_revision")
	return int(v) if typeof(v) == TYPE_INT else 0
