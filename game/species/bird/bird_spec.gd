extends RefCounted

## Small perching songbird — dark iridescent upperparts over pale underparts, in
## the shape of a chat or a bluebird and in the colours of a martin.
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
## Not referenced by any part: the body shader reads slot 1 directly through its
## `marking_index` uniform. See the palette note in `build`.
const COL_MANTLE_BAND := 1
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

	# Slot 1 is not a free colour, and that constrains the whole scheme.
	#
	# The body shader paints its dorsal markings — mackerel bars plus a solid spine
	# line — in `palette[marking_index]`, and both that index and the
	# `marking_strength` beside it are left at their shader defaults, because
	# `CreatureRenderer._upload_static` never sets either. So every species takes
	# full-strength tabby out of slot 1 whether it wants it or not. A cat wants
	# exactly that. A songbird does not: bars that bend and break along the flank
	# are a mammal's agouti banding, and on a bird they read as watered silk.
	#
	# The one lever a species actually owns is *how far slot 1 sits from slot 0*,
	# since the marking is a `mix` between them. Pulling it to within about half the
	# old distance turns the bars into the soft tonal variation real feather tracts
	# have, and leaves the barbs from `pet_feather` — the structure this species
	# exists to show — as the loudest thing on the mantle rather than the second
	# loudest. It is a workaround, not a fix; the fix is a per-species
	# `marking_strength`, flagged in the hand-off because `CreatureSpec` is not this
	# file's to change.
	#
	# The second constraint is the one that actually chose these colours, and it is
	# worth stating as a rule because it is invisible until it has already ruined a
	# palette: `takes = smoothstep(0.88, 0.60, luminance)`. Markings apply at *full*
	# strength to anything below luminance 0.60, taper to nothing by 0.88, and the
	# mix runs at 0.88 toward slot 1. So any saturated mid-tone on a feathered part
	# is not "a colour with faint bars over it" — it is a colour that gets replaced
	# by slot 1 across most of its area.
	#
	# The first pass of this species was a saturated rust breast at luminance 0.50
	# and near-black navy wings at 0.10. Both sat squarely in the full-strength
	# band, so the mackerel code mixed the rust 88% toward blue and *lightened* the
	# wing in four hard-edged bands — the wing arrived on screen as a row of dark
	# rectangles, which is what sent this pass looking for a bug in the wing
	# geometry. The wing was fine. The colours were in the wrong luminance window.
	#
	# There are only two ways out, and the species has to pick one per colour:
	# climb above the gate, or sit close enough to slot 1 that the mix has nowhere
	# to move you. The useful measure is not the colour distance to slot 1 but
	# `0.88 * takes * distance` — how far a bar *actually* shifts the pixel. Under
	# about 0.06 it is invisible, around 0.10 it reads as tonal banding, and past
	# 0.20 it reads as a stripe painted on a toy.
	#
	#   mantle       lum 0.28  takes 1.00  bar shift 0.09   soft tract banding
	#   flight       lum 0.17  takes 1.00  bar shift 0.10   covert edging
	#   flight dark  lum 0.12  takes 1.00  bar shift 0.18   feather tips
	#   breast       lum 0.83  takes 0.09  bar shift 0.09   immune by luminance
	#   cheek        lum 0.86  takes 0.02  bar shift 0.02   immune by luminance
	#   belly        lum 0.95  takes 0.00  bar shift 0.00   immune by luminance
	#
	# That is what drove the bird dark above and pale below rather than the mid
	# sky-blue and rust it started as: a *saturated mid-tone is the one thing this
	# palette cannot contain*, because it is far from slot 1 and far below the gate
	# at the same time. Dark-above/pale-below is also the honest resolution
	# aesthetically — deep blue-black upperparts with pale underparts is a swallow
	# or a martin, and those are precisely the birds that are iridescent, which is
	# the surface effect this species exists to show. The thin-film term in
	# `creature_body` is additive and reads against a dark ground; on the pale
	# sky-blue it was invisible.
	s.palette = PackedColorArray([
		Color(0.205, 0.280, 0.470),   # mantle: crown, back, rump, uppertail
		Color(0.163, 0.228, 0.390),   # dorsal feather-tract banding (shader slot 1)
		Color(0.120, 0.165, 0.300),   # wing coverts and central rectrices
		Color(0.105, 0.145, 0.268),   # secondaries, primaries, outer rectrix
		Color(0.975, 0.800, 0.655),   # breast and flank, warm apricot
		Color(0.965, 0.945, 0.905),   # belly and throat
		Color(0.900, 0.855, 0.760),   # ear-covert cheek patch, warm buff
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
	# This number is the whole feather read, and it runs backwards from the
	# intuition that "denser = more detail".
	#
	# `pet_feather` lays barbs at a pitch of `150 * coat_density` lanes per rig
	# unit and then multiplies the entire result — relief, occlusion, spec break-up
	# and the iridescence weight — by `smoothstep(1.8, 4.2, px_per_unit / pitch)`,
	# i.e. by how many screen pixels one barb gets. Raising density shrinks the
	# barb, so it *closes* that gate. At 158 px/unit the arithmetic is:
	#
	#   density 0.70 → 105 lanes/unit → 1.5 px per barb → gate 0.00
	#   density 0.38 →  57 lanes/unit → 2.8 px per barb → gate 0.36
	#   density 0.30 →  45 lanes/unit → 3.5 px per barb → gate 0.80
	#
	# The species shipped at 0.70, which is not "fine plumage" — it is the vanes
	# switched off entirely, leaving the mammal marking code as the only structure
	# on the bird, and the thin-film term dead with it (`irid` is barb coverage, and
	# coverage was zero).
	#
	# The other end is just as wrong, and less obvious. `pet_feather` builds its
	# lane from `arc + abs(v) * 1.6`, where `arc` is the world position projected on
	# the groom direction but `v` is distance *through the blended field*. On a long
	# flat part — a primary, a rectrix — the `v` term bends the lanes into barbs
	# raking back off a rachis, which is exactly right. On a three-capsule egg it
	# bends them into iso-distance contours of the whole body, so at gate 0.80 the
	# torso came back as a topographic map: concentric fingerprint whorls with a
	# 28% occlusion swing between lane and gap.
	#
	# 0.38 is where the two failures are both avoided. The vanes are real — fine
	# enough to read as barbs, and carrying enough coverage to light the
	# iridescence — while the contouring on the body stays a sheen rather than a
	# relief map. Wings and tail get the good end of the same number for free,
	# because there the contours *are* the barbs.
	#
	# The cost is that `coat_density` is one global and the scaled tarsi read it too
	# (`pet_scale` sizes a plate at `0.030 / density`), so this trades finer scutes
	# for a bird that actually has feathers. It puts about four plates on a 0.26-unit
	# tarsus, which is close to what a real passerine shows anyway.
	s.coat_density = 0.38
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
	# Only two segments of the far leg exist: the far side is a sliver beside the
	# near leg, and a third capsule there would cost a uniform slot the budget no
	# longer has (this species is 28 of 28).
	#
	# The segment tokens are therefore a lie, deliberately, and the next person to
	# read this needs to know which way. `upper` here is the *tibiotarsus* and
	# `lower` is the *tarsometatarsus* — each shifted one segment proximal from what
	# it anatomically is, so that the chain `_fit_limb` builds starts at an UPPER
	# bone. A limb whose first member declares `lower` gets a chain with no root
	# bone at all, and the near leg's history shows what that costs: the IK solved it
	# as though the tibiotarsus were the femur and planted the hip on the ground. The
	# near leg fixes it honestly, with a real femur; the far leg cannot afford one
	# and buys the same well-formed chain by renaming instead.
	#
	# It is not a complete fix. The far ankle still measures about 0.08 below the
	# ground plane against the near leg's 0.00 — see the hand-off note. Behind the
	# body and under the contact shadow it does not read, but it is not right.
	#
	# The far tibiotarsus takes the *same* buff as the near one rather than a
	# darkened stand-in. It is still feathered flank at this height — the trousers,
	# not the bare leg — so painting it a separate dark colour put a brown blob
	# under the belly that read as a shadow rather than as a limb. The BEHIND layer
	# already has `layer_occlude` and the atmospheric term to push it back, and
	# those desaturate rather than just darken, which is the whole reason they
	# exist.
	var fl_far := _part(&"leg_hind_far_upper", Vector2(0.168, -0.556), Vector2(-0.036, -0.278), 0.072, 0.042, COL_BREAST, 0)
	var fc_far := _part(&"leg_hind_far_lower", Vector2(-0.036, -0.278), Vector2(0.102, -0.052), 0.031, 0.024, COL_TARSUS_DARK, 0)
	fc_far.surface = P.Surface.SCALE
	fc_far.blend = 0.022
	var ft_far := _part(&"leg_hind_far_toe", Vector2(0.102, -0.052), Vector2(0.244, -0.026), 0.023, 0.010, COL_TARSUS_DARK, 0)
	ft_far.surface = P.Surface.CLAW
	ft_far.blend = 0.016
	# One far primary, sitting a hair higher than the near bundle so a sliver of
	# it shows past the near wing tip. That sliver is the entire depth read on a
	# bird held in profile — without it the folded wing is a flat decal.
	var wing_far := _part(&"flank_far_primary", Vector2(-0.260, -0.782), Vector2(-0.535, -0.748), 0.058, 0.020, COL_FLIGHT_DARK, 0)
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
	# The pale/dark boundary on a real bird runs along the flank, not around the
	# body's circumference, so the underparts have to be their own volumes slung
	# under the egg rather than a differently coloured section of it.
	#
	# Both run further back and sit higher than they first did, and that is doing
	# work for the *wing* rather than for the belly. The folded wing is painted
	# after these, so wherever the two overlap the wing wins and the visible edge is
	# the wing's own lower outline. That makes the pale underparts the only thing
	# this species has that can draw that outline with real contrast: tonal
	# separation between wing and mantle is capped by the marking gate above, but
	# pale against dark is not capped by anything. Where the pale stopped short of
	# the wing tip the wing's rear half was dark-on-dark and simply disappeared,
	# which is most of why the folded wing stayed invisible at desktop size even
	# after it was being drawn at all.
	# These two are *surface*, not paint, and the difference is the whole reason the
	# underparts read as underparts.
	#
	# A part buried inside the body only paints where `engulf` lets it, and that
	# gate is `smoothstep(0.15 * r, 0.6 * r, burial)` — scaled by the painting
	# part's own radius. A breast wide enough to cover a bird's underside is r 0.17
	# inside a body of r 0.25, so the deepest burial it can ever reach is about 0.08
	# against the 0.10 it would need. It is arithmetically incapable of painting
	# fully: only its core comes through, faded, which is exactly the soft oval
	# stain floating on the flank that this replaces. Shrinking it to fit the gate
	# would make it too small to be a belly.
	#
	# So they are pitched a hair *proud* of the mantle capsules along the ventral
	# line instead. There the pale wins the ordinary smooth-union blend rather than
	# the paint path, the flank line falls where the two fields cross, and `blend`
	# sets how sharp that line is — which is why it drops from 0.12 to 0.035. It is
	# the same thing the cat's belly does.
	var belly := _part(&"belly", Vector2(-0.350, -0.565), Vector2(-0.120, -0.578), 0.150, 0.160, COL_CREAM)
	belly.blend = 0.024
	var breast := _part(&"belly_breast", Vector2(-0.120, -0.570), Vector2(0.185, -0.650), 0.150, 0.172, COL_BREAST)
	breast.blend = 0.026
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
	#
	# The femur is authored even though it can never be seen, and that is not
	# bookkeeping — without it the leg is broken. A bird's femur really is horizontal
	# and buried in the flank, so the first instinct is to leave it out and start the
	# chain at the tibiotarsus, which is what this species did. But `_fit_limb` reads
	# the segment token off each part and builds the bone chain from it, so a leg
	# whose first member declares `lower` gets a chain with no UPPER bone, and the IK
	# then solves it as though the tibiotarsus were the femur. The result measured
	# +0.018 at the top of the thigh — the hip joint planted *on the ground*, with
	# the drumstick drawn as a second shin standing beside the real one. It is
	# clearly visible once you know to look: every earlier capture in this pass has
	# four leg segments on the near side instead of three.
	#
	# So it exists to give the chain its UPPER, and it is painted in mantle rather
	# than in flank buff precisely so it stays invisible: matching the body colour
	# drives `distinct` to zero, and a part that fails the distinctness test paints
	# nothing at all.
	var ff := _part(&"leg_hind_near_upper", Vector2(-0.075, -0.628), Vector2(0.085, -0.552), 0.072, 0.070, COL_MANTLE)
	ff.blend = 0.05
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
	parts.append_array([ff, fl, fc, ft, hal])

	# --- folded wing --------------------------------------------------------
	# Named `flank_*` and not `wing_*`, and that is load-bearing rather than
	# cosmetic. `RigBoneMap` routes any id containing `wing`, `covert`, `primary` or
	# `secondary` to `Slot.WING`, and `RigSkeleton.build` then fits it as an
	# articulated limb — twice, because the `fore` loop it sits inside is only
	# skipped for `Slot.LIMB`, so both passes add the same bone names and parts end
	# up bound against duplicated rest transforms. The measured result was the wing
	# collapsing: the secondary's root snapped onto the covert's root and the primary
	# tip was dragged from x = -0.59 to -0.30, which is why the folded wing was
	# unreadable no matter how it was coloured. Classified on `flank` it becomes a
	# SPINE part, rides the torso rigidly, and holds the shape authored here to
	# within a hundredth of a unit. A perched songbird's folded wing does not
	# articulate anyway. See the hand-off: this wants fixing in the rig, and until it
	# is, a species that names a wing `wing` gets a broken one.
	#
	# In BODY, not FRONT. A folded wing is not held away from the flank; it is
	# pressed flat against it, so the honest model is a patch on the body rather than
	# a separate plane in front of it. FRONT was tried and is badly wrong: that layer
	# takes no occlusion at all and casts a 42% shadow on everything behind it, so
	# the wing came back fully lit with a hard rim and read as a plank leaning
	# against the bird.
	#
	# Sitting inside the body's field, each capsule is engulfed and therefore paints,
	# and the renderer gives a painted part its own shallow dome at the edge of the
	# painted region — so the outline gets relief even though the silhouette cannot.
	#
	# Soft coverts, stiff flight feathers, and the distinction is carried by the
	# *material* rather than by shape or tone.
	#
	# Tone cannot carry it: the marking gate caps how far the wing may sit from the
	# mantle (see the palette note), and inside that cap the wing is a faint patch
	# however it is drawn. What the renderer does hand over is `f.mat` — a part that
	# wins the paint test brings its own surface family with it, which is the same
	# mechanism that lets a nose be bare leather in the middle of a furry face. So
	# the secondaries and primaries are CLAW: the same hard keratin as the beak and
	# the claws, because that is literally what a flight feather's rachis and vane
	# are. They come back with a tight 0.16 roughness and a specular that runs along
	# the fibre, against the broad matte barb scatter of the contour feathers around
	# them. A folded wing catching a hard line of light while the breast beside it
	# stays soft is the read the brief is asking for, and it is the only one
	# available that the palette cannot veto.
	#
	# The coverts stay FEATHER — they are the soft, rounded, overlapping rows that
	# cover the base of the flight feathers, and turning them glossy too would lose
	# the contrast this is buying.
	#
	# `height_scale` is set on all three for documentation only: an engulfed part
	# loses that field to the body it is painted on (`h` saturates at 1 in the smin,
	# so the torso's value wins). It matters on the far wing, which unions in its
	# own layer, and nowhere else.
	var w_cov := _part(&"flank_covert", Vector2(0.168, -0.834), Vector2(-0.050, -0.790), 0.078, 0.096, COL_FLIGHT)
	w_cov.height_scale = 0.86
	w_cov.blend = 0.016
	var w_sec := _part(&"flank_secondary", Vector2(-0.050, -0.790), Vector2(-0.278, -0.752), 0.096, 0.062, COL_FLIGHT_DARK)
	w_sec.surface = P.Surface.CLAW
	w_sec.height_scale = 0.44
	w_sec.blend = 0.014
	# The primaries carry the one piece of the wing that is allowed to be geometry
	# rather than paint. Everything forward of here is buried in the flank and can
	# only ever be a painted patch, but past the rump the body has run out and the
	# only thing left at this height is the tail — so lifting the tip until its
	# upper edge clears the tail's by about 0.03 puts a real tapered point into the
	# silhouette. That is worth more than any amount of extra contrast on the buried
	# part: a shape that breaks the outline is read as a separate object for free,
	# and wing tips crossing over the base of the tail is exactly how a perched
	# passerine folds.
	var w_pri := _part(&"flank_primary", Vector2(-0.276, -0.754), Vector2(-0.590, -0.748), 0.062, 0.024, COL_FLIGHT_DARK)
	w_pri.surface = P.Surface.CLAW
	w_pri.height_scale = 0.30
	w_pri.blend = 0.014
	parts.append_array([w_cov, w_sec, w_pri])

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
	# The gape flange. The whole point of it is that it is a *fledgling* feature, so
	# the adult radius is set by what should be invisible rather than by what looks
	# right on a chick: at 0.008 it is a hairline of yellow skin in the crease where
	# the mandibles meet the face, which is all an adult passerine has. At 0.016 —
	# where it started — a head close-up showed a grown bird with a yellow patch on
	# its bill like a permanent baby.
	#
	# `baby_radius_scale` then does the work in the other direction, and it has to be
	# large because it is compensating for a deliberately tiny adult. Multiplied by
	# the 1.45 head bias it swells past the bill's own radius, so it stops being a
	# marking and becomes the swollen fleshy corner that makes a fledgling read as a
	# fledgling.
	var gape := _part(&"beak_gape", Vector2(0.462, -0.968), Vector2(0.492, -0.962), 0.008, 0.007, COL_GAPE, 2)
	gape.surface = P.Surface.SKIN
	gape.blend = 0.012
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
			p.baby_radius_scale = 3.80
			p.baby_length_scale = 1.10
			p.baby_offset = BABY_FACE_PUSH
		elif id == "crest_down":
			# Shorter and blunter than it was. Natal down is a scruffy tuft, and at
			# 2.4 length it came to a point and read as a little grey horn.
			p.baby_radius_scale = 4.60
			p.baby_length_scale = 1.60
			p.baby_offset = Vector2(-0.022, -0.128)
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
		elif id.begins_with("flank"):
			# The folded wing — see the naming note above it. A fledgling's flight
			# feathers are still half in their sheaths, so it is short and blunt, and
			# too short to fly with, which is the point of the stage.
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
	# the wing (`flank_*`) and tail capsules is simply their own axis. `pet_feather`
	# indexes its barbs off this, so getting it wrong on the wing lays the barbs
	# along the vane instead of across it and the whole thing reads as a painted
	# shell.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("flank") or id.begins_with("tail") or id.begins_with("beak") \
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

	# The far eye is a hint, not a second eye. A bird's eyes sit on the sides of a
	# round skull, so at this three-quarter angle the far one should be most of the
	# way round the curve: a small dark bead, high, deep in its socket. Sitting where
	# it first did — 0.046 lower than the near eye and two thirds its size — it came
	# forward onto the cheek and read as a googly second eye rather than as the far
	# side of a head. Raised nearly level with its partner and shrunk, it goes back
	# to doing the only job it has, which is saying the skull has a far side.
	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.258, -0.998)
	eye_far.radius = 0.019
	eye_far.tilt = 0.0
	eye_far.iris_ratio = 0.93
	eye_far.pupil_ratio = 0.62
	eye_far.pupil_slit = 0.0
	eye_far.iris_color = Color(0.17, 0.11, 0.08)
	eye_far.limbal_color = Color(0.03, 0.02, 0.02)
	eye_far.sclera_color = Color(0.86, 0.82, 0.77)
	eye_far.socket_depth = 0.82
	eye_far.lid_palette_index = COL_MANTLE

	s.eyes = [eye_far, eye_near]
	# Birds blink far more often than mammals, and the nictitating flick is part
	# of why they read as nervous.
	s.blink_interval = 2.6
	return s
