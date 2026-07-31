extends RefCounted

## Domestic cat.
##
## Rig space convention used by every species:
##   * +x is forward (the creature faces right at rotation 0),
##   * +y is down (matching Godot's 2D axes),
##   * the origin sits between the paws on the ground plane,
##   * 1.0 unit ≈ adult shoulder height.
##
## Built in code rather than as a .tres so a species reads as a document: you
## can see the whole animal's proportions in one screen and diff a change to its
## ear angle.

const P := preload("res://core/creature/sdf_part.gd")
const S := preload("res://core/creature/creature_spec.gd")
const E := preload("res://core/creature/eye_spec.gd")

# Palette slots, referenced by every part below.
const COL_COAT := 0
const COL_COAT_DARK := 1
const COL_BELLY := 2
const COL_MUZZLE := 3
const COL_INNER_EAR := 4
const COL_PAW_PAD := 5
const COL_NOSE := 6
const COL_CLAW := 7


static func _part(id: StringName, a: Vector2, b: Vector2, ra: float, rb: float,
		col: int, layer: int = 1) -> P:
	var p: P = P.new()
	p.id = id
	p.a = a
	p.b = b
	p.radius_a = ra
	p.radius_b = rb
	p.palette_index = col
	p.layer = layer
	p.surface = P.Surface.FUR
	p.blend = 0.055
	return p


## Extra fore/aft spread between the near and far legs of a kitten, in adult rig
## units before the 0.40 body scale.
##
## The near and far pairs are authored about 0.06 apart, which is a readable gap
## on an adult and eight pixels on a kitten — the far limbs disappear behind the
## near ones and the baby reads as a two-legged loaf. Shortening the legs makes
## it worse, because a stubby leg has less length over which the gap can show.
##
## The split is spent as a three-quarter-view offset rather than as a symmetric
## widening: the far fore paw goes further back and the far hind paw further
## forward, so the far pair sits *inside* the near pair's stance. That reads as
## depth. Pushing the near pair the other way by a third of the same amount also
## widens the kitten's own stance, which is what a wobbly baby actually does.
static func _kitten_stance(id: String) -> Vector2:
	var far: bool = id.contains("far")
	var fore: bool = id.contains("fl")
	var dx: float = 0.10 if far else 0.035
	if fore == far:
		dx = -dx
	return Vector2(dx, 0.0)


static func build() -> S:
	var s: S = S.new()
	s.species_id = &"cat"
	s.display_name = "Cat"
	s.blurb = "Sleeps on whatever you are currently working on. Will knock a folder off the edge and hold eye contact while doing it."

	s.palette = PackedColorArray([
		Color(0.52, 0.42, 0.34),   # coat
		Color(0.33, 0.25, 0.20),   # coat shadow / tabby stripes
		Color(0.88, 0.83, 0.76),   # belly, chest, chin
		Color(0.93, 0.89, 0.83),   # muzzle
		Color(0.86, 0.60, 0.60),   # inner ear
		Color(0.79, 0.53, 0.53),   # paw pads
		Color(0.86, 0.50, 0.52),   # nose
		Color(0.90, 0.88, 0.84),   # claws
	])

	s.adult_height = 1.0
	s.pixels_per_unit = 190.0
	s.coat_surface = P.Surface.FUR
	s.coat_length = 0.017
	s.coat_density = 1.15
	s.translucency = 0.55
	s.roughness = 0.52

	s.hours_per_stage = 20.0
	s.stage_scale = PackedFloat32Array([0.40, 0.60, 0.82, 1.0])
	s.stage_head_bias = PackedFloat32Array([1.48, 1.26, 1.10, 1.0])
	s.stage_eye_bias = PackedFloat32Array([1.55, 1.30, 1.12, 1.0])

	s.locomotion = S.Locomotion.QUADRUPED
	s.walk_speed = 0.85
	s.run_speed = 3.1
	s.stride = 0.42
	s.bob = 0.035
	s.jump_height = 2.2
	s.can_climb = true
	s.can_fly = false

	s.energy = 0.55
	s.affection_drive = 0.45
	s.curiosity = 0.85
	s.skittishness = 0.55

	s.voice_hz = 480.0
	s.baby_voice_scale = 1.75
	s.voice_timbre = 0.35

	var parts: Array[P] = []

	# Proportions are the whole ballgame, and this is the third pass at them: the
	# first cat was 1.1 long to 1 tall and read as a toy, the correction overshot
	# into a dachshund. So the numbers below are measured against a real animal
	# rather than chosen by eye, and `_measure.gd` next to this file prints them
	# back on every build.
	#
	# Adult domestic shorthair, standing square (cm, and as multiples of the
	# 24 cm withers height that is this rig's 1.0 unit):
	#
	#   withers height            24     1.00   built here as 0.98
	#   nose to rump              46     1.90 *along the animal* — which is only
	#                                    ~1.6 measured as a horizontal box, since
	#                                    the neck carries the head up and forward
	#                                    at about 40° rather than straight out.
	#                                    The probe reports 1.60; the old build's
	#                                    1.70 was that number with the head held
	#                                    out level, which is an ox, not a cat.
	#   shoulder joint to hip     19     0.80   the span with nothing under it
	#   chest depth               11     0.46   built at 0.53, brisket to withers
	#   fore paw to hind paw      22     0.92   built at 0.89; nearly square
	#   head length                9     0.38   built at 0.42 — see the head block
	#   neck thickness             —     0.75 of head height. This one matters:
	#                                    a neck as thick as the skull is an ox,
	#                                    and that is what the previous cat had.
	#
	# The cantilever — how much animal hangs forward of the front paws — is
	# ~35% of body length on a real cat and is *supposed* to be large; the probe
	# reads 28% here. What made the old build look unsupported was not its
	# length, it was that the humerus was drawn as a bare stick pinned to the
	# side of a barrel with nothing over it. Hence `scapula`.
	#
	# Withers sit at y = -0.97, the ear tips reach -1.31, and the body spans
	# x = -0.80 (rump) to +0.76 (muzzle tip), with the tail out to -1.07.

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# Set inboard of the near pair: in a three-quarter view the far fore paw is
	# *behind* the near one and the far hind paw *ahead* of it, which foreshortens
	# the far side and is most of what stops four legs reading as two.
	var fl_far_u := _part(&"leg_fl_far_upper", Vector2(0.196, -0.645), Vector2(0.238, -0.468), 0.070, 0.050, COL_COAT_DARK, 0)
	var fl_far_l := _part(&"leg_fl_far_lower", Vector2(0.238, -0.468), Vector2(0.252, -0.150), 0.048, 0.032, COL_COAT_DARK, 0)
	var fl_far_p := _part(&"paw_fl_far", Vector2(0.252, -0.150), Vector2(0.296, -0.042), 0.034, 0.040, COL_COAT_DARK, 0)
	var bl_far_u := _part(&"leg_bl_far_upper", Vector2(-0.508, -0.660), Vector2(-0.628, -0.448), 0.100, 0.056, COL_COAT_DARK, 0)
	var bl_far_l := _part(&"leg_bl_far_lower", Vector2(-0.628, -0.448), Vector2(-0.546, -0.158), 0.050, 0.034, COL_COAT_DARK, 0)
	var bl_far_p := _part(&"paw_bl_far", Vector2(-0.546, -0.158), Vector2(-0.488, -0.042), 0.035, 0.041, COL_COAT_DARK, 0)
	var ear_far := _part(&"ear_far", Vector2(0.570, -1.066), Vector2(0.532, -1.266), 0.072, 0.017, COL_COAT_DARK, 0)
	ear_far.height_scale = 0.30
	ear_far.blend = 0.03
	parts.append_array([fl_far_u, fl_far_l, fl_far_p, bl_far_u, bl_far_l, bl_far_p, ear_far])

	# --- torso --------------------------------------------------------------
	# The back is not a tube: it rises over the hips, dips through a short loin,
	# and rises again into the withers, and that double curve is most of what
	# reads as "cat" in silhouette. So the loin is 0.158 against 0.198 at the
	# croup and 0.202 at the ribcage — a real waist — and it sits 0.058 higher
	# along the top. It is also the shortest of the three runs; a long lumbar
	# span is precisely what turns a cat into a dachshund, and the old spec spent
	# 0.46 units on it against 0.29 here.
	#
	# Blends drop from 0.12 to 0.075 for the same reason: a 0.12 smooth-union
	# erases a 0.06 dip, which is how the previous build ended up with a topline
	# you could set a ruler against.
	var rump := _part(&"hip", Vector2(-0.610, -0.715), Vector2(-0.415, -0.748), 0.188, 0.198, COL_COAT)
	rump.blend = 0.085
	var torso := _part(&"torso", Vector2(-0.415, -0.748), Vector2(-0.130, -0.730), 0.198, 0.158, COL_COAT)
	torso.blend = 0.075
	var chest := _part(&"chest", Vector2(-0.130, -0.730), Vector2(0.155, -0.742), 0.158, 0.202, COL_COAT)
	chest.blend = 0.075
	# The shoulder blade, running from the withers down and forward to the
	# shoulder joint. Costs one of 28 part slots and buys the single biggest
	# structural read in the animal: the foreleg now leaves a mass instead of
	# starting halfway up a barrel.
	var scapula := _part(&"scapula", Vector2(0.075, -0.845), Vector2(0.240, -0.650), 0.126, 0.100, COL_COAT)
	scapula.blend = 0.10
	# Standing slightly proud of the height field, so the blade catches the key
	# light as its own form rather than disappearing into the ribcage the moment
	# the smooth-union blends them.
	scapula.height_scale = 1.15
	# Belly with a real flank tuck: the brisket drops to -0.450, 0.11 below the
	# tucked flank at -0.536. Without that the underline is a straight plank and
	# the animal reads as a barrel on sticks no matter what the back does. The
	# pale palette slot doubles as the chest bib, which is the one broad value
	# break on the underside that survives at 260 px.
	var belly := _part(&"belly", Vector2(-0.290, -0.576), Vector2(0.125, -0.530), 0.040, 0.080, COL_BELLY)
	# Sunk until its top edge barely clears the torso's underline, and blended
	# wide. Sitting 0.10 higher it painted a hard pale stripe up the flank, and a
	# bright band across the middle of the body at 260 px is the same plank
	# artifact the coat was pulled up for — countershading is a gradient.
	belly.blend = 0.135
	belly.coat_length = 1.35
	# Thinner than the skull by a quarter, and steeper than before (38° rather
	# than 30°), which is what lifts the head off the shoulder line.
	var neck := _part(&"neck", Vector2(0.185, -0.790), Vector2(0.372, -0.962), 0.115, 0.094, COL_COAT)
	neck.blend = 0.10
	parts.append_array([rump, torso, chest, scapula, belly, neck])

	# --- head ---------------------------------------------------------------
	# Short and round. The old head was 0.45 long against a 0.29 height, which is
	# a muzzle-forward ungulate profile; a cat is 0.41 by 0.30 with the mass in
	# the cranium. The chin capsule is gone — it was a 0.88 grey sitting against a
	# 0.93 grey, five pixels wide at ship size, and its slot is worth more as the
	# shoulder. The muzzle now tips down to carry the jaw itself.
	# 0.34 of shoulder height rather than the anatomical 0.29. At 260 px the head
	# and ear pair is the only species cue with any pixels behind it, so it is
	# worth the one place this animal is deliberately not to scale — and a
	# slightly large head is what every stylised cat that reads well does.
	var skull := _part(&"head", Vector2(0.480, -0.998), Vector2(0.595, -0.983), 0.155, 0.146, COL_COAT)
	skull.blend = 0.078
	var cheek := _part(&"cheek", Vector2(0.552, -0.940), Vector2(0.632, -0.933), 0.114, 0.095, COL_COAT)
	cheek.blend = 0.072
	var muzzle := _part(&"muzzle", Vector2(0.632, -0.936), Vector2(0.702, -0.914), 0.070, 0.058, COL_MUZZLE, 2)
	muzzle.blend = 0.045
	muzzle.coat_length = 0.5
	var nose := _part(&"nose", Vector2(0.720, -0.933), Vector2(0.728, -0.929), 0.018, 0.015, COL_NOSE, 2)
	nose.surface = P.Surface.SKIN
	nose.blend = 0.012
	nose.coat_length = 0.0
	parts.append_array([skull, cheek, muzzle, nose])

	# --- near ear -----------------------------------------------------------
	# Taller than before: a cat's ear is ~85% of its head height, and at 260 px
	# the ear pair is the strongest species cue on the whole animal.
	var ear_base := _part(&"ear_near", Vector2(0.482, -1.078), Vector2(0.436, -1.288), 0.080, 0.018, COL_COAT, 2)
	ear_base.height_scale = 0.32
	ear_base.blend = 0.032
	var ear_inner := _part(&"ear_near_inner", Vector2(0.474, -1.094), Vector2(0.442, -1.258), 0.049, 0.011, COL_INNER_EAR, 2)
	ear_inner.height_scale = 0.14
	ear_inner.blend = 0.02
	ear_inner.coat_length = 0.25
	parts.append_array([ear_base, ear_inner])

	# --- near limbs ---------------------------------------------------------
	# The humerus is thick at the top and buried in the scapula; the free leg
	# starts at the elbow, which sits just under the chest at y = -0.462. The
	# paw is a distinct swelling rather than the end of a taper, because at ship
	# size a leg with no paw shape is a noodle.
	#
	# Both upper segments sit on BODY, not FRONT, while everything below the
	# elbow and the stifle stays on FRONT. Only parts sharing a layer are
	# smooth-unioned, so on FRONT the thigh composited *over* the hip as a
	# separate sausage with a seam down it. On BODY it fuses into the girdle the
	# way a real haunch and shoulder do, and the free leg still draws in front of
	# the flank where it has to. Neither part carries a near/far token, so their
	# side is inferred from the layer — BODY still resolves to near, BEHIND to
	# far, which is exactly what the far pair below relies on.
	var fl_u := _part(&"leg_fl_upper", Vector2(0.240, -0.650), Vector2(0.285, -0.462), 0.080, 0.055, COL_COAT, 1)
	fl_u.blend = 0.075
	# Starts a hair wider than the humerus ends (0.058 against 0.055) so the
	# elbow overlaps rather than butting: the two are on different layers and are
	# composited, not blended, and an exact match shows the seam.
	var fl_l := _part(&"leg_fl_lower", Vector2(0.285, -0.462), Vector2(0.300, -0.140), 0.058, 0.034, COL_COAT, 2)
	# The paw is its own short, swelling capsule — 0.044 against the 0.034 the
	# forearm arrives at. A taper that just runs out at the floor is the noodle
	# the review saw; the swell is the only paw shape that survives at 260 px.
	var fl_paw := _part(&"paw_fl", Vector2(0.300, -0.140), Vector2(0.348, -0.040), 0.038, 0.044, COL_COAT, 2)
	fl_paw.blend = 0.03
	# The haunch carries a cat's whole sprint; it should be the widest single
	# mass below the spine, not a stick the same gauge as the forearm. The hind
	# paw plants a little behind the hip, which puts the fore and hind paws
	# 0.90 of a shoulder height apart — a cat stands very nearly square, and the
	# old spec had both legs raked forward under a body that leaned nowhere.
	var bl_u := _part(&"leg_bl_upper", Vector2(-0.545, -0.665), Vector2(-0.672, -0.445), 0.112, 0.062, COL_COAT, 1)
	bl_u.blend = 0.095
	var bl_l := _part(&"leg_bl_lower", Vector2(-0.672, -0.445), Vector2(-0.578, -0.150), 0.066, 0.037, COL_COAT, 2)
	var bl_paw := _part(&"paw_bl", Vector2(-0.578, -0.150), Vector2(-0.516, -0.040), 0.038, 0.045, COL_COAT, 2)
	bl_paw.blend = 0.03
	parts.append_array([fl_u, fl_l, fl_paw, bl_u, bl_l, bl_paw])

	# --- tail ---------------------------------------------------------------
	# A domestic cat's tail is about 0.9 of its withers height; the old one was
	# 0.50 and stopped in a blunt club, which is a fox-squirrel silhouette at
	# best and a broken branch at ship size. Long, rising, and tapering to an
	# actual point — 0.014 at the tip against 0.058 at the root — because the
	# taper is the only part of a tail that survives at 260 px.
	var tail_a := _part(&"tail_0", Vector2(-0.652, -0.712), Vector2(-0.845, -0.748), 0.058, 0.048, COL_COAT, 2)
	var tail_b := _part(&"tail_1", Vector2(-0.845, -0.748), Vector2(-1.008, -0.938), 0.048, 0.034, COL_COAT, 2)
	var tail_c := _part(&"tail_2", Vector2(-1.008, -0.938), Vector2(-1.058, -1.238), 0.034, 0.014, COL_COAT_DARK, 2)
	for t in [tail_a, tail_b, tail_c]:
		t.blend = 0.05
		# Shorthair, not a plume: the old 1.6 of coat fluffed the tail back up to
		# the width the taper had just taken off it.
		t.coat_length = 1.15
	parts.append_array([tail_a, tail_b, tail_c])

	# Baby proportions. A kitten is compact, not merely small: the torso shortens
	# faster than it thins, the legs stay stubby, and the tail is a fraction of
	# adult length. The head is deliberately left near 1.0 here because
	# `stage_head_bias` already enlarges it by 1.48 — stacking a second multiplier
	# on top is what turned the first kitten into a featureless loaf.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.baby_length_scale = 0.70
			p.baby_radius_scale = 1.10
			p.baby_offset = _kitten_stance(id)
		elif id.begins_with("tail"):
			p.baby_length_scale = 0.52
			p.baby_radius_scale = 1.18
		elif id.begins_with("ear"):
			p.baby_radius_scale = 0.80
			p.baby_length_scale = 0.70
		elif id in ["head", "cheek", "muzzle", "nose"]:
			p.baby_radius_scale = 1.06
		elif id in ["hip", "torso", "chest", "scapula", "belly"]:
			p.baby_length_scale = 0.86
			p.baby_radius_scale = 1.12
		else:
			p.baby_radius_scale = 1.04

	# Grooming direction: fur flows back along the body, down the legs, and out
	# along the tail. This is what the anisotropic coat shading reads.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.groom_angle = PI * 0.5
		elif id.begins_with("tail"):
			p.groom_angle = (p.b - p.a).angle()
		elif id.begins_with("ear"):
			p.groom_angle = -PI * 0.42
		else:
			p.groom_angle = PI

	s.parts = parts

	# Cats get a near eye and a sliver of the far one, which is what sells the
	# three-quarter head read without leaving 2D.
	var eye_near: E = E.new()
	eye_near.id = &"eye_near"
	eye_near.bone = &"head"
	eye_near.center = Vector2(0.608, -0.982)
	eye_near.radius = 0.043
	eye_near.tilt = -0.20
	eye_near.iris_ratio = 0.80
	eye_near.pupil_ratio = 0.40
	eye_near.pupil_slit = 0.85
	eye_near.iris_color = Color(0.62, 0.74, 0.24)
	eye_near.limbal_color = Color(0.07, 0.10, 0.04)
	eye_near.socket_depth = 0.30
	eye_near.lid_palette_index = COL_COAT

	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.504, -0.994)
	eye_far.radius = 0.031
	eye_far.tilt = -0.28
	eye_far.iris_ratio = 0.80
	eye_far.pupil_ratio = 0.40
	eye_far.pupil_slit = 0.85
	eye_far.iris_color = Color(0.56, 0.68, 0.22)
	eye_far.limbal_color = Color(0.06, 0.09, 0.04)
	eye_far.socket_depth = 0.45
	eye_far.lid_palette_index = COL_COAT

	s.eyes = [eye_far, eye_near]
	s.blink_interval = 4.2
	return s
