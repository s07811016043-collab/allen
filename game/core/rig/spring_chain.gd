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
	## Extra rest bias written from outside (ear swivel, mood tail carry).
	var bias := 0.0
	var bias2 := Vector2.ZERO


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
## Musculature thins toward the tip: each joint further out is this much softer
## and this much lighter, which is why the last third of a tail whips hardest.
var falloff := 1.18

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
	for i in bone_indices:
		var l := Link.new()
		l.bone = i
		l.arm = maxf(skeleton.bones[i].length, 0.01)
		links.append(l)


func is_empty() -> bool:
	return links.is_empty()


## Bias the whole chain away from rest — an ear swivelling toward a sound, a
## tail lifted in greeting. Applied as a rest-angle offset so the spring still
## does the settling.
func set_bias(radians: float, taper: float = 1.0) -> void:
	var k := 1.0
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
		l.vel = 0.0
		l.pos = l.bias2
		l.vel2 = Vector2.ZERO
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


func _step(skeleton: RigSkeleton, h: float) -> void:
	var soft := 1.0
	for l in links:
		var k: float = maxf(stiffness * soft, 1e-4)
		var c := 2.0 * damping * sqrt(k)
		# Pseudo-force in the accelerating frame, plus real gravity. +y is down.
		var force := (Vector2(0.0, gravity) - _accel * inertia) / soft
		if mode == Mode.OFFSET:
			var acc2 := -k * (l.pos - l.bias2) - c * l.vel2 + force
			l.vel2 += acc2 * h
			l.pos += l.vel2 * h
			if l.pos.length() > limit:
				var n := l.pos.normalized()
				l.pos = n * limit
				l.vel2 = l.vel2.slide(n)
		else:
			# Torque = r x F about the joint, with r the half-segment to the next.
			var dir := Vector2.RIGHT.rotated(skeleton.bones[l.bone].xform.get_rotation())
			var r := dir * l.arm * 0.5
			var torque := (r.x * force.y - r.y * force.x) / maxf(l.arm * 0.5, 1e-3)
			var acc := -k * (l.angle - l.bias) - c * l.vel + torque - _alpha * inertia
			l.vel += acc * h
			var next: float = clampf(l.angle + l.vel * h, -limit, limit)
			if absf(next) >= limit:
				l.vel = 0.0
			l.angle = next
		soft /= falloff


func _write(skeleton: RigSkeleton) -> void:
	for l in links:
		if mode == Mode.OFFSET:
			skeleton.bones[l.bone].offset += l.pos
		else:
			skeleton.bones[l.bone].angle += l.angle
	if not links.is_empty():
		skeleton.update_from(links[0].bone)
