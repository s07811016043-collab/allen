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
		# Belly, chest bib and chin. Pulled down from 0.88/0.83/0.76, and the
		# reason is the belly capsule below rather than taste: fattening it to
		# clear the height-field groove also lets the cream win the colour blend
		# further up the flank, and at the old value that arrived as a bright bar
		# across the middle of the animal — the same failure the dog's belly block
		# describes from the other direction. Countershading on a real cat is about
		# two stops, not five.
		Color(0.78, 0.72, 0.65),   # belly, chest bib, chin
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
	#
	# Both far uppers are authored with their girdle end *closer to the trunk's
	# radius-weighted centroid* than their free end, and that is a hard contract
	# rather than a style note. `Growth._relink_chains` decides which way a limb
	# runs by exactly that comparison and then slides every distal segment onto the
	# previous one's far tip; get it backwards and the whole leg is dragged up to
	# the hip. It cost a capture to find: moving the brisket forward in this pass
	# shifted the centroid 0.023 and flipped the far hind femur, whose two ends had
	# been 0.006 apart on that test, and `_measure` came back with the far hind foot
	# 0.208 units — 24 rendered pixels — in the air, in the *posed* frame as well as
	# the bind pose. The femurs below now carry a margin of 0.04 rather than 0.006,
	# so a future change to the trunk cannot silently amputate a leg.
	var fl_far_u := _part(&"leg_fl_far_upper", Vector2(0.190, -0.648), Vector2(0.140, -0.440), 0.072, 0.050, COL_COAT_DARK, 0)
	var fl_far_l := _part(&"leg_fl_far_lower", Vector2(0.140, -0.440), Vector2(0.104, -0.040), 0.050, 0.042, COL_COAT_DARK, 0)
	# The far hind's third segment is gone, and it paid for the chin. The Z was
	# authored on both hind legs on the argument that a pair where one zigzags and
	# the other is a straight post reads as a break — which is true at review zoom
	# and false at 260 px, where the whole far hind is one dark shape in the near
	# leg's shadow and its hock is three pixels of rearward travel that nothing
	# lights. That is the "if you cannot see it, it is not earning its slot" test,
	# and the slot buys a jaw on the face instead.
	#
	# Straightening it also opens the pair. The probe had the hind gap at −0.002 —
	# near and far fused into one silhouette run below the stifle — because the far
	# hock swung *back* toward the near tibia at exactly the height the near tibia
	# was raking back to meet it. A plumb shank from the stifle to the floor holds
	# the far foot 0.094 ahead of the near paw instead.
	#
	# The whole far hind limb sits 0.09 forward of where it was, and its femur is
	# raked over to something like the 35° a real one carries rather than the 18°
	# it had. The pair used to fuse from 20% of the animal's height upward — one
	# 31 px column where four 12 px legs were wanted — because both femurs are
	# thick and both converged on the same x under the hip. Forward is the only
	# direction that opens it without thinning a haunch that carries a cat's entire
	# sprint, and raking the femur is what carries the opening up past the stifle
	# instead of leaving it to start below.
	var bl_far_u := _part(&"leg_bl_far_upper", Vector2(-0.430, -0.664), Vector2(-0.318, -0.446), 0.092, 0.060, COL_COAT_DARK, 0)
	var bl_far_l := _part(&"leg_bl_far_lower", Vector2(-0.318, -0.446), Vector2(-0.364, -0.040), 0.060, 0.042, COL_COAT_DARK, 0)
	var ear_far := _part(&"ear_far", Vector2(0.570, -1.066), Vector2(0.532, -1.266), 0.072, 0.017, COL_COAT_DARK, 0)
	ear_far.height_scale = 0.30
	ear_far.blend = 0.03
	parts.append_array([fl_far_u, fl_far_l, bl_far_u, bl_far_l, ear_far])

	# --- torso --------------------------------------------------------------
	# The back is not a tube: it rises over the hips, dips through a short loin,
	# and rises again into the withers, and that double curve is most of what
	# reads as "cat" in silhouette. So the loin runs 0.166 → 0.142 against 0.194 at
	# the croup and 0.212 at the ribcage — a real waist. It is also the shortest of
	# the three runs; a long lumbar span is precisely what turns a cat into a
	# dachshund, and the old spec spent 0.46 units on it against 0.27 here.
	#
	# Blends drop from 0.12 to 0.075 for the same reason: a 0.12 smooth-union
	# erases a 0.06 dip, which is how the previous build ended up with a topline
	# you could set a ruler against.
	#
	# The step from rib to flank is the third thing, and it is what a blind
	# reviewer was reading when they called this animal an Oriental rather than a
	# housecat. An Oriental *is* a smooth tube; a domestic shorthair is a barrel
	# with a hard rear edge to it, because the last rib is bone and the flank
	# behind it is not.
	#
	# The first attempt at it was made the way the file has always made shape —
	# taper the front cap of the loin down and tighten the blend — and it was
	# measured on a 260 px alpha capture and found to be worth 2.9 rendered pixels
	# against 8.5 of authored step. That is the coat-fringe rule again and it is
	# harsher here than anywhere else on the animal: a smooth union cannot hold a
	# concave notch narrower than its own blend, and the fringe then fills another
	# 3.6 px on top. Steepening the taper made it *worse*, because a step is a
	# corner and a corner is exactly what the two of them round off.
	#
	# What survives is a waist with *length*. The loin is held near-uniformly thin
	# over its whole 0.27-unit run — 0.166 down to 0.142 — between a 0.194 croup and
	# a 0.212 ribcage, so the concavity is 32 rendered pixels wide instead of four
	# and neither the blend nor the fringe can reach across it. Measured the same
	# way afterwards: the ribcage's topline stands 9 px above the loin's at ship
	# size, against 7 before, and the loin now sits below the croup as well as below
	# the ribs, which is the double curve the block above is describing.
	#
	# The crease is the other half and it costs nothing. `f.crease` is the volume
	# the smooth-min adds, and the shader turns it straight into occlusion, so the
	# 0.028 join between two capsules 0.07 apart in radius draws a dark line down
	# the flank for free. That line is the last rib, it lives inside the silhouette,
	# and it is the one part of this feature the fringe cannot touch.
	var rump := _part(&"hip", Vector2(-0.610, -0.715), Vector2(-0.420, -0.744), 0.188, 0.194, COL_COAT)
	rump.blend = 0.085
	var torso := _part(&"torso", Vector2(-0.420, -0.740), Vector2(-0.150, -0.734), 0.166, 0.142, COL_COAT)
	torso.blend = 0.070
	var chest := _part(&"chest", Vector2(-0.150, -0.758), Vector2(0.150, -0.758), 0.204, 0.212, COL_COAT)
	chest.blend = 0.028
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
	#
	# It is a near-horizontal capsule now, and that is a *shading* decision rather
	# than an anatomical one — the anatomy comes out the same either way, and the
	# shading does not. The version this replaces ran from the withers down and
	# forward at +51°, crossing a chest at −2° and a neck at −43°, so three
	# capsules whose axes disagreed by up to 94° all smooth-unioned inside one
	# 0.125 blend at the point of shoulder.
	#
	# What that costs is legible in `PETALIA_DEBUG_VIEW=3`, the coat's lane
	# coordinate: over the whole neck and shoulder the lanes open into wide closed
	# loops instead of running back along the body, and a lane that wide has no
	# strand detail in it at all. The shader has two separate guards that fire
	# there — `frame_ok` clamps the coat relief wherever `fwidth(f.axis)` says the
	# blended frame is spinning, and `band_ok` fades the bands out wherever the
	# blended `arc` stalls at an extremum — and between them they shave the region
	# bald, which is exactly the "large smooth glossy patch with no coat direction
	# in it" the review reports. It is the same mechanism the bird's egg block
	# describes: capsules that disagree about which way is "along the body" blend
	# into a field with saddles in it.
	#
	# So the sternum now runs forward at +12° against the ribcage's 0°, and the
	# withers it used to carry are the ribcage's own top surface, which is 0.02
	# higher than the old brisket cap reached anyway.
	var brisket := _part(&"brisket", Vector2(0.072, -0.630), Vector2(0.298, -0.582), 0.146, 0.154, COL_COAT)
	# Still blended wider than the parts it joins, and standing less proud than it
	# did. Pushed forward at 0.10 blend and 1.12 height it stopped being a chest
	# and became a ball: a sphere with its own highlight and a hard crease ringing
	# it where the neck and the humerus arrived. What the eye wants at the point of
	# shoulder is a *mass* that the neck runs into and the leg comes out of, and
	# the difference between the two is entirely in how fast the union closes.
	brisket.blend = 0.095
	# Down from 1.06. Lifted proud of the ribcage the sternum grew its own
	# highlight and its own ring of crease where the neck and the humerus arrived,
	# which at review zoom is a ball glued to the front of the animal. The mass is
	# still there — it is in the radius and in how far forward the capsule reaches —
	# it just no longer stands off the chest in the height field as well.
	brisket.height_scale = 1.00
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
	#
	# It is also a real ventral half-volume now instead of a lens, and that is the
	# belly-seam finding from the dog applied here. The diagnosis is written up in
	# `dog_spec.gd` and was made with two captures that could not have been
	# reasoned out: repainting the capsule in the coat colour left the white streak
	# and the black stipple untouched (so it is not the pigment and not the marking
	# path), and shrinking it to nothing made them vanish (so it is the capsule's
	# shape). The height field biases its radius toward the thicker part of a union
	# with a strength running on `(R_fat − R_thin) / (R_fat + R_thin)`, and past
	# about 0.36 that digs a groove whose two walls light as hard lines.
	#
	# This capsule sat at 0.66 at the rear cap and 0.42 at the front — the worst
	# ratio of any part on any species we ship, which is why the cat's seam was the
	# loudest of the four. At 0.080 → 0.104 against a 0.150 → 0.206 trunk it is
	# 0.30 and 0.33.
	#
	# The underline is unchanged to the pixel: both endpoints are the old lower
	# surface re-expressed as centre minus radius, so the tuck, the groin and the
	# depth of the chest against the belly are all exactly where they were.
	var belly := _part(&"belly", Vector2(-0.210, -0.666), Vector2(0.140, -0.579), 0.079, 0.104, COL_BELLY)
	# Sunk until its top edge barely clears the torso's underline, and blended
	# wide. Sitting 0.10 higher it painted a hard pale stripe up the flank, and a
	# bright band across the middle of the body at 260 px is the same plank
	# artifact the coat was pulled up for — countershading is a gradient.
	belly.blend = 0.105
	belly.coat_length = 1.35
	# Thinner than the skull by a quarter, and steeper than before (38° rather
	# than 30°), which is what lifts the head off the shoulder line.
	#
	# The blend is the widest on the trunk and it is deliberate. The neck is the
	# one capsule left whose axis genuinely has to disagree with the ribcage's —
	# it is 43° off — and the shader's frame guard reads *rate*, not amount:
	# `fwidth(f.axis)` is the disagreement divided by how many pixels the union
	# takes to turn through it. At 118 px per rig unit the clamp starts biting
	# below about 0.10 of blend for a 43° turn, so a *tight* throat join is what
	# shaves the neck bald, not a soft one. This is the opposite of the rule that
	# governs the rib step 0.4 units behind it, where the two axes agree and the
	# tight join costs nothing but buys a crease.
	var neck := _part(&"neck", Vector2(0.185, -0.790), Vector2(0.372, -0.962), 0.115, 0.094, COL_COAT)
	neck.blend = 0.112
	parts.append_array([rump, torso, chest, brisket, belly, neck])

	# --- head ---------------------------------------------------------------
	# Short and round. The old head was 0.45 long against a 0.29 height, which is
	# a muzzle-forward ungulate profile; a cat is 0.41 by 0.30 with the mass in
	# the cranium.
	# 0.34 of shoulder height rather than the anatomical 0.29. At 260 px the head
	# and ear pair is the only species cue with any pixels behind it, so it is
	# worth the one place this animal is deliberately not to scale — and a
	# slightly large head is what every stylised cat that reads well does.
	var skull := _part(&"head", Vector2(0.480, -0.998), Vector2(0.595, -0.983), 0.155, 0.146, COL_COAT)
	skull.blend = 0.078
	var cheek := _part(&"cheek", Vector2(0.552, -0.940), Vector2(0.632, -0.933), 0.114, 0.095, COL_COAT)
	cheek.blend = 0.072
	# The muzzle stays on FRONT, and the reason is worth a capture's worth of space
	# because the obvious move is to put it on BODY and it is wrong.
	#
	# The front layer never accumulates `f.crease`, so a muzzle drawn there gets no
	# occlusion at its root and the mask boundary is a colour edge and nothing
	# else — which is exactly the sticker the review named, and moving the part to
	# BODY does fix that. What it also does is hand the muzzle to the *colour*
	# blend, and inside a smooth union the albedo goes with the field, so a 0.070
	# capsule unioned against a 0.155 skull and a 0.114 cheek loses. Rendered, the
	# entire pale mask vanished and the cat came back with a plain brown face and a
	# pink smudge where its nose had been. Two captures, one at 560 and one head
	# close-up, and both were unambiguous.
	#
	# So the mask boundary is broken up with coat instead — see `coat_length`
	# below — and the crease that the front layer cannot draw is drawn by the chin
	# underneath it, which *is* on BODY and does not need to keep a colour.
	var muzzle := _part(&"muzzle", Vector2(0.632, -0.936), Vector2(0.702, -0.914), 0.070, 0.058, COL_MUZZLE, 2)
	muzzle.blend = 0.045
	# Up from 0.5, and this is the muzzle *mask* edge rather than the muzzle. The
	# pale patch is a marking, so its boundary is drawn by the colour blend and
	# arrives as a clean arc — a sticker laid on the face, which is what the review
	# named. `coat_length` scales the per-part fringe the coat stands off its own
	# outline with, and the fringe is indexed off the outline's arc length, so
	# raising it on the part that owns the boundary breaks that arc into strands
	# without moving the silhouette of the head at all. It is also true of the
	# animal: the whisker pad is the fluffiest thing on a cat's face.
	muzzle.coat_length = 1.30
	var nose := _part(&"nose", Vector2(0.720, -0.933), Vector2(0.728, -0.929), 0.018, 0.015, COL_NOSE, 2)
	nose.surface = P.Surface.SKIN
	nose.blend = 0.012
	nose.coat_length = 0.0
	# The chin, and with it the mouth. It is one part doing two jobs and that is
	# why it was worth a slot back off the far hind leg.
	#
	# A cat's lower jaw is not a separate lump the way a dog's is — it is a small
	# shelf tucked under and behind the nose, and what you actually read across a
	# room is not the shelf but the line above it. So this capsule hangs 0.039
	# below the muzzle's lower surface at its root and converges on it toward the
	# front, which puts a smooth-union crease exactly where a cat's mouth line
	# runs: forward and slightly down, from under the cheek to under the nose
	# leather. `blend` at 0.016 is what keeps that a line; at the muzzle's own 0.045
	# the union rounded the two into one sausage and the face lost its jaw again.
	#
	# BODY, not FRONT, and it is the half of the muzzle problem that the front layer
	# cannot solve. Sitting on BODY the chin unions with the cheek, so it collects
	# a crease along its top edge and casts the layer's ambient occlusion, and the
	# muzzle then composites *over* it. What the eye gets is the muzzle's own lower
	# outline drawn as a hard composite edge against a shadowed jaw immediately
	# below it — a mouth line, made of the one thing the renderer draws crisply at
	# any size, a layer boundary.
	#
	# The colour is the coat's, not the belly's. On BODY the albedo goes with the
	# field and a small capsule loses that blend anyway, so asking for a pale chin
	# here buys nothing; what the shape has to do is be *darker* than the mask above
	# it, and coat over cheek is already three stops down from 0.93.
	var chin := _part(&"chin", Vector2(0.652, -0.872), Vector2(0.716, -0.884), 0.048, 0.030, COL_COAT, 1)
	chin.blend = 0.016
	chin.coat_length = 0.62
	parts.append_array([skull, cheek, muzzle, nose, chin])

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
	# rim: the shoulder crease is a real feature and it was drawing as a line, and
	# then — once the sternum moved forward under it — as a closed ring round a
	# dome, which is worse. 0.118 is the widest union on the animal and it is the
	# right place for it: this is the one joint that is genuinely buried in muscle.
	fl_u.blend = 0.118
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
		elif id == "chin":
			# A kitten has almost no jaw. Shrinking it rather than letting the head
			# bias inflate it with the rest of the skull is most of why a baby face
			# is all forehead and cheeks.
			p.baby_radius_scale = 0.82
			p.baby_length_scale = 0.78
		elif id in ["head", "cheek", "muzzle", "nose"]:
			p.baby_radius_scale = 1.06
		elif id in ["hip", "torso", "chest", "brisket", "belly"]:
			p.baby_length_scale = 0.86
			p.baby_radius_scale = 1.12
		else:
			p.baby_radius_scale = 1.04

	# Grooming direction: fur flows back along the body, down the legs, and out
	# along the tail. This is what the anisotropic coat shading reads.
	#
	# The forehand is the exception, and it is the other half of the bald-shoulder
	# fix. Every trunk part used to be groomed at a flat PI, so the neck, the point
	# of shoulder and the ribcage were one continuous field with no direction
	# change anywhere in it — which is the literal complaint. On a real cat the
	# coat leaves the throat pointing down and back, sweeps round the point of
	# shoulder, and only straightens out into the flank behind the elbow. Twenty
	# degrees of turn across three capsules is enough to put a visible sweep there
	# and is well inside what the frame guard will carry at a 0.09-plus blend.
	const SWEEP := {"neck": PI * 0.845, "brisket": PI * 0.895, "chest": PI * 0.955}
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.groom_angle = PI * 0.5
		elif id.begins_with("tail"):
			p.groom_angle = (p.b - p.a).angle()
		elif id.begins_with("ear"):
			p.groom_angle = -PI * 0.42
		elif SWEEP.has(id):
			p.groom_angle = SWEEP[id]
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

	# The far eye is foreshortened rather than merely small, and there are four
	# separate terms in that because the contract has no ellipse in it.
	#
	# A head turned three-quarters on presents the far eye at an angle, so what a
	# photograph shows is a *sliver*: less of the ball, more lid over it, the whole
	# thing sunk behind the bridge of the nose, and the wet highlight killed
	# because the cornea is no longer facing the key. Drawn as a small copy of the
	# near eye instead — which is what 0.031 at the same lid and socket was — the
	# face reads as having two eyes pointing the same way on a head that is
	# pointing somewhere else, and that is uncanny in a way nobody can name.
	#
	#   radius 0.0255   0.59 of the near eye rather than 0.72
	#   lid_open 0.78   the upper lid carries a third of the ball
	#   socket 0.68     the nose bridge occludes it; the catchlight goes under
	#   tilt −0.40      the aperture rotates with the far side of the skull
	#
	# The sclera goes down with it. Aerial perspective is not the reason — the two
	# eyes are 0.1 units apart — the reason is that the far eye lies in the head's
	# own shadow terminator, and a white that stays white through a terminator is
	# the single loudest "this is a decal" signal a face can send.
	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.504, -0.994)
	eye_far.radius = 0.0255
	eye_far.tilt = -0.40
	eye_far.iris_ratio = 0.80
	eye_far.pupil_ratio = 0.40
	eye_far.pupil_slit = 0.85
	eye_far.iris_color = Color(0.47, 0.57, 0.19)
	eye_far.limbal_color = Color(0.05, 0.08, 0.03)
	eye_far.sclera_color = Color(0.74, 0.73, 0.71)
	eye_far.lid_open = 0.78
	eye_far.socket_depth = 0.68
	eye_far.lid_palette_index = COL_COAT

	s.eyes = [eye_far, eye_near]
	s.blink_interval = 4.2
	return s
