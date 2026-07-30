class_name LegIK
extends RefCounted

## Analytic inverse kinematics for limbs, plus the bookkeeping that keeps a
## planted foot planted.
##
## Two solvers:
##   * two-bone — law of cosines, one circle intersection. Exact, branchless,
##     and stable right up to full extension.
##   * three-bone — a digitigrade hind leg (femur, tibia, metatarsus). A third
##     bone makes the chain redundant, so we remove the freedom the way the
##     animal does: the hock fold is mechanically coupled to how compressed the
##     leg is. Fold first, then solve the remaining two bones exactly.
##
## The bend direction is never hardcoded. It is read off the bind pose at build
## time (`pole_sign`), which means a cat's rearward stifle and a bird's forward
## knee both come out right without a per-species switch.
##
## Foot planting lives in `Gait`, which hands this class a target already
## expressed in rig space. The contract that matters is that the target does not
## drift: sliding feet are the loudest tell of amateur animation.

const RigBones := preload("res://core/rig/bone_map.gd")


## One solvable limb, resolved against a built skeleton.
class Chain:
	## IK segment bones, proximal → distal. Two or three entries.
	var segs := PackedInt32Array()
	var lengths := PackedFloat32Array()
	## Bone whose origin is the ankle — the IK end effector.
	var ankle_bone := -1
	## Ground-contact bones posed separately so the foot can roll over the toe.
	var foot_bones := PackedInt32Array()
	var root_bone := -1
	## +1 or -1: which side of the root→ankle line the mid joint sits on.
	var pole_sign := 1.0
	## Interior angle at the middle joint in the bind pose, for three-bone legs.
	var fold_rest := 0.0
	var root_bind := Vector2.ZERO
	var ankle_bind := Vector2.ZERO
	## Straight-line reach, used by the gait for step height and body support.
	var reach := 0.0
	var fore := true
	var far := false
	var valid := false

	func total_length() -> float:
		var s := 0.0
		for l in lengths:
			s += l
		return s


## Resolve every limb present in `skeleton` into a solvable chain, ordered
## fore-near, fore-far, hind-near, hind-far. Missing limbs come back invalid so
## a biped and a quadruped share one code path.
static func gather(skeleton: RigSkeleton) -> Array[Chain]:
	var out: Array[Chain] = []
	for fore in [true, false]:
		for far in [false, true]:
			out.append(_build_chain(skeleton, fore, far))
	return out


static func _build_chain(skeleton: RigSkeleton, fore: bool, far: bool) -> Chain:
	var c := Chain.new()
	c.fore = fore
	c.far = far
	var order := [RigBones.Seg.UPPER, RigBones.Seg.LOWER, RigBones.Seg.CANNON]
	var seq := PackedInt32Array()
	for seg in order:
		var i := skeleton.index_of(RigBones.limb_bone(fore, far, false, seg))
		if i >= 0:
			seq.append(i)
	if seq.size() < 2:
		return c

	# The end effector is the first ground-contact bone; anything past it is the
	# foot, which the gait pitches independently of the IK.
	var ankle := -1
	for seg in [RigBones.Seg.FOOT, RigBones.Seg.TOE]:
		var i := skeleton.index_of(RigBones.limb_bone(fore, far, false, seg))
		if i >= 0:
			if ankle < 0:
				ankle = i
			c.foot_bones.append(i)
	if ankle < 0:
		ankle = skeleton.index_of(RigBones.limb_bone(fore, far, false, -1))
	if ankle < 0:
		return c

	c.segs = seq
	c.ankle_bone = ankle
	c.root_bone = seq[0]
	c.root_bind = skeleton.bones[seq[0]].rest_xform.origin
	c.ankle_bind = skeleton.bones[ankle].rest_xform.origin
	for i in seq.size():
		var next: int = seq[i + 1] if i + 1 < seq.size() else ankle
		c.lengths.append(skeleton.bones[seq[i]].rest_xform.origin.distance_to(
			skeleton.bones[next].rest_xform.origin))
	c.reach = c.total_length()

	# Which way the limb folds, straight off the bind pose.
	var mid: Vector2 = skeleton.bones[seq[1]].rest_xform.origin
	var span := c.ankle_bind - c.root_bind
	var arm := mid - c.root_bind
	var cross := span.x * arm.y - span.y * arm.x
	c.pole_sign = -1.0 if cross < 0.0 else 1.0

	if seq.size() >= 3:
		var j2: Vector2 = skeleton.bones[seq[2]].rest_xform.origin
		var u := (mid - j2).normalized()
		var v := (c.ankle_bind - j2).normalized()
		c.fold_rest = acos(clampf(u.dot(v), -1.0, 1.0))
	c.valid = true
	return c


## Two-bone solve. Returns the mid-joint position.
static func solve_two(root: Vector2, target: Vector2, l1: float, l2: float,
		pole_sign: float) -> Vector2:
	var span := target - root
	var d: float = clampf(span.length(), absf(l1 - l2) + 1e-4, l1 + l2 - 1e-4)
	var dir: Vector2 = span.normalized() if span.length_squared() > 1e-10 else Vector2.DOWN
	# Distance along the root→target line to the foot of the mid joint.
	var a := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var perp := Vector2(-dir.y, dir.x) * pole_sign
	return root + dir * a + perp * h


## Three-bone (digitigrade) solve. Returns [mid, hock].
##
## The fold at the hock is not free: as the leg compresses the whole Z closes up,
## and as it extends the hock opens toward straight. Choosing that angle first
## collapses the redundant chain to an exact two-bone problem on (l1, virtual),
## which is then unfolded back into l2 and l3.
static func solve_three(root: Vector2, target: Vector2, l1: float, l2: float,
		l3: float, pole_sign: float, fold_rest: float) -> PackedVector2Array:
	var total := l1 + l2 + l3
	var d: float = clampf((target - root).length(), 1e-4, total - 1e-4)
	# 0 = fully gathered, 1 = fully extended.
	var extend: float = clampf(d / maxf(total, 1e-4), 0.0, 1.0)
	var fold: float = clampf(lerpf(fold_rest * 0.55, PI * 0.94, extend), 0.15, PI * 0.97)
	# Length of the l2+l3 pair once folded to `fold` (interior angle at the hock).
	var virt := sqrt(maxf(l2 * l2 + l3 * l3 - 2.0 * l2 * l3 * cos(fold), 1e-6))
	var mid := solve_two(root, target, l1, virt, pole_sign)

	# Unfold: the hock sits off the mid→target chord, on the opposite side to the
	# stifle, which is exactly what makes a hind leg read as a Z and not a bow.
	var chord := target - mid
	var cl: float = maxf(chord.length(), 1e-5)
	var cdir := chord / cl
	var a := (l2 * l2 - l3 * l3 + cl * cl) / (2.0 * cl)
	var h := sqrt(maxf(l2 * l2 - a * a, 0.0))
	var perp := Vector2(-cdir.y, cdir.x) * -pole_sign
	var hock := mid + cdir * a + perp * h
	return PackedVector2Array([mid, hock])


## Solve `chain` to `target` and write the result into the skeleton.
## `foot_pitch` rotates the ground-contact bones: negative lifts the toe at
## touchdown, positive rolls onto it at push-off.
static func apply(skeleton: RigSkeleton, chain: Chain, target: Vector2,
		foot_pitch: float) -> void:
	if not chain.valid:
		return
	var root: Vector2 = skeleton.bones[chain.root_bone].xform.origin
	var joints := PackedVector2Array()
	if chain.segs.size() >= 3:
		joints = solve_three(root, target, chain.lengths[0], chain.lengths[1],
			chain.lengths[2], chain.pole_sign, chain.fold_rest)
	else:
		joints = PackedVector2Array([solve_two(root, target, chain.lengths[0],
			chain.lengths[1], chain.pole_sign)])

	var prev := root
	for i in chain.segs.size():
		var next: Vector2 = joints[i] if i < joints.size() else target
		skeleton.aim_bone(chain.segs[i], next - prev)
		skeleton.update_from(chain.segs[i])
		prev = next

	# The foot is not part of the IK: it tracks the ground plane, so it stays
	# flat through stance no matter what the leg above it is doing.
	for fb in chain.foot_bones:
		var b := skeleton.bones[fb]
		var rest_dir: float = b.rest_xform.get_rotation()
		skeleton.aim_bone(fb, Vector2.RIGHT.rotated(rest_dir + foot_pitch))
		skeleton.update_from(fb)
