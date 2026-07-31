extends RefCounted

## Small perching songbird — a bluebird-shaped archetype.
##
## Rig space convention used by every species:
##   * +x is forward (the creature faces right at rotation 0),
##   * +y is down (matching Godot's 2D axes),
##   * the origin sits between the feet on the ground plane,
##   * 1.0 unit ≈ adult shoulder height (here: the top of the back).
##
## Built in code rather than as a .tres so a species reads as a document: you
## can see the whole animal's proportions in one screen and diff a change to its
## beak angle.

const P := preload("res://core/creature/sdf_part.gd")
const S := preload("res://core/creature/creature_spec.gd")
const E := preload("res://core/creature/eye_spec.gd")

# Palette slots, referenced by every part below. Twelve is the hard ceiling
# (`CreatureRenderer.MAX_PALETTE`) and this species spends all of them: a
# songbird's whole charm is that it is *patterned*, and every stripe here costs
# a slot rather than a texture.
const COL_MANTLE := 0
const COL_MANTLE_DARK := 1
const COL_FLIGHT := 2
const COL_FLIGHT_DARK := 3
const COL_BREAST := 4
const COL_CREAM := 5
const COL_CHEEK := 6
const COL_BEAK := 7
const COL_BEAK_PALE := 8
const COL_TARSUS := 9
const COL_TARSUS_DARK := 10
const COL_GAPE := 11


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
	p.surface = P.Surface.FEATHER
	p.blend = 0.05
	return p


static func build() -> S:
	var s: S = S.new()
	s.species_id = &"bird"
	s.display_name = "Songbird"
	s.blurb = "Never stops moving. Investigates the cursor, decides it is a threat, decides it is food, and sings about the whole ordeal from the top of your window frame."

	# Two constraints shape this palette beyond taste.
	#
	# Slot 1 is not free. The body shader paints its dorsal markings — bars plus a
	# spine line — in `palette[marking_index]`, and that index defaults to 1, so
	# whatever sits in slot 1 is what gets drawn down the back of every furred or
	# feathered animal. A cat wants that: slot 1 is its tabby. A songbird does not,
	# and the only lever a species has today is how far slot 1 sits from slot 0. It
	# is therefore a *deeper mantle* rather than a contrasting colour, which turns
	# the bars into the soft tonal banding real feather tracts have while still
	# serving as the far side's shade. See the note in the hand-off: this wants a
	# per-species `marking_strength` before it is properly solved.
	#
	# Second, the markings and the agouti ticking over them are both gated on
	# luminance and fade out above about 0.85, so a mid-dark coat takes them at
	# full strength. Pitching the blue and the rust high keeps both to a whisper —
	# and a pale sky-blue passerine is a perfectly real animal.
	s.palette = PackedColorArray([
		Color(0.335, 0.505, 0.795),   # mantle: crown, back, rump, uppertail
		Color(0.235, 0.365, 0.620),   # dorsal feather-tract banding, far-side shade
		Color(0.150, 0.240, 0.470),   # wing coverts and rectrices
		Color(0.062, 0.098, 0.200),   # secondaries, primaries, outer rectrix
		Color(0.825, 0.430, 0.175),   # breast and flank, rust
		Color(0.930, 0.900, 0.840),   # belly and throat
		Color(0.740, 0.660, 0.545),   # ear-covert cheek patch, warm buff
		Color(0.105, 0.098, 0.112),   # upper mandible, near black horn
		Color(0.330, 0.310, 0.300),   # lower mandible, pale horn
		Color(0.360, 0.295, 0.260),   # tarsus and toes
		Color(0.215, 0.180, 0.160),   # far tarsus
		Color(0.960, 0.740, 0.310),   # gape flange
	])

	s.adult_height = 1.0
	# Deliberately below the cat's 190: a songbird sharing a desktop with a cat
	# has to *be* smaller, and this is the only place that ratio is expressed.
	s.pixels_per_unit = 158.0

	s.coat_surface = P.Surface.FEATHER
	s.coat_length = 0.010
	# Barb pitch is `150 * coat_density` per rig unit and a tier only fades in
	# once its pitch clears about 2.5 screen pixels. At 158 px/unit that puts the
	# usable ceiling near 0.4 — above it the vanes go sub-Nyquist and the bird
	# reads as a smooth painted egg, which is the one thing a feathered species
	# must not do.
	s.coat_density = 0.70
	s.translucency = 0.50
	s.roughness = 0.46

	# Birds fledge fast, and the baby → adult arc here is the most dramatic of any
	# species, so it is worth reaching sooner.
	s.hours_per_stage = 14.0
	s.stage_scale = PackedFloat32Array([0.44, 0.64, 0.85, 1.0])
	# A shade under the cat's 1.48. A nestling passerine really is mostly head,
	# but the skull grows *around* the parts mounted on it, so pushing this past
	# about 1.5 swallows the bill, the gape and the face markings whole.
	s.stage_head_bias = PackedFloat32Array([1.45, 1.24, 1.09, 1.0])
	s.stage_eye_bias = PackedFloat32Array([1.60, 1.32, 1.13, 1.0])

	s.locomotion = S.Locomotion.BIPED_HOP
	s.walk_speed = 1.15
	s.run_speed = 3.60
	s.stride = 0.42
	s.bob = 0.075
	s.jump_height = 3.20
	s.can_climb = false
	s.can_fly = true

	s.energy = 0.92
	s.affection_drive = 0.34
	s.curiosity = 0.80
	s.skittishness = 0.86

	s.voice_hz = 2200.0
	s.baby_voice_scale = 1.45
	s.voice_timbre = 0.74

	var parts: Array[P] = []

	# Proportions are the whole ballgame, and a bird's are nothing like a
	# mammal's. Reference figures for a house-sparrow-sized passerine standing on
	# the ground, measured from photographs rather than from a stretched museum
	# skin (that "16 cm long" figure is a laid-out specimen and would give a
	# hopelessly stretched animal):
	#
	#   feet → top of back      7.9 cm   ← this is 1.0 rig unit
	#   feet → crown            9.0 cm
	#   bill tip → tail tip    13.2 cm
	#   body egg               5.2 cm tall by 7.4 cm long  (1.4 : 1)
	#   exposed tarsus          2.0 cm
	#   head diameter           3.0 cm   (0.58 of the body's height)
	#
	# So the target is length / height ≈ 1.47 and an egg that is only 1.4 times
	# as long as it is deep. The failure mode to avoid is the tall skinny
	# "cartoon chick": a real songbird is a fat horizontal-ish teardrop carried
	# high on short legs, with the head *overlapping* the shoulders rather than
	# perched above them on a neck.
	#
	# The body axis tilts about 20° nose-up, which is the second-strongest cue
	# after the leg. Everything below is laid out on that tilted axis.

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# Only the lower two segments of the far leg exist. The femur of a bird is
	# horizontal and completely buried in the flank; authoring it would spend two
	# uniform slots on something that can never be seen.
	var fl_far := _part(&"leg_hind_far_lower", Vector2(0.168, -0.556), Vector2(-0.036, -0.278), 0.072, 0.042, COL_MANTLE_DARK, 0)
	var fc_far := _part(&"leg_hind_far_cannon", Vector2(-0.036, -0.278), Vector2(0.102, -0.052), 0.031, 0.024, COL_TARSUS_DARK, 0)
	fc_far.surface = P.Surface.SCALE
	fc_far.blend = 0.022
	var ft_far := _part(&"leg_hind_far_toe", Vector2(0.102, -0.052), Vector2(0.244, -0.026), 0.023, 0.010, COL_TARSUS_DARK, 0)
	ft_far.surface = P.Surface.CLAW
	ft_far.blend = 0.016
	# One far primary, sitting a hair higher than the near bundle so a sliver of
	# it shows past the near wing tip. That sliver is the entire depth read on a
	# bird held in profile — without it the folded wing is a flat decal.
	var wing_far := _part(&"wing_far_primary", Vector2(-0.260, -0.782), Vector2(-0.535, -0.748), 0.058, 0.020, COL_FLIGHT_DARK, 0)
	wing_far.height_scale = 0.34
	wing_far.blend = 0.022
	parts.append_array([fl_far, fc_far, ft_far, wing_far])

	# --- the egg ------------------------------------------------------------
	# Three capsules on one rising axis, blended hard enough that they stop being
	# three capsules. A cat gets four with a dip behind the shoulder; a bird must
	# get the opposite — an unbroken convex curve from vent to crown, because the
	# absence of any waist is what makes the silhouette read as a bird at all.
	var rump := _part(&"rump", Vector2(-0.335, -0.605), Vector2(-0.170, -0.675), 0.180, 0.240, COL_MANTLE)
	rump.blend = 0.13
	rump.height_scale = 1.12
	var torso := _part(&"torso", Vector2(-0.170, -0.675), Vector2(0.060, -0.735), 0.240, 0.258, COL_MANTLE)
	torso.blend = 0.14
	torso.height_scale = 1.14
	var chest := _part(&"chest", Vector2(0.060, -0.735), Vector2(0.200, -0.762), 0.258, 0.212, COL_MANTLE)
	chest.blend = 0.13
	chest.height_scale = 1.12
	# The rust/blue boundary on a real bird runs along the flank, not around the
	# body's circumference, so the breast has to be its own volume slung under
	# the egg rather than a differently coloured section of it.
	var belly := _part(&"belly", Vector2(-0.235, -0.515), Vector2(-0.085, -0.530), 0.120, 0.150, COL_CREAM)
	belly.blend = 0.115
	var breast := _part(&"belly_breast", Vector2(-0.035, -0.588), Vector2(0.215, -0.718), 0.215, 0.152, COL_BREAST)
	breast.blend = 0.125
	# "Nape", not "neck". A perching songbird at rest has no visible neck: the
	# vertebrae are folded into an S inside the feathers and the head simply
	# continues the shoulder. This capsule exists to fill that junction solid, so
	# the blend never opens a notch under the skull.
	var nape := _part(&"nape", Vector2(0.140, -0.815), Vector2(0.265, -0.880), 0.185, 0.162, COL_MANTLE)
	nape.blend = 0.105
	parts.append_array([rump, torso, chest, belly, breast, nape])

	# --- head ---------------------------------------------------------------
	# Nearly spherical: the two endpoints are only 0.11 apart under a 0.17
	# radius. A bird's skull has no muzzle to lengthen it — everything in front of
	# the eye is beak, and that hard boundary between a round skull and a straight
	# cone is a species cue in its own right.
	var skull := _part(&"head", Vector2(0.286, -0.950), Vector2(0.404, -0.964), 0.194, 0.176, COL_MANTLE)
	skull.blend = 0.075
	# The three face markings below all sit *inside* the skull volume, which makes
	# the renderer treat them as paint rather than as geometry — see the marking
	# branch in `eval_layer`. That is the only way to get a stripe onto a face
	# built out of capsules.
	var throat := _part(&"chin_throat", Vector2(0.305, -0.875), Vector2(0.400, -0.912), 0.055, 0.048, COL_CREAM)
	throat.blend = 0.03
	var cheek := _part(&"cheek_patch", Vector2(0.298, -0.935), Vector2(0.408, -0.952), 0.074, 0.058, COL_CHEEK)
	cheek.blend = 0.028
	parts.append_array([skull, throat, cheek])

	# --- tail ---------------------------------------------------------------
	# Seen from the side a closed songbird tail is a blade, not a fan, so three
	# chained capsules with a falling `height_scale` is an honest model of it:
	# thick and rounded where the uppertail coverts still cover the quills, then
	# progressively flatter out to the tips.
	var tail_a := _part(&"tail_0", Vector2(-0.370, -0.650), Vector2(-0.555, -0.652), 0.104, 0.082, COL_MANTLE)
	tail_a.height_scale = 0.60
	tail_a.blend = 0.05
	var tail_b := _part(&"tail_1", Vector2(-0.555, -0.652), Vector2(-0.790, -0.648), 0.082, 0.072, COL_FLIGHT)
	tail_b.height_scale = 0.28
	tail_b.blend = 0.028
	var tail_c := _part(&"tail_2", Vector2(-0.790, -0.648), Vector2(-0.908, -0.638), 0.072, 0.050, COL_FLIGHT_DARK)
	tail_c.height_scale = 0.24
	tail_c.blend = 0.024
	parts.append_array([tail_a, tail_b, tail_c])

	# --- near leg -----------------------------------------------------------
	# The single strongest species cue on the whole animal. A bird's ankle is the
	# intertarsal joint, and it folds *backwards* — what looks like a knee bending
	# the wrong way. The chain here is:
	#
	#   tibiotarsus   from inside the belly feathers, down and BACK
	#   ankle         the rearmost point of the leg, at x = -0.062
	#   tarsometatarsus  bare, scaled, down and FORWARD to the toes
	#
	# The interior angle at the ankle is about 118°, which is a relaxed perching
	# crouch. Straighten it past ~150° and the bird instantly reads as a mammal
	# on two legs; close it past ~90° and it reads as a wading bird.
	var fl := _part(&"leg_hind_near_lower", Vector2(0.085, -0.552), Vector2(-0.125, -0.268), 0.078, 0.046, COL_BREAST)
	fl.blend = 0.05
	var fc := _part(&"leg_hind_near_cannon", Vector2(-0.125, -0.268), Vector2(0.010, -0.040), 0.033, 0.025, COL_TARSUS)
	fc.surface = P.Surface.SCALE
	fc.blend = 0.022
	var ft := _part(&"leg_hind_near_toe", Vector2(0.010, -0.040), Vector2(0.158, -0.012), 0.025, 0.010, COL_TARSUS)
	ft.surface = P.Surface.CLAW
	ft.blend = 0.016
	# The hallux. Three toes forward and one back is what a perching foot *is*,
	# and it costs one capsule. Deliberately named without a segment token so the
	# limb fitter spends its one foot bone on the forward toes and binds this to
	# them rather than fighting over which is the end effector.
	var hal := _part(&"leg_hind_near_hallux", Vector2(0.008, -0.040), Vector2(-0.100, -0.014), 0.019, 0.007, COL_TARSUS)
	hal.surface = P.Surface.CLAW
	hal.blend = 0.014
	parts.append_array([fl, fc, ft, hal])

	# --- folded wing --------------------------------------------------------
	# In BODY, not FRONT, and that is a considered choice. A folded wing is not
	# held away from the flank; it is pressed flat against it, so the honest model
	# is a raised patch on the body rather than a separate plane in front of it.
	# Authored in FRONT it also came out visibly *brighter* than the mantle it is
	# lying on — the front layer is lit with no occlusion while everything behind
	# it pays a cast shadow — and it dragged that shadow across the whole flank,
	# which is what was turning the rust underneath into mud.
	#
	# Sitting inside the body's field, each capsule is engulfed and therefore
	# paints, and the renderer gives a painted part its own shallow dome. So the
	# wing arrives as what it actually is: a crisply outlined shape standing a
	# little proud of the contour feathers, with the smooth-union crease drawing
	# the dark line along its lower edge for free.
	#
	# The coverts stay rounded and soft; the flight groups flatten toward a
	# `height_scale` of 0.30 and drop their blend to 0.02, which is the whole
	# difference between a stiff vane and the down it lies on. The tip clears the
	# rump and reaches about a third of the way down the tail — a folded wing that
	# stops at the rump reads as clipped.
	var w_cov := _part(&"wing_near_covert", Vector2(0.158, -0.826), Vector2(-0.060, -0.786), 0.084, 0.102, COL_FLIGHT)
	w_cov.height_scale = 0.86
	w_cov.blend = 0.016
	var w_sec := _part(&"wing_near_secondary", Vector2(-0.060, -0.786), Vector2(-0.280, -0.748), 0.102, 0.066, COL_FLIGHT_DARK)
	w_sec.height_scale = 0.44
	w_sec.blend = 0.014
	var w_pri := _part(&"wing_near_primary", Vector2(-0.278, -0.750), Vector2(-0.566, -0.714), 0.066, 0.021, COL_FLIGHT_DARK)
	w_pri.height_scale = 0.30
	w_pri.blend = 0.014
	pass # DIAGNOSTIC: wing omitted

	# --- beak ---------------------------------------------------------------
	# Hard keratin, so CLAW rather than SKIN: the claw model pipes light along the
	# fibre to the point, which is exactly what a translucent bill tip does. The
	# two mandibles overlap by a third of their radii so they fuse into one solid
	# cone with the colour break falling on the gape line.
	var beak_up := _part(&"beak_upper", Vector2(0.452, -0.988), Vector2(0.678, -0.942), 0.066, 0.010, COL_BEAK, 2)
	beak_up.surface = P.Surface.CLAW
	beak_up.blend = 0.020
	var beak_lo := _part(&"beak_lower", Vector2(0.452, -0.938), Vector2(0.654, -0.930), 0.048, 0.009, COL_BEAK_PALE, 2)
	beak_lo.surface = P.Surface.CLAW
	beak_lo.blend = 0.018
	# The gape flange. At adult it is a 0.019 speck buried in the base of the bill
	# and paints as a thin yellow rictus; at baby `baby_radius_scale` and the head
	# bias between them multiply it past the bill's own radius so it stops being a
	# marking and becomes a swollen fleshy corner. That single number is most of
	# what makes the fledgling read as a fledgling.
	var gape := _part(&"beak_gape", Vector2(0.462, -0.968), Vector2(0.492, -0.962), 0.016, 0.012, COL_GAPE, 2)
	gape.surface = P.Surface.SKIN
	gape.blend = 0.016
	# Natal down. Invisibly thin on an adult, a proper cowlick on a chick.
	var down := _part(&"crest_down", Vector2(0.320, -1.086), Vector2(0.300, -1.134), 0.009, 0.004, COL_CREAM)
	down.height_scale = 0.70
	down.blend = 0.020
	parts.append_array([beak_up, beak_lo, gape, down])

	# Fledgling proportions. A baby bird is not a small bird — it is a different
	# silhouette: a huge round head on a stubby body, a tail that is barely a
	# stump, wings too short to fly with, and legs that are already nearly
	# adult length, which is why fledglings look so leggy and precarious.
	#
	# The trap here is that `stage_head_bias` inflates the skull *around a fixed
	# part position*. Anything mounted on the face therefore has to be walked
	# outward with `baby_offset` or the growing head simply eats it — the first
	# chick had its whole bill inside its own cheek and a gape flange floating in
	# the middle of its face like a second eye.
	const BABY_FACE_PUSH := Vector2(0.150, 0.034)
	for p in parts:
		var id := String(p.id)
		if id == "beak_gape":
			p.baby_radius_scale = 2.20
			p.baby_length_scale = 1.10
			p.baby_offset = BABY_FACE_PUSH
		elif id == "crest_down":
			p.baby_radius_scale = 4.00
			p.baby_length_scale = 2.40
			p.baby_offset = Vector2(-0.022, -0.152)
		elif id.begins_with("beak"):
			# Short, blunt and stubby, but still clear of the skull.
			p.baby_length_scale = 0.82
			p.baby_radius_scale = 1.10
			p.baby_offset = BABY_FACE_PUSH
		elif id.begins_with("tail"):
			# A stump with real width rather than a needle: a fledgling's rectrices
			# are half-grown and still in their sheaths, so the tail is short *and*
			# blunt-ended.
			p.baby_length_scale = 0.46
			p.baby_radius_scale = 1.45
		elif id.begins_with("wing"):
			p.baby_length_scale = 0.55
			p.baby_radius_scale = 1.50
		elif id.begins_with("leg"):
			# Nearly adult length under a body less than half adult size, which is
			# exactly why fledglings look so leggy and precarious.
			p.baby_length_scale = 0.90
			p.baby_radius_scale = 1.32
		elif id in ["rump", "torso", "chest", "belly", "belly_breast"]:
			p.baby_length_scale = 0.86
			p.baby_radius_scale = 1.10
		elif id in ["head", "cheek_patch", "chin_throat"]:
			# Left near 1.0 on purpose: `stage_head_bias` is already 1.45 here, and
			# stacking a second multiplier on top is what turns a chick's head into
			# a featureless ball with the markings swallowed inside it.
			p.baby_radius_scale = 1.05
		else:
			p.baby_radius_scale = 1.08

	# Feather tract direction. Contour feathers sweep back and down along the
	# body; a flight feather's rachis runs the length of the feather, which for
	# the wing and tail capsules is simply their own axis. `pet_feather` indexes
	# its barbs off this, so getting it wrong on the wing lays the barbs along the
	# vane instead of across it and the whole thing reads as a painted shell.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("wing") or id.begins_with("tail") or id.begins_with("beak") \
				or id.begins_with("crest") or id.begins_with("leg"):
			p.groom_angle = (p.b - p.a).angle()
		else:
			# Backwards along the tilted body axis, not along -x: the tract has to
			# follow the egg or the barb rows cross the silhouette at an angle.
			p.groom_angle = 2.80

	s.parts = parts

	# Round pupil in a round eye, set high and forward on the skull — the
	# opposite of a cat in every respect. The iris of a small passerine is so dark
	# it is nearly indistinguishable from the pupil, so `iris_ratio` runs almost
	# to the lid and the sclera survives only as a thin warm crescent. Reading
	# "one big black bead" is correct here; a visible white eyeball would make it
	# a cartoon.
	var eye_near: E = E.new()
	eye_near.id = &"eye_near"
	eye_near.bone = &"head"
	eye_near.center = Vector2(0.436, -1.012)
	eye_near.radius = 0.054
	eye_near.tilt = 0.0
	eye_near.iris_ratio = 0.93
	eye_near.pupil_ratio = 0.62
	eye_near.pupil_slit = 0.0
	eye_near.iris_color = Color(0.20, 0.13, 0.09)
	eye_near.limbal_color = Color(0.03, 0.02, 0.02)
	eye_near.sclera_color = Color(0.90, 0.86, 0.80)
	eye_near.socket_depth = 0.18
	eye_near.lid_palette_index = COL_MANTLE

	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.248, -0.966)
	eye_far.radius = 0.026
	eye_far.tilt = 0.0
	eye_far.iris_ratio = 0.93
	eye_far.pupil_ratio = 0.62
	eye_far.pupil_slit = 0.0
	eye_far.iris_color = Color(0.17, 0.11, 0.08)
	eye_far.limbal_color = Color(0.03, 0.02, 0.02)
	eye_far.sclera_color = Color(0.86, 0.82, 0.77)
	eye_far.socket_depth = 0.70
	eye_far.lid_palette_index = COL_MANTLE

	s.eyes = [eye_far, eye_near]
	# Birds blink far more often than mammals, and the nictitating flick is part
	# of why they read as nervous.
	s.blink_interval = 2.6
	return s
