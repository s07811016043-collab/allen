class_name NavMobility
extends RefCounted

## How one animal, at one age, moves through the desktop.
##
## The graph and the traversal executor have to agree exactly: if the planner
## says "that gap is jumpable" and the arc solver then falls short, the pet
## walks off an icon into nothing. So both read their physics from here, and
## nowhere else derives a jump arc on its own.
##
## Everything is converted out of rig units into screen pixels up front, because
## the desktop is measured in pixels and a baby cat and an adult cat have very
## different ideas of how far a 76 px icon gap is.

## Downward acceleration in rig units per second squared. Chosen so an adult
## cat's 1.4-unit jump has ~0.68 s of airtime: long enough to read as a real
## leap at 60 fps, short enough that the pet never looks like it is on the moon.
const GRAVITY_UNITS := 24.0
## Fraction of a body height of clearance the planner insists on above the lip
## it is jumping onto, so an arc never grazes the destination corner.
const ARC_CLEARANCE := 0.34

## Screen pixels per rig unit at this growth stage. The single conversion factor.
var unit: float = 180.0
var gravity: float = GRAVITY_UNITS * 180.0

var walk_speed: float = 160.0
var run_speed: float = 460.0
var climb_speed: float = 90.0
var fly_speed: float = 560.0

## Peak height of a maximum-effort jump, in pixels.
var jump_height: float = 250.0
## Vertical takeoff speed that produces exactly `jump_height`.
var jump_speed: float = 300.0
## How far the pet will voluntarily fall. Animals drop much further than they
## jump — that asymmetry is most of what makes descent read as confident.
var max_drop: float = 700.0

var can_climb: bool = false
var can_fly: bool = false

## Silhouette width; used for "is that one surface or two" and for the inset
## that stops a pet standing balanced on a single corner pixel.
var body_width: float = 100.0
## A lip this small is walked over, not jumped.
var step_up: float = 29.0
## How far above a ledge the paws reach when hanging off the face below it.
var grab_reach: float = 63.0

# Cost weights, in "seconds of walking are worth this much". All are >= 1 so
# the A* heuristic (straight-line distance over top speed) stays admissible.
var cost_walk: float = 1.0
var cost_jump: float = 1.35
var cost_climb: float = 1.6
var cost_drop: float = 1.15
var cost_fly: float = 1.0
## Flat penalty in seconds for reversing direction, so paths do not zig-zag
## across a ledge for a 3 px saving.
var cost_turn: float = 0.25

## Fixed animation time the traversal executor spends on the non-ballistic parts
## of a move. The planner has to include them or its estimates drift.
const CROUCH_TIME := 0.15
const LAND_TIME := 0.16
const GRAB_TIME := 0.18
const PULLUP_TIME := 0.34
const TAKEOFF_TIME := 0.22


## Read a property off an object that may not have it. Specs are edited by other
## agents while this runs; a missing field must degrade, never crash.
static func _f(o: Object, prop: String, def: float) -> float:
	if o == null:
		return def
	var v: Variant = o.get(prop)
	if v == null or (typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT):
		return def
	return float(v)


static func _b(o: Object, prop: String, def: bool) -> bool:
	if o == null:
		return def
	var v: Variant = o.get(prop)
	if typeof(v) != TYPE_BOOL:
		return def
	return v


## Build a profile from a `CreatureSpec` at a continuous growth value.
## `ui_scale` folds in the user's pet-size preference and the monitor's DPI so
## a pet on a 4K display still jumps the same *number of icons*.
static func from_spec(spec: Object, growth: float = 3.0, ui_scale: float = 1.0) -> NavMobility:
	var m := NavMobility.new()
	var ppu := _f(spec, "pixels_per_unit", 180.0)
	var body_scale := 1.0
	if spec != null and spec.has_method("scale_at"):
		body_scale = float(spec.call("scale_at", growth))
	m.unit = maxf(1.0, ppu * body_scale * maxf(0.05, ui_scale))
	m.gravity = GRAVITY_UNITS * m.unit

	m.walk_speed = maxf(8.0, _f(spec, "walk_speed", 0.9) * m.unit)
	m.run_speed = maxf(m.walk_speed * 1.2, _f(spec, "run_speed", 2.6) * m.unit)
	m.jump_height = maxf(1.0, _f(spec, "jump_height", 1.4) * m.unit)
	m.can_climb = _b(spec, "can_climb", false)
	m.can_fly = _b(spec, "can_fly", false)

	m.jump_speed = sqrt(2.0 * m.gravity * m.jump_height)
	# Climbing is slow and deliberate; flight is faster than a sprint but has a
	# takeoff cost, which is what stops a bird flying between adjacent icons.
	m.climb_speed = m.walk_speed * 0.55
	m.fly_speed = m.run_speed * 1.25
	m.max_drop = m.jump_height * 2.6 + m.unit * 0.5

	var height := _f(spec, "adult_height", 1.0) * body_scale
	m.body_width = maxf(6.0, m.unit * height * 0.55)
	m.step_up = m.unit * height * 0.16
	m.grab_reach = m.unit * height * 0.35
	return m


## Fastest the animal can possibly move, used by the A* heuristic. Must be an
## upper bound or the search stops being admissible and starts cutting corners.
func top_speed() -> float:
	var s := maxf(run_speed, walk_speed)
	if can_fly:
		s = maxf(s, fly_speed)
	return maxf(s, 1.0)


## Seconds of flight for a maximum-effort jump that ends `dy_up` pixels above
## the takeoff point (negative = below). Returns -1 when the apex cannot reach.
func air_time(dy_up: float) -> float:
	var disc := jump_speed * jump_speed - 2.0 * gravity * dy_up
	if disc < 0.0:
		return -1.0
	return (jump_speed + sqrt(disc)) / gravity


## Furthest horizontal gap the animal can clear while rising `dy_up` pixels.
func jump_reach(dy_up: float) -> float:
	if dy_up > jump_height:
		return -1.0
	var t := air_time(dy_up)
	if t < 0.0:
		return -1.0
	return run_speed * t


## Solve the actual arc between two points, picking the *lowest* jump that still
## clears the destination lip. Pets that pop a full-height leap over a 20 px gap
## look like they are being flung; this is the difference between "animal" and
## "projectile".
##
## Returns `{ok, vy, vx, time, apex}` with `vy` positive upward and `apex` the
## screen-space y of the top of the arc.
func solve_jump(from: Vector2, to: Vector2) -> Dictionary:
	var dy_up := from.y - to.y
	var dx := to.x - from.x
	var clearance := ARC_CLEARANCE * unit + absf(dx) * 0.06
	var peak := maxf(dy_up, 0.0) + clearance
	peak = minf(peak, jump_height)
	# The destination must still be reachable after the clamp: an arc that peaks
	# exactly at the target height arrives with zero clearance, which is the
	# honest failure boundary.
	if peak < dy_up:
		return {"ok": false}
	var vy := sqrt(2.0 * gravity * peak)
	var disc := vy * vy - 2.0 * gravity * dy_up
	if disc < 0.0:
		return {"ok": false}
	var t := (vy + sqrt(disc)) / gravity
	if t <= 0.0001:
		return {"ok": false}
	var vx := dx / t
	if absf(vx) > run_speed * 1.05:
		# Too far for the airtime this arc buys. Trade height for time: a taller
		# arc hangs longer, which is exactly what an animal does for a long leap.
		var t_needed := absf(dx) / maxf(run_speed, 1.0)
		var vy2 := 0.5 * (gravity * t_needed + 2.0 * dy_up / maxf(t_needed, 0.0001))
		if vy2 > jump_speed or vy2 < 0.0:
			return {"ok": false}
		vy = vy2
		t = t_needed
		vx = dx / t
		peak = vy * vy / (2.0 * gravity)
	return {
		"ok": true, "vy": vy, "vx": vx, "time": t,
		"apex": from.y - peak,
	}


## Free-fall solution for stepping off an edge. Pets do not launch downward;
## they walk off and let gravity do it, with just enough forward speed to clear
## the corner.
func solve_drop(from: Vector2, to: Vector2) -> Dictionary:
	var fall := to.y - from.y
	if fall <= 0.0:
		return {"ok": false}
	var t := sqrt(2.0 * fall / gravity)
	if t <= 0.0001:
		return {"ok": false}
	var vx := (to.x - from.x) / t
	if absf(vx) > run_speed * 1.05:
		return {"ok": false}
	return {"ok": true, "vy": 0.0, "vx": vx, "time": t, "apex": from.y}
