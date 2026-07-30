class_name LedgeGraph
extends RefCounted

## The desktop as a directed graph, and A* over it.
##
## Nodes are ledges; edges are *moves a particular animal can make*. That last
## part is why the graph is rebuilt per species rather than shared: a gecko
## climbs the side of a window that a corgi has to walk around, and a budgie
## ignores both. Baking mobility into the edge set means the search itself stays
## a plain A* and every "can it get there" question is answered once, at build
## time, by the same solver the traversal executor will use.
##
## Costs are in seconds, weighted. Weights are all >= 1, which keeps the
## heuristic (straight-line distance over top speed) admissible, so the search
## really does return the cheapest route rather than a plausible-looking one.

## Above this the O(n^2) edge build stops being free. Real desktops sit around
## 40-120 ledges; the cap only ever bites on a pathological 6-monitor wall.
const MAX_LEDGES := 256
## Fly edges connect everything to everything, so each perch keeps a thinned set.
## Thinning by cost alone is wrong — the cheapest edges are all to the nearest
## perches, and the one long hop to an isolated shelf is exactly what gets
## culled. So candidates are first deduplicated by destination *cell*, which
## keeps one option in every direction and at every range.
const MAX_FLY_EDGES := 24
const FLY_CELL := 320.0
## Arc samples used for the tunnelling test.
const ARC_SAMPLES := 6

class Edge:
	var move: int = 0
	var to_id: int = 0
	## Where on the source ledge the move begins, and where on the destination
	## it ends. Precomputed so the search only has to add the walk between the
	## point it arrived at and this exit.
	var exit: Vector2 = Vector2.ZERO
	var entry: Vector2 = Vector2.ZERO
	var cost: float = 0.0
	var time: float = 0.0
	var apex: float = 0.0
	var vx: float = 0.0
	var vy: float = 0.0

var mobility: NavMobility = null
## Stamp of the desktop topology this graph was built from. The navigator
## compares it against `DesktopBridge.topology_revision` to know it is stale.
var revision: int = 0
var edge_count: int = 0

var _ledges: Array[NavLedge] = []
var _by_id: Dictionary = {}
var _edges: Dictionary = {}
var _buckets: Dictionary = {}
var _bucket_size: float = 192.0


func build(ledges: Array, mob: NavMobility, rev: int = 0) -> void:
	mobility = mob if mob != null else NavMobility.new()
	revision = rev
	_ledges.clear()
	_by_id.clear()
	_edges.clear()
	_buckets.clear()
	edge_count = 0
	for l in ledges:
		if l is NavLedge:
			_ledges.append(l)
			if _ledges.size() >= MAX_LEDGES:
				break
	for l in _ledges:
		_by_id[l.id] = l
	_index_buckets()
	_build_edges()


func ledge_count() -> int:
	return _ledges.size()


func ledges() -> Array[NavLedge]:
	return _ledges


func ledge(id: int) -> NavLedge:
	return _by_id.get(id)


func ledge_by_key(key: String) -> NavLedge:
	if key == "":
		return null
	for l in _ledges:
		if l.key == key:
			return l
	return null


func edges_from(id: int) -> Array:
	return _edges.get(id, [])


# --- Spatial index -----------------------------------------------------------
# One-dimensional buckets on x. The arc-tunnelling test asks "what could be in
# the way between these two x values", which on a desktop is a handful of things
# even when the graph is large.

func _index_buckets() -> void:
	for l in _ledges:
		var c0 := int(floor(l.rect.position.x / _bucket_size))
		var c1 := int(floor(l.rect.end.x / _bucket_size))
		for c in range(c0, c1 + 1):
			var arr: PackedInt32Array = _buckets.get(c, PackedInt32Array())
			arr.append(l.id)
			_buckets[c] = arr


func _bucket_at(x: float) -> PackedInt32Array:
	return _buckets.get(int(floor(x / _bucket_size)), PackedInt32Array())


# --- Edge construction -------------------------------------------------------

## Inset from the ends of a ledge where the pet actually plants its feet. A cat
## standing with half its body over a 48 px icon edge reads as a bug, not as
## bravado.
func _stand_inset(l: NavLedge) -> float:
	return minf(mobility.body_width * 0.30, l.rect.size.x * 0.35)


func _build_edges() -> void:
	for a in _ledges:
		var list: Array = []
		var fly: Array = []
		for b in _ledges:
			if b.id == a.id:
				continue
			_connect(a, b, list, fly)
		if not fly.is_empty():
			var by_cell := {}
			for e in fly:
				var edge: Edge = e
				var cell := Vector2i(int(floor(edge.entry.x / FLY_CELL)),
					int(floor(edge.entry.y / FLY_CELL)))
				var held: Edge = by_cell.get(cell)
				if held == null or edge.cost < held.cost:
					by_cell[cell] = edge
			var kept: Array = by_cell.values()
			kept.sort_custom(func(x: Edge, y: Edge) -> bool: return x.cost < y.cost)
			for i in mini(kept.size(), MAX_FLY_EDGES):
				list.append(kept[i])
		_edges[a.id] = list
		edge_count += list.size()


func _connect(a: NavLedge, b: NavLedge, out: Array, fly_out: Array) -> void:
	var mob := mobility
	# Positive dy_up means b is *higher* on screen; y grows downward here.
	var dy_up := a.top_y() - b.top_y()
	var gap := a.gap_x(b)
	var a_stand := a.is_standable()
	var b_stand := b.is_standable()
	var inset_a := _stand_inset(a)
	var inset_b := _stand_inset(b)
	var linked := false

	# Two surfaces that are level and touching are one walkable run: the taskbar
	# meeting the screen floor, two icons in the same row of a dense grid. A wall
	# is allowed at one end — arriving at the top of a window's side face and
	# stepping onto its title bar is the same move, and without it every climb
	# dead-ends on the lip it just reached.
	if (a_stand or b_stand) and absf(dy_up) <= mob.step_up and gap <= mob.body_width * 0.35:
		var hand := _handoff_x(a, b, inset_a, inset_b)
		var e := Edge.new()
		e.move = NavSegment.Move.WALK
		e.to_id = b.id
		e.exit = Vector2(hand.x, a.top_y())
		e.entry = Vector2(hand.y, b.top_y())
		e.time = e.exit.distance_to(e.entry) / mob.walk_speed
		e.cost = e.time * mob.cost_walk
		out.append(e)
		linked = true

	if mob.can_climb and _wall_between(a, b):
		var up := dy_up > 0.0
		var climb_from := Vector2(a.clamp_x(b.rect.get_center().x, inset_a), a.top_y())
		var climb_to := Vector2(b.clamp_x(climb_from.x, inset_b), b.top_y())
		var e := Edge.new()
		e.move = NavSegment.Move.CLIMB_UP if up else NavSegment.Move.CLIMB_DOWN
		e.to_id = b.id
		e.exit = climb_from
		e.entry = climb_to
		# Descending a face is faster than hauling up one, and the pull-up beat
		# is replaced by a shorter lower-over-the-lip beat.
		var speed := mob.climb_speed * (1.0 if up else 1.45)
		e.time = absf(dy_up) / speed + NavMobility.GRAB_TIME \
			+ (NavMobility.PULLUP_TIME if up else NavMobility.PULLUP_TIME * 0.6)
		e.cost = e.time * mob.cost_climb
		out.append(e)
		linked = true

	if a_stand and b_stand and not linked and dy_up <= mob.jump_height:
		var pts := _hop_points(a, b, inset_a, inset_b)
		var jump_from: Vector2 = pts[0]
		var jump_to: Vector2 = pts[1]
		var jump_sol := mob.solve_jump(jump_from, jump_to)
		if jump_sol.get("ok", false) and not _arc_blocked(jump_from, jump_sol, a.id, b.id):
			var e := Edge.new()
			e.move = NavSegment.Move.JUMP
			e.to_id = b.id
			e.exit = jump_from
			e.entry = jump_to
			e.vx = jump_sol["vx"]
			e.vy = jump_sol["vy"]
			e.apex = jump_sol["apex"]
			e.time = float(jump_sol["time"]) + NavMobility.CROUCH_TIME + NavMobility.LAND_TIME
			e.cost = e.time * mob.cost_jump
			out.append(e)
			linked = true

	# A drop is not a downward jump: no impulse, just stepping off. It reaches
	# much further down than a jump reaches up, which is why it gets its own
	# edge even where a JUMP already exists.
	if a_stand and b_stand and dy_up < -mob.step_up and -dy_up <= mob.max_drop:
		var drop_x := a.clamp_x(b.rect.get_center().x, inset_a)
		var drop_from := Vector2(drop_x, a.top_y())
		var drop_to := Vector2(b.clamp_x(drop_x, inset_b), b.top_y())
		var drop_sol := mob.solve_drop(drop_from, drop_to)
		if drop_sol.get("ok", false) and not _arc_blocked(drop_from, drop_sol, a.id, b.id):
			var e := Edge.new()
			e.move = NavSegment.Move.DROP
			e.to_id = b.id
			e.exit = drop_from
			e.entry = drop_to
			e.vx = drop_sol["vx"]
			e.vy = 0.0
			e.apex = drop_from.y
			e.time = float(drop_sol["time"]) + NavMobility.LAND_TIME
			e.cost = e.time * mob.cost_drop
			out.append(e)

	if mob.can_fly and b_stand:
		var fly_from := Vector2(a.clamp_x(b.rect.get_center().x, inset_a), a.top_y())
		var fly_to := Vector2(b.clamp_x(fly_from.x, inset_b), b.top_y())
		var fly_d := fly_from.distance_to(fly_to)
		# Two and a half seconds of flight is the practical range of a desk-sized
		# bird; beyond that it would rather hop the distance in stages.
		if fly_d <= mob.fly_speed * 2.5:
			var e := Edge.new()
			e.move = NavSegment.Move.FLY
			e.to_id = b.id
			e.exit = fly_from
			e.entry = fly_to
			e.time = fly_d / mob.fly_speed + NavMobility.TAKEOFF_TIME
			e.cost = e.time * mob.cost_fly
			# Fly arcs bow upward, away from whatever is between the perches.
			e.apex = minf(fly_from.y, fly_to.y) - minf(fly_d * 0.22, mob.unit * 1.1)
			fly_out.append(e)


## Where two level, touching ledges hand off. Returns (exit_x, entry_x).
func _handoff_x(a: NavLedge, b: NavLedge, inset_a: float, inset_b: float) -> Vector2:
	var lo: float = maxf(a.rect.position.x, b.rect.position.x)
	var hi: float = minf(a.rect.end.x, b.rect.end.x)
	if hi >= lo:
		var mid: float = (lo + hi) * 0.5
		return Vector2(a.clamp_x(mid, 0.0), b.clamp_x(mid, 0.0))
	if a.rect.end.x <= b.rect.position.x:
		return Vector2(a.clamp_x(a.rect.end.x, inset_a * 0.4),
			b.clamp_x(b.rect.position.x, inset_b * 0.4))
	return Vector2(a.clamp_x(a.rect.position.x, inset_a * 0.4),
		b.clamp_x(b.rect.end.x, inset_b * 0.4))


## Takeoff and landing points for a hop: leave from the near lip of `a`, land on
## the near lip of `b`. Directly overlapping ledges hop straight up instead.
func _hop_points(a: NavLedge, b: NavLedge, inset_a: float, inset_b: float) -> Array:
	var dir := a.dir_to(b)
	var ex: float
	var en: float
	if dir > 0.0:
		ex = a.rect.end.x
		en = b.rect.position.x
	elif dir < 0.0:
		ex = a.rect.position.x
		en = b.rect.end.x
	else:
		ex = b.rect.get_center().x
		en = ex
	ex = a.clamp_x(ex, inset_a)
	en = b.clamp_x(en, inset_b)
	return [Vector2(ex, a.top_y()), Vector2(en, b.top_y())]


## Is there a graspable vertical face joining these two tops? The honest test is
## whether the upper surface's body actually reaches down to within paw range of
## the lower one — a window floating in the middle of the screen has no wall
## going down to the desktop, so it has to be jumped to, not climbed.
func _wall_between(a: NavLedge, b: NavLedge) -> bool:
	var dy_up := a.top_y() - b.top_y()
	if absf(dy_up) <= mobility.step_up:
		return false
	if a.gap_x(b) > mobility.body_width * 0.6:
		return false
	var upper := b if dy_up > 0.0 else a
	var lower := a if dy_up > 0.0 else b
	return upper.rect.end.y >= lower.rect.position.y - mobility.grab_reach


## Does this arc pass through the body of some other ledge? Sampling the solved
## trajectory rather than the straight line matters: the whole point of an arc
## is to go *over* things, and a chord test would reject leaps that clear fine.
func _arc_blocked(p0: Vector2, sol: Dictionary, ignore_a: int, ignore_b: int) -> bool:
	var total := float(sol.get("time", 0.0))
	if total <= 0.0:
		return false
	var vx := float(sol.get("vx", 0.0))
	var vy := float(sol.get("vy", 0.0))
	for i in range(1, ARC_SAMPLES):
		var t := total * float(i) / float(ARC_SAMPLES)
		var p := Vector2(p0.x + vx * t, p0.y - vy * t + 0.5 * mobility.gravity * t * t)
		if _point_inside_other(p, ignore_a, ignore_b):
			return true
	return false


func _point_inside_other(p: Vector2, ignore_a: int, ignore_b: int) -> bool:
	for id in _bucket_at(p.x):
		if id == ignore_a or id == ignore_b:
			continue
		var l: NavLedge = _by_id.get(id)
		if l == null or not l.rect.has_point(p):
			continue
		# Only genuinely solid furniture blocks a leap. An icon is a 48 px glyph
		# the pet is drawn in front of anyway, and treating it as a wall makes a
		# column of icons unclimbable — the pet's head clips the one above every
		# time it hops up a rung, which is exactly what a real cat does.
		if l.rect.size.y <= mobility.step_up * 2.0:
			continue
		# Skimming the top of a surface is what clearing it looks like; only a
		# point well inside a body counts as tunnelling through it.
		if p.y > l.top_y() + mobility.step_up:
			return true
	return false


# --- Search ------------------------------------------------------------------

## A* from a point on `start_id` to a point on `goal_id`.
##
## Returns an empty array when no route exists — which is a real answer, not a
## failure: a ground animal genuinely cannot reach a floating window, and the
## brain should pick a different desire rather than have the pathfinder invent
## a route.
func find_path(start: Vector2, start_id: int, goal_id: int,
		goal_x: float = NAN) -> Array[NavSegment]:
	var out: Array[NavSegment] = []
	if mobility == null or _ledges.is_empty():
		return out
	var start_l: NavLedge = _by_id.get(start_id)
	var goal_l: NavLedge = _by_id.get(goal_id)
	if start_l == null or goal_l == null:
		return out

	var goal_point := goal_l.surface_point(
		goal_l.rect.get_center().x if is_nan(goal_x) else goal_x,
		_stand_inset(goal_l))

	if start_id == goal_id:
		_append_walk(out, start_l, Vector2(start.x, start_l.top_y()), goal_point)
		return out

	var top := mobility.top_speed()
	var g := {start_id: 0.0}
	var f := {start_id: start.distance_to(goal_point) / top}
	var arrive := {start_id: Vector2(start.x, start_l.top_y())}
	var heading := {start_id: 0.0}
	var came := {}
	var open := {start_id: true}
	var closed := {}

	while not open.is_empty():
		var cur := -1
		var best := INF
		for id in open:
			var fv: float = f.get(id, INF)
			if fv < best:
				best = fv
				cur = id
		if cur < 0:
			break
		if cur == goal_id:
			return _reconstruct(came, arrive, start, start_l, goal_l, goal_point)
		open.erase(cur)
		closed[cur] = true

		var here: Vector2 = arrive[cur]
		var here_heading: float = heading.get(cur, 0.0)
		for e in edges_from(cur):
			var edge: Edge = e
			if closed.has(edge.to_id):
				continue
			var stride := edge.exit.x - here.x
			var step_cost := absf(stride) / mobility.walk_speed * mobility.cost_walk
			var dir := signf(stride)
			if dir != 0.0 and here_heading != 0.0 and dir != here_heading:
				step_cost += mobility.cost_turn
			var tentative: float = float(g[cur]) + step_cost + edge.cost
			if tentative >= float(g.get(edge.to_id, INF)):
				continue
			came[edge.to_id] = {"from": cur, "edge": edge}
			g[edge.to_id] = tentative
			arrive[edge.to_id] = edge.entry
			heading[edge.to_id] = signf(edge.entry.x - edge.exit.x) if edge.entry.x != edge.exit.x else dir
			f[edge.to_id] = tentative + edge.entry.distance_to(goal_point) / top
			open[edge.to_id] = true

	return out


## Path to an arbitrary screen point: land on whatever surface owns that point.
func find_path_to_point(start: Vector2, start_id: int, point: Vector2) -> Array[NavSegment]:
	var target := ledge_under(point)
	if target == null:
		target = nearest_standable(point)
	if target == null:
		var empty: Array[NavSegment] = []
		return empty
	return find_path(start, start_id, target.id, point.x)


func _reconstruct(came: Dictionary, arrive: Dictionary, start: Vector2,
		start_l: NavLedge, goal_l: NavLedge, goal_point: Vector2) -> Array[NavSegment]:
	# Walk the parent chain back to the start, then replay it forwards so the
	# walk-along-a-ledge fillers land in the right order.
	var chain: Array = []
	var node := goal_l.id
	var guard := 0
	while came.has(node) and guard < MAX_LEDGES * 2:
		guard += 1
		var step: Dictionary = came[node]
		chain.push_front(step)
		node = int(step["from"])
	var out: Array[NavSegment] = []
	if node != start_l.id:
		return out

	var cur := Vector2(start.x, start_l.top_y())
	var cur_ledge := start_l
	for step in chain:
		var edge: Edge = step["edge"]
		var to_l: NavLedge = _by_id.get(edge.to_id)
		if to_l == null:
			out.clear()
			return out
		_append_walk(out, cur_ledge, cur, edge.exit)
		if edge.move == NavSegment.Move.WALK and edge.exit.distance_to(edge.entry) < 0.75:
			# Stepping off the top of a window's side face onto its title bar is
			# a graph transition with no distance in it. Emitting a zero-length
			# segment would give the rig a move with no duration to play.
			cur = edge.entry
			cur_ledge = to_l
			continue
		var seg := NavSegment.make(edge.move, edge.exit, edge.entry)
		seg.from_ledge = cur_ledge.id
		seg.to_ledge = to_l.id
		seg.to_key = to_l.key
		seg.duration = edge.time
		seg.apex = edge.apex
		seg.vx = edge.vx
		seg.vy = edge.vy
		if edge.move == NavSegment.Move.CLIMB_UP or edge.move == NavSegment.Move.CLIMB_DOWN:
			# A climber faces the wall, which is the side the destination is on.
			seg.facing = 1.0 if to_l.rect.get_center().x >= cur_ledge.rect.get_center().x else -1.0
		out.append(seg)
		cur = edge.entry
		cur_ledge = to_l
	_append_walk(out, cur_ledge, cur, goal_point)
	return out


func _append_walk(out: Array[NavSegment], l: NavLedge, from: Vector2, to: Vector2) -> void:
	if absf(to.x - from.x) < 0.75:
		return
	var seg := NavSegment.make(NavSegment.Move.WALK, from, to)
	seg.from_ledge = l.id
	seg.to_ledge = l.id
	seg.to_key = l.key
	seg.duration = from.distance_to(to) / maxf(mobility.walk_speed, 1.0)
	out.append(seg)


# --- Queries the brain and the navigator need --------------------------------

## Standable surface directly beneath a point — where a pet lands if released.
func ledge_under(point: Vector2, slack: float = 8.0) -> NavLedge:
	var best: NavLedge = null
	var best_dy := INF
	for l in _ledges:
		if not l.is_standable() or not l.contains_x(point.x, slack):
			continue
		var dy := l.top_y() - point.y
		if dy < -2.0:
			continue
		if dy < best_dy:
			best_dy = dy
			best = l
	return best


func nearest_standable(point: Vector2) -> NavLedge:
	var best: NavLedge = null
	var best_d := INF
	for l in _ledges:
		if not l.is_standable():
			continue
		var d: float = l.surface_point(point.x).distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = l
	return best


## Every ledge this animal can actually get to from `start_id`. The brain uses
## it to pick a wander target it will not immediately fail to path to.
func reachable_from(start_id: int) -> PackedInt32Array:
	var seen := {start_id: true}
	var stack: PackedInt32Array = PackedInt32Array([start_id])
	var out := PackedInt32Array()
	while not stack.is_empty():
		var id := stack[stack.size() - 1]
		stack.remove_at(stack.size() - 1)
		out.append(id)
		for e in edges_from(id):
			var edge: Edge = e
			if seen.has(edge.to_id):
				continue
			seen[edge.to_id] = true
			stack.append(edge.to_id)
	return out
