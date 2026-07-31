class_name SpringChain
extends RefCounted

## Secondary motion for everything that hangs off the skeleton: tails, ears,
## jowls, wattles, bellies.
##
## The single most valuable thing a chain does is *lag*. A tail that rotates with
## the hips reads as a stick glued to the animal; a tail that keeps going when
## the hips stop reads as mass. So the driver here is not the parent bone's
## rotation but its **acceleration**: we take the pseudo-force an accelerating
## frame exerts on the chain, turn it into a torque about each joint, and let a
## damped spring pull the joint back to its rest angle.
##
## Two modes, because not everything that wobbles swings:
##   * ANGULAR — joints rotate. Tails, ears, crests, wattles.
##   * OFFSET  — joints translate. Bellies and jowls, which sag and jiggle
##               rather than pivoting about a hinge.
##
## The solver substeps at a fixed rate so a stiff ear stays stable at 30 fps and
## so a rig advanced from t=0 lands on the same pose every run — the capture
## harness depends on that.

enum Mode { ANGULAR, OFFSET }

## Fixed integration step. Small enough for the stiffest ear we ship, and the
## reason two runs of `--t=1.4` produce identical pixels.
const SUBSTEP := 1.0 / 240.0
const MAX_SUBSTEPS := 24


class Link:
	var bone := -1
	var angle := 0.0
	var vel := 0.0
	var pos := Vector2.ZERO
	var vel2 := Vector2.ZERO
	## Rest length of the segment, i.e. the moment arm of the pseudo-force.
	var arm := 0.0
	## Extra rest bias written from outside (ear swivel, mood tail carry), and the
	## delayed copy the spring is actually pulled toward. The delay grows down the
	## chain, which is what turns a bias written at the base into a wave that
	## arrives at the tip later — see `bias_travel`.
	var bias := 0.0
	var bias_now := 0.0
	var bias2 := Vector2.ZERO
	var bias2_now := Vector2.ZERO
	## This joint's own delayed copy of the driver's orientation, and how far the
	## driver has turned ahead of it. Per joint rather than per chain: a single
	## shared trail shared out equally moves every joint by the same amount, which
	## is a rigid rotation however it is divided up.
	var lag_rot := 0.0
	var trail := 0.0


var links: Array[Link] = []
var mode: int = Mode.ANGULAR
## Undamped natural frequency squared. Higher = crisper snap back to rest.
var stiffness := 55.0
## 1.0 is critically damped. Tails look best a shade under — a single soft
## overshoot is what sells the weight — while ears want to be nearly dead.
var damping := 0.92
## Rig units/s² pulling the chain down. A tail carries itself; a wattle does not.
var gravity := 0.0
## How hard the parent's acceleration drives the chain. This is the whip knob.
var inertia := 1.0
## Per-joint travel limit in radians (ANGULAR) or rig units (OFFSET), so a
## violent stop cannot fold a tail through the body.
var limit := 0.9
## Acceleration of the whole creature through the world, rig units/s², written by
## the rig each step.
##
## Without it the chain is deaf to the one event it exists for. `_track_driver`
## watches a bone's transform *in rig space*, and a creature travelling across the
## desktop does that by moving its own node — so the hips braking from a run to a
## standstill produce exactly zero change in any bone the chain can see, and the
## tail that is supposed to keep going simply does not move.
var carrier_accel := Vector2.ZERO
## Musculature thins toward the tip: each joint further out is this much softer
## and this much lighter, which is why the last third of a tail whips hardest.
var falloff := 1.18
## Seconds each joint trails the joint before it. Zero means the chain tracks.
##
## Inertia alone is not lag. A spring driven by acceleration still hangs off the
## parent's *current* frame, so a tail on a hip that rotates — turning, pitching,
## counter-rolling — sweeps around with it on the same frame and only the
## overshoot is secondary. A real tail is still pointing where the hips were an
## eighth of a second ago. Tracked as a one-pole follower rather than a delay
## line, because at the frequencies a tail cares about a one-pole's group delay
## is its time constant, and it costs one float instead of a ring buffer.
##
## Accumulated *down the chain*, one time constant per joint. This is the whole
## difference between a tail and a stick, and it was the bug: one trail shared
## equally between the joints rotates every one of them by the same amount, which
## is a rigid rotation whichever way it is divided. Measured on the cat before
## this change, the three tail joints held to within 6% of each other on every
## frame of a walk — the chain was mathematically a rod. Giving each joint its
## own lagged copy of the driver and applying only the *increment* means the base
## answers first and the tip last, so the tail carries a travelling bend.
var lag := 0.0
## Seconds a rest-angle bias takes to travel from one joint to the next.
##
## Same argument as `lag`, for the channel the idle layer writes. A tail flick
## starts at the root and runs out to the tip; delivered to every joint on the
## same frame it is a rod pivoting about its base, which is exactly what a blind
## reviewer called "a rigid stick".
var bias_travel := 0.0

## Total length of the chain in rig units, measured at setup. Used to keep the
## chain's *tip travel* comparable between species instead of its joint angles;
## see the torque term in `_step`.
var _span := 0.0
var _driver_bone := -1
var _prev_driver := Vector2.ZERO
var _prev_vel := Vector2.ZERO
var _accel := Vector2.ZERO
var _prev_rot := 0.0
var _prev_spin := 0.0
var _alpha := 0.0
var _primed := false


## `bone_indices` are the *joints* to simulate, root first. The chain's tip leaf
## bone is deliberately excluded: it has no segment of its own to rotate.
func setup(skeleton: RigSkeleton, bone_indices: PackedInt32Array, driver_bone: int) -> void:
	links.clear()
	_driver_bone = driver_bone
	_span = 0.0
	for i in bone_indices:
		var l := Link.new()
		l.bone = i
		l.arm = maxf(skeleton.bones[i].length, 0.01)
		_span += l.arm
		links.append(l)


func is_empty() -> bool:
	return links.is_empty()


## Total length of the chain, rig units. Whatever drives a chain is levered by
## this, so callers that write into the chain's *parent* need to know it.
func span() -> float:
	return _span


## Bias the whole chain away from rest — an ear swivelling toward a sound, a
## tail lifted in greeting. Applied as a rest-angle offset so the spring still
## does the settling.
func set_bias(radians: float, taper: float = 1.0) -> void:
	# Same length normalisation as the torque term: a bias is radians at a joint,
	# and what a reviewer sees is the tip. Chains shorter than one rig unit — every
	# ear, crest and jowl we ship, and the cat's, dog's and bird's tails — are
	# untouched.
	var k: float = 1.0 / maxf(_span, 1.0)
	for l in links:
		l.bias = radians * k
		k *= taper


func set_bias_offset(v: Vector2) -> void:
	for l in links:
		l.bias2 = v


## Snap to rest. Used when a creature teleports or is first spawned, so it does
## not arrive with a tail still whipping from wherever it was built.
func settle() -> void:
	for l in links:
		l.angle = l.bias
		l.bias_now = l.bias
		l.vel = 0.0
		l.pos = l.bias2
		l.bias2_now = l.bias2
		l.vel2 = Vector2.ZERO
		l.trail = 0.0
	_primed = false


func advance(skeleton: RigSkeleton, dt: float) -> void:
	if links.is_empty() or dt <= 0.0:
		return
	_track_driver(skeleton, dt)
	var steps: int = clampi(int(ceil(dt / SUBSTEP)), 1, MAX_SUBSTEPS)
	var h := dt / float(steps)
	for _s in steps:
		_step(skeleton, h)
	_write(skeleton)


## Finite-difference the driver joint twice, in both position and rotation.
##
## Translation is the obvious driver — the body stops, the tail keeps going — but
## angular acceleration matters just as much: because the chain's joints are
## local angles, a base that starts rotating carries the whole chain rigidly
## unless something resists it. That resistance is exactly `-alpha`, and without
## it a tail follows a turning hip like a welded rod.
##
## Acceleration from raw differences is spiky, so both go through a one-pole
## filter; the chain should respond to the body stopping, not to one noisy frame.
func _track_driver(skeleton: RigSkeleton, dt: float) -> void:
	var p := Vector2.ZERO
	var rot := 0.0
	if _driver_bone >= 0:
		p = skeleton.bones[_driver_bone].xform.origin
		rot = skeleton.bones[_driver_bone].xform.get_rotation()
	if not _primed:
		_prev_driver = p
		_prev_vel = Vector2.ZERO
		_accel = Vector2.ZERO
		_prev_rot = rot
		_prev_spin = 0.0
		_alpha = 0.0
		for l in links:
			l.lag_rot = rot
			l.trail = 0.0
			l.bias_now = l.bias
			l.bias2_now = l.bias2
		_primed = true
		return
	var v := (p - _prev_driver) / dt
	var a := (v - _prev_vel) / dt
	_prev_driver = p
	_prev_vel = v
	_accel = _accel.lerp(a, clampf(dt * 22.0, 0.0, 1.0))

	var spin := wrapf(rot - _prev_rot, -PI, PI) / dt
	var alpha := (spin - _prev_spin) / dt
	_prev_rot = rot
	_prev_spin = spin
	_alpha = lerpf(_alpha, alpha, clampf(dt * 22.0, 0.0, 1.0))

	# One time constant per joint out from the base, so joint j is pointing where
	# the driver was j lags ago and the chain holds a bend rather than a pose.
	for j in links.size():
		var l: Link = links[j]
		if lag > 0.0:
			var tc: float = lag * float(j + 1)
			l.lag_rot += wrapf(rot - l.lag_rot, -PI, PI) * clampf(dt / tc, 0.0, 1.0)
			l.trail = wrapf(rot - l.lag_rot, -PI, PI)
		else:
			l.lag_rot = rot
			l.trail = 0.0
		# The rest angle travels outward on the same principle. A flick handed to
		# every joint at once cannot be anything but a rigid swing.
		if bias_travel > 0.0:
			var bk: float = clampf(dt / (bias_travel * float(j + 1)), 0.0, 1.0)
			l.bias_now += (l.bias - l.bias_now) * bk
			l.bias2_now += (l.bias2 - l.bias2_now) * bk
		else:
			l.bias_now = l.bias
			l.bias2_now = l.bias2


func _step(skeleton: RigSkeleton, h: float) -> void:
	var soft := 1.0
	for l in links:
		var k: float = maxf(stiffness * soft, 1e-4)
		var c := 2.0 * damping * sqrt(k)
		# Pseudo-force in the accelerating frame, plus real gravity. +y is down. The
		# frame accelerates for two independent reasons — the hips moving inside the
		# body, and the whole body moving through the world — and the chain has to
		# feel both or a stop reads as a freeze.
		var force := (Vector2(0.0, gravity) - (_accel + carrier_accel) * inertia) / soft
		if mode == Mode.OFFSET:
			var acc2 := -k * (l.pos - l.bias2_now) - c * l.vel2 + force
			l.vel2 += acc2 * h
			l.pos += l.vel2 * h
			if l.pos.length() > limit:
				var n := l.pos.normalized()
				l.pos = n * limit
				l.vel2 = l.vel2.slide(n)
		else:
			# Torque = r x F about the joint, with r the half-segment to the next.
			#
			# Divided by the chain's own length, because the conversion above cancels
			# the arm entirely and an *angle* is not a visual quantity: the same
			# 0.1 rad that moves the cat's 0.7-unit tail tip by a tenth of a unit
			# swings the reptile's 3.5-unit tail through half a unit, and measured,
			# that put its tail tip 0.15 below the ground plane on part of every
			# stride — the whole silhouette's lowest point, under the floor. A longer
			# segment genuinely does turn less for the same push, so this is the
			# physics as much as the picture. Normalised against one rig unit — adult
			# shoulder height — so every chain we ship that is shorter than the animal
			# is tall is left exactly as it was, and only the outlier is reined in.
			var dir := Vector2.RIGHT.rotated(skeleton.bones[l.bone].xform.get_rotation())
			var r := dir * l.arm * 0.5
			var torque := (r.x * force.y - r.y * force.x) \
				/ maxf(l.arm * 0.5, 1e-3) / maxf(_span, 1.0)
			var acc := -k * (l.angle - l.bias_now) - c * l.vel + torque - _alpha * inertia
			l.vel += acc * h
			var next: float = clampf(l.angle + l.vel * h, -limit, limit)
			if absf(next) >= limit:
				l.vel = 0.0
			l.angle = next
		soft /= falloff


func _write(skeleton: RigSkeleton) -> void:
	# Each joint applies only the *extra* delay it adds over its parent, so the
	# lags accumulate along the chain exactly once: the tip ends up trailing by
	# the whole of the last joint's time constant while the base trails by the
	# first joint's, and the difference between them is the bend. Composed here
	# rather than fed in as a rest-angle offset because the tail spring's natural
	# frequency (0.8 Hz) sits well below a walking cadence (2 Hz): routed through
	# the spring, a stride-rate lag came out attenuated to a sixth of itself.
	# Kinematic lag and spring inertia are different things and they compose;
	# cascading one through the other just deletes it.
	var carried := 0.0
	for l in links:
		if mode == Mode.OFFSET:
			skeleton.bones[l.bone].offset += l.pos
		else:
			skeleton.bones[l.bone].angle += l.angle - (l.trail - carried)
			carried = l.trail
	if not links.is_empty():
		skeleton.update_from(links[0].bone)
