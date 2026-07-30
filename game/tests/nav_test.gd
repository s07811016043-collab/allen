extends Node

## Headless exercise of the ledge graph, the pathfinder and the traversal
## executor against a synthetic desktop.
##
##   .tools/Godot_v4.5-stable_linux.x86_64 --path game --headless \
##       res://tests/nav_test.tscn
##
## Prints one line per check and a final NAV_TEST PASS/FAIL, and sets the exit
## code, so it can be dropped into CI as-is.
##
## The desktop here is synthetic rather than DesktopBridge's, because the point
## is to test reachability against a layout with *known* answers: an icon column
## a ground animal can climb one hop at a time, a window only a climber can get
## onto, and an island only a flier can reach. The live bridge is checked
## separately at the end, and only for the things that must be true everywhere.

const SCREEN := Rect2(0, 0, 1920, 1080)
const WORK := Rect2(0, 0, 1920, 1040)
const DT := 1.0 / 60.0

## Minimal stand-in for CreatureSpec. Deliberately not the real cat: species
## files are edited by other agents, and a nav regression should not be
## indistinguishable from someone retuning a jump height.
class FakeSpec:
	extends RefCounted
	var pixels_per_unit := 180.0
	var adult_height := 1.0
	var walk_speed := 0.9
	var run_speed := 2.6
	var jump_height := 1.4
	var can_climb := false
	var can_fly := false

	func scale_at(_growth: float) -> float:
		return 1.0


## Duck-typed desktop the navigator can be pointed at, so a re-plan can be
## triggered by editing this rather than by moving a real window.
class FakeDesktop:
	extends RefCounted
	var ledges: Array[NavLedge] = []
	var topology_revision := 1

	func get_ledges() -> Array:
		return ledges

	func get_topology_revision() -> int:
		return topology_revision

	func by_key(key: String) -> NavLedge:
		for l in ledges:
			if l.key == key:
				return l
		return null

	func drop(key: String) -> void:
		for i in ledges.size():
			if ledges[i].key == key:
				ledges.remove_at(i)
				break
		renumber()

	func renumber() -> void:
		for i in ledges.size():
			ledges[i].id = i
		topology_revision += 1


var _passed := 0
var _failed := 0
var _fail_notes := PackedStringArray()


func _ready() -> void:
	var desk := _build_desktop()
	_test_graph_builds(desk)
	_test_ground_animal(desk)
	_test_climber(desk)
	_test_flier(desk)
	_test_path_continuity(desk)
	_test_traversal_execution(desk)
	_test_ballistic_execution(desk)
	_test_dropped_pet(desk)
	_test_wander(desk)
	_test_growth_and_dpi()
	_test_determinism(desk)
	_test_replan_on_moved_ledge()
	_test_replan_on_destroyed_goal()
	_test_provider_parsers()
	_test_live_bridge()

	print("")
	for note in _fail_notes:
		print("  ! %s" % note)
	print("NAV_TEST %s  (%d passed, %d failed)"
		% ["PASS" if _failed == 0 else "FAIL", _passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(ok: bool, what: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s%s" % [what, "" if detail.is_empty() else "  <- " + detail])
		_fail_notes.append(what if detail.is_empty() else "%s: %s" % [what, detail])
	return ok


# --- Fixtures ----------------------------------------------------------------

## A desktop with one deliberately reachable route and two deliberately gated
## ones. Icon pitch and window geometry match what the real providers emit.
func _build_desktop() -> FakeDesktop:
	var d := FakeDesktop.new()
	var cell := Vector2(76.0, 90.0)

	# Two icon columns running from the top of the work area down to within one
	# hop of the floor: the ladder a ground animal uses.
	for col in 2:
		for row in 11:
			var l := NavLedge.make(
				Rect2(Vector2(20.0 + col * cell.x, 16.0 + row * cell.y), Vector2(48.0, 48.0)),
				&"icon", "Icon %d-%d" % [col, row], "icon:%d:%d" % [col, row])
			l.climb_left = true
			l.climb_right = true
			d.ledges.append(l)

	# A window whose sides reach the desktop floor. Its title bar is 738 px up:
	# far beyond any jump, and reachable only by walking up the side face.
	for dict in DesktopProvider.window_ledges(Rect2(700, 300, 500, 740), "Editor", "win:editor"):
		d.ledges.append(NavLedge.from_dict(dict))

	# A floating shelf with nothing beneath it and nothing within a leap. Flight
	# is the only way onto it, which is what makes it a useful negative test.
	d.ledges.append(NavLedge.make(Rect2(1600, 200, 120, 20), &"window_top", "Island", "island"))

	d.ledges.append(NavLedge.make(Rect2(0, 1038, 1920, 2), &"screen_floor", "Desktop", "floor"))
	d.ledges.append(NavLedge.make(Rect2(0, 1040, 1920, 40), &"taskbar", "Taskbar", "taskbar"))
	d.renumber()
	d.topology_revision = 1
	return d


func _mobility(climb: bool, fly: bool) -> NavMobility:
	var spec := FakeSpec.new()
	spec.can_climb = climb
	spec.can_fly = fly
	return NavMobility.from_spec(spec, 3.0, 1.0)


## The fastest this animal can legitimately move, in px per frame: terminal
## velocity of its longest survivable drop, plus a full sprint sideways. Any
## frame that beats it is a teleport, which is the failure this whole system
## exists to avoid, so the bound is derived rather than guessed.
static func _teleport_limit(mob: NavMobility) -> float:
	return (sqrt(2.0 * mob.gravity * mob.max_drop) + mob.run_speed) * DT + 2.0


func _graph_for(desk: FakeDesktop, mob: NavMobility) -> LedgeGraph:
	var g := LedgeGraph.new()
	g.build(desk.ledges, mob, desk.topology_revision)
	return g


func _navigator_for(desk: FakeDesktop, mob: NavMobility) -> Navigator:
	var nav := Navigator.new()
	nav.set_world(desk)
	nav.set_mobility(mob)
	return nav


static func _moves(path: Array) -> Array:
	var out: Array = []
	for s in path:
		out.append(s.move)
	return out


# --- Tests -------------------------------------------------------------------

func _test_graph_builds(desk: FakeDesktop) -> void:
	var g := _graph_for(desk, _mobility(false, false))
	_check(g.ledge_count() == desk.ledges.size(), "graph keeps every ledge",
		"%d of %d" % [g.ledge_count(), desk.ledges.size()])
	_check(g.edge_count > 0, "graph produces edges", str(g.edge_count))
	_check(g.ledge_by_key("floor") != null, "ledges are addressable by key")
	var floor_l := g.ledge_by_key("floor")
	var under := g.ledge_under(Vector2(400, 500))
	_check(under != null and under.key == floor_l.key, "ledge_under finds the floor",
		"got %s" % ("null" if under == null else under.key))


func _test_ground_animal(desk: FakeDesktop) -> void:
	var mob := _mobility(false, false)
	var g := _graph_for(desk, mob)
	var floor_l := g.ledge_by_key("floor")
	var target := g.ledge_by_key("icon:0:4")

	var path := g.find_path(Vector2(900, floor_l.top_y()), floor_l.id, target.id)
	_check(not path.is_empty(), "ground animal reaches the icon column")
	_check(NavSegment.Move.JUMP in _moves(path), "route up the column uses jumps",
		_summary(path))
	_check(not (NavSegment.Move.CLIMB_UP in _moves(path)),
		"a non-climber is never given a climb", _summary(path))

	var island := g.ledge_by_key("island")
	var no_path := g.find_path(Vector2(900, floor_l.top_y()), floor_l.id, island.id)
	_check(no_path.is_empty(), "unreachable island is reported unreachable, not faked",
		_summary(no_path))

	var window_top := g.ledge_by_key("win:editor:top")
	var no_climb := g.find_path(Vector2(900, floor_l.top_y()), floor_l.id, window_top.id)
	_check(no_climb.is_empty(), "a window 738 px up is out of reach without climbing",
		_summary(no_climb))


func _test_climber(desk: FakeDesktop) -> void:
	var mob := _mobility(true, false)
	var g := _graph_for(desk, mob)
	var floor_l := g.ledge_by_key("floor")
	var window_top := g.ledge_by_key("win:editor:top")
	var path := g.find_path(Vector2(900, floor_l.top_y()), floor_l.id, window_top.id)
	_check(not path.is_empty(), "climber reaches the window title bar")
	_check(NavSegment.Move.CLIMB_UP in _moves(path), "route uses the window's side face",
		_summary(path))

	# And back down again: descending is a different edge, not the same one run
	# backwards, so it needs its own check.
	var down := g.find_path(window_top.center_top(), window_top.id, floor_l.id)
	_check(not down.is_empty(), "climber can get back down", _summary(down))


func _test_flier(desk: FakeDesktop) -> void:
	var mob := _mobility(false, true)
	var g := _graph_for(desk, mob)
	var floor_l := g.ledge_by_key("floor")
	var island := g.ledge_by_key("island")
	var path := g.find_path(Vector2(1600, floor_l.top_y()), floor_l.id, island.id)
	_check(not path.is_empty(), "flier reaches the island")
	_check(NavSegment.Move.FLY in _moves(path), "island route uses flight", _summary(path))


func _test_path_continuity(desk: FakeDesktop) -> void:
	var mob := _mobility(true, false)
	var g := _graph_for(desk, mob)
	var floor_l := g.ledge_by_key("floor")
	var window_top := g.ledge_by_key("win:editor:top")
	var path := g.find_path(Vector2(120, floor_l.top_y()), floor_l.id, window_top.id)
	if not _check(not path.is_empty(), "continuity fixture produced a path"):
		return
	var worst := 0.0
	for i in range(1, path.size()):
		worst = maxf(worst, path[i - 1].to.distance_to(path[i].from))
	_check(worst < 0.01, "segments join end-to-end with no gaps", "worst %.3f px" % worst)
	var positive := true
	for s in path:
		if s.duration <= 0.0 or is_nan(s.duration):
			positive = false
	_check(positive, "every segment has a positive planned duration")


func _test_traversal_execution(desk: FakeDesktop) -> void:
	var mob := _mobility(true, false)
	var nav := _navigator_for(desk, mob)
	var limit := _teleport_limit(mob)
	var floor_l := desk.by_key("floor")
	nav.place(Vector2(120, floor_l.top_y()))
	var window_top := desk.by_key("win:editor:top")
	if not _check(nav.travel_to_ledge(window_top.id, 0.5), "navigator plans to the window"):
		return

	var result := _drive(nav, 30.0)
	_check(bool(result["arrived"]), "traversal runs the whole plan to completion",
		"stopped after %.1f s, path %s" % [result["elapsed"], nav.path_summary()])
	_check(not bool(result["nan"]), "no NaN or infinite positions were produced")
	_check(float(result["max_step"]) <= limit,
		"no frame teleports the pet",
		"worst %.1f px, limit %.1f" % [result["max_step"], limit])
	# A climb has no ballistic phase at all, so what is checked here is that the
	# executor actually played the climb beats rather than sliding up the wall.
	var phases: Dictionary = result["phases"]
	_check(phases.has(&"climb") and phases.has(&"grab") and phases.has(&"pullup"),
		"climb plays reach, edge-grab and pull-up", str(phases.keys()))
	_check(bool(result["crouch_seen"]), "body compression is driven during the haul")
	var landed := nav.position.distance_to(window_top.surface_point(nav.position.x))
	_check(landed < 4.0, "the pet ends up standing on the destination surface",
		"%.1f px off" % landed)


## The jump is the move the whole graph is gated on, so its execution gets
## checked separately from the climb: the arc must actually leave the ground,
## must go *over* both endpoints, and must land on the surface it promised.
func _test_ballistic_execution(desk: FakeDesktop) -> void:
	var mob := _mobility(false, false)
	var nav := _navigator_for(desk, mob)
	var limit := _teleport_limit(mob)
	var floor_l := desk.by_key("floor")
	nav.place(Vector2(600, floor_l.top_y()))
	var goal := desk.by_key("icon:0:7")
	if not _check(nav.travel_to_ledge(goal.id, 0.5), "ground animal plans up the column"):
		return
	_check(NavSegment.Move.JUMP in _moves(nav.path), "the plan contains jumps",
		nav.path_summary())

	var apex_ok := true
	for s in nav.path:
		if s.move != NavSegment.Move.JUMP:
			continue
		# Screen y grows downward, so a valid arc peaks *above* both ends.
		if s.apex > minf(s.from.y, s.to.y) + 0.01:
			apex_ok = false
	_check(apex_ok, "every planned arc peaks above both of its endpoints")

	var result := _drive(nav, 40.0)
	_check(bool(result["arrived"]), "the pet completes a multi-jump ascent",
		"stopped after %.1f s" % result["elapsed"])
	_check(bool(result["airborne_seen"]), "the pet actually leaves the ground")
	var phases: Dictionary = result["phases"]
	_check(phases.has(&"crouch") and phases.has(&"air") and phases.has(&"land"),
		"jump plays crouch, flight and landing absorb", str(phases.keys()))
	_check(float(result["max_step"]) <= limit, "ballistic motion stays within physics",
		"worst %.1f px, limit %.1f" % [result["max_step"], limit])
	var off := nav.position.distance_to(goal.surface_point(nav.position.x))
	_check(off < 4.0, "the pet lands on the icon it aimed for", "%.1f px off" % off)


## Being dropped by the player is the one time a pet starts in mid-air. It has
## to fall, not snap.
func _test_dropped_pet(desk: FakeDesktop) -> void:
	var mob := _mobility(false, false)
	var nav := _navigator_for(desk, mob)
	nav.place(desk.by_key("icon:0:2").center_top())
	# Held over the middle of the screen and released.
	nav.position = Vector2(500, 500)
	nav.current_ledge = -1
	nav.current_key = ""
	if not _check(nav.fall_to_ground(), "a released pet finds ground beneath it"):
		return
	_check(nav.path.size() == 1 and nav.path[0].move == NavSegment.Move.DROP,
		"the fall is a drop, not a teleport", nav.path_summary())
	var result := _drive(nav, 10.0)
	_check(bool(result["arrived"]), "the fall completes")
	_check(bool(result["airborne_seen"]), "the pet is airborne while falling")
	var floor_l := desk.by_key("floor")
	_check(absf(nav.position.y - floor_l.top_y()) < 2.0, "the pet lands on the floor",
		"y %.1f vs %.1f" % [nav.position.y, floor_l.top_y()])


func _test_wander(desk: FakeDesktop) -> void:
	var nav := _navigator_for(desk, _mobility(false, false))
	nav.place(desk.by_key("floor").center_top())
	var rng := RandomNumberGenerator.new()
	rng.seed = 20250730
	var started := 0
	for attempt in 8:
		if nav.wander(rng):
			started += 1
			var result := _drive(nav, 40.0)
			if not bool(result["arrived"]):
				started = -1000
				break
	_check(started >= 6, "wander keeps picking reachable destinations",
		"completed %d of 8" % started)


## Growth and DPI both scale the pet, and both have to scale its reach with it —
## otherwise a kitten on a 4K screen is asked to make an adult's leap.
func _test_growth_and_dpi() -> void:
	var spec := FakeSpec.new()
	var baby := NavMobility.from_spec(spec, 0.0, 1.0)
	var adult := NavMobility.from_spec(spec, 3.0, 1.0)
	var retina := NavMobility.from_spec(spec, 3.0, 2.0)
	_check(is_equal_approx(baby.jump_height, adult.jump_height),
		"a flat scale_at keeps growth neutral (fixture sanity)")
	_check(is_equal_approx(retina.jump_height, adult.jump_height * 2.0),
		"a 2x display doubles every distance", "%.1f vs %.1f" % [retina.jump_height, adult.jump_height])
	_check(is_equal_approx(retina.jump_reach(0.0), adult.jump_reach(0.0) * 2.0),
		"reach scales with the display too, so the pet clears the same icons")
	_check(adult.jump_reach(adult.jump_height + 1.0) < 0.0,
		"a ledge above the jump ceiling reports as unreachable")
	var sol := adult.solve_jump(Vector2(0, 0), Vector2(60, -40))
	_check(bool(sol.get("ok", false)) and float(sol["apex"]) < -40.0,
		"a short hop still arcs over its landing lip")


func _test_determinism(desk: FakeDesktop) -> void:
	var mob := _mobility(true, false)
	var g := _graph_for(desk, mob)
	var floor_l := g.ledge_by_key("floor")
	var goal := g.ledge_by_key("icon:1:2")
	var a := g.find_path(Vector2(1400, floor_l.top_y()), floor_l.id, goal.id)
	var b := g.find_path(Vector2(1400, floor_l.top_y()), floor_l.id, goal.id)
	var same := a.size() == b.size()
	if same:
		for i in a.size():
			if a[i].move != b[i].move or a[i].to.distance_to(b[i].to) > 0.001:
				same = false
	_check(same, "the same query returns the same route twice")


## The desktop moving under a pet is the normal case, not the exception. The pet
## has to absorb it: keep walking, arrive somewhere sensible, never jump-cut.
func _test_replan_on_moved_ledge() -> void:
	var desk := _build_desktop()
	var mob := _mobility(false, false)
	var limit := _teleport_limit(mob)
	var nav := _navigator_for(desk, mob)
	var floor_l := desk.by_key("floor")
	nav.place(Vector2(1500, floor_l.top_y()))
	var goal := desk.by_key("icon:0:10")
	if not _check(nav.travel_to_ledge(goal.id, 0.5), "plan exists before the desktop moves"):
		return

	# GDScript lambdas capture locals by value, so the trip flag lives in a
	# dictionary — a reference the closure and the caller genuinely share.
	var flag := {"moved": false}
	var result := _drive(nav, 30.0, func() -> void:
		# Drag the destination icon a long way sideways once the pet is under way.
		if not flag["moved"] and nav.position.x < 900.0:
			flag["moved"] = true
			desk.by_key("icon:0:10").rect.position.x += 210.0
			desk.renumber())
	_check(bool(flag["moved"]), "the fixture actually moved the goal mid-path")
	_check(bool(result["arrived"]), "pet still completes the journey after the goal moved",
		"stopped after %.1f s" % result["elapsed"])
	_check(float(result["max_step"]) <= limit,
		"re-planning does not teleport the pet",
		"worst %.1f px, limit %.1f" % [result["max_step"], limit])
	var goal_now := desk.by_key("icon:0:10")
	var off := absf(nav.position.x - goal_now.rect.get_center().x)
	_check(off < 90.0, "pet arrives at where the icon went, not where it was",
		"%.1f px off" % off)


func _test_replan_on_destroyed_goal() -> void:
	var desk := _build_desktop()
	var mob := _mobility(false, false)
	var limit := _teleport_limit(mob)
	var nav := _navigator_for(desk, mob)
	var floor_l := desk.by_key("floor")
	nav.place(Vector2(1500, floor_l.top_y()))
	var goal := desk.by_key("icon:1:10")
	if not _check(nav.travel_to_ledge(goal.id, 0.5), "plan exists before the goal is closed"):
		return

	var flag := {"killed": false, "failed": false}
	nav.path_failed.connect(func(_reason: StringName) -> void: flag["failed"] = true)
	var result := _drive(nav, 30.0, func() -> void:
		if not flag["killed"] and nav.position.x < 1000.0:
			flag["killed"] = true
			desk.drop("icon:1:10"))
	_check(bool(flag["killed"]), "the fixture actually removed the goal mid-path")
	_check(bool(result["arrived"]) or bool(flag["failed"]),
		"a destroyed goal resolves — retargeted or cleanly failed")
	_check(float(result["max_step"]) <= limit,
		"losing the goal does not teleport the pet",
		"worst %.1f px, limit %.1f" % [result["max_step"], limit])
	_check(not nav.is_travelling(), "the navigator does not get stuck travelling forever")


## The native probes cannot run here — there is no Explorer, no Finder and no
## window manager in a Linux container. What *can* be pinned down is the half of
## each provider that is pure text handling, by feeding it exactly what its
## helper emits. That covers the code most likely to rot silently, because
## nobody on this platform ever executes it.
func _test_provider_parsers() -> void:
	var win := Win32DesktopProvider.new()
	var win_out := win._parse("\n".join(PackedStringArray([
		"MONITOR\t0\t0\t1920\t1080\t0\t0\t1920\t1040\t1",
		"TASKBAR\t0\t1040\t1920\t40",
		"WINDOW\t131074\t300\t200\t900\t600\t0\tEditor - notes.md",
		"ICON\t20\t16\t48\t48\tRecycle Bin",
		"NOTE\ticons:UnauthorizedAccessException",
		"",
	])), SCREEN, WORK)
	var win_kinds := _kind_counts(win_out)
	_check(win_kinds.get("icon", 0) == 1, "win32: desktop icons are parsed", str(win_kinds))
	_check(win_kinds.get("window_top", 0) == 1 and win_kinds.get("window_edge", 0) == 2,
		"win32: a window yields a title bar and two climbable faces", str(win_kinds))
	_check(win_kinds.get("taskbar", 0) == 1 and win_kinds.get("screen_floor", 0) == 1,
		"win32: the shell's exact taskbar replaces the derived panel", str(win_kinds))
	_check(win.last_error.contains("UnauthorizedAccess"),
		"win32: a partial failure is reported, not swallowed", win.last_error)
	var icon: NavLedge = null
	for d in win_out:
		if String(d.get("kind", "")) == "icon":
			icon = NavLedge.from_dict(d)
	_check(icon != null and icon.key == "icon:Recycle Bin" and not icon.approximate,
		"win32: icons are keyed by name and reported as measured, not guessed")

	var lin := LinuxDesktopProvider.new()
	var wm := lin._parse_wmctrl("\n".join(PackedStringArray([
		"0x03400003  0 100  50   800  600  host Terminal - bash",
		"0x03600005  0 900  200  600  400  host Firefox",
		"0x02000002 -1 0    0    1920 1080 host Desktop",
	])))
	_check(_kind_counts(wm).get("window_top", 0) == 2,
		"linux: wmctrl columns survive titles containing spaces", str(_kind_counts(wm)))
	_check(_kind_counts(wm).get("window_edge", 0) == 4,
		"linux: the wallpaper window is rejected, real windows are not")

	var xd := lin._parse_xdotool("\n".join(PackedStringArray([
		"WINDOW=12345", "X=100", "Y=50", "WIDTH=800", "HEIGHT=600", "SCREEN=0",
		"WINDOW=67890", "X=900", "Y=200", "WIDTH=600", "HEIGHT=400", "SCREEN=0",
	])))
	_check(_kind_counts(xd).get("window_top", 0) == 2,
		"linux: xdotool shell blocks are split per window", str(_kind_counts(xd)))

	var furniture := DesktopProvider.screen_furniture(SCREEN, Rect2(64, 28, 1856, 1012), 0)
	var f_kinds := _kind_counts(furniture)
	_check(f_kinds.get("menu_bar", 0) == 1 and f_kinds.get("dock", 0) == 1,
		"a work area inset on the top and left becomes a menu bar and a dock",
		str(f_kinds))


static func _kind_counts(dicts: Array) -> Dictionary:
	var out := {}
	for d in dicts:
		var k := String(d.get("kind", "?"))
		out[k] = int(out.get(k, 0)) + 1
	return out


## The live bridge, checked only for invariants that hold on every machine —
## including this one, which has no display server at all.
func _test_live_bridge() -> void:
	var bridge := get_node_or_null(^"/root/DesktopBridge")
	if not _check(bridge != null, "DesktopBridge autoload is present"):
		return
	_check(not bridge.get_ledges().is_empty(), "bridge always offers somewhere to stand")
	var before: int = bridge.get_topology_revision()
	bridge.rescan()
	bridge.rescan()
	_check(bridge.get_topology_revision() == before,
		"an unchanged desktop does not emit a topology change",
		"revision %d -> %d" % [before, bridge.get_topology_revision()])

	# And the whole stack end to end: a real pet, on the real bridge's desktop.
	var nav := Navigator.new()
	nav.set_world(bridge)
	nav.set_mobility(_mobility(false, false))
	var floor_l = bridge.ledge_by_key("floor:%d" % bridge.current_screen)
	if floor_l == null:
		floor_l = bridge.nearest_ledge(bridge.work_area.get_center())
	if not _check(floor_l != null, "bridge exposes a floor to start from"):
		return
	nav.place(floor_l.center_top())
	var reached := nav.graph.reachable_from(nav.current_ledge)
	_check(reached.size() > 4,
		"a ground animal can get to several places on the default desktop",
		"%d of %d" % [reached.size(), bridge.get_ledges().size()])

	# Asking to go where you already stand is a no-op, not a routing failure.
	var flag := {"failed": false, "arrived": false}
	nav.path_failed.connect(func(_r: StringName) -> void: flag["failed"] = true)
	nav.arrived.connect(func(_id: int) -> void: flag["arrived"] = true)
	var here := nav.current_ledge
	nav.travel_to_point(nav.position)
	nav.step(DT)
	_check(not bool(flag["failed"]), "travelling to your own feet is not a failure")
	_check(bool(flag["arrived"]) or nav.is_travelling(),
		"a zero-length journey still resolves")
	_check(nav.current_ledge == here, "a zero-length journey leaves the pet where it was")

	_check(not bridge.screens.is_empty(), "the bridge always describes at least one screen")
	_check(bridge.dpi_scale_for() >= 1.0, "DPI scale is sane",
		"%.2f" % bridge.dpi_scale_for())
	_check(bridge.virtual_desktop.size.x >= bridge.screen_rect.size.x,
		"the virtual desktop spans at least the current screen")
	var probe: Variant = bridge.screen_at(bridge.work_area.get_center())
	_check(probe != null, "every point on the work area belongs to a screen")


# --- Driving -----------------------------------------------------------------

## Run a navigator at a fixed 60 Hz and watch for the failure modes that matter:
## teleports, NaN, and never finishing.
func _drive(nav: Navigator, max_seconds: float, each_frame: Callable = Callable()) -> Dictionary:
	var elapsed := 0.0
	var last := nav.position
	var max_step := 0.0
	var saw_nan := false
	var saw_air := false
	var saw_crouch := false
	var phases := {}
	# Dictionary, not a local bool: a lambda captures locals by value, so a
	# signal handler writing to one would never be seen out here.
	var flag := {"arrived": false}
	nav.arrived.connect(func(_id: int) -> void: flag["arrived"] = true)
	while elapsed < max_seconds:
		if each_frame.is_valid():
			each_frame.call()
		var running := nav.step(DT)
		elapsed += DT
		var p := nav.position
		if is_nan(p.x) or is_nan(p.y) or is_inf(p.x) or is_inf(p.y):
			saw_nan = true
			break
		max_step = maxf(max_step, p.distance_to(last))
		last = p
		phases[nav.traversal.phase] = true
		if nav.traversal.airborne:
			saw_air = true
		if nav.traversal.crouch > 0.15:
			saw_crouch = true
		if not running:
			break
	return {
		"elapsed": elapsed, "max_step": max_step, "nan": saw_nan,
		"airborne_seen": saw_air, "crouch_seen": saw_crouch,
		"arrived": bool(flag["arrived"]), "phases": phases,
	}


static func _summary(path: Array) -> String:
	if path.is_empty():
		return "<no path>"
	var parts := PackedStringArray()
	for s in path:
		parts.append(NavSegment.move_name(s.move))
	return "|".join(parts)
