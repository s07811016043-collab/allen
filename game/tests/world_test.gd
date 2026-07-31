extends Node

## Boots the assembled game headless and runs it.
##
##     .tools/Godot_v4.5-stable_linux.x86_64 --path game --headless \
##         res://tests/world_test.tscn
##
## Prints one line per check and a final WORLD_TEST PASS/FAIL, and sets the exit
## code, so it can be dropped into CI as-is.
##
## The other two test scenes check components: `nav_test` proves the pathfinder
## can route across a desktop, `test_mind` proves the simulation and the touch
## model behave. Neither of them ever builds a game. This one does — it
## instantiates `scenes/world.tscn` exactly as `boot.gd` does, then drives it for
## several simulated minutes and asks the questions you can only ask of the whole
## thing assembled:
##
##   * does it come up at all, and adopt a pet for a first-time player?
##   * does anything log an error over thousands of frames?
##   * does the pet stay somewhere it is allowed to be?
##   * does it actually travel, and end up on the surfaces it planned for?
##   * does the body end up where the navigator says the pet is?
##   * does the mind keep changing its mind?
##   * does the desktop moving under it leave it stranded?
##   * does what happens survive being saved and loaded back?
##
## Determinism: `Clock.time_scale` is zeroed so the real clock cannot interfere,
## every pet is put in simulated mode so its brain's time and senses are inputs
## rather than readings, and the world is stepped by hand at a fixed 60 Hz. The
## desktop is `DesktopBridge`'s own simulated layout, which is what a player with
## no native provider actually gets and is fixed geometry under the headless
## display server.

const WORLD_SCENE := "res://scenes/world.tscn"

const DT := 1.0 / 60.0
## Simulated minutes of play. Long enough for a utility AI with multi-second
## commitments to change its mind several times and cross the desktop more than
## once; short enough to stay a test rather than a soak.
const MINUTES := 5.0
const HOUR := 3600.0
## Age the starter is run at. A newborn covers about 65 px a second and would
## spend the whole run walking to its first icon, which measures the growth curve
## rather than the game; two-and-a-bit stages is where a pet spends its life.
const RUN_AT_GROWTH := 2.6

## A frame that moves the pet further than this is a teleport, and teleports are
## the failure this whole stack exists to avoid. Generous — it has to cover a
## drop at terminal velocity — because the point is to catch a snap, not to
## re-derive the physics `nav_test` already pins down.
const TELEPORT_LIMIT := 90.0
## How far outside the allowed area a pet may be before the world is expected to
## have put it back. Matches `PetaliaWorld.STRAY_MARGIN`, plus a frame of slack.
const STRAY_TOLERANCE := 110.0

var _passed := 0
var _failed := 0
var _notes := PackedStringArray()

## The developer's real pet lives in the same `user://` directory this runs in.
## Snapshot it, and put it back whatever happens.
var _had_save := false
var _snapshot := {}
var _log_mark := 0

var _behaviours := {}
var _ledges_visited := {}


func _ready() -> void:
	Clock.time_scale = 0.0
	Log.min_level = Log.Level.INFO
	seed(20250731)
	_had_save = FileAccess.file_exists(SaveSystem.SAVE_PATH)
	_snapshot = GameState.serialise()
	_log_mark = Log.history.size()

	DesktopBridge.rescan()
	_check(DesktopBridge.ledges.size() > 8,
		"the desktop offers somewhere to live", str(DesktopBridge.ledges.size()))

	# A first-time player: no save, no pets. The world is expected to fix that
	# before anyone sees an empty screen.
	GameState.pets.clear()
	var world: PetaliaWorld = _boot()
	if world == null:
		_finish()
		return

	_check(GameState.pets.size() == 1, "an empty save adopts a starter pet",
		str(GameState.pets.size()))
	_check(world.hosts.size() == 1, "and the world builds a body for it",
		str(world.hosts.size()))
	if world.hosts.is_empty():
		_finish()
		return

	var host: PetHost = world.hosts[0]
	_check(host.creature != null, "the pet has a creature")
	_check(host.mind != null and host.mind.get("brain") != null, "and a brain")
	_check(host.navigator != null, "and a route through the desktop")
	_check(_allowed_rect().has_point(host.position_of()),
		"it is spawned somewhere it can stand", str(host.position_of()))

	host.record.growth = RUN_AT_GROWTH

	_watch_bus()
	var run := _drive(world, host, MINUTES * 60.0)
	_unwatch_bus()

	_assert_run(host, run)
	_assert_directed_journey(world, host)
	_assert_pick_up_and_drop(world, host)
	_assert_save_round_trip(world, host)
	_finish()


# --- Harness -----------------------------------------------------------------

func _boot() -> PetaliaWorld:
	if not ResourceLoader.exists(WORLD_SCENE):
		_check(false, "the world scene exists", WORLD_SCENE)
		return null
	var scene: PackedScene = load(WORLD_SCENE)
	var world: PetaliaWorld = scene.instantiate()
	# Injected before `_ready` so the world never falls back to looking the
	# autoload up itself, and so a future test can hand it a different desktop.
	world.desktop = DesktopBridge
	add_child(world)
	# Everything from here is driven by hand: the engine never gets a frame while
	# this test runs, so nothing may depend on `_process` being called.
	world.set_process(false)
	world.set_simulated(true)
	if world.vfx != null:
		world.vfx.set_process(false)
	return world


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s%s" % [what, "" if detail.is_empty() else "  <- " + detail])
		_notes.append(what if detail.is_empty() else "%s: %s" % [what, detail])
	return ok


func _finish() -> void:
	_restore_save()
	print("")
	for note in _notes:
		print("  ! %s" % note)
	print("WORLD_TEST %s  (%d passed, %d failed)"
		% ["PASS" if _failed == 0 else "FAIL", _passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _restore_save() -> void:
	GameState.pets.clear()
	if _had_save:
		GameState.deserialise(_snapshot)
		SaveSystem.save(_snapshot)
	else:
		SaveSystem.wipe()


func _watch_bus() -> void:
	EventBus.behaviour_changed.connect(_on_behaviour_changed)
	EventBus.pet_reached_ledge.connect(_on_reached_ledge)


func _unwatch_bus() -> void:
	EventBus.behaviour_changed.disconnect(_on_behaviour_changed)
	EventBus.pet_reached_ledge.disconnect(_on_reached_ledge)


func _on_behaviour_changed(_pet_id: StringName, behaviour_id: StringName,
		_previous: StringName) -> void:
	_behaviours[behaviour_id] = int(_behaviours.get(behaviour_id, 0)) + 1


func _on_reached_ledge(_pet_id: StringName, ledge_id: int) -> void:
	_ledges_visited[ledge_id] = true


# --- The run -----------------------------------------------------------------

## Drive the world at a fixed step, feeding it a plausible player, and watch for
## the failure modes that only show up over thousands of frames.
func _drive(world: PetaliaWorld, host: PetHost, seconds: float) -> Dictionary:
	var frames: int = int(seconds / DT)
	var allowed := _allowed_rect()
	var last := host.position_of()
	var travelled := 0.0
	var worst_step := 0.0
	var worst_stray := 0.0
	var worst_body_gap := 0.0
	var saw_nan := false
	var moved_desktop := false
	var t := 0.0

	for i in frames:
		t += DT
		_drive_senses(host, t)
		# A slice of the pet's day every simulated minute, so growth, mood and the
		# need clocks are exercised rather than frozen at their starting values.
		if i > 0 and i % int(60.0 / DT) == 0:
			GameState.advance(host.record, HOUR, true)
		# Halfway through, rearrange the desktop under the animal: drag every icon
		# sideways and close the window it might be standing on. This is the
		# normal case for a desktop pet, not an edge case.
		if not moved_desktop and i == frames / 2:
			moved_desktop = true
			_rearrange_desktop()
			allowed = _allowed_rect()

		world.step(DT)

		var p := host.position_of()
		if is_nan(p.x) or is_nan(p.y) or is_inf(p.x) or is_inf(p.y):
			saw_nan = true
			break
		worst_step = maxf(worst_step, p.distance_to(last))
		travelled += p.distance_to(last)
		last = p
		worst_stray = maxf(worst_stray, _outside_by(allowed, p))
		if host.creature != null:
			worst_body_gap = maxf(worst_body_gap,
				(host.creature.global_position + _window_origin()).distance_to(p))

	return {
		"travelled": travelled, "worst_step": worst_step, "worst_stray": worst_stray,
		"worst_body_gap": worst_body_gap, "nan": saw_nan, "moved_desktop": moved_desktop,
		"frames": frames,
	}


## The half of the brain's senses that normally come from the display server.
## With `autonomous_senses` off these are inputs, which is what makes the run
## reproducible — and it lets the test put the player somewhere specific.
func _drive_senses(host: PetHost, t: float) -> void:
	var ctx: Object = host.mind.brain.ctx
	# Mid-afternoon drifting toward evening, so the circadian term in behaviour
	# scoring actually moves over the run.
	ctx.set("hour", 14.0 + t / 120.0)
	ctx.set("player_present", true)
	ctx.set("cursor_idle", 0.5)
	var cursor := Vector2(960.0 + cos(t * 0.35) * 520.0, 640.0 + sin(t * 0.27) * 240.0)
	ctx.set("cursor", cursor)
	ctx.set("cursor_speed", 180.0)


## Drag the icons and close a window while the pet is living on them.
func _rearrange_desktop() -> void:
	var kept: Array = []
	var dropped := 0
	for l in DesktopBridge.ledges:
		if l.kind == &"window_top" and dropped == 0:
			dropped += 1
			continue
		if l.kind == &"icon":
			l.rect.position.x += 44.0
		kept.append(l)
	DesktopBridge.ledges.clear()
	for i in kept.size():
		kept[i].id = i
		DesktopBridge.ledges.append(kept[i])
	DesktopBridge.topology_revision += 1
	EventBus.desktop_topology_changed.emit()


# --- Assertions --------------------------------------------------------------

func _assert_run(host: PetHost, run: Dictionary) -> void:
	# Printed whether or not anything failed: when a behavioural test does fail,
	# the first question is always "what was the pet actually doing".
	print("  note %d plans, %d arrivals, %d unroutable; %.0f px travelled"
		% [int(host.stats[&"plans"]), int(host.stats[&"arrivals"]),
			int(host.stats[&"failures"]), run["travelled"]])
	print("  note behaviours: %s" % str(_behaviours))

	_check(not bool(run["nan"]), "no NaN or infinite positions were produced")
	_check(bool(run["moved_desktop"]), "the fixture really did rearrange the desktop")

	var errors := _log_lines("[ERR]")
	_check(errors.is_empty(), "%d frames without a logged error" % int(run["frames"]),
		"\n      ".join(errors))
	var warnings := _log_lines("[WRN]")
	if not warnings.is_empty():
		# Not a failure — some warnings are a subsystem telling you it is
		# degrading on purpose — but they must never be invisible.
		print("  note %d warning(s) logged:" % warnings.size())
		for w in warnings:
			print("       %s" % w)

	_check(float(run["travelled"]) > 400.0,
		"the pet actually goes places", "%.0f px travelled" % run["travelled"])
	_check(float(run["worst_step"]) <= TELEPORT_LIMIT,
		"no frame teleports the pet",
		"worst %.1f px, limit %.1f" % [run["worst_step"], TELEPORT_LIMIT])
	_check(float(run["worst_stray"]) <= STRAY_TOLERANCE,
		"the pet stays inside the desktop it is allowed",
		"%.1f px outside" % run["worst_stray"])
	_check(float(run["worst_body_gap"]) < 1.0,
		"the drawn body is where the navigator says the pet is",
		"%.2f px apart" % run["worst_body_gap"])

	_check(int(host.stats[&"arrivals"]) > 0,
		"the pet completes journeys", "%d arrivals in %d plans"
			% [int(host.stats[&"arrivals"]), int(host.stats[&"plans"])])
	_check(float(host.stats[&"worst_arrival_error"]) < 8.0,
		"and ends up standing on the ledge it planned for",
		"%.1f px off" % host.stats[&"worst_arrival_error"])
	_check(_ledges_visited.size() >= 2,
		"it reaches more than one surface", "%d distinct ledges" % _ledges_visited.size())

	_check(_behaviours.size() >= 2, "the mind changes its mind over time",
		str(_behaviours.keys()))
	_check(int(host.stats[&"frames"]) == int(run["frames"]),
		"every frame reached the pet",
		"%d of %d" % [int(host.stats[&"frames"]), int(run["frames"])])


## The free run proves the pet decides to go places; whether it gets there is up
## to whatever a cat felt like doing that minute. This pins the other half down:
## the mind is lifted out for a moment and the navigator is pointed at a named
## icon, so what is being measured is the world's plan-move-draw pipeline rather
## than the AI's taste in destinations.
func _assert_directed_journey(world: PetaliaWorld, host: PetHost) -> void:
	var mind := host.mind
	host.mind = null

	# Re-anchor first: this also forces the ledge graph to be rebuilt against the
	# desktop as it is now, which is what `reachable_from` reads.
	host.navigator.call("place", host.position_of())
	var goal: Object = _pick_goal(host)
	if not _check(goal != null, "the desktop offers a reachable icon to walk to"):
		host.mind = mind
		return

	var arrivals_before: int = int(host.stats[&"arrivals"])
	_check(bool(host.navigator.call("travel_to_ledge", goal.id, 0.5)),
		"the world plans a route to '%s'" % goal.label)
	var elapsed := 0.0
	while elapsed < 60.0 and bool(host.navigator.call("is_travelling")):
		world.step(DT)
		elapsed += DT
	_check(int(host.stats[&"arrivals"]) > arrivals_before,
		"and the pet walks it all the way to the end", "gave up after %.1f s" % elapsed)
	var here: Vector2 = host.position_of()
	var off: float = here.distance_to(goal.surface_point(here.x))
	_check(off < 8.0, "finishing standing on the surface it aimed for",
		"%.1f px off" % off)
	_check((host.creature.global_position + _window_origin()).distance_to(here) < 1.0,
		"with the body drawn where it finished")

	host.mind = mind


## The furthest icon the pet can genuinely get to from where it is standing.
## Furthest, because a route with jumps and climbs in it is the one worth
## executing; `LedgeGraph` decides what "can get to" means.
func _pick_goal(host: PetHost) -> Object:
	var graph: Object = host.navigator.get("graph")
	if graph == null:
		return null
	var here: Vector2 = host.position_of()
	var best: Object = null
	var best_d := -1.0
	for id in graph.call("reachable_from", host.navigator.get("current_ledge")):
		var l: Object = graph.call("ledge", id)
		if l == null or l.kind != &"icon":
			continue
		var d: float = here.distance_to(l.center_top())
		if d > best_d:
			best_d = d
			best = l
	return best


## Input, end to end. The pointer goes in, `PetGesture` decides the press is a
## deliberate hold, `DragBody` carries the animal, and when it is let go the
## navigator takes the body back and puts it on a surface.
##
## This is the one path where three systems each own the transform for a while,
## so it is worth asserting through the assembled world rather than in isolation:
## `test_mind` already proves the router works, and cannot prove the hand-off.
func _assert_pick_up_and_drop(world: PetaliaWorld, host: PetHost) -> void:
	var router: Node = host.mind.router
	var counts := {"grabbed": 0, "landed": 0}
	var on_grab := func(_id: StringName) -> void: counts["grabbed"] += 1
	var on_land := func(_id: StringName, _i: float, _u: bool) -> void: counts["landed"] += 1
	EventBus.pet_grabbed.connect(on_grab)
	EventBus.pet_landed.connect(on_land)

	var grip: Vector2 = host.hit_rect().get_center()
	router.set("pointer", grip)
	router.call("press")
	_check(String(router.call("current_region")) != "",
		"the pointer lands on a body region", "grip %s" % grip)
	for i in 40:
		world.step(DT)
	_check(int(counts["grabbed"]) == 1, "holding still on the body picks the pet up",
		str(counts["grabbed"]))
	_check(host.is_carried(), "and the world knows it is being carried")

	# Lift it clear of the floor, then let go.
	for i in 60:
		router.set("pointer", grip + Vector2(float(i + 1) * 1.5, float(i + 1) * -4.0))
		world.step(DT)
	router.call("release")
	var frames := 0
	while host.is_carried() and frames < 900:
		world.step(DT)
		frames += 1
	_check(int(counts["landed"]) == 1, "and letting go drops it exactly once",
		str(counts["landed"]))

	world.step(DT)  # the frame on which the host takes the body back
	_check(int(host.navigator.get("current_ledge")) >= 0,
		"the navigator has the pet on a surface again",
		str(host.navigator.get("current_ledge")))
	var here: Vector2 = host.position_of()
	_check((host.creature.global_position + _window_origin()).distance_to(here) < 1.0,
		"the body is back under the navigator's control")
	_check(_allowed_rect().grow(STRAY_TOLERANCE).has_point(here),
		"having come down somewhere it is allowed to be", str(here))
	_check(absf(host.creature.rotation) < 1e-4, "and standing upright again",
		"%.3f rad" % host.creature.rotation)

	EventBus.pet_grabbed.disconnect(on_grab)
	EventBus.pet_landed.disconnect(on_land)


## The one thing that must survive a crash: the pet. Exercised through the
## world's own exit path rather than by calling `SaveSystem` directly, because
## "does it save when it goes away" is the part that actually breaks.
func _assert_save_round_trip(world: PetaliaWorld, host: PetHost) -> void:
	var record = host.record
	GameState.rename(record, "Wollemi")
	GameState.note(record, &"world_test", "It walked the taskbar for you.")
	var growth: float = record.growth
	var affection: float = record.affection
	var journal: int = record.journal.size()
	var pet_id: StringName = record.id

	# Leaving the tree is what happens when the app quits.
	remove_child(world)
	world.free()

	GameState.pets.clear()
	var payload := SaveSystem.load_save()
	_check(not payload.is_empty(), "leaving the tree wrote a save")
	GameState.deserialise(payload)
	_check(GameState.pets.size() == 1, "the pet comes back", str(GameState.pets.size()))
	if GameState.pets.is_empty():
		return
	var back = GameState.pets[0]
	_check(back.id == pet_id, "with the same identity", String(back.id))
	_check(back.nickname == "Wollemi", "and its name", back.nickname)
	_check(absf(back.growth - growth) < 1e-3, "and its age",
		"%.4f vs %.4f" % [back.growth, growth])
	_check(absf(back.affection - affection) < 1e-3, "and the bond it earned",
		"%.4f vs %.4f" % [back.affection, affection])
	_check(back.journal.size() == journal, "and everything it remembers",
		"%d vs %d" % [back.journal.size(), journal])


# --- Helpers -----------------------------------------------------------------

## Everywhere a pet is allowed to be: the work area plus every surface the
## desktop offers. Computed the same way `PetaliaWorld._allowed_rect` does,
## because that is the contract being asserted.
func _allowed_rect() -> Rect2:
	var r: Rect2 = DesktopBridge.work_area
	for l in DesktopBridge.ledges:
		r = r.merge(l.rect)
	return r


static func _outside_by(rect: Rect2, p: Vector2) -> float:
	return maxf(maxf(rect.position.x - p.x, p.x - rect.end.x),
		maxf(rect.position.y - p.y, p.y - rect.end.y))


func _log_lines(level: String) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(_log_mark, Log.history.size()):
		if Log.history[i].begins_with(level):
			out.append(Log.history[i])
	return out


static func _window_origin() -> Vector2:
	return Vector2(DisplayServer.window_get_position())
