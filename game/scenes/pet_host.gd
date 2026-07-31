class_name PetHost
extends Node2D

## One pet, fully assembled, and the order its parts run in.
##
## The world spawns one of these per `GameState.PetRecord`. It owns the record,
## the body, the mind and the route — but the reason it exists is the sequence:
##
##     hands  ->  mind  ->  route  ->  body
##
## That order is load-bearing. The router has to have classified this frame's
## touch before the brain scores against it; the brain has to have published its
## intent before the navigator turns it into a plan; the plan has to have moved
## before the rig is asked where the feet go. Get it wrong and every pet reacts
## to the previous frame — invisible in a single frame, and read as sluggishness
## in aggregate.
##
## Two authorities, split so they can never argue:
##
##   * `Navigator` owns **where the pet is**. It is the only thing that writes
##     the body's position, because it is the only thing that knows the desktop
##     is made of ledges rather than open space.
##   * `Creature` owns **how the body looks getting there**. Each frame it is
##     handed the navigator's ground speed and heading, so the gait solver plants
##     feet against the distance actually covered; its own integration is then
##     overwritten by the navigator's position. The two never disagree by more
##     than one frame's worth of acceleration.
##
## While the player is carrying the pet neither of them is in charge: `DragBody`
## inside the touch router owns the transform until it lands, and the navigator
## is re-anchored wherever it comes down.
##
## Every hop into `core/` is loaded by path and probed with `has_method`. Those
## files are being written in parallel with this one, and a hook that has not
## landed yet must cost a feature, never the build.

const GS := preload("res://autoload/game_state.gd")

const CREATURE_SCRIPT := "res://core/creature/creature.gd"
const MIND_SCRIPT := "res://core/brain/pet_mind.gd"
const NAVIGATOR_SCRIPT := "res://core/nav/navigator.gd"

## Goal drift under this is the same goal. Without it a pet following the cursor
## re-runs A* every frame and stutters once per plan.
const GOAL_EPS := 26.0
## Floor on the interval between plans for one pet.
const PLAN_INTERVAL := 0.28
## How far ahead of itself the creature is told to walk, in strides. Comfortably
## past `Creature`'s arrival ease-in (1.5 strides) so its speed ramp settles on
## the navigator's ground speed instead of braking for a mark it never reaches.
const LOOKAHEAD_STRIDES := 4.0
## Ceiling on how much faster than planned an urgent behaviour may play a walk.
## The planner costs every route at walking pace; urgency plays that plan faster,
## which for a walk is exactly what running is.
const MAX_PACE := 3.0
## Growth has to move this far before the jump physics are re-derived. A kitten
## and an adult reach very differently, but re-solving it every frame is waste.
const GROWTH_EPS := 0.02

var record: GS.PetRecord = null
var spec: Object = null
## `Creature`, typed loosely so this file still parses while that one is open in
## another agent's editor.
var creature: Node2D = null
## `PetMind` — brain plus touch router.
var mind: Node = null
## `Navigator`.
var navigator: RefCounted = null

## Counters the diagnostics overlay and `tests/world_test.gd` both read. Cheap
## enough to keep always-on, and the only way to answer "did it actually get
## where it said it was going" without a camera.
var stats := {
	&"plans": 0,
	&"arrivals": 0,
	&"failures": 0,
	&"worst_arrival_error": 0.0,
	&"frames": 0,
}

var _desktop: Object = null
var _vfx: Node = null
var _goal := Vector2.INF
## True once the current goal has been reached or abandoned, so a settled pet
## does not re-plan its way to its own feet four times a second.
var _goal_settled := true
var _plan_cooldown := 0.0
var _phase: StringName = &"idle"
var _gait_override: StringName = &""
var _carried := false
## True only inside `reground`, so a re-settle onto moved furniture is not
## mistaken for a journey the pet chose to make.
var _settling := false
var _air_velocity := Vector2.ZERO
var _mobility_growth := -1.0
var _px := 180.0
var _stride_px := 80.0
## Capability probes, resolved once at setup rather than per frame.
var _can_tick := false
var _can_move := false
var _can_stop := false
var _can_gait := false
var _can_react := false
var _can_speed := false
## Last ledge the audio layer was told about, so the surface is only pushed on a
## real change rather than every frame.
var _reported_ledge := -2


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## Assemble a pet. Returns false when the species has no spec or the creature
## script is not available, in which case the host is inert and the world should
## drop it rather than keep a half-built pet in the frame loop.
func setup(p_record: GS.PetRecord, p_desktop: Object) -> bool:
	record = p_record
	_desktop = p_desktop
	name = "Pet_%s" % record.id
	spec = GameState.spec_for(record.species)
	if spec == null:
		Log.warn("PetHost", "no spec for species '%s'; not spawning %s"
			% [record.species, record.id])
		return false
	_px = maxf(_num(spec, "pixels_per_unit", 180.0), 1.0)
	_stride_px = maxf(_num(spec, "stride", 0.45) * _px, 8.0)

	if not _build_creature():
		return false
	_build_mind()
	_build_navigator()
	return true


func _build_creature() -> bool:
	if not ResourceLoader.exists(CREATURE_SCRIPT):
		Log.error("PetHost", "creature script missing at %s" % CREATURE_SCRIPT)
		return false
	var script: Script = load(CREATURE_SCRIPT)
	if script == null:
		return false
	creature = script.new()
	creature.name = "Creature"
	# Added before `setup`: the renderer only acquires its shader material once
	# it is in the tree, and `Creature.setup` finishes the moment it is.
	add_child(creature)
	# The world sequences the frame. Letting the creature also tick itself would
	# put the body half a frame ahead of the plan that moves it, and which half
	# would depend on tree order.
	creature.set_process(false)
	if creature.has_method("setup"):
		creature.call("setup", record)

	_can_tick = creature.has_method("tick")
	_can_move = creature.has_method("move_to")
	_can_stop = creature.has_method("stop")
	_can_gait = creature.has_method("set_gait")
	_can_react = creature.has_method("play_reaction")
	_can_speed = creature.get("speed") != null
	if creature.has_signal("footfall"):
		creature.connect("footfall", _on_footfall)
	# The audio layer needs the same signal, and it wants to know what the paw
	# landed on: an icon, the taskbar and a window edge are three materials, and
	# hearing the difference is most of what makes the pet feel like it is *on*
	# the desktop rather than floating in front of it.
	AudioDirector.bind_creature(record.id, creature)
	return true


func _build_mind() -> void:
	if not ResourceLoader.exists(MIND_SCRIPT):
		Log.warn("PetHost", "no mind script; %s will stand still" % record.id)
		return
	var script: Script = load(MIND_SCRIPT)
	if script == null:
		return
	# `attach` is a static factory; calling it through the script is how the rest
	# of the codebase reaches static builders (see `GameState._load_specs`).
	mind = script.call("attach", creature, record)
	if mind == null:
		return
	# Both halves of the mind expose their per-frame work as `_process`. Taking
	# the engine off them is what lets `step()` fix the order below.
	var brain := _brain()
	if brain != null:
		brain.set_process(false)
	var router := _router()
	if router != null:
		router.set_process(false)


func _build_navigator() -> void:
	if not ResourceLoader.exists(NAVIGATOR_SCRIPT):
		Log.warn("PetHost", "no navigator; %s will not path" % record.id)
		return
	var script: Script = load(NAVIGATOR_SCRIPT)
	if script == null:
		return
	navigator = script.new()
	if navigator.has_method("set_world"):
		navigator.call("set_world", _desktop)
	_refit_mobility()
	if navigator.has_signal("arrived"):
		navigator.connect("arrived", _on_arrived)
	if navigator.has_signal("path_failed"):
		navigator.connect("path_failed", _on_path_failed)


## Re-derive the jump physics for the pet's current age.
##
## `ui_scale` is deliberately 1.0. The mobility profile has to agree with the
## body that is actually drawn, and `Creature` renders at the spec's
## `pixels_per_unit` regardless of the monitor's DPI — so scaling reach by DPI
## here would let a pet plan leaps its legs cannot make. Growth *is* folded in,
## because `Growth` really does shrink a kitten's body.
func _refit_mobility() -> void:
	if navigator == null or not navigator.has_method("configure"):
		return
	if absf(record.growth - _mobility_growth) < GROWTH_EPS:
		return
	_mobility_growth = record.growth
	navigator.call("configure", spec, record.growth, 1.0)


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

## Put the pet down at a screen point, snapping to whatever surface owns it.
## Used on spawn, after a drop, and when the desktop moves out from under it.
func place_at(point: Vector2) -> void:
	var landed := point
	if navigator != null and navigator.has_method("place"):
		navigator.call("place", point)
		landed = navigator.get("position")
		_goal = Vector2.INF
		_goal_settled = true
	_write_body_position(landed)
	var brain := _brain()
	if brain != null and brain.has_method("place_at"):
		brain.call("place_at", landed)


## Re-settle onto the desktop as it is now. Called when the topology changes: a
## pet standing on a window that just closed has to find the floor, and the
## navigator only does that for a pet that is already walking.
##
## It *falls* rather than snapping. The difference is the whole point: a window
## closing under a cat is a thing that happened to the cat, and it should read as
## one. Snapping the body 120 px down in a single frame reads as a bug, and it is
## the same 120 px either way.
func reground() -> void:
	if navigator == null:
		return
	_refit_mobility()
	if _travelling():
		# Already walking: `Navigator.step` re-plans against the new topology on
		# its own, and interrupting it here would undo exactly that work.
		return
	if navigator.has_method("fall_to_ground"):
		# An arrival raised inside this call is a re-settle, not a journey the pet
		# asked for, and must not be counted as one. A real fall emits later, once
		# the drop has played, and is counted like any other landing.
		_settling = true
		var ok := bool(navigator.call("fall_to_ground"))
		_settling = false
		if ok:
			_goal = Vector2.INF
			_goal_settled = true
			_write_body_position(position_of())
			return
	place_at(position_of())


## Screen-space position of the pet's feet.
func position_of() -> Vector2:
	if navigator != null:
		var p: Variant = navigator.get("position")
		if p is Vector2:
			return p
	if creature != null:
		return creature.global_position + _window_origin()
	return Vector2.ZERO


## Screen rectangle the pointer has to be inside for this pet to be touchable.
## The window layer unions these to build the click-through region.
func hit_rect() -> Rect2:
	var box := _body_box_rig()
	var origin := position_of()
	return Rect2(origin + box.position * _px, box.size * _px)


# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

func step(delta: float) -> void:
	if record == null or creature == null:
		return
	stats[&"frames"] = int(stats[&"frames"]) + 1
	_refit_mobility()

	# 1. Hands. The router reads the pointer, classifies the gesture and runs the
	#    drag simulation, so the brain scores against this frame's touch.
	var router := _router()
	if router != null:
		router._process(delta)

	# 2. Mind. Decides what the pet wants and publishes it as intent.
	var brain := _brain()
	if brain != null:
		brain._process(delta)

	# 3. A carried pet has no route. The drag simulation owns the transform until
	#    it lands; the body still ticks, so it can be furious about it.
	if _is_carried():
		if not _carried:
			_carried = true
			_stop_route()
		if _can_tick:
			creature.call("tick", delta)
		return
	if _carried:
		_carried = false
		# It came down somewhere of the player's choosing. Re-anchor the plan
		# there rather than teleporting back to where it was picked up.
		creature.rotation = 0.0
		place_at(brain.ctx.position if brain != null else position_of())

	# 4. Route. Turn desire into a plan, then play the plan.
	_follow_intent(delta)
	var before := position_of()
	if navigator != null and navigator.has_method("step"):
		navigator.call("step", delta * _pace_scale())
		_report_surface()

	# 5. Body. Speed and heading in, then the rig, then the authoritative
	#    position back out over whatever the creature integrated for itself.
	#
	#    The ground velocity is measured from the move that just happened rather
	#    than read off the traversal: urgency plays a walk faster than planned, and
	#    the traversal reports the speed it was *planned* at. Feeding the rig that
	#    number would slide the feet by exactly the difference.
	_drive_body((position_of() - before) / maxf(delta, 1e-5))
	if _can_tick:
		creature.call("tick", delta)
	_write_body_position(position_of())
	_publish_to_vfx()


## Turn the brain's move target into a navigator goal.
##
## The navigator is deliberately not asked to re-solve every frame: it keeps a
## stable plan and only disturbs it when the goal genuinely moved. What this adds
## on top is the same discipline for the *brain's* side of the contract, because
## a behaviour that re-asserts its target sixty times a second is not asking for
## sixty different journeys.
func _follow_intent(delta: float) -> void:
	_plan_cooldown = maxf(0.0, _plan_cooldown - delta)
	var brain := _brain()
	if brain == null or navigator == null:
		return
	var intent: Object = brain.ctx.intent
	if not bool(intent.get("has_move_target")):
		# Nothing being asked for. Whatever plan is already running is played out
		# rather than abandoned: the navigator only ever comes to rest standing on
		# a ledge, and a pet that freezes mid-stride — or worse, mid-arc — is the
		# single most obviously fake thing a desktop pet can do. The behaviour
		# that stopped asking gets the body back the moment the last leg lands,
		# which is at most a couple of seconds and reads as "it finished crossing
		# the icon, then curled up".
		return

	var raw: Variant = intent.get("move_target")
	if not (raw is Vector2):
		return
	var target: Vector2 = raw
	if _goal != Vector2.INF and target.distance_to(_goal) <= GOAL_EPS:
		if _travelling() or _goal_settled:
			return
	if _plan_cooldown > 0.0 or _committed():
		return
	_goal = target
	_goal_settled = false
	_plan_cooldown = PLAN_INTERVAL
	stats[&"plans"] = int(stats[&"plans"]) + 1
	if not bool(navigator.call("travel_to_point", target)):
		# `path_failed` has already fired and been counted; settling the goal is
		# what stops the pet re-asking for an impossible journey every 0.28 s.
		_goal_settled = true


## How much faster than planned to play the current move. Only walking is scaled:
## a jump arc is physics the planner validated, and speeding it up would land the
## pet somewhere the graph never promised.
func _pace_scale() -> float:
	var brain := _brain()
	if brain == null or not _travelling():
		return 1.0
	if _traversal_phase() != &"walk":
		return 1.0
	return clampf(_num(brain.ctx.intent, "speed_scale", 1.0), 0.35, MAX_PACE)


## Feed the body what it needs to look like it is doing the move: heading, ground
## speed, gait family, and the one-shot reactions at the beats that need them.
## Tell the audio layer which ledge the pet is standing on. Cheap, and only
## when it changes — the navigator is the only thing that knows.
func _report_surface() -> void:
	var id: int = int(navigator.get("current_ledge"))
	if id == _reported_ledge:
		return
	_reported_ledge = id
	var ledge: Variant = DesktopBridge.ledge_by_id(id)
	AudioDirector.set_surface(record.id, ledge.kind if ledge != null else &"")


func _drive_body(velocity: Vector2) -> void:
	var travelling := _travelling()
	var traversal: Object = navigator.get("traversal") if navigator != null else null
	var airborne: bool = travelling and traversal != null and bool(traversal.get("airborne"))
	var v_rig: float = (velocity.length() / _px) if travelling else 0.0

	if travelling and traversal != null:
		creature.set("facing", _num(traversal, "facing", 1.0))
		if airborne:
			_air_velocity = velocity

	# Airborne, the arc *is* the animation: the legs tuck and the squash comes
	# from the jump/land reactions rather than from a cycling gait.
	var want_gait: StringName = &"idle" if airborne else &""
	if want_gait != _gait_override and _can_gait and creature.get("rig") != null:
		_gait_override = want_gait
		creature.call("set_gait", want_gait)

	if travelling and not airborne and v_rig > 0.01:
		if _can_speed:
			creature.set("speed", v_rig)
		if _can_move:
			var heading := velocity.normalized() if velocity.length() > 1.0 \
				else Vector2(_num(creature, "facing", 1.0), 0.0)
			var ahead := position_of() + heading * _stride_px * LOOKAHEAD_STRIDES
			creature.call("move_to", ahead - _window_origin(), _pace_for(v_rig))
	else:
		if not travelling and _can_speed:
			creature.set("speed", 0.0)
		if _can_stop:
			creature.call("stop")

	var phase: StringName = _traversal_phase() if travelling else &"idle"
	if phase != _phase:
		_on_phase_changed(phase, traversal)
		_phase = phase


## The beats a move has that a position curve cannot express on its own.
func _on_phase_changed(phase: StringName, traversal: Object) -> void:
	match phase:
		&"air":
			var effort: float = clampf(_air_velocity.length() / maxf(_run_px(), 1.0), 0.3, 1.4)
			_react(&"jump", effort)
			_vfx_call("took_off", [record.id, creature.global_position, _air_velocity])
		&"land":
			var impact: float = clampf(absf(_air_velocity.y) / maxf(_run_px(), 1.0), 0.15, 1.2)
			_react(&"land", 0.6 + impact)
			_vfx_call("landed", [record.id, creature.global_position, _air_velocity])
			_foley(&"land", clampf(0.25 + impact, 0.0, 1.0))
		&"grab":
			# Catching an edge is a whole-body effort; perking the ears reads as
			# the animal committing to the haul rather than sliding up the wall.
			_react(&"perk", 0.7)
	if traversal != null and phase != &"air":
		_air_velocity = Vector2.ZERO


func _on_footfall(_slot: int, force: float) -> void:
	var speed_norm: float = clampf(_num(creature, "speed", 0.0) / _run_rig(), 0.0, 1.6)
	_vfx_call("footfall", [record.id, creature.global_position, speed_norm,
		_num(creature, "facing", 1.0)])
	_foley(&"step", clampf(0.15 + 0.5 * force, 0.0, 1.0))


# ---------------------------------------------------------------------------
# Presentation hookup
# ---------------------------------------------------------------------------

## Register with the VFX director, when there is one. Sizes come from the body
## the pet actually has, so a kitten's dust puff is a kitten's.
func attach_vfx(director: Node) -> void:
	_vfx = director
	if _vfx == null or not _vfx.has_method("register_pet") or creature == null:
		return
	var box := _body_box_rig()
	_vfx.call("register_pet", record.id, creature, {
		"renderer": creature.get("renderer"),
		"px_per_unit": _px,
		"radius": maxf(box.size.y * 0.5 * _px, 8.0),
		"width": maxf(box.size.x * 0.5 * _px, 8.0),
		"coat": _coat_colour(),
		"facing": 1.0,
	})


func detach_vfx() -> void:
	if _vfx != null and _vfx.has_method("unregister_pet"):
		_vfx.call("unregister_pet", record.id)
	_vfx = null


func _publish_to_vfx() -> void:
	if _vfx == null or not _vfx.has_method("update_pet"):
		return
	_vfx.call("update_pet", record.id, {
		"facing": _num(creature, "facing", 1.0),
		"wetness": _num(creature, "wetness", 0.0),
	})


func _vfx_call(method: String, args: Array) -> void:
	if _vfx != null and _vfx.has_method(method):
		_vfx.callv(method, args)


## Foley, probed the same way as everything else this file reaches for. The
## audio layer is an autoload rather than a script loaded by path, but it is
## being rewritten in parallel just like `core/`, and a footfall must never be
## the thing that takes a frame down.
func _foley(foley_id: StringName, intensity: float) -> void:
	var audio := get_node_or_null(^"/root/AudioDirector")
	if audio != null and audio.has_method("foley"):
		audio.call("foley", foley_id, intensity)


# ---------------------------------------------------------------------------
# Interaction surface
# ---------------------------------------------------------------------------

## True while the player is holding the pet. The drag simulation owns the body
## then, and nothing else may move it.
func is_carried() -> bool:
	return _is_carried()


## Is the pointer over this pet right now? Used by the window layer to decide
## whether the cursor belongs to the pet or to the desktop underneath.
func contains_point(screen_point: Vector2) -> bool:
	if creature == null:
		return false
	if creature.has_method("contains_point"):
		return bool(creature.call("contains_point", screen_point - _window_origin()))
	return hit_rect().has_point(screen_point)


## Drive time in the pet's mind from the caller rather than from the wall clock,
## and stop the router reading the real pointer. The world test and the capture
## harness both need a pet whose week is reproducible.
func set_simulated(on: bool) -> void:
	var brain := _brain()
	if brain != null:
		brain.set("autonomous_senses", not on)
	var router := _router()
	if router != null:
		router.set("read_display_pointer", not on)


## Ask for a specific behaviour by id. The radial menu knows things the scoring
## pass cannot infer — that the player just chose "sleep", say.
func provoke(behaviour_id: StringName) -> bool:
	var brain := _brain()
	if brain == null or not brain.has_method("provoke"):
		return false
	return bool(brain.call("provoke", behaviour_id))


func offer_toy(toy_id: StringName, at: Vector2) -> void:
	var brain := _brain()
	if brain != null and brain.has_method("offer_toy"):
		brain.call("offer_toy", toy_id, at)


func react(reaction: StringName, intensity: float = 1.0) -> void:
	_react(reaction, intensity)


## One line for the diagnostics overlay: what this pet is doing and where.
func debug_line() -> String:
	var brain := _brain()
	var behaviour := &"-"
	if brain != null and brain.get("current") != null:
		behaviour = brain.get("current").get("id")
	return "%s  %s  %s  (%.0f, %.0f)  plans %d  arrivals %d  fails %d" % [
		GameState.display_name(record), record.mood, behaviour,
		position_of().x, position_of().y,
		int(stats[&"plans"]), int(stats[&"arrivals"]), int(stats[&"failures"])]


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _on_arrived(ledge_id: int) -> void:
	_goal_settled = true
	if _settling:
		return
	stats[&"arrivals"] = int(stats[&"arrivals"]) + 1
	# Did it actually end up standing on the thing it planned for? Measuring the
	# distance from the feet to that ledge's surface is the only honest answer,
	# and it is the assertion the world test hangs its nav check on.
	if navigator == null:
		return
	var graph: Object = navigator.get("graph")
	if graph == null or not graph.has_method("ledge"):
		return
	var ledge: Object = graph.call("ledge", ledge_id)
	if ledge == null or not ledge.has_method("surface_point"):
		return
	var here: Vector2 = position_of()
	var err: float = here.distance_to(ledge.call("surface_point", here.x))
	stats[&"worst_arrival_error"] = maxf(float(stats[&"worst_arrival_error"]), err)


func _on_path_failed(reason: StringName) -> void:
	_goal_settled = true
	stats[&"failures"] = int(stats[&"failures"]) + 1
	Log.debug("PetHost", "%s could not route: %s" % [record.id, reason])


func _stop_route() -> void:
	if navigator != null and navigator.has_method("stop"):
		navigator.call("stop")
	_goal = Vector2.INF
	_goal_settled = true


func _travelling() -> bool:
	return navigator != null and navigator.has_method("is_travelling") \
		and bool(navigator.call("is_travelling"))


func _committed() -> bool:
	if navigator == null:
		return false
	var t: Object = navigator.get("traversal")
	return t != null and t.has_method("is_committed") and bool(t.call("is_committed"))


func _traversal_phase() -> StringName:
	if navigator == null:
		return &"idle"
	var t: Object = navigator.get("traversal")
	if t == null:
		return &"idle"
	return StringName(String(t.get("phase")))


func _is_carried() -> bool:
	var router := _router()
	return router != null and router.has_method("is_carrying") \
		and bool(router.call("is_carrying"))


func _write_body_position(screen_point: Vector2) -> void:
	if creature != null:
		creature.global_position = screen_point - _window_origin()


func _react(reaction: StringName, intensity: float) -> void:
	if _can_react and creature.get("rig") != null:
		creature.call("play_reaction", reaction, intensity)


## Convert a ground speed in rig units per second into `Creature`'s walk-to-run
## pace, so the body's own speed ramp settles exactly on what the navigator is
## doing instead of fighting it.
func _pace_for(v_rig: float) -> float:
	var walk: float = _num(spec, "walk_speed", 0.9)
	var run: float = _num(spec, "run_speed", 2.6)
	return clampf((v_rig - walk) / maxf(run - walk, 0.001), 0.0, 1.0)


func _run_rig() -> float:
	return maxf(_num(spec, "run_speed", 2.6), 0.01)


func _run_px() -> float:
	return _run_rig() * _px


func _brain() -> Node:
	if mind == null:
		return null
	var b: Variant = mind.get("brain")
	return b if b is Node else null


func _router() -> Node:
	if mind == null:
		return null
	var r: Variant = mind.get("router")
	return r if r is Node else null


## Rig-space bounding box of the body, for hit rectangles and effect sizing.
## `BodyMap` already computes it from the grown bind pose; falling back to a
## plausible box keeps the pet clickable even before the mind exists.
func _body_box_rig() -> Rect2:
	var router := _router()
	if router != null:
		var body: Variant = router.get("body")
		if body != null and body.has_method("bounds_rig"):
			return body.call("bounds_rig", record.growth)
	return Rect2(-0.75, -1.15, 1.5, 1.2)


func _coat_colour() -> Color:
	if spec != null and spec.has_method("palette_color"):
		return spec.call("palette_color", 0)
	return Color(0.44, 0.35, 0.29)


## Read a number off an object that may not have the property. Every file this
## one talks to is being edited in parallel; a field that has not landed yet must
## degrade to a sensible default rather than take the frame down with it.
static func _num(o: Object, prop: String, def: float) -> float:
	if o == null:
		return def
	var v: Variant = o.get(prop)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return def


## Where the game window sits on the desktop. The brain, the ledge graph and the
## pointer are all in screen space; nodes live in the window's viewport.
static func _window_origin() -> Vector2:
	return Vector2(DisplayServer.window_get_position())
