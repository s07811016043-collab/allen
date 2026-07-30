class_name Traversal
extends RefCounted

## Turns one planned `NavSegment` into motion over time.
##
## The planner only promises that a move is *possible*. This is where it becomes
## an animal: a jump gets a takeoff crouch and a landing absorb, a climb gets an
## edge grab and a pull-up that rotates the body over the lip, a flight gets a
## bank into the turn. Those beats are not decoration — without the crouch the
## pet looks like it was fired from a cannon, and without the absorb it looks
## like it landed on a trampoline.
##
## Deliberately a `RefCounted` with an explicit `advance(delta)` rather than a
## node with `_process`. The creature owns its own update order (it has a rig, a
## brain and a renderer to sequence), and a nav system that ticks itself would
## fight that.
##
## Everything the rig needs is read off the public fields after `advance()`.
## `apply_to()` will push them onto a creature that exposes any of the usual
## setters, but a creature is free to just read the fields instead.

## Current ground/air position of the pet's origin (between the paws).
var position: Vector2 = Vector2.ZERO
## Derived from the position delta, so it is always consistent with what the
## pet actually did rather than with what it was asked to do.
var velocity: Vector2 = Vector2.ZERO
## +1 facing right, -1 facing left.
var facing: float = 1.0
## &"idle", &"walk", &"crouch", &"air", &"land", &"step_off", &"climb",
## &"grab", &"pullup", &"lower", &"takeoff", &"glide", &"flare".
var phase: StringName = &"idle"
## Leg compression, 0 neutral .. 1 fully folded. Drives squash on the rig.
var crouch: float = 0.0
## Limb extension, 0 neutral .. 1 fully reached out. The counterpart to
## `crouch`; both are never large at once.
var stretch: float = 0.0
## Body pitch, -1 nose down .. +1 nose up.
var lean: float = 0.0
## Roll into a turn, -1 .. 1. Only ever non-zero in flight.
var bank: float = 0.0
## How much of the body is hanging off a wall or lip, 0 .. 1. The rig uses it to
## swap the leg solver from "stand on ground" to "grip surface".
var grip: float = 0.0
## Fraction of this segment completed.
var progress: float = 0.0
var airborne: bool = false
var finished: bool = true

var segment: NavSegment = null
var mobility: NavMobility = null

var _t := 0.0
var _total := 0.0
## Sub-timings, in seconds, resolved once at `begin()` so `advance()` is branchy
## but never has to re-solve physics.
var _t_pre := 0.0     # crouch / step-off / takeoff
var _t_main := 0.0    # airtime, climb, or glide
var _t_post := 0.0    # landing absorb / pull-up / flare
var _air_vy := 0.0
var _impact := 0.0
var _c1 := Vector2.ZERO
var _c2 := Vector2.ZERO
var _grab := Vector2.ZERO
var _prev := Vector2.ZERO


func begin(seg: NavSegment, mob: NavMobility) -> void:
	segment = seg
	mobility = mob if mob != null else NavMobility.new()
	_t = 0.0
	progress = 0.0
	finished = false
	airborne = false
	crouch = 0.0
	stretch = 0.0
	lean = 0.0
	bank = 0.0
	grip = 0.0
	position = seg.from
	_prev = seg.from
	velocity = Vector2.ZERO
	if absf(seg.to.x - seg.from.x) > 0.5:
		facing = 1.0 if seg.to.x > seg.from.x else -1.0
	elif seg.facing != 0.0:
		facing = signf(seg.facing)

	match seg.move:
		NavSegment.Move.WALK: _begin_walk()
		NavSegment.Move.JUMP: _begin_jump()
		NavSegment.Move.DROP: _begin_drop()
		NavSegment.Move.CLIMB_UP, NavSegment.Move.CLIMB_DOWN: _begin_climb()
		NavSegment.Move.FLY: _begin_fly()
		_: _begin_walk()
	_total = maxf(_t_pre + _t_main + _t_post, 0.0001)
	# Keep the plan honest: the planner compared routes using `duration`, so the
	# executor publishes what it will actually take.
	seg.duration = _total


func _begin_walk() -> void:
	_t_main = segment.from.distance_to(segment.to) / maxf(mobility.walk_speed, 1.0)
	phase = &"walk"


func _begin_jump() -> void:
	var dy_up := segment.from.y - segment.to.y
	var vy := segment.vy
	if vy <= 0.0:
		# Hand-built segment (a test, or the brain asking for a specific hop).
		# Re-solving here is what stops a synthetic path from launching a pet on
		# a trajectory the planner never validated.
		var sol := mobility.solve_jump(segment.from, segment.to)
		if not sol.get("ok", false):
			_begin_walk()
			return
		vy = sol["vy"]
		segment.vy = vy
		segment.vx = sol["vx"]
		segment.apex = sol["apex"]
	var disc := vy * vy - 2.0 * mobility.gravity * dy_up
	if disc < 0.0:
		_begin_walk()
		return
	_air_vy = vy
	_t_main = (vy + sqrt(disc)) / mobility.gravity
	if absf(segment.vx) < 0.0001 and absf(segment.to.x - segment.from.x) > 0.0:
		segment.vx = (segment.to.x - segment.from.x) / _t_main
	# A bigger effort needs a deeper wind-up; a 30 px hop should not have the
	# same 0.15 s squat as a leap onto the monitor bezel.
	var effort: float = clampf(vy / maxf(mobility.jump_speed, 1.0), 0.15, 1.0)
	_t_pre = NavMobility.CROUCH_TIME * (0.55 + 0.45 * effort)
	var land_vy := vy - mobility.gravity * _t_main
	_impact = clampf(absf(land_vy) / maxf(mobility.jump_speed * 1.3, 1.0), 0.2, 1.0)
	_t_post = NavMobility.LAND_TIME * (0.6 + 0.4 * _impact)
	phase = &"crouch"


func _begin_drop() -> void:
	var fall := segment.to.y - segment.from.y
	if fall <= 0.0:
		_begin_walk()
		return
	_air_vy = 0.0
	_t_main = sqrt(2.0 * fall / mobility.gravity)
	segment.vx = (segment.to.x - segment.from.x) / maxf(_t_main, 0.0001)
	# Stepping off is a weight shift, not a launch: short, and the same length
	# whatever the drop, because the pet does not know how far it is yet.
	_t_pre = 0.08
	_impact = clampf(mobility.gravity * _t_main / maxf(mobility.jump_speed * 1.3, 1.0), 0.25, 1.0)
	_t_post = NavMobility.LAND_TIME * (0.7 + 0.6 * _impact)
	phase = &"step_off"


func _begin_climb() -> void:
	var up := segment.move == NavSegment.Move.CLIMB_UP
	# Hang point just below the lip, where the paws catch before the pull-up.
	_grab = Vector2(segment.to.x, segment.to.y + mobility.grab_reach * 0.6)
	var travel := segment.from.distance_to(_grab)
	_t_main = travel / maxf(mobility.climb_speed * (1.0 if up else 1.45), 1.0)
	_t_pre = 0.0
	_t_post = NavMobility.GRAB_TIME + NavMobility.PULLUP_TIME * (1.0 if up else 0.6)
	phase = &"climb" if up else &"lower"


func _begin_fly() -> void:
	var d := segment.from.distance_to(segment.to)
	_t_pre = NavMobility.TAKEOFF_TIME
	_t_main = maxf(d / maxf(mobility.fly_speed, 1.0), 0.12)
	_t_post = 0.18
	var apex := segment.apex
	if apex == 0.0 or apex > minf(segment.from.y, segment.to.y):
		apex = minf(segment.from.y, segment.to.y) - minf(d * 0.22, mobility.unit * 1.1)
		segment.apex = apex
	# A cubic whose interior control points sit at the apex height gives a swoop
	# that leaves and arrives level-ish and bows over anything between.
	_c1 = Vector2(lerpf(segment.from.x, segment.to.x, 0.28), apex)
	_c2 = Vector2(lerpf(segment.from.x, segment.to.x, 0.72), apex)
	phase = &"takeoff"


## Step the move forward. Returns true while it is still running.
func advance(delta: float) -> bool:
	if finished or segment == null:
		return false
	_t = minf(_t + maxf(delta, 0.0), _total)
	progress = _t / _total
	match segment.move:
		NavSegment.Move.WALK: _tick_walk()
		NavSegment.Move.JUMP: _tick_ballistic(true)
		NavSegment.Move.DROP: _tick_ballistic(false)
		NavSegment.Move.CLIMB_UP: _tick_climb(true)
		NavSegment.Move.CLIMB_DOWN: _tick_climb(false)
		NavSegment.Move.FLY: _tick_fly()
		_: _tick_walk()
	velocity = (position - _prev) / maxf(delta, 0.0001)
	_prev = position
	if _t >= _total:
		finished = true
		position = segment.to
		airborne = false
		return false
	return true


## Trapezoidal speed profile over a unit interval: ease out of a standstill,
## cruise, ease back into one. A pet that starts and stops at full walk speed
## looks like it is on rails.
static func _ramped(u: float, ramp: float) -> float:
	var r: float = clampf(ramp, 0.0001, 0.5)
	var s: float
	if u < r:
		s = u * u / (2.0 * r)
	elif u > 1.0 - r:
		# Mirror of the acceleration ramp, measured back from the end. Deriving
		# it forwards is where the seam creeps in, and a seam here is a visible
		# jump of `ramp` times the whole segment length in a single frame.
		var v := 1.0 - u
		s = (1.0 - r) - v * v / (2.0 * r)
	else:
		s = u - r * 0.5
	return clampf(s / maxf(1.0 - r, 0.0001), 0.0, 1.0)


func _tick_walk() -> void:
	phase = &"walk"
	var ramp: float = clampf(0.16 / maxf(_total, 0.0001), 0.02, 0.45)
	var s := _ramped(_t / _total, ramp)
	position = segment.from.lerp(segment.to, s)
	# Lean into acceleration and out of deceleration — the cheapest possible
	# read on "this animal has mass".
	var u := _t / _total
	if u < ramp:
		lean = -0.25 * (1.0 - u / ramp)
	elif u > 1.0 - ramp:
		lean = 0.25 * (1.0 - (1.0 - u) / ramp)
	else:
		lean = 0.0
	crouch = 0.0
	stretch = 0.0
	grip = 0.0
	airborne = false


func _tick_ballistic(with_crouch: bool) -> void:
	if _t < _t_pre:
		var u := _t / maxf(_t_pre, 0.0001)
		position = segment.from
		airborne = false
		if with_crouch:
			phase = &"crouch"
			# Ease-out so the squat settles rather than snapping to its bottom.
			crouch = 1.0 - (1.0 - u) * (1.0 - u)
			lean = -0.35 * crouch
		else:
			# A weight shift, not a translation: the pet leans out over the lip
			# and lets go. Sliding the body forward here and then starting the
			# ballistic arc back at `from` would pop it a body-width sideways in
			# a single frame.
			phase = &"step_off"
			crouch = 0.35 * u
			lean = 0.3 * u
		stretch = 0.0
		grip = 0.0
		return

	var ta := _t - _t_pre
	if ta <= _t_main:
		phase = &"air"
		airborne = true
		grip = 0.0
		position = Vector2(
			segment.from.x + segment.vx * ta,
			segment.from.y - _air_vy * ta + 0.5 * mobility.gravity * ta * ta)
		var vy_now := _air_vy - mobility.gravity * ta
		lean = clampf(vy_now / maxf(mobility.jump_speed, 1.0), -1.0, 1.0) * 0.7
		# Extend hard out of the launch, then reach for the ground on the way in.
		var launch: float = clampf(1.0 - ta / 0.13, 0.0, 1.0)
		var reach: float = clampf((ta - (_t_main - 0.20)) / 0.20, 0.0, 1.0)
		stretch = maxf(launch, reach * 0.8)
		crouch = 0.0
		return

	phase = &"land"
	airborne = false
	position = segment.to
	var s: float = clampf((ta - _t_main) / maxf(_t_post, 0.0001), 0.0, 1.0)
	# One compression and release. `sin` is the right shape here: the absorb is
	# symmetric, and any asymmetry reads as a limp.
	crouch = _impact * sin(PI * s)
	stretch = 0.0
	lean = -0.2 * crouch


func _tick_climb(up: bool) -> void:
	if _t <= _t_main:
		phase = &"climb" if up else &"lower"
		airborne = false
		grip = 1.0
		var s := _ramped(_t / maxf(_t_main, 0.0001), 0.2)
		# Reach the wall first, then run up it: a diagonal scramble looks like a
		# pet sliding along an invisible ramp.
		var lateral: float = clampf(s / 0.3, 0.0, 1.0)
		position = Vector2(
			lerpf(segment.from.x, _grab.x, lateral),
			lerpf(segment.from.y, _grab.y, s))
		# Climbing pumps: the body alternately gathers and extends up the face.
		var pump := sin(_t * mobility.climb_speed / maxf(mobility.unit * 0.22, 1.0))
		crouch = 0.25 + 0.2 * pump
		stretch = 0.25 - 0.2 * pump
		lean = 0.0
		return

	var tp := _t - _t_main
	if tp < NavMobility.GRAB_TIME:
		phase = &"grab"
		position = _grab
		grip = 1.0
		# Gather before the haul. This beat is what sells the weight of the pet.
		crouch = 0.55
		stretch = 0.0
		lean = 0.15
		return

	phase = &"pullup" if up else &"lower"
	var pull := NavMobility.PULLUP_TIME * (1.0 if up else 0.6)
	var s2: float = clampf((tp - NavMobility.GRAB_TIME) / maxf(pull, 0.0001), 0.0, 1.0)
	var eased := s2 * s2 * (3.0 - 2.0 * s2)
	# Rise a touch above the lip mid-haul, then settle: the hips clear the edge
	# before the feet come under the body.
	position = _grab.lerp(segment.to, eased) - Vector2(0.0, sin(PI * s2) * mobility.unit * 0.10)
	grip = 1.0 - eased
	lean = sin(PI * s2) * (0.9 if up else -0.7)
	crouch = lerpf(0.55, 0.12, eased)
	stretch = sin(PI * s2) * 0.35
	airborne = false


func _tick_fly() -> void:
	grip = 0.0
	if _t < _t_pre:
		phase = &"takeoff"
		airborne = false
		var u := _t / maxf(_t_pre, 0.0001)
		position = segment.from - Vector2(0.0, u * u * mobility.unit * 0.10)
		crouch = (1.0 - u) * 0.5
		stretch = u * 0.6
		lean = 0.4 * u
		bank = 0.0
		return

	var tf := _t - _t_pre
	if tf <= _t_main:
		phase = &"glide"
		airborne = true
		var s: float = _ramped(tf / maxf(_t_main, 0.0001), 0.18)
		position = _bezier(s)
		var tan := _bezier_tangent(s)
		var tan2 := _bezier_tangent(minf(s + 0.03, 1.0))
		lean = clampf(-tan.normalized().y * 1.2, -1.0, 1.0)
		# Bank is the rate the flight path is turning. In a side-on view that
		# reads as the body rolling into the arc, which is what makes a bird
		# look like it is flying rather than sliding along a spline.
		var turn := tan2.angle() - tan.angle()
		bank = clampf(wrapf(turn, -PI, PI) * 6.0, -1.0, 1.0)
		crouch = 0.0
		stretch = 0.25
		return

	phase = &"flare"
	airborne = false
	var s3: float = clampf((tf - _t_main) / maxf(_t_post, 0.0001), 0.0, 1.0)
	position = _bezier(1.0).lerp(segment.to, s3)
	# Wings out, nose up, legs down: the deceleration pose.
	lean = (1.0 - s3) * 0.8
	stretch = (1.0 - s3) * 0.9
	crouch = s3 * 0.4
	bank = lerpf(bank, 0.0, s3)


func _bezier(s: float) -> Vector2:
	var q := 1.0 - s
	return segment.from * (q * q * q) + _c1 * (3.0 * q * q * s) \
		+ _c2 * (3.0 * q * s * s) + segment.to * (s * s * s)


func _bezier_tangent(s: float) -> Vector2:
	var q := 1.0 - s
	var d := (_c1 - segment.from) * (3.0 * q * q) + (_c2 - _c1) * (6.0 * q * s) \
		+ (segment.to - _c2) * (3.0 * s * s)
	return d if d.length_squared() > 0.0001 else Vector2(facing, 0.0)


## True while the move physically cannot be abandoned. The navigator checks this
## before re-planning: rewriting a ballistic arc mid-flight is precisely the
## teleport that makes a desktop pet look fake.
func is_committed() -> bool:
	if finished or segment == null:
		return false
	if airborne:
		return true
	return phase == &"pullup" or phase == &"grab" or phase == &"flare"


func time_remaining() -> float:
	return maxf(_total - _t, 0.0)


## Push the current pose onto a creature or rig without knowing its type.
##
## `core/creature/creature.gd` and `core/rig/` are owned by other agents and are
## still moving, so every call is guarded. A creature that implements
## `set_nav_pose` gets everything in one call; otherwise we fall back to whatever
## individual setters exist, and a creature that implements none of them is
## still free to read this object's fields directly.
func apply_to(target: Object) -> void:
	if target == null or not is_instance_valid(target):
		return
	if target.has_method("set_nav_pose"):
		target.call("set_nav_pose", position, facing, phase, crouch, stretch, lean, bank, airborne, grip)
		return
	if target.has_method("set_nav_position"):
		target.call("set_nav_position", position)
	elif target.get("position") != null:
		target.set("position", position)
	if target.has_method("set_facing"):
		target.call("set_facing", facing)
	if target.has_method("set_locomotion_phase"):
		target.call("set_locomotion_phase", phase)
	if target.has_method("set_body_compression"):
		target.call("set_body_compression", crouch - stretch)
	if target.has_method("set_body_lean"):
		target.call("set_body_lean", lean)
	if target.has_method("set_body_bank"):
		target.call("set_body_bank", bank)
	if target.has_method("set_airborne"):
		target.call("set_airborne", airborne)
