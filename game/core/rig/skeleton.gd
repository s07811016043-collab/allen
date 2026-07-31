class_name RigSkeleton
extends RefCounted

## A named bone tree in rig space, plus the skinning that drives implicit parts
## from it.
##
## Petalia has no mesh, so "skinning" means something simpler than usual: every
## `SDFPart` endpoint is stored in the rest frame of a bone, and each frame we
## push it back out through that bone's live transform. Radii ride along through
## the bone's local deformation, which is what lets a squashed body genuinely
## fatten instead of just scaling on screen.
##
## The tree is *fitted*, not authored. `build` reads a species' bind pose,
## classifies every part with `RigBoneMap`, and lays canonical bones onto the
## geometry it finds. A species therefore gets a correct skeleton for free and
## only has to name bones when it wants to override the fit. See `BONES.md`.

const RigBones := preload("res://core/rig/bone_map.gd")


class Bone:
	var name: StringName = &""
	var parent: int = -1
	var children := PackedInt32Array()
	## Bind-pose transforms. `rest_local` is relative to the parent; the global
	## pair is cached because skinning inverts it once per bind, never per frame.
	var rest_local := Transform2D()
	var rest_xform := Transform2D()
	var rest_inv := Transform2D()
	## Live global transform, rebuilt by `update_pose`.
	var xform := Transform2D()
	## Per-frame animation composed on top of `rest_local`. Three separate
	## channels rather than one Transform2D so the gait can write an offset while
	## the IK writes an angle without either stomping the other.
	var angle := 0.0
	var offset := Vector2.ZERO
	var bone_scale := Vector2.ONE
	## Distance to the primary child — the bone's visual length. Spring chains
	## need it to turn a force into a torque.
	var length := 0.0
	## Limb roots switch this off: a squashed torso must lower the shoulder
	## without also shortening the leg the IK is about to solve to a fixed
	## ground target.
	var inherit_scale := true


## One capsule endpoint pair, expressed in bone rest frames.
class PartBind:
	var part := 0
	var bone_a := 0
	var local_a := Vector2.ZERO
	var bone_b := 0
	var local_b := Vector2.ZERO
	## Unit normal of the bind axis in each driving bone's rest frame. Pushing it
	## through the live transform gives the radius its deformation factor.
	var normal_a := Vector2.ZERO
	var normal_b := Vector2.ZERO


class EyeBind:
	var eye := 0
	var bone := 0
	var local := Vector2.ZERO


var bones: Array[Bone] = []
var part_binds: Array[PartBind] = []
var eye_binds: Array[EyeBind] = []
## Transform of the whole rig. The gait writes body bob, pitch and squash here
## rather than into `root`, so `root` stays a clean ground-locked frame.
var root_xform := Transform2D()

var _by_name := {}


# ---------------------------------------------------------------------------
# Tree construction
# ---------------------------------------------------------------------------

## Rest position and angle are given in *global* rig space; the local transform
## is derived. Parents must already exist — the array stays parent-first, which
## is what makes `update_pose` a single forward sweep.
func add_bone(bone_name: StringName, parent_name: StringName, rest_pos: Vector2,
		rest_angle: float) -> int:
	# A duplicate name is always a fitting bug, and a silent one: the name table
	# keeps the last copy so every lookup finds it, while `_bind_parts_to_bones`
	# scans the array and matches the first, so the parts end up skinned to a bone
	# nothing poses. That cost the bird its wings for a whole round and read as a
	# geometry fault. Cheap to shout about, and it can only fire on a real defect.
	if _by_name.has(bone_name):
		Log.warn("RigSkeleton", "duplicate bone '%s'; the fit is wrong" % bone_name)
	var b := Bone.new()
	b.name = bone_name
	b.parent = index_of(parent_name)
	b.rest_xform = Transform2D(rest_angle, rest_pos)
	var parent_rest := Transform2D()
	if b.parent >= 0:
		parent_rest = bones[b.parent].rest_xform
	b.rest_local = parent_rest.affine_inverse() * b.rest_xform
	b.rest_inv = b.rest_xform.affine_inverse()
	b.xform = b.rest_xform
	var idx := bones.size()
	bones.append(b)
	_by_name[bone_name] = idx
	if b.parent >= 0:
		var p := bones[b.parent]
		p.children.append(idx)
		# The first child defines the parent's length; later children are ears
		# and other branches hanging off the same joint.
		if p.length <= 0.0:
			p.length = rest_pos.distance_to(p.rest_xform.origin)
	return idx


func index_of(bone_name: StringName) -> int:
	return _by_name.get(bone_name, -1)


func has_bone(bone_name: StringName) -> bool:
	return _by_name.has(bone_name)


func bone_position(bone_name: StringName) -> Vector2:
	var i := index_of(bone_name)
	return bones[i].xform.origin if i >= 0 else Vector2.ZERO


# ---------------------------------------------------------------------------
# Posing
# ---------------------------------------------------------------------------

func reset_pose() -> void:
	for b in bones:
		b.angle = 0.0
		b.offset = Vector2.ZERO
		b.bone_scale = Vector2.ONE


func update_pose() -> void:
	update_from(0)


## Recompute bone `first` and everything after it. Parent-first ordering means
## anything before `first` is already correct, so IK can re-solve one limb
## without paying for the whole tree.
func update_from(first: int) -> void:
	for i in range(maxi(first, 0), bones.size()):
		var b := bones[i]
		var local := b.rest_local * Transform2D(b.angle, b.bone_scale, 0.0, b.offset)
		if b.parent < 0:
			b.xform = root_xform * local
			continue
		var pg: Transform2D = bones[b.parent].xform
		if b.inherit_scale:
			b.xform = pg * local
			continue
		# Follow the parent's position and rotation but not its scale, so the
		# squash that compresses the torso does not also shrink this limb.
		b.xform = Transform2D(pg.get_rotation() + local.get_rotation(), pg * local.origin) \
			.scaled_local(b.bone_scale)


## Set `angle` so the bone's own +x axis points along `dir` in rig space. The
## parent must already be up to date.
func aim_bone(i: int, dir: Vector2) -> void:
	if i < 0 or i >= bones.size() or dir.length_squared() < 1e-12:
		return
	var b := bones[i]
	var base := b.rest_local.get_rotation()
	base += bones[b.parent].xform.get_rotation() if b.parent >= 0 else root_xform.get_rotation()
	b.angle = wrapf(dir.angle() - base, -PI, PI)


# ---------------------------------------------------------------------------
# Skinning
# ---------------------------------------------------------------------------

## Push the live pose into `live_parts`. `bind_parts` supplies the authored radii
## and the untouched shading fields, so this never accumulates drift.
func apply(bind_parts: Array[SDFPart], live_parts: Array[SDFPart]) -> void:
	for pb in part_binds:
		var src: SDFPart = bind_parts[pb.part]
		var dst: SDFPart = live_parts[pb.part]
		var ba := bones[pb.bone_a]
		var bb := bones[pb.bone_b]
		dst.a = ba.xform * pb.local_a
		dst.b = bb.xform * pb.local_b
		var sa: float = ba.xform.basis_xform(pb.normal_a).length()
		var sb: float = bb.xform.basis_xform(pb.normal_b).length()
		dst.radius_a = src.radius_a * sa
		dst.radius_b = src.radius_b * sb
		dst.blend = src.blend * maxf(sa, sb)
		# Fur lies along the body, so the groom direction has to rotate with the
		# bone or a curled tail ends up combed against itself.
		dst.groom_angle = src.groom_angle \
			+ (ba.xform.get_rotation() - ba.rest_xform.get_rotation())


func apply_eyes(live_eyes: Array) -> void:
	for eb in eye_binds:
		if eb.eye >= live_eyes.size():
			continue
		var b := bones[eb.bone]
		var live: EyeSpec.Live = live_eyes[eb.eye]
		live.center = b.xform * eb.local
		live.tilt += b.xform.get_rotation() - b.rest_xform.get_rotation()


# ---------------------------------------------------------------------------
# Fitting a canonical skeleton onto a bind pose
# ---------------------------------------------------------------------------

## Build the canonical tree for `spec`, fitted to `bind_parts` and `bind_eyes` —
## the bind pose *after* `Growth` has been applied, so the skeleton matches the
## creature's current age rather than its adult proportions.
static func build(spec: CreatureSpec, bind_parts: Array[SDFPart],
		bind_eyes: Array) -> RigSkeleton:
	var sk := RigSkeleton.new()
	var tags: Array = []
	for p in bind_parts:
		tags.append(RigBones.classify(p.id, int(p.layer)))

	# Limbs whose id never said fore or hind get their girdle from geometry.
	var mid_x := _body_mid_x(bind_parts, tags)
	for i in bind_parts.size():
		var tag = tags[i]
		if tag.slot == RigBones.Slot.LIMB and not RigBones.girdle_stated(bind_parts[i].id):
			tag.fore = _mid(bind_parts[i]).x >= mid_x

	# --- axis anchors -------------------------------------------------------
	var pelvis_p := _axis_anchor(bind_parts, tags, RigBones.Slot.PELVIS, -1.0,
		_axis_anchor(bind_parts, tags, RigBones.Slot.SPINE, -1.0, Vector2(-0.3, -0.5)))
	var chest_p := _axis_anchor(bind_parts, tags, RigBones.Slot.CHEST, 1.0,
		_axis_anchor(bind_parts, tags, RigBones.Slot.SPINE, 1.0, Vector2(0.2, -0.5)))
	var head_c := _centroid(bind_parts, tags, RigBones.Slot.HEAD)
	var head_p := head_c
	if head_c != Vector2.INF:
		# Pivot at the atlas, not the middle of the skull: a head that rotates
		# about its own centroid detaches from the neck the moment it looks up.
		head_p = _axis_anchor(bind_parts, tags, RigBones.Slot.HEAD, -1.0, head_c).lerp(head_c, 0.25)
	else:
		head_p = chest_p + (chest_p - pelvis_p).normalized() * 0.25
	var neck_base := _axis_anchor(bind_parts, tags, RigBones.Slot.NECK, -1.0, chest_p)

	# --- axis chain ---------------------------------------------------------
	sk.add_bone(RigBones.ROOT, &"", Vector2.ZERO, 0.0)
	var axis_dir := (chest_p - pelvis_p).angle()
	sk.add_bone(RigBones.PELVIS, RigBones.ROOT, pelvis_p, axis_dir)
	var prev := RigBones.PELVIS
	for i in RigBones.SPINE_BONES:
		var t := float(i + 1) / float(RigBones.SPINE_BONES + 1)
		var name_i := RigBones.spine_bone(i)
		sk.add_bone(name_i, prev, pelvis_p.lerp(chest_p, t), axis_dir)
		prev = name_i
	sk.add_bone(RigBones.CHEST, prev, chest_p, axis_dir)

	var neck_dir := (head_p - neck_base).angle()
	prev = RigBones.CHEST
	for i in RigBones.NECK_BONES:
		var t := float(i) / float(RigBones.NECK_BONES)
		var name_i := RigBones.neck_bone(i)
		var idx := sk.add_bone(name_i, prev, neck_base.lerp(head_p, t), neck_dir)
		# Trunk deformation stops at the neck. Breathing and impact squash are
		# authored as bone scale on the spine and chest so the ribcage genuinely
		# fattens, but scale compounds down a chain, and the head hangs off the end
		# of that chain: measured, a resting cat's breath was stretching the neck
		# enough to pump the skull 30 px at ship size against 5.6 px of chest
		# travel — a slow deliberate nod, once every four seconds, that nobody
		# asked for. The neck still *follows* the chest wherever the ribcage puts
		# it; it just is not inflated by it.
		if i == 0:
			sk.bones[idx].inherit_scale = false
		prev = name_i
	sk.add_bone(RigBones.HEAD, prev, head_p, neck_dir)

	var muzzle_p := _axis_anchor(bind_parts, tags, RigBones.Slot.MUZZLE, -1.0, Vector2.INF)
	if muzzle_p != Vector2.INF:
		sk.add_bone(RigBones.MUZZLE, RigBones.HEAD, muzzle_p, neck_dir)
	var jaw_p := _axis_anchor(bind_parts, tags, RigBones.Slot.JAW, -1.0, Vector2.INF)
	if jaw_p != Vector2.INF:
		sk.add_bone(RigBones.JAW, RigBones.HEAD, jaw_p, neck_dir)

	# --- secondary-motion chains -------------------------------------------
	sk._fit_chain(bind_parts, tags, RigBones.Slot.TAIL, "tail", RigBones.SIDE_NONE,
		RigBones.PELVIS, pelvis_p, RigBones.MAX_TAIL_JOINTS, true)
	for far in [false, true]:
		var side := RigBones.SIDE_FAR if far else RigBones.SIDE_NEAR
		sk._fit_chain(bind_parts, tags, RigBones.Slot.EAR, "ear", side,
			RigBones.HEAD, head_p, RigBones.EAR_JOINTS, false)
		sk._fit_chain(bind_parts, tags, RigBones.Slot.JOWL, "jowl", side,
			RigBones.HEAD, head_p, 1, false)
	sk._fit_chain(bind_parts, tags, RigBones.Slot.CREST, "crest", RigBones.SIDE_NONE,
		RigBones.HEAD, head_p, 3, true)
	sk._fit_chain(bind_parts, tags, RigBones.Slot.WATTLE, "wattle", RigBones.SIDE_NONE,
		RigBones.JAW if sk.has_bone(RigBones.JAW) else RigBones.HEAD, head_p, 3, true)
	sk._fit_chain(bind_parts, tags, RigBones.Slot.BELLY, "belly", RigBones.SIDE_NONE,
		RigBones.spine_bone(1), pelvis_p, 2, true)

	# --- limbs --------------------------------------------------------------
	for fore in [true, false]:
		for far in [true, false]:
			sk._fit_limb(bind_parts, tags, RigBones.Slot.LIMB, fore, far, false,
				RigBones.CHEST if fore else RigBones.PELVIS,
				chest_p if fore else pelvis_p)
	# Wings are fitted once per side, *not* once per girdle. A wing has no fore or
	# hind — `limb_base` does not even put one in the name — so running them through
	# the same fore/hind loop as legs called `add_bone` twice with identical names.
	# The name table kept the second copy, which is what every lookup by name found,
	# while `_bind_parts_to_bones` matched the first: the wing was skinned to a
	# duplicate that nothing ever posed, and it collapsed. The bird spec currently
	# works around it by naming its wing parts so they classify as SPINE; with this
	# fixed it can call them wings again.
	for far in [true, false]:
		sk._fit_limb(bind_parts, tags, RigBones.Slot.WING, true, far, true,
			RigBones.CHEST, chest_p)

	sk._bind_parts_to_bones(bind_parts, tags)
	sk._bind_eyes(spec, bind_eyes)
	sk.update_pose()
	return sk


# --- fitting helpers -------------------------------------------------------

static func _mid(p: SDFPart) -> Vector2:
	return (p.a + p.b) * 0.5


static func _body_mid_x(parts: Array[SDFPart], tags: Array) -> float:
	var sum := 0.0
	var n := 0
	for i in parts.size():
		var slot: int = tags[i].slot
		if slot in [RigBones.Slot.PELVIS, RigBones.Slot.SPINE, RigBones.Slot.CHEST]:
			sum += _mid(parts[i]).x
			n += 1
	return sum / float(n) if n > 0 else 0.0


## Radius-weighted centre of every part in `slot`, or `Vector2.INF` if none.
static func _centroid(parts: Array[SDFPart], tags: Array, slot: int) -> Vector2:
	var sum := Vector2.ZERO
	var w := 0.0
	for i in parts.size():
		if tags[i].slot != slot:
			continue
		var r: float = maxf(parts[i].radius_a + parts[i].radius_b, 1e-4)
		sum += _mid(parts[i]) * r
		w += r
	return sum / w if w > 0.0 else Vector2.INF


## The endpoint of `slot`'s parts furthest along the body axis. `dir` is -1 for
## the rear-most (a pelvis, an ear root) and +1 for the front-most (a chest).
static func _axis_anchor(parts: Array[SDFPart], tags: Array, slot: int, dir: float,
		fallback: Vector2) -> Vector2:
	var best := Vector2.INF
	var best_score := -INF
	for i in parts.size():
		if tags[i].slot != slot:
			continue
		for e in [parts[i].a, parts[i].b]:
			var score: float = e.x * dir
			if score > best_score:
				best_score = score
				best = e
	return best if best != Vector2.INF else fallback


## Lay a chain of `joints` bones plus a tip leaf from the parts in `slot`.
## `ordered` chains (tails, crests) follow their parts end to end; unordered ones
## (ears, jowls) span the union of their parts, so a decorative inner-ear overlay
## does not get mistaken for a second segment.
func _fit_chain(parts: Array[SDFPart], tags: Array, slot: int, base: String,
		side: int, parent: StringName, body_anchor: Vector2, joints: int,
		ordered: bool) -> void:
	if index_of(parent) < 0:
		return
	var members: Array[int] = []
	for i in parts.size():
		var tag = tags[i]
		if tag.slot != slot:
			continue
		if side != RigBones.SIDE_NONE and tag.far != (side == RigBones.SIDE_FAR):
			continue
		members.append(i)
	if members.is_empty():
		return

	var joint_pos: Array[Vector2] = []
	if ordered:
		# Walk outward from whichever part starts nearest the body.
		members.sort_custom(func(x: int, y: int) -> bool:
			return _root_dist(parts[x], body_anchor) < _root_dist(parts[y], body_anchor))
		var cursor := body_anchor
		for i in members:
			if joint_pos.size() >= joints:
				break
			var p: SDFPart = parts[i]
			var a_first: bool = p.a.distance_to(cursor) <= p.b.distance_to(cursor)
			joint_pos.append(p.a if a_first else p.b)
			cursor = p.b if a_first else p.a
		joint_pos.append(cursor)
	else:
		var root := Vector2.INF
		var tip := Vector2.INF
		var best_near := INF
		var best_far := -INF
		for i in members:
			for e in [parts[i].a, parts[i].b]:
				var d: float = e.distance_to(body_anchor)
				if d < best_near:
					best_near = d
					root = e
				if d > best_far:
					best_far = d
					tip = e
		for j in joints:
			joint_pos.append(root.lerp(tip, float(j) / float(joints)))
		joint_pos.append(tip)

	var prev := parent
	for j in joint_pos.size():
		var dir_to: Vector2 = joint_pos[mini(j + 1, joint_pos.size() - 1)] - joint_pos[j]
		if dir_to.length_squared() < 1e-10 and j > 0:
			dir_to = joint_pos[j] - joint_pos[j - 1]
		var bone_name: StringName = RigBones.chain_tip(base, side) \
			if j == joint_pos.size() - 1 else RigBones.chain_bone(base, side, j)
		add_bone(bone_name, prev, joint_pos[j], dir_to.angle())
		prev = bone_name


static func _root_dist(p: SDFPart, anchor: Vector2) -> float:
	return minf(p.a.distance_to(anchor), p.b.distance_to(anchor))


## Lay out one limb: a bone per authored segment, proximal → distal, plus a tip.
func _fit_limb(parts: Array[SDFPart], tags: Array, slot: int, fore: bool, far: bool,
		wing: bool, parent: StringName, anchor: Vector2) -> void:
	if index_of(parent) < 0:
		return
	var members: Array[int] = []
	for i in parts.size():
		var tag = tags[i]
		if tag.slot != slot or tag.far != far:
			continue
		if slot == RigBones.Slot.LIMB and tag.fore != fore:
			continue
		members.append(i)
	if members.is_empty():
		return
	members.sort_custom(func(x: int, y: int) -> bool:
		return _limb_order(parts[x], tags[x], anchor) < _limb_order(parts[y], tags[y], anchor))

	# Assign canonical segment names in order, honouring any the id declared.
	var cursor := 0
	var prev := parent
	var last_distal := anchor
	for i in members:
		var seg: int = tags[i].seg
		if seg < cursor:
			seg = cursor
		cursor = seg + 1
		var p: SDFPart = parts[i]
		var a_first: bool = p.a.distance_to(last_distal) <= p.b.distance_to(last_distal)
		var proximal: Vector2 = p.a if a_first else p.b
		var distal: Vector2 = p.b if a_first else p.a
		var bone_name := RigBones.limb_bone(fore, far, wing, seg)
		var idx := add_bone(bone_name, prev, proximal, (distal - proximal).angle())
		# Limb roots ignore torso squash; see Bone.inherit_scale.
		if prev == parent:
			bones[idx].inherit_scale = false
		prev = bone_name
		last_distal = distal
		if cursor > RigBones.Seg.TOE:
			break
	add_bone(RigBones.limb_bone(fore, far, wing, -1), prev, last_distal,
		bones[index_of(prev)].rest_xform.get_rotation())


## Sort key for limb segments: an explicit segment token wins, otherwise the
## endpoint nearest the girdle is the proximal one.
static func _limb_order(p: SDFPart, tag, anchor: Vector2) -> float:
	if tag.seg >= 0:
		return float(tag.seg)
	return 10.0 + _root_dist(p, anchor)


# --- binding ---------------------------------------------------------------

func _bind_parts_to_bones(parts: Array[SDFPart], tags: Array) -> void:
	part_binds.clear()
	for i in parts.size():
		var p: SDFPart = parts[i]
		var candidates := _candidates_for(tags[i], p)
		var pb := PartBind.new()
		pb.part = i
		pb.bone_a = _explicit_or_nearest(p.bone_a, p.a, candidates)
		pb.bone_b = _explicit_or_nearest(p.bone_b, p.b, candidates)
		var axis := p.b - p.a
		var n := Vector2(-axis.y, axis.x).normalized() if axis.length_squared() > 1e-10 \
			else Vector2(0.0, -1.0)
		pb.local_a = bones[pb.bone_a].rest_inv * p.a
		pb.local_b = bones[pb.bone_b].rest_inv * p.b
		pb.normal_a = bones[pb.bone_a].rest_inv.basis_xform(n)
		pb.normal_b = bones[pb.bone_b].rest_inv.basis_xform(n)
		part_binds.append(pb)


## Bones a part of this slot is allowed to attach to. Restricting the candidate
## set is what stops a muzzle snapping to a nearby ear bone.
func _candidates_for(tag, p: SDFPart) -> PackedInt32Array:
	var prefixes: Array[String] = []
	match tag.slot:
		RigBones.Slot.PELVIS, RigBones.Slot.SPINE, RigBones.Slot.CHEST:
			prefixes = ["pelvis", "spine_", "chest"]
		RigBones.Slot.NECK:
			prefixes = ["neck_", "chest", "head"]
		RigBones.Slot.HEAD:
			prefixes = ["head", "neck_02"]
		RigBones.Slot.JAW:
			prefixes = ["jaw", "head"]
		RigBones.Slot.MUZZLE:
			prefixes = ["muzzle", "head"]
		RigBones.Slot.EAR:
			prefixes = [RigBones.chain_prefix("ear", _side(tag.far))]
		RigBones.Slot.TAIL:
			prefixes = [RigBones.chain_prefix("tail", RigBones.SIDE_NONE)]
		RigBones.Slot.CREST:
			prefixes = [RigBones.chain_prefix("crest", RigBones.SIDE_NONE)]
		RigBones.Slot.WATTLE:
			prefixes = [RigBones.chain_prefix("wattle", RigBones.SIDE_NONE)]
		RigBones.Slot.JOWL:
			prefixes = [RigBones.chain_prefix("jowl", _side(tag.far))]
		RigBones.Slot.BELLY:
			prefixes = [RigBones.chain_prefix("belly", RigBones.SIDE_NONE)]
		RigBones.Slot.LIMB, RigBones.Slot.WING:
			prefixes = [RigBones.limb_base(tag.fore, tag.far, tag.slot == RigBones.Slot.WING) + "_"]
		_:
			prefixes = ["pelvis", "spine_", "chest", "neck_", "head"]
	var out := PackedInt32Array()
	for i in bones.size():
		var n := String(bones[i].name)
		for pre in prefixes:
			if n.begins_with(pre):
				out.append(i)
				break
	if out.is_empty():
		# The species named a body part the fitted tree has no bone for; the
		# spine is the safest carrier and still animates with the body.
		for i in bones.size():
			if String(bones[i].name).begins_with("spine_"):
				out.append(i)
	return out


static func _side(far: bool) -> int:
	return RigBones.SIDE_FAR if far else RigBones.SIDE_NEAR


func _explicit_or_nearest(named: StringName, point: Vector2, candidates: PackedInt32Array) -> int:
	if named != &"":
		var i := index_of(named)
		if i >= 0:
			return i
		Log.warn("RigSkeleton", "unknown bone '%s'; falling back to the fitted tree" % named)
	var best := 0
	var best_d := INF
	for c in candidates:
		var d: float = bones[c].rest_xform.origin.distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = c
	return best


func _bind_eyes(spec: CreatureSpec, bind_eyes: Array) -> void:
	eye_binds.clear()
	for i in mini(spec.eyes.size(), bind_eyes.size()):
		var e: EyeSpec = spec.eyes[i]
		if e == null:
			continue
		var eb := EyeBind.new()
		eb.eye = i
		eb.bone = index_of(e.bone)
		if eb.bone < 0:
			eb.bone = maxi(index_of(RigBones.HEAD), 0)
		# Bind from the grown centre, not the authored one: a kitten's skull sits
		# at 0.4x scale and the eye has to ride it there.
		eb.local = bones[eb.bone].rest_inv * (bind_eyes[i] as EyeSpec.Live).center
		eye_binds.append(eb)
