class_name CreatureRig
extends RefCounted

## The rig: owns the skeleton and every solver that writes to it, and ticks them
## in the one order that is actually correct.
##
## Order matters more than any individual solver here. Body before limbs, because
## the IK has to solve to a hip that has already moved. Limbs before chains,
## because a tail can only lag a hip whose acceleration is already known. Chains
## before skinning, because skinning is the last word. Getting this wrong shows
## up as a one-frame lag that reads as rubberiness and is very hard to diagnose
## from a still.
##
##   1. gait      footfall timing, foot targets, body bob / pitch / roll
##   2. squash    impact deformation
##   3. idle      breathing, blinks, saccades, ear swivel, weight drift
##   4. body      root, spine, neck, head — including head counter-motion
##   5. legs      analytic IK onto the gait's targets
##   6. chains    tail, ears, jowls, wattle, belly
##   7. skin      push bones into the live parts and eyes
##
## The rig is advanced with a fixed step so a creature driven to t = 1.4 s lands
## in exactly the same pose every run; that determinism is what makes the capture
## harness's contact sheets comparable between runs.

const RigBones := preload("res://core/rig/bone_map.gd")

## Fixed simulation step. Long frames are consumed in whole steps rather than
## scaled, so a stall cannot make a spring explode or change the resulting pose.
const STEP := 1.0 / 120.0
const MAX_STEPS := 16
## Fore-aft head lag per unit of the body's vertical speed, in rig units.
const HEAD_LEAD := 0.06

var skeleton: RigSkeleton
var gait := Gait.new()
var idle := IdleRig.new()
var squash := SquashStretch.new()
var chains: Array[SpringChain] = []
var legs: Array[LegIK.Chain] = []

## Written by `Creature` each frame.
var speed := 0.0
var turn_rate := 0.0
## Where the creature is looking, in rig space. `Vector2.INF` means "no target".
var look_target := Vector2.INF
## 0 = relaxed, 1 = braced. Stiffens the chains and lifts the head.
var tension := 0.0
## Force a `Gait.Kind` instead of deriving it from speed; -1 hands it back.
var gait_override := -1

var _spec: CreatureSpec
var _time := 0.0
var _accum := 0.0
var _ear_near_chain := -1
var _ear_far_chain := -1
var _tail_chain := -1
var _spine_bones := PackedInt32Array()
var _neck_bones := PackedInt32Array()
var _head := -1
var _chest := -1
var _pelvis := -1
var _root := -1
var _head_level := 0.0
var _head_aim := 0.0
var _prev_bob := 0.0


func setup(spec: CreatureSpec, bind_parts: Array[SDFPart], bind_eyes: Array,
		seed_value: int) -> void:
	_spec = spec
	skeleton = RigSkeleton.build(spec, bind_parts, bind_eyes)
	legs = LegIK.gather(skeleton)
	gait.setup(spec, legs)
	idle.setup(spec, seed_value)
	squash.setup(spec)
	_cache_bones()
	_build_chains(spec)
	_time = 0.0
	_accum = 0.0


func _cache_bones() -> void:
	_root = skeleton.index_of(RigBones.ROOT)
	_pelvis = skeleton.index_of(RigBones.PELVIS)
	_chest = skeleton.index_of(RigBones.CHEST)
	_head = skeleton.index_of(RigBones.HEAD)
	_spine_bones = PackedInt32Array()
	for i in RigBones.SPINE_BONES:
		var b := skeleton.index_of(RigBones.spine_bone(i))
		if b >= 0:
			_spine_bones.append(b)
	_neck_bones = PackedInt32Array()
	for i in RigBones.NECK_BONES:
		var b := skeleton.index_of(RigBones.neck_bone(i))
		if b >= 0:
			_neck_bones.append(b)


## Chain tuning. The numbers are the character of the animal as much as the
## proportions are: a stiff, high-frequency tail belongs to a nervous animal and
## a slack low-frequency one to a heavy relaxed animal, and the difference is
## legible at a glance.
func _build_chains(spec: CreatureSpec) -> void:
	chains.clear()
	# The tail is the loudest secondary motion the creature has: low stiffness so
	# it keeps going after the hips stop, and inertia well above 1 so it reads as
	# heavy rope rather than as a wire.
	_tail_chain = _add_chain("tail", RigBones.SIDE_NONE, RigBones.PELVIS,
		SpringChain.Mode.ANGULAR, lerpf(15.0, 34.0, spec.energy), 0.52,
		0.9, 2.6, 0.70)
	_ear_near_chain = _add_chain("ear", RigBones.SIDE_NEAR, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 210.0, 0.90, 0.0, 0.55, 0.42)
	_ear_far_chain = _add_chain("ear", RigBones.SIDE_FAR, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 210.0, 0.90, 0.0, 0.55, 0.42)
	_add_chain("crest", RigBones.SIDE_NONE, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 120.0, 0.72, 0.25, 0.9, 0.5)
	_add_chain("wattle", RigBones.SIDE_NONE, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 44.0, 0.55, 1.6, 1.25, 0.85)
	_add_chain("jowl", RigBones.SIDE_NEAR, RigBones.HEAD,
		SpringChain.Mode.OFFSET, 60.0, 0.58, 0.9, 1.1, 0.045)
	_add_chain("jowl", RigBones.SIDE_FAR, RigBones.HEAD,
		SpringChain.Mode.OFFSET, 60.0, 0.58, 0.9, 1.1, 0.045)
	_add_chain("belly", RigBones.SIDE_NONE, RigBones.spine_bone(1),
		SpringChain.Mode.OFFSET, 78.0, 0.50, 0.7, 1.0, 0.035)


func _add_chain(base: String, side: int, driver: StringName, mode: int,
		stiffness: float, damping: float, gravity: float, inertia: float,
		limit: float) -> int:
	var joints := PackedInt32Array()
	var i := 0
	while true:
		var b := skeleton.index_of(RigBones.chain_bone(base, side, i))
		if b < 0:
			break
		joints.append(b)
		i += 1
	if joints.is_empty():
		return -1
	var c := SpringChain.new()
	c.mode = mode
	c.stiffness = stiffness
	c.damping = damping
	c.gravity = gravity
	c.inertia = inertia
	c.limit = limit
	var d := skeleton.index_of(driver)
	c.setup(skeleton, joints, d if d >= 0 else joints[0])
	c.settle()
	chains.append(c)
	return chains.size() - 1


## Drop every solver back to rest. Called when a creature spawns or teleports so
## it does not arrive mid-whip.
func settle() -> void:
	gait.settle()
	squash.settle()
	for c in chains:
		c.settle()
	skeleton.reset_pose()
	skeleton.root_xform = Transform2D()
	skeleton.update_pose()


func time() -> float:
	return _time


## Advance by `dt` of wall time, in fixed steps.
func advance(dt: float) -> void:
	if skeleton == null or dt <= 0.0:
		return
	_accum += dt
	var steps := 0
	while _accum >= STEP and steps < MAX_STEPS:
		_accum -= STEP
		steps += 1
		_step(STEP)
	if steps == MAX_STEPS:
		# A long stall: drop the backlog rather than fast-forwarding, which would
		# teleport the feet and break planting.
		_accum = 0.0


func _step(dt: float) -> void:
	_time += dt

	gait.speed = speed
	gait.turn = turn_rate
	gait.set_kind(gait_override if gait_override >= 0 else gait.kind_for_speed(speed))
	gait.advance(dt)

	var impact := gait.landing_impulse()
	if impact > 0.0:
		squash.land(impact)
	squash.advance(dt)

	idle.exertion = gait.exertion
	idle.alertness = clampf(tension, 0.0, 1.0)
	idle.advance(dt)

	skeleton.reset_pose()
	_pose_body(dt)
	skeleton.update_pose()
	_pose_legs()
	for c in chains:
		c.advance(skeleton, dt)
	_pose_ears()
	skeleton.update_pose()


# ---------------------------------------------------------------------------
# Body
# ---------------------------------------------------------------------------

func _pose_body(dt: float) -> void:
	# The whole rig sits under one transform so bob, surge and squash apply to
	# the animal without disturbing the ground-locked bone frame the feet are
	# planted against.
	var bank: float = clampf(turn_rate * 0.28, -0.35, 0.35)
	skeleton.root_xform = Transform2D(0.0, Vector2(
		gait.surge + idle.weight_shift.x,
		gait.bob + idle.weight_shift.y))

	if _pelvis >= 0:
		var p := skeleton.bones[_pelvis]
		p.angle += gait.pitch
		# Roll is invisible in a strict side view, so it is expressed the way a
		# side view actually shows it: the near half of the body rides slightly
		# higher or lower than the far half, plus a touch of whole-body lean.
		p.angle += (gait.roll + idle.weight_roll + bank) * 0.22
		p.bone_scale = squash.scale_vector()

	# Spine: breathing swell, the lateral wave for sprawling gaits, and a bend
	# into the turn distributed evenly so no single joint cranks.
	var swell: float = idle.breath_swell()
	for i in _spine_bones.size():
		var b := skeleton.bones[_spine_bones[i]]
		var t: float = float(i) / maxf(float(_spine_bones.size() - 1), 1.0)
		b.angle += gait.undulation * sin(TAU * (t * 0.8 - gait.cycle))
		b.angle += -bank * 0.20
		# Ribcage expands most in the middle of the trunk, tapering to the hips.
		var swell_here: float = swell * (1.0 - absf(t - 0.55) * 1.2)
		b.bone_scale *= Vector2(1.0, 1.0 + swell_here)

	if _chest >= 0:
		skeleton.bones[_chest].bone_scale *= Vector2(1.0 + swell * 0.7, 1.0 + swell * 1.3)

	_pose_head(dt)


## Head stabilisation and aim.
##
## The head counter-rotating and counter-translating against the body is the
## clearest single signal that an animal has a nervous system. A walking cat's
## skull stays remarkably level while its shoulders rise and fall underneath it;
## an animated character whose head rides the body bob rigidly looks like a toy
## on a stick.
func _pose_head(dt: float) -> void:
	# A *velocity*, not the per-step difference it used to be: a lead written as
	# a raw delta silently scales with the step size, and at 120 Hz it came to a
	# third of a pixel — a term that looked deliberate and did nothing.
	var bob_vel: float = clampf((gait.bob - _prev_bob) / maxf(dt, 1e-5), -2.0, 2.0)
	_prev_bob = gait.bob
	# Track the body's vertical motion with a lag, then cancel most of it.
	_head_level = lerpf(_head_level, gait.bob, clampf(dt * 11.0, 0.0, 1.0))
	var cancel: float = -(_head_level * 0.62)

	var aim := 0.0
	if look_target != Vector2.INF and _head >= 0:
		var from: Vector2 = skeleton.bones[_head].rest_xform.origin
		var to_dir := look_target - from
		if to_dir.length_squared() > 1e-8:
			var rest_dir: float = skeleton.bones[_head].rest_xform.get_rotation()
			aim = clampf(wrapf(to_dir.angle() - rest_dir, -PI, PI), -0.55, 0.55)
	# The head leads a turn and the neck follows it, never the other way round.
	_head_aim = lerpf(_head_aim, aim - clampf(turn_rate * 0.18, -0.3, 0.3),
		clampf(dt * 7.0, 0.0, 1.0))

	# Distribute the aim down the neck so the join stays smooth, with the head
	# itself taking the largest share.
	for i in _neck_bones.size():
		var b := skeleton.bones[_neck_bones[i]]
		b.angle += _head_aim * 0.22
		b.offset += Vector2(0.0, cancel * 0.35 / maxf(float(_neck_bones.size()), 1.0))
	if _head >= 0:
		var h := skeleton.bones[_head]
		h.angle += _head_aim * 0.56 - gait.pitch * 0.7
		# The muzzle noses forward as the shoulders drop out from under it and
		# settles back as they rise. Small — a couple of pixels at walking pace —
		# but it is the difference between a head that is carried and one bolted
		# to the spine.
		h.offset += Vector2(-bob_vel * HEAD_LEAD, cancel)
		# A braced animal carries its head higher and further forward.
		h.offset += Vector2(0.012, -0.020) * tension


# ---------------------------------------------------------------------------
# Legs
# ---------------------------------------------------------------------------

func _pose_legs() -> void:
	for i in legs.size():
		var c: LegIK.Chain = legs[i]
		if not c.valid or i >= gait.feet.size():
			continue
		var f: Gait.Foot = gait.feet[i]
		if not f.present:
			continue
		LegIK.apply(skeleton, c, f.target, f.pitch)


# ---------------------------------------------------------------------------
# Ears
# ---------------------------------------------------------------------------

func _pose_ears() -> void:
	if _ear_near_chain >= 0:
		chains[_ear_near_chain].set_bias(idle.ear_near, 0.55)
	if _ear_far_chain >= 0:
		chains[_ear_far_chain].set_bias(idle.ear_far, 0.55)


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

## Push the solved pose into the renderer's live arrays.
func write(bind_parts: Array[SDFPart], live_parts: Array[SDFPart],
		bind_eyes: Array, live_eyes: Array) -> void:
	skeleton.apply(bind_parts, live_parts)
	idle.write_eyes(live_eyes, bind_eyes)
	skeleton.apply_eyes(live_eyes)


## Tail carry: raised when happy, tucked when frightened, in [-1, 1].
func set_tail_carry(amount: float) -> void:
	if _tail_chain >= 0:
		chains[_tail_chain].set_bias(clampf(amount, -1.0, 1.0) * -0.30, 0.86)


func hear(direction: Vector2, strength: float = 1.0) -> void:
	idle.hear(direction, strength)
