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
## Only the *upper* segment's offset survives: `Growth._relink_chains` slides
## every distal segment onto the one above it, so an offset on a shank is thrown
## away and an offset on a femur translates the whole limb. Returning it for all
## of them is harmless and keeps the rule in one place.
##
## The top-up is small, and the reason is worth recording because the review
## asked for the opposite. Measured on a 260 px kitten frame, growth 0 already
## showed four separate silhouette runs — the baby was never the broken one, the
## adult was. Shortening a limb toward its root scales its paw's offset from the
## girdle by `baby_length_scale`, but it does *not* shrink the body, so a kitten
## inherits a split that is a larger fraction of its own height than the adult's
## is of theirs. With the adult stagger now at 0.213 fore and 0.197 hind, a large
## top-up would splay the baby into a spider; 0.049 lands the kitten at 13 and 15
## rendered pixels of daylight at the floor, which is where the adult sits too.
##
## The direction still matches the adult's three-quarter offset: the far fore
## paw goes further back and the far hind paw further forward, so the far pair
## sits inside the near pair's stance. Pushing the near pair the other way by
## two fifths of the same amount also widens the kitten's own stance, which is
## what a wobbly baby actually does.
static func _kitten_stance(id: String) -> Vector2:
	var far: bool = id.contains("far")
	var fore: bool = id.contains("fl")
	var dx: float = 0.035 if far else 0.014
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
	#   chest depth               11     0.46   built at 0.52, brisket to withers
	#   fore paw to hind paw      22     0.92   built at 0.92; nearly square
	#   head length                9     0.38   built at 0.42 — see the head block
	#   neck thickness             —     0.75 of head height. This one matters:
	#                                    a neck as thick as the skull is an ox,
	#                                    and that is what the previous cat had.
	#
	# The cantilever — how much animal hangs forward of the front paws — is
	# ~35% of body length on a real cat and is *supposed* to be large; the probe
	# reads 28% here. What made the old build look unsupported was not its
	# length, it was that the humerus was drawn as a bare stick pinned to the
	# side of a barrel with nothing over it. Hence `brisket`, which now carries
	# both the blade above the shoulder joint and the chest in front of it.
	#
	# Withers sit at y = -0.99, the ear tips reach -1.31, and the body spans
	# x = -0.80 (rump) to +0.76 (muzzle tip), with the tail out to -1.07.

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# The stagger, sized off the rendered frame rather than off the spec. Two
	# numbers govern it and both were measured on a 260 px alpha capture with the
	# contact shadow turned off, scanline by scanline:
	#
	#   * A pair only shows daylight once its two axes are further apart than
	#     r_near + r_far, which down the shins is ~0.09.
	#   * The coat then eats another ~0.030 of it. A 0.038 geometric gap at the
	#     shin measured as *zero* rendered pixels; 0.082 measured as 7. So
	#     rendered_px ≈ geometric_px − 3.5, and anything under 0.085 of axis
	#     separation is spent for nothing.
	#
	# The previous pass set the offset at the paws and let the legs converge on
	# their way up, which gave a wedge: 15 px of daylight at the floor and 2 px
	# at mid-shin, where the animal is read. So the offset is now held roughly
	# *constant* over the free length instead — the far shank runs parallel to
	# the near one, 0.18-0.19 behind it, and both pairs hold 6-14 rendered pixels
	# of gap from the floor all the way up to the elbow and the stifle.
	#
	# The direction is the three-quarter one the far girdles already use — far
	# fore foot *behind* the near one, far hind foot *ahead* of it, so the far
	# side's stance is the compressed one. It is more compression than a true
	# projection of a 0.90 girdle foreshortening would give, and that is the
	# trade being made on purpose: at 260 px "this animal has four legs" is worth
	# more than the projection is.
	#
	# The far paws are gone. At ship size each was two pixels of shadow tucked
	# behind a near paw — the "if you cannot see it, it is not earning its slot"
	# test, failed — and their two slots pay for the hock below. Each far shank
	# now runs to the floor and ends on its own cap, which is all a leg lying in
	# the body's shadow needs in order to read as ending in a foot.
	var fl_far_u := _part(&"leg_fl_far_upper", Vector2(0.190, -0.648), Vector2(0.128, -0.466), 0.072, 0.050, COL_COAT_DARK, 0)
	var fl_far_l := _part(&"leg_fl_far_lower", Vector2(0.128, -0.466), Vector2(0.104, -0.040), 0.050, 0.042, COL_COAT_DARK, 0)
	# The far hind gets the same three-segment Z as the near one; a hind pair
	# where one leg zigzags and the other is a straight post reads as a break,
	# not as depth. Its metatarsus doubles as its foot for the reason above.
	#
	# The whole far hind limb has moved 0.09 forward of where it was, and its
	# femur is raked over to something like the 35° a real one carries rather
	# than the 18° it had. The pair used to fuse from 20% of the animal's height
	# upward — one 31 px column where four 12 px legs were wanted — because both
	# femurs are thick and both converged on the same x under the hip. Forward is
	# the only direction that opens it without thinning a haunch that carries a
	# cat's entire sprint, and raking the femur is what carries the opening up
	# past the stifle instead of leaving it to start below.
	var bl_far_u := _part(&"leg_bl_far_upper", Vector2(-0.470, -0.658), Vector2(-0.322, -0.454), 0.092, 0.060, COL_COAT_DARK, 0)
	var bl_far_l := _part(&"leg_bl_far_lower", Vector2(-0.322, -0.454), Vector2(-0.432, -0.254), 0.060, 0.042, COL_COAT_DARK, 0)
	var bl_far_h := _part(&"leg_bl_far_hock", Vector2(-0.432, -0.254), Vector2(-0.334, -0.036), 0.040, 0.040, COL_COAT_DARK, 0)
	var ear_far := _part(&"ear_far", Vector2(0.570, -1.066), Vector2(0.532, -1.266), 0.072, 0.017, COL_COAT_DARK, 0)
	ear_far.height_scale = 0.30
	ear_far.blend = 0.03
	parts.append_array([fl_far_u, fl_far_l, bl_far_u, bl_far_l, bl_far_h, ear_far])

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
	# Shoulder blade *and* brisket in one capsule, because the budget affords one
	# and the animal needs both. It runs from the withers down and forward to the
	# sternum: the top cap stands 0.04 proud of the ribcage, which is the blade
	# the previous pass bought, and the bottom cap fills the wedge between the
	# forelegs that nothing filled before.
	#
	# The wall it replaces was measured rather than guessed. On the 260 px frame
	# the leading edge of the body ran 192, 191, 191, 189, 188, 188, 188, 188,
	# 188, 187 px from throat to elbow — five pixels of movement over seventy,
	# which is a plank, and it is why the torso reads as a loaf however good the
	# topline is.
	#
	# The first brisket bought 0.066 of movement between the throat notch and the
	# point of shoulder, and 0.066 is 7 px at ship — a curve you can measure and
	# cannot see. The sternum is 0.030 further forward and 0.006 fatter again
	# here, which takes the profile to 0.34 at the notch and 0.46 at its peak:
	# 13 px of swell over 28 px of height, and an overhang of 0.117 in front of
	# the elbow. That is the number the eye is actually reading — not how far the
	# chest reaches, but how much it moves between the throat and the leg.
	var brisket := _part(&"brisket", Vector2(0.100, -0.860), Vector2(0.306, -0.604), 0.126, 0.134, COL_COAT)
	# Blended wider than the parts it joins, and standing less proud than it did.
	# Pushed forward at 0.10 blend and 1.12 height it stopped being a chest and
	# became a ball: a sphere with its own highlight and a hard crease ringing it
	# where the neck and the humerus arrived. What the eye wants at the point of
	# shoulder is a *mass* that the neck runs into and the leg comes out of, and
	# the difference between the two is entirely in how fast the union closes.
	brisket.blend = 0.125
	brisket.height_scale = 1.06
	# Belly, and with it the tuck. Two things were wrong with the old one and
	# both were measured off the rendered frame, not off these numbers.
	#
	# Its front cap sat at -0.450, which put the lowest point of the whole trunk
	# *behind* the sternum — the belly, not the chest, was the deepest thing on
	# the animal, which is the profile of a badger. It now bottoms out at -0.475
	# against the brisket's -0.470, so the chest is the deepest point by a hair
	# and everything behind it rises.
	#
	# And the tuck itself was too shallow to survive the blend. Across the belly
	# columns of a 260 px alpha capture the rendered underline moved *three
	# pixels* while the topline moved ten, which is what a curved back on a flat
	# bottom looks like, and it is most of the loaf. The union costs about 45% of
	# whatever is authored here — 0.070 of tuck rendered as 0.027 — so the tuck
	# is 0.105 now and runs over a shorter span, which turns a ramp into a curve.
	# Behind its rear cap the torso's own underline takes over and drops again
	# into the groin, which is the second half of the shape.
	#
	# The pale palette slot doubles as the chest bib, which is the one broad
	# value break on the underside that survives at 260 px.
	var belly := _part(&"belly", Vector2(-0.185, -0.612), Vector2(0.140, -0.557), 0.032, 0.082, COL_BELLY)
	# Sunk until its top edge barely clears the torso's underline, and blended
	# wide. Sitting 0.10 higher it painted a hard pale stripe up the flank, and a
	# bright band across the middle of the body at 260 px is the same plank
	# artifact the coat was pulled up for — countershading is a gradient.
	belly.blend = 0.105
	belly.coat_length = 1.35
	# Thinner than the skull by a quarter, and steeper than before (38° rather
	# than 30°), which is what lifts the head off the shoulder line.
	var neck := _part(&"neck", Vector2(0.185, -0.790), Vector2(0.372, -0.962), 0.115, 0.094, COL_COAT)
	neck.blend = 0.10
	parts.append_array([rump, torso, chest, brisket, belly, neck])

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
	# The humerus is thick at the top and now sits entirely inside the brisket,
	# which is where a cat's is; the free leg starts at the elbow, at y = -0.462,
	# exactly where the brisket's lower cap ends. The paw is a distinct swelling
	# rather than the end of a taper, because at ship size a leg with no paw
	# shape is a noodle.
	#
	# Every segment of a near limb sits on BODY, girdle to toe. Only parts sharing
	# a layer are smooth-unioned; across layers they are *composited*, and the
	# joint the composite lands on is where the leg breaks. The previous split —
	# upper on BODY, everything below the elbow on FRONT — put that break in the
	# open air halfway down the limb, and the ship-size frame showed the result
	# plainly: a pale hemispherical knob at the elbow and another at the stifle,
	# each with a hard edge against the segment above, so the legs read as doll
	# limbs pinned on rather than as one continuous tapering column.
	#
	# The knob was not just an outline. `f.crease` — the volume a smooth union
	# adds — is what the shader turns into joint occlusion, and it only
	# accumulates *within* a layer. A segment that unions with nothing arrives at
	# its own cap with zero crease AO, so the cap is not merely seamed, it is the
	# brightest thing on the leg.
	#
	# Nothing is lost by fusing them: below the girdle the near free leg does not
	# overlap the trunk at all (the hip's lowest surface is y = -0.53, the tibia
	# passes it 0.23 lower), so there is no place the limb still needed to be
	# composited in *front* of the flank. Neither upper carries a near/far token,
	# so their side is inferred from the layer — BODY resolves to near, BEHIND to
	# far, which is exactly what the far pair above relies on.
	var fl_u := _part(&"leg_fl_upper", Vector2(0.240, -0.650), Vector2(0.285, -0.462), 0.080, 0.055, COL_COAT, 1)
	# Wide enough that the humerus leaves the chest as a taper rather than as a
	# rim: the shoulder crease is a real feature and it was drawing as a line.
	fl_u.blend = 0.100
	var fl_l := _part(&"leg_fl_lower", Vector2(0.285, -0.462), Vector2(0.306, -0.140), 0.056, 0.034, COL_COAT, 1)
	# The paw is its own short, swelling capsule — 0.044 against the 0.034 the
	# forearm arrives at. A taper that just runs out at the floor is the noodle
	# the review saw; the swell is the only paw shape that survives at 260 px.
	var fl_paw := _part(&"paw_fl", Vector2(0.306, -0.140), Vector2(0.352, -0.040), 0.038, 0.044, COL_COAT, 1)
	fl_paw.blend = 0.03
	# The hind leg, as a Z rather than an L. This is the single most recognisable
	# thing about a cat and the old spec did not have it: femur, tibia and paw
	# gave the rig two IK segments, one bend, and a limb that hinged the wrong
	# way — the joint at -0.672 was the only kink and it pointed *backwards* out
	# of the hip, which is a chair leg.
	#
	# The real chain is three bones and two folds. The femur swings forward and
	# down so the stifle tucks just under the flank at -0.470; the tibia rakes
	# back to put the point of the hock at -0.672, the rearmost thing on the
	# standing animal below the tail; the metatarsus drops forward again to the
	# toe at -0.504, back under the hip. That is 0.202 of horizontal travel and
	# then 0.168 back — 23 px and 19 px at ship size, where the whole leg is only
	# 9 px wide, so the zigzag is by a long way the widest feature the limb has.
	#
	# The return leg of the Z is the half that was missing. At 0.093 it was ten
	# pixels, and ten pixels of forward rake under a twenty-two pixel backward
	# one does not read as a fold — it reads as a leg that leans back. Both
	# strokes have to be about the same length before the eye sees a zigzag, and
	# that is why the metatarsus is now nearly as long a horizontal run as the
	# tibia.
	#
	# The rig gets it too, not just the bind pose: naming the third segment
	# `hock` classifies it as `Seg.CANNON`, which is what promotes the chain from
	# `LegIK.solve_two` to `solve_three` and keeps the fold coupled to how
	# compressed the leg is as it steps.
	#
	# The haunch still carries a cat's whole sprint, so the femur stays the
	# widest mass below the spine (0.115 against the forearm's 0.058) rather than
	# a stick the same gauge as the foreleg.
	var bl_u := _part(&"leg_bl_upper", Vector2(-0.545, -0.665), Vector2(-0.470, -0.436), 0.115, 0.072, COL_COAT, 1)
	bl_u.blend = 0.095
	var bl_l := _part(&"leg_bl_lower", Vector2(-0.470, -0.436), Vector2(-0.672, -0.230), 0.072, 0.045, COL_COAT, 1)
	var bl_h := _part(&"leg_bl_hock", Vector2(-0.672, -0.230), Vector2(-0.612, -0.058), 0.043, 0.033, COL_COAT, 1)
	var bl_paw := _part(&"paw_bl", Vector2(-0.612, -0.058), Vector2(-0.548, -0.038), 0.037, 0.044, COL_COAT, 1)
	bl_paw.blend = 0.03
	parts.append_array([fl_u, fl_l, fl_paw, bl_u, bl_l, bl_h, bl_paw])

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
		elif id in ["hip", "torso", "chest", "brisket", "belly"]:
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
