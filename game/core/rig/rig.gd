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
## Fore-aft head lag per unit of the shoulder's vertical speed, in rig units.
const HEAD_LEAD := 0.025
## Fraction of the shoulder's stride ripple the neck absorbs. Not 1.0: a head
## welded level is as dead a tell as a head welded to the spine.
const HEAD_STEADY := 0.80

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
## Midpoint of the trunk in rig space. Trunk pitch turns about this rather than
## about the hips; see `_pose_body`.
var _trunk_pivot := Vector2.ZERO
var _head_aim := 0.0
## Where the skull is riding, slow-followed, and the correction applied to it
## last frame. The head is stabilised against its own measured travel rather
## than against the gait's bob; see `_pose_head`.
var _head_level := 0.0
var _head_fix := 0.0
## Vertical speed of the shoulder, which is what the muzzle leads against.
var _prev_chest := 0.0
var _chest_vel := 0.0
var _prev_speed := 0.0
var _carrier_accel := 0.0
## Mood tail carry, kept here rather than written straight into the chain: the
## idle layer wants to add its own wander to the same rest angle, and whichever
## of the two wrote last would otherwise erase the other.
var _tail_carry := 0.0


## `body_scale` is the creature's growth scale. The bind pose handed in has
## already been scaled by it, so anything the gait reads out of the spec in
## absolute units — the bob, which is authored against adult height — has to be
## brought onto the same footing or a kitten inherits an adult's amplitude.
func setup(spec: CreatureSpec, bind_parts: Array[SDFPart], bind_eyes: Array,
		seed_value: int, body_scale: float = 1.0) -> void:
	_spec = spec
	skeleton = RigSkeleton.build(spec, bind_parts, bind_eyes)
	legs = LegIK.gather(skeleton)
	gait.setup(spec, legs, body_scale)
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
	# Halfway between the girdles. A quadruped pitches about somewhere near its
	# own centre of mass, not about its hips, and the difference is not cosmetic:
	# see `_pose_body`.
	if _pelvis >= 0 and _chest >= 0:
		_trunk_pivot = (skeleton.bones[_pelvis].rest_xform.origin
			+ skeleton.bones[_chest].rest_xform.origin) * 0.5


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
	if _tail_chain >= 0:
		# ~120 ms of trail behind the hips. Now that the pelvis actually pitches
		# and counter-rolls there is something to trail *behind*: without this the
		# tail inherits every hip rotation on the same frame it happens and reads
		# as a welded rod, however soft the spring under it is.
		chains[_tail_chain].lag = 0.12
	_ear_near_chain = _add_chain("ear", RigBones.SIDE_NEAR, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 210.0, 0.90, 0.0, 0.55, 0.42)
	_ear_far_chain = _add_chain("ear", RigBones.SIDE_FAR, RigBones.HEAD,
		SpringChain.Mode.ANGULAR, 210.0, 0.90, 0.0, 0.55, 0.42)
	# Ears are light and short, so they trail by about the length of one blink —
	# enough to keep a swivel from snapping, not enough to look loose.
	if _ear_near_chain >= 0:
		chains[_ear_near_chain].lag = 0.045
	if _ear_far_chain >= 0:
		chains[_ear_far_chain].lag = 0.045
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
	# Prime the followers on the rest pose. Left at zero they start a whole
	# body-height away from the bones they track, and the head arrives craned
	# back for the first half-second of every spawn.
	_head_level = skeleton.bones[_head].xform.origin.y if _head >= 0 else 0.0
	_head_fix = 0.0
	_prev_chest = skeleton.bones[_chest].xform.origin.y if _chest >= 0 else 0.0
	_chest_vel = 0.0


func time() -> float:
	return _time


## The vertical correction the neck applied to the skull this step. Exposed for
## the motion probe: whether the stabiliser is working is a question about how
## much of this reaches the head bone, and that has to be measured against the
## head's own travel rather than reasoned about.
func head_fix() -> float:
	return _head_fix


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
	# The neck runs *after* the body has been pushed through the tree, because it
	# is correcting the skull against where the body actually put it and there is
	# no way to know that until the body pose exists. It used to read the previous
	# frame's transform and subtract its own last output to recover the raw — which
	# is sound at a stroll and falls apart as the cadence climbs, since one frame of
	# staleness is a fixed slice of time and therefore a growing slice of a phase.
	# Measured: the correction removed 55% of the skull's travel at a walk and 27%
	# at a trot, from the same gain, because at a trot it was arriving late enough
	# to be partly adding.
	_stabilise_head(dt)
	_pose_legs()
	# The creature crosses the desktop by moving its own node, which never touches
	# a bone transform, so the chains cannot see it happen. Differentiate the speed
	# the brain wrote and hand the result over: braking from a run is the textbook
	# reason a tail keeps going, and until this existed it was the one event the
	# springs were structurally unable to feel. Clamped and filtered because a
	# scripted speed change is a step, and an undamped step here would fold a tail
	# through the hips in a single frame.
	_carrier_accel = lerpf(_carrier_accel,
		clampf((speed - _prev_speed) / dt, -40.0, 40.0), clampf(dt * 20.0, 0.0, 1.0))
	_prev_speed = speed
	for c in chains:
		c.carrier_accel = Vector2(_carrier_accel, 0.0)
		c.advance(skeleton, dt)
	_pose_ears()
	_pose_tail()
	skeleton.update_pose()


# ---------------------------------------------------------------------------
# Body
# ---------------------------------------------------------------------------

func _pose_body(dt: float) -> void:
	# The whole rig sits under one transform so bob, surge and squash apply to
	# the animal without disturbing the ground-locked bone frame the feet are
	# planted against.
	var bank: float = clampf(turn_rate * 0.28, -0.35, 0.35)
	# Trunk pitch turns about the middle of the back, not about the hips.
	#
	# The amount of pitch was never the problem — it measured 5.3° at a walk, which
	# is a real cat. The *pivot* was. Hung off the pelvis, every degree of it threw
	# the whole animal in front of the hips through a 0.9-unit lever, so the visible
	# result was the forehand and the skull heaving up and down while the trunk
	# itself never appeared to rotate at all: the head travelled 1.87 times as far
	# as the shoulders under it, measured. Pivoting at the centre turns the same
	# rotation into a see-saw — croup up as the forehand drops — which is what
	# pitch actually looks like on an animal, and it halves the lever the neck then
	# has to fight.
	var attitude: float = gait.pitch + idle.weight_pitch
	skeleton.root_xform = Transform2D(attitude,
		_trunk_pivot - _trunk_pivot.rotated(attitude)
		+ Vector2(gait.surge + idle.weight_shift.x, gait.bob + idle.weight_shift.y))

	# Girdle counter-rotation. A quadruped's shoulders and hips rotate in
	# opposite senses about the long axis, and the only part of that a strict
	# side view can show is the two ends of the trunk pitching against each
	# other. So the twist is split: half of it backwards into the croup, all of
	# it forwards along the lumbar run, which leaves the withers and the croup
	# equal and opposite about the middle of the back. That is the difference
	# between a supple spine and a plank with legs.
	var twist: float = gait.girdle_twist
	if _pelvis >= 0:
		var p := skeleton.bones[_pelvis]
		p.angle += -twist * 0.5
		# Roll is invisible in a strict side view, so it is expressed the way a
		# side view actually shows it: the near half of the body rides slightly
		# higher or lower than the far half, plus a touch of whole-body lean.
		p.angle += gait.roll + (idle.weight_roll + bank) * 0.22
		p.bone_scale = squash.scale_vector()

	# Spine: breathing swell, the lateral wave for sprawling gaits, the lumbar
	# share of the girdle twist, and a bend into the turn — all distributed
	# evenly so no single joint cranks.
	var swell: float = idle.breath_swell()
	var spine_n: float = maxf(float(_spine_bones.size()), 1.0)
	# Lumbar flexion is weighted toward the loin — the joints just ahead of the
	# hips, which is where a cat's back actually hinges. Spread evenly it arcs the
	# ribcage too, and a ribcage is a barrel of bone that does not bend.
	var flex_w := PackedFloat32Array()
	var flex_sum := 0.0
	for i in _spine_bones.size():
		var t: float = float(i) / maxf(float(_spine_bones.size() - 1), 1.0)
		var w: float = 1.0 - 0.65 * t
		flex_w.append(w)
		flex_sum += w
	for i in _spine_bones.size():
		var b := skeleton.bones[_spine_bones[i]]
		var t: float = float(i) / maxf(float(_spine_bones.size() - 1), 1.0)
		b.angle += gait.undulation * sin(TAU * (t * 0.8 - gait.cycle))
		b.angle += -bank * 0.20
		b.angle += twist / spine_n
		# Rounding the back means rotating each joint *up*, and up is −y here, so
		# the sign is negative. The chest gets the whole accumulated bend taken back
		# out below, which is what keeps this a change of shape: the topline bows
		# while the forehand it carries stays pointing where it was.
		b.angle += -gait.flex * flex_w[i] / maxf(flex_sum, 1e-3)
		# Ribcage expands most in the middle of the trunk, tapering to the hips.
		var swell_here: float = swell * (1.0 - absf(t - 0.55) * 1.2)
		b.bone_scale *= Vector2(1.0, 1.0 + swell_here)

	if _chest >= 0:
		var c := skeleton.bones[_chest]
		c.bone_scale *= Vector2(1.0 + swell * 0.7, 1.0 + swell * 1.3)
		c.angle += gait.flex
		# The scapula riding up the ribcage under load. Written in rig space and
		# converted into the chest's rest frame once, because that frame is tilted
		# along the body axis on every species we ship — pushed in raw it would
		# slide the shoulder forwards as much as upwards.
		c.offset += c.rest_xform.basis_xform_inv(Vector2(0.0, -gait.withers))

	_pose_head(dt, twist)


## Head stabilisation and aim.
##
## The head counter-rotating and counter-translating against the body is the
## clearest single signal that an animal has a nervous system. A walking cat's
## skull stays remarkably level while its shoulders rise and fall underneath it;
## an animated character whose head rides the body bob rigidly looks like a toy
## on a stick.
func _pose_head(dt: float, twist: float) -> void:
	var chest_y: float = skeleton.bones[_chest].xform.origin.y if _chest >= 0 else 0.0
	# A *velocity*, not the per-step difference it used to be: a lead written as
	# a raw delta silently scales with the step size, and at 120 Hz it came to a
	# third of a pixel — a term that looked deliberate and did nothing. Filtered,
	# because the shoulder takes a step at every footfall and the one-frame
	# derivative of a step is a spike several times the motion it describes.
	_chest_vel = lerpf(_chest_vel,
		clampf((chest_y - _prev_chest) / maxf(dt, 1e-5), -3.0, 3.0),
		clampf(dt * 18.0, 0.0, 1.0))
	_prev_chest = chest_y

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
	# itself taking the largest share. The offsets are authored in rig space and
	# converted into each bone's rest frame once, because that frame is the neck
	# direction — a steep diagonal on every species we ship. Written in raw, a
	# "vertical" stabiliser was being applied along the neck instead: it threw
	# the skull forwards and carried a third of itself back into vertical with
	# the wrong sign. The neck takes a third of the correction and the skull the
	# rest, so the join bends instead of the head sliding off the end of it.
	for i in _neck_bones.size():
		skeleton.bones[_neck_bones[i]].angle += _head_aim * 0.22
	if _head >= 0:
		var h := skeleton.bones[_head]
		# The skull rejects both trunk attitude channels, not just the pitch. The
		# withers carry half the girdle twist, and a head that inherited it would
		# nod once per forelimb — the exact tell of a character rigged as one
		# rigid chain. Countering it here leaves the *neck* carrying the motion,
		# which is what a walking cat actually looks like from the side.
		h.angle += _head_aim * 0.56 - gait.pitch * 0.7 - twist * 0.45
		# The muzzle noses forward as the shoulders drop out from under it and
		# settles back as they rise. Small — a couple of pixels at walking pace —
		# but it is the difference between a head that is carried and one bolted
		# to the spine. A braced animal also carries its head higher and further
		# forward. In rig space, converted into the skull's rest frame once, because
		# that frame is the neck direction — a steep diagonal on every species we
		# ship. Written in raw, a "forward" lead would be applied along the neck.
		h.offset += h.rest_xform.basis_xform_inv(
			Vector2(-_chest_vel * HEAD_LEAD + 0.012 * tension, -0.020 * tension))


## Hold the skull level while the body works underneath it.
##
## The single clearest signal that an animal has a nervous system, and the one
## the blind review kept missing: a walking cat's head barely moves while its
## shoulders rise and fall by a tenth of its own height. A head that rides the
## body rigidly is a toy on a stick, and — measured — this rig's skull was
## travelling 35 px at ship size on a 10 px bob, because the trunk swung it
## through a long lever and nothing took that back out.
##
## Runs after `update_pose`, on purpose. The correction is a response to where
## the body actually put the skull, and that is not knowable until the body pose
## has been pushed through the tree; the previous version read a one-frame-stale
## transform and subtracted its own last output to recover the raw, which works
## at a stroll and decays as the cadence rises, because a fixed slice of time is
## a growing slice of a phase.
func _stabilise_head(dt: float) -> void:
	if _head < 0:
		return
	var head_y: float = skeleton.bones[_head].xform.origin.y
	# Split the head's vertical motion into the part it should follow and the part
	# it should reject. `_head_level` is a slow follower, so it tracks postural
	# change — an animal crouches as it settles into a walk, and a resting one
	# raises and lowers its head on purpose, both of which must survive — while
	# sliding straight past the stride ripple. What is left is the ripple, and that
	# is what gets cancelled.
	#
	# The time constant is tied to the cadence rather than fixed. The follower has
	# exactly one job, and "the stride" is a different frequency at every gait;
	# pinned at 0.45 s it sat less than an octave below a trot and tracked a third
	# of the very ripple it was meant to ignore.
	var tau: float = clampf(1.7 / maxf(gait.frequency, 0.5), 0.4, 2.0)
	_head_level = lerpf(_head_level, head_y, clampf(dt / tau, 0.0, 1.0))
	# Faded out at a standstill. There is no stride ripple to reject when the animal
	# is not walking, and the idle layer's postural motion — breath lifting the
	# shoulders, weight rocking between the girdles — is motion the head is supposed
	# to ride. Left running at rest the stabiliser only deletes it, which costs the
	# idle exactly the liveness it exists to provide.
	var gate: float = clampf(gait.frequency * 1.6, 0.0, 1.0)
	_head_fix = -(head_y - _head_level) * HEAD_STEADY * gate
	if absf(_head_fix) < 1e-6:
		return
	# The neck takes a third of it and the skull the rest, so the join bends
	# instead of the head sliding off the end of it.
	var neck_n: float = maxf(float(_neck_bones.size()), 1.0)
	for i in _neck_bones.size():
		_shift_bone(_neck_bones[i], _head_fix * 0.34 / neck_n)
	_shift_bone(_head, _head_fix * 0.66)
	# Only the neck and everything hanging off it needs rebuilding; the trunk and
	# the legs are already correct and the array is parent-first.
	skeleton.update_from(_neck_bones[0] if _neck_bones.size() > 0 else _head)


## Move one bone `amount` rig units vertically — genuinely that far, whatever the
## chain above it is doing.
##
## A bone's `offset` is expressed in its own local frame, so asking for a vertical
## shift means inverting the frame first. Converting through the bone's *rest*
## transform is only right if nothing above it has been scaled, and something
## always has: breathing multiplies a factor into all three spine bones and the
## chest, and squash multiplies another into the pelvis, and they compound down
## the chain. Measured with a constant correction and a mean, which is the only
## way to ask this question without phase muddying the answer: 0.060 requested,
## 0.0513 delivered — 86%, modulated by the breath. Inverting the live frame
## instead delivers what was asked for, and `_stabilise_head` runs after the pose
## is built precisely so that frame is available.
func _shift_bone(index: int, amount: float) -> void:
	var b := skeleton.bones[index]
	var frame := b.rest_local
	if b.parent >= 0:
		frame = skeleton.bones[b.parent].xform * b.rest_local
	b.offset += frame.affine_inverse().basis_xform(Vector2(0.0, amount))


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
# Tail
# ---------------------------------------------------------------------------

## Mood carry plus the idle layer's wander, written together every step. The
## spring still does the settling — this only moves the angle it settles toward.
func _pose_tail() -> void:
	if _tail_chain >= 0:
		chains[_tail_chain].set_bias(_tail_carry * -0.30 + idle.tail_sway, 0.86)


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
	_tail_carry = clampf(amount, -1.0, 1.0)


func hear(direction: Vector2, strength: float = 1.0) -> void:
	idle.hear(direction, strength)
