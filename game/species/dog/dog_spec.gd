extends RefCounted

## Shiba Inu.
##
## Rig space convention used by every species:
##   * +x is forward (the creature faces right at rotation 0),
##   * +y is down (matching Godot's 2D axes),
##   * the origin sits between the paws on the ground plane,
##   * 1.0 unit ≈ adult shoulder height.
##
## Why a Shiba and not "a dog": at desktop-pet size the silhouette is the whole
## performance, and a generic dog has no silhouette. A Shiba has four shapes that
## survive being 60 px tall — small pricked triangular ears, a thick tail carried
## high off the croup, a blunt wedge muzzle under a broad skull, and a deep chest
## over a hard tuck-up. Every one of those is something a cat does not have, which
## is the actual brief: the dog must not read as a recoloured cat.
##
## The tail is the *sashio* sickle, not the *maki-o* curl, and the standard allows
## both. The curl was drawn for four passes and measured at ship size as a second
## head; see the tail block for the numbers and for why no amount of daylight
## under a curl survives the downscale.

const P := preload("res://core/creature/sdf_part.gd")
const S := preload("res://core/creature/creature_spec.gd")
const E := preload("res://core/creature/eye_spec.gd")

# Palette slots, referenced by every part below. A red Shiba is two colours and
# a nose: the red coat, the cream `urajiro` that runs along everything the sun
# does not hit, and black leather. Keeping it that tight is deliberate — the
# breed's markings are a hard-edged pattern, not a gradient, and extra hues just
# muddy the boundary that makes the face readable.
const COL_COAT := 0
const COL_COAT_DARK := 1
const COL_CREAM := 2
const COL_CREAM_FACE := 3
const COL_INNER_EAR := 4
const COL_NOSE := 5


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
	p.blend = 0.06
	return p


static func build() -> S:
	var s: S = S.new()
	s.species_id = &"dog"
	s.display_name = "Shiba"
	s.blurb = "Has opinions about your typing speed. Will fetch a window you were not finished with and present it to you, tail first, entirely pleased with itself."

	s.palette = PackedColorArray([
		Color(0.71, 0.42, 0.21),   # red coat
		Color(0.55, 0.31, 0.16),   # far side, ear backs, tail tip. Only a step
		                           # down from the coat: the BEHIND layer is
		                           # already shaded as far-side, and stacking a
		                           # genuinely dark pigment on top of that turned
		                           # the off legs and the far ear into holes.
		Color(0.94, 0.90, 0.83),   # urajiro: belly, socks
		Color(0.90, 0.85, 0.76),   # urajiro on the face — a shade warmer, so the
		                           # cheek mask reads as fur meeting fur and not
		                           # as a sticker laid over the muzzle
		Color(0.79, 0.51, 0.44),   # inner ear
		Color(0.13, 0.12, 0.13),   # nose leather
	])

	s.adult_height = 1.0
	# A Shiba stands taller than a cat in life and should draw a little larger on
	# the desktop, but not so much that two pets cannot share a taskbar.
	s.pixels_per_unit = 200.0
	s.coat_surface = P.Surface.FUR
	# A double coat: stiff guard hairs standing off a dense undercoat. Denser than
	# the cat's, less translucent because there is a second layer behind it, and
	# rougher because guard hairs do not take a sheen. Strand *length* is barely
	# above the cat's, though — at 0.024 the anisotropic shading resolved into
	# visible parallel lines and the whole animal read as wood grain.
	s.coat_length = 0.019
	s.coat_density = 1.28
	s.translucency = 0.42
	s.roughness = 0.62

	s.hours_per_stage = 20.0
	s.stage_scale = PackedFloat32Array([0.42, 0.62, 0.84, 1.0])
	s.stage_head_bias = PackedFloat32Array([1.52, 1.28, 1.11, 1.0])
	s.stage_eye_bias = PackedFloat32Array([1.58, 1.32, 1.13, 1.0])

	s.locomotion = S.Locomotion.QUADRUPED
	s.walk_speed = 1.05
	s.run_speed = 3.35
	# Shorter stride than the cat at a higher speed, which is the whole difference
	# in how the two move: a cat lengthens its stride, a small dog just takes more
	# of them. Step frequency is speed/stride, so 1.05/0.34 ≈ 3.1 Hz against the
	# cat's 2.0 — busy, trotty, and paired with a bob nearly twice the cat's it
	# reads as bouncing rather than flowing.
	s.stride = 0.34
	# `Gait._calibrate_bob` solves for the gain that lands on this number whatever
	# the leg length, so it is a real amplitude and not a hint: 0.055 against the
	# cat's 0.035 is a 57% deeper rise and fall per step.
	s.bob = 0.055
	# No claws to hook with and a body built for driving forward rather than up.
	s.jump_height = 1.25
	s.can_climb = false
	s.can_fly = false

	s.energy = 0.82
	s.affection_drive = 0.90
	# Curious, but about *you*: a dog investigates the thing you just touched,
	# where the cat investigates the thing that moved. Slightly under the cat's
	# 0.85 so the utility AI biases toward the cursor rather than the icons.
	s.curiosity = 0.70
	s.skittishness = 0.20

	# Roughly an octave below the cat, and buzzier: a small dog's voice sits on a
	# harsh vocal-fold rasp where a cat's sits on breath.
	s.voice_hz = 252.0
	s.baby_voice_scale = 1.95
	s.voice_timbre = 0.72

	var parts: Array[P] = []

	# Proportions, from the breed standard and checked against the rig:
	#   * body length : height at withers = 11 : 10. That is the number that makes
	#     a Shiba a Shiba — it is a *square* dog, where the cat this engine
	#     already ships is a long one. Built here as 1.095 : 0.954.
	#   * depth of chest = half the height at the withers, so the elbow sits at
	#     y = -0.477 with the withers at -0.954.
	#   * the underline then rises 0.16 from brisket to flank. That tuck-up, and
	#     the topline sloping the other way from a 0.954 withers down to a 0.907
	#     croup, are the two lines a cat does not have: a cat's back dips behind
	#     the shoulder and its belly runs level.
	#   * head carried high and back, so the skull crowns the neck instead of
	#     continuing the spine. Withers -0.954, top of skull -1.192, ear tips
	#     -1.319.
	# Measured off the grown bind pose, adult: nose-to-rump 1.512 over a 0.954
	# withers is L/H 1.58, against the cat's 1.68, and the whole animal is 1.15
	# times as long as it is tall against the cat's 1.34. Short, deep and upright
	# where the cat is long, level and low. Those two numbers are the argument.

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# Staggered hard against the near pair — fore 0.088 back, hind 0.058 forward.
	# The stagger is not styling: the BEHIND layer is darkened in proportion to
	# how close it comes to the nearest FRONT part, so a far leg tucked directly
	# behind a near one is crushed to a featureless dark disc and reads as the
	# near leg's shadow. Prising them apart is what makes a viewer count four.
	#
	# The two far paws are gone and their slots bought the carpus on both
	# forelegs. Each was a 0.047 knob in the coat-shadow colour tucked directly
	# behind a near paw that is 0.050 in cream: at 260 px it is four pixels of the
	# same brown the shank above it already is, against a near paw that has a
	# hard white sock to hold the eye. The cat cut its far paws two rounds ago on
	# the same test and nothing was lost — a leg lying in the body's shadow needs
	# to *end*, and a shank running to its own cap on the floor does that.
	var ff_far_u := _part(&"leg_fore_far_upper", Vector2(0.150, -0.700), Vector2(0.204, -0.470), 0.080, 0.054, COL_COAT_DARK, 0)
	var ff_far_l := _part(&"leg_fore_far_lower", Vector2(0.204, -0.470), Vector2(0.180, -0.182), 0.056, 0.044, COL_COAT_DARK, 0)
	# The far side gets the carpus too, and it is an IK constraint rather than a
	# drawing one. Naming a third segment `pastern` classifies it `Seg.CANNON`,
	# which promotes the chain from `LegIK.solve_two` to `solve_three`; a fore pair
	# where one leg has a wrist that folds under load and the other does not runs
	# the two legs on different solvers at the same phase of the same stride, and
	# that is a thing a viewer sees in motion even when they cannot say what it is.
	var ff_far_c := _part(&"leg_fore_far_pastern", Vector2(0.180, -0.182), Vector2(0.208, -0.042), 0.046, 0.042, COL_COAT_DARK, 0)
	var hf_far_u := _part(&"leg_hind_far_upper", Vector2(-0.360, -0.772), Vector2(-0.462, -0.348), 0.132, 0.060, COL_COAT_DARK, 0)
	var hf_far_l := _part(&"leg_hind_far_lower", Vector2(-0.462, -0.348), Vector2(-0.404, -0.046), 0.056, 0.046, COL_COAT_DARK, 0)
	# The off ear needs real daylight between it and the near one — 0.094 of axis
	# separation — and the coat colour rather than the shadow colour. The BEHIND
	# layer already gets up to 0.58 cast shadow plus 0.28 occlusion from whatever
	# FRONT part is nearest, and an ear tucked in close behind another ear collects
	# all of it: at the first spacing this came out solid black and read as the
	# near ear's drop shadow rather than as a second ear.
	var ear_far := _part(&"ear_far", Vector2(0.404, -1.126), Vector2(0.462, -1.282), 0.052, 0.014, COL_COAT, 0)
	# Thicker slabs than the cat's ears: a Shiba's ear is a small leather triangle
	# with a real cross-section, and it has to survive being seen edge-on.
	ear_far.height_scale = 0.44
	ear_far.blend = 0.032
	parts.append_array([ff_far_u, ff_far_l, ff_far_c, hf_far_u, hf_far_l, ear_far])

	# --- torso --------------------------------------------------------------
	# Three capsules whose radii grow forward: 0.140 at the croup to 0.240 at the
	# brisket. The cat's torso is a tube of near-constant thickness that dips
	# behind the shoulder; this one is a wedge, heaviest at the front, which is
	# both the deep chest and the reason the animal reads as standing on its
	# forehand.
	var croup := _part(&"hip", Vector2(-0.470, -0.772), Vector2(-0.220, -0.762), 0.140, 0.170, COL_COAT)
	croup.blend = 0.105
	var torso := _part(&"torso", Vector2(-0.220, -0.762), Vector2(0.110, -0.726), 0.170, 0.218, COL_COAT)
	torso.blend = 0.115
	var chest := _part(&"chest", Vector2(0.110, -0.726), Vector2(0.245, -0.714), 0.218, 0.240, COL_COAT)
	chest.blend = 0.115
	# The urajiro underside, and it is a *volume* now rather than a band. This is
	# the shared "white streak over black stipple along the belly" the review
	# reports on all four species, and it is authored here, not in the shader.
	#
	# Two captures settled it, in this order, and neither could have been reasoned
	# out. Repainting the capsule in the coat colour — no cream pigment anywhere on
	# the underside — left the black stippled slab and its hard straight top edge
	# completely unchanged, which rules out the pigment and every marking path.
	# Shrinking the same capsule to radius 0.006 and leaving its colour alone made
	# the slab vanish outright, and what was left underneath was the clean shaded
	# gradient the underside should always have had. So the defect is the capsule's
	# *shape*: a thin lens hung along a fat barrel.
	#
	# Which is exactly what the shader warns about in two separate places. The
	# height field blends its radius toward the thicker part inside a union, and
	# the strength of that bias runs on `(R_fat − R_thin) / (R_fat + R_thin)` — at
	# 0.045 against the torso's 0.19 that ratio was 0.62 and it dug a groove the
	# whole length of the animal, whose two walls are the hard lines. Then the
	# coat's own anisotropic lobe fires along the resulting cylinder, which is the
	# pale streak, and the `slot` occlusion under a body mass takes the flank below
	# it down to 0.58 of key, which is the black. Three separate terms, one cause.
	#
	# The underline is unchanged to the pixel — both endpoints below are the old
	# lower surface, re-expressed as centre minus radius — so the silhouette, the
	# brisket and the tuck-up are all exactly where they were. What changed is that
	# the underside is a real ventral half-volume, 0.080 → 0.105 against the
	# barrel's 0.17 → 0.24, which drops the radius ratio from 0.62 to 0.36 and takes
	# the groove with it.
	#
	# 0.36 is a ceiling found by capture and not a round number. The first fat pass
	# went to 0.115 → 0.150, ratio 0.19, and the slab was gone — but a cream volume
	# that size wins the colour blend over most of the lower flank, and since the
	# coat's TRT specular is tinted by albedo, a large pale patch comes back as a
	# large pale *sheen*. What that drew was a bright band cutting the animal in
	# half lengthways, which is the same failure the first ever pass of this file
	# reported from the opposite direction. Thin enough to keep the cream low, fat
	# enough that the height field does not dig: that is the whole window, and it is
	# about three tenths of the barrel.
	#
	# The marking classification is the second half, and the last pass got it
	# backwards. It reasoned that a part this size classifies as a *region* rather
	# than an object, so the cream would cross into the coat over roughly a tenth
	# of a unit and arrive as countershading rather than as a stencil. That is the
	# right instinct and it overshot by a factor of two, which is the "ventral
	# airbrush smear" the review now names: a soft pale cloud on the lower flank
	# with no edge anywhere on it and no coat texture inside it.
	#
	# The arithmetic is in the shader and it is worth writing down, because this is
	# a cliff and not a slope. The colour feather is
	#
	#     region  = smoothstep(0.024, 0.048, pr / body_h)
	#             * smoothstep(2.2, 4.5, length / pr)
	#     feather = max(blend, pr * mix(0.10, 1.55, region))
	#
	# The old capsule was 0.484 long on a 0.105 radius — 4.61 aspect, past the top
	# of that second ramp — and 0.077 of body height, past the top of the first. So
	# `region` was pinned at 1.0, `feather` came out at 0.163 of a rig unit, and at
	# 146 px per unit that is a 24-pixel colour ramp at ship size and a 90-pixel one
	# at review zoom. Nothing with a 90-pixel gradient across it has an edge.
	#
	# Shortened to 0.311 the aspect is 2.99, `region` lands at 0.28, and the ramp
	# the classifier asks for drops to 0.052 — under the blend, which then sets the
	# feather outright. That is the useful part: below the cliff the *blend* is the
	# authoring lever on the pigment boundary, in rig units, and it can be dialled.
	# 0.082 is 12 rendered pixels: a countershading ramp you can see is a ramp,
	# rather than either a stencil or a fog bank.
	#
	# What the capsule gives up is the front third, which is no loss. Urajiro on a
	# Shiba runs cheek, throat, chest, belly and inner leg as *separate* patches
	# with coat between them; the cheek and chin already carry the face pair, and
	# stopping the belly behind the elbow is what puts a band of red coat between
	# the two rather than one continuous pale underside from jaw to groin.
	#
	# The underline is unchanged to the pixel over the run that remains: both
	# endpoints are the old lower surface re-expressed as centre minus radius.
	var belly := _part(&"belly", Vector2(-0.230, -0.659), Vector2(0.075, -0.596), 0.092, 0.104, COL_CREAM)
	belly.blend = 0.082
	belly.coat_length = 1.25
	# Short and thick, and set on high enough that the neck rises out of the
	# withers instead of leaving them. Base radius 0.170 against the cat's 0.128.
	var neck := _part(&"neck", Vector2(0.250, -0.795), Vector2(0.470, -0.975), 0.170, 0.142, COL_COAT)
	neck.blend = 0.105
	parts.append_array([croup, torso, chest, belly, neck])

	# --- head ---------------------------------------------------------------
	# Broad round braincase, then a separate cream cheek that swells below and
	# ahead of it, then a muzzle joined with a deliberately tight blend.
	#
	# The stop is the hard part, and it has to be measured at the muzzle's root
	# rather than at the skull's apex: the skull's own surface directly above
	# x = 0.690 sits at -1.125, and the bridge of the muzzle there sits at -1.020.
	# That 0.105 step, held together with a 0.032 blend, is the crease. The first
	# pass measured against the apex, put the muzzle 0.05 higher than this, and
	# the smooth union ate the whole step and left a fox. A cat has no stop at
	# all, which is most of why a cat muzzle and a dog muzzle read as different
	# animals across a room.
	var skull := _part(&"head", Vector2(0.462, -1.030), Vector2(0.578, -1.022), 0.162, 0.152, COL_COAT)
	skull.blend = 0.075
	# The cheek has to stay well under the bridge line or it bridges the stop and
	# undoes the crease the muzzle blend just bought.
	var cheek := _part(&"cheek", Vector2(0.548, -0.918), Vector2(0.646, -0.916), 0.092, 0.070, COL_CREAM_FACE)
	cheek.blend = 0.058
	# Blunt: 0.164 deep against a 0.324-deep skull, only 0.176 long, and near
	# parallel-sided rather than tapering — a fox or a cat narrows to a point over
	# twice that distance.
	var muzzle := _part(&"muzzle", Vector2(0.690, -0.938), Vector2(0.796, -0.936), 0.082, 0.074, COL_COAT)
	muzzle.blend = 0.032
	muzzle.coat_length = 0.55
	var chin := _part(&"chin", Vector2(0.692, -0.882), Vector2(0.786, -0.890), 0.054, 0.040, COL_CREAM_FACE)
	chin.blend = 0.036
	# Big, black and bald. The cat's nose is a 0.016 pink stud; this is 0.040 of
	# bare leather that overhangs the end of the muzzle, and the SKIN surface
	# gives it the wet specular the coat shader will not put on fur.
	var nose := _part(&"nose", Vector2(0.840, -0.966), Vector2(0.866, -0.962), 0.040, 0.036, COL_NOSE)
	nose.surface = P.Surface.SKIN
	nose.blend = 0.014
	nose.coat_length = 0.0
	parts.append_array([skull, cheek, muzzle, chin, nose])

	# --- near ear -----------------------------------------------------------
	# Small, thick, firmly pricked and tilted forward — the ear leans 0.054 ahead
	# over its 0.164 of rise, and clears the skull by 0.135 against a skull 0.324
	# deep. Rooted 0.045 inside the braincase so the base blends into it rather
	# than balancing on top.
	#
	# "Small" is doing real work here. At the first pass's 0.082 base radius the
	# ear was 55% as wide as the skull and read as a rabbit's; a Shiba's ear is a
	# stubby triangle roughly as tall as it is wide, and the inner surface needs a
	# coat-coloured rim around it or the whole ear goes pink.
	var ear_near := _part(&"ear_near", Vector2(0.498, -1.140), Vector2(0.552, -1.304), 0.056, 0.015, COL_COAT, 2)
	ear_near.height_scale = 0.50
	ear_near.blend = 0.034
	var ear_inner := _part(&"ear_near_inner", Vector2(0.502, -1.148), Vector2(0.546, -1.278), 0.034, 0.010, COL_INNER_EAR, 2)
	ear_inner.height_scale = 0.26
	ear_inner.blend = 0.024
	ear_inner.coat_length = 0.30
	parts.append_array([ear_near, ear_inner])

	# --- near limbs ---------------------------------------------------------
	# Foreleg: a heavy column, and it now has two joints in it instead of none.
	#
	# The review read the forelegs as smooth featureless sticks, and they were: one
	# humerus and one forearm, both tapering the same way, met at a 0.050 blend
	# that closed the 0.004 of radius step between them into nothing. A dog's
	# foreleg has two landmarks a viewer can name — the point of the elbow under
	# the chest, and the carpus a hand above the foot — and both of them are read
	# as *breaks* rather than as bumps.
	#
	# The elbow is a direction break. The humerus used to lean 0.058 *forward* from
	# shoulder to elbow, which is what a foreleg does on nothing; on a real dog the
	# shoulder joint is the forwardmost point of the assembly and the elbow hangs
	# behind it, under the deepest part of the chest. Reversed to lean 0.028 back,
	# the elbow now sits behind the point of shoulder and the forearm has to come
	# forward again to reach the ground — so the limb has a shallow zigzag where it
	# had a straight line, and the outline changes direction twice.
	#
	# The 0.006 of radius step at each joint is the second half and it costs
	# nothing. A capsule's radius is linear along its spine, so a segment that
	# *starts* fatter than the one above it ends leaves a small overhang, and the
	# smooth union at a tight blend turns that overhang into a crease. That is the
	# olecranon at the elbow and the accessory carpal at the wrist, and it is why
	# the blends drop to 0.042 and 0.030 here where the shoulder's stays at 0.095.
	var ff_u := _part(&"leg_fore_near_upper", Vector2(0.268, -0.712), Vector2(0.240, -0.470), 0.064, 0.058, COL_COAT, 2)
	ff_u.blend = 0.095
	var ff_l := _part(&"leg_fore_near_lower", Vector2(0.240, -0.470), Vector2(0.268, -0.186), 0.064, 0.044, COL_COAT, 2)
	ff_l.blend = 0.042
	# The pastern, and it is a real segment rather than a decoration. A dog is
	# digitigrade: the metacarpus is a bone that stands nearly upright and carries
	# a visible slope of ten to fifteen degrees off plumb, and it *flexes* — which
	# is the part that matters here, because naming it `pastern` classifies it
	# `Seg.CANNON` and promotes the whole chain from `LegIK.solve_two` to
	# `solve_three`. The three-bone solver couples the fold at this joint to how
	# compressed the leg is, so the wrist now gives a few degrees under load at
	# each footfall instead of the leg being one rigid rod from elbow to toe.
	# Measured off the bind pose the rest fold is 168°, so nothing about the
	# standing silhouette changes; what changes is that the stride has a joint in
	# it below the elbow.
	var ff_c := _part(&"leg_fore_near_pastern", Vector2(0.268, -0.186), Vector2(0.296, -0.104), 0.050, 0.042, COL_COAT, 2)
	ff_c.blend = 0.030
	var ff_p := _part(&"paw_fore_near", Vector2(0.296, -0.104), Vector2(0.336, -0.050), 0.046, 0.050, COL_CREAM, 2)
	ff_p.blend = 0.032
	# Hind leg: one muscled haunch from hip to hock, then a rear pastern.
	#
	# The haunch's radius has to reach the croup line (-0.782 - 0.150 = -0.932,
	# just proud of the pelvis at -0.912) and its back edge has to reach out to
	# x = -0.568, or the rump has no buttock and the leg reads as a stick pushed
	# into the body. Tapering it away from a mere 0.132 was enough to lose that.
	#
	# The hock lands at y = -0.352, 37% of the withers height, and the pastern
	# below it slopes forward 12° from plumb. The cat's hock sits at 47% and its
	# pastern slopes 29°. Dropping the joint and standing the pastern up is what
	# "straighter hocks" means, and it is the clearest tell in the rear quarter —
	# but taken all the way to vertical the leg stops having a hock at all.
	var hf_u := _part(&"leg_hind_near_upper", Vector2(-0.418, -0.782), Vector2(-0.524, -0.352), 0.150, 0.064, COL_COAT, 2)
	hf_u.blend = 0.095
	var hf_l := _part(&"leg_hind_near_lower", Vector2(-0.524, -0.352), Vector2(-0.478, -0.130), 0.060, 0.046, COL_COAT, 2)
	hf_l.blend = 0.050
	var hf_p := _part(&"paw_hind_near", Vector2(-0.478, -0.130), Vector2(-0.436, -0.050), 0.046, 0.050, COL_CREAM, 2)
	hf_p.blend = 0.032
	parts.append_array([ff_u, ff_l, ff_c, ff_p, hf_u, hf_l, hf_p])

	# --- tail: sashio, the sickle carriage -----------------------------------
	# The Shiba standard allows two tails, maki-o (curled) and sashio (sickle).
	# This file drew the curl for four passes and it was measured, at the size the
	# pet ships at, as a second head.
	#
	# The measurement, off a 260 px alpha capture: the curl was a rounded island
	# 48 px wide by 36 px tall — one and a third times as wide as it was long —
	# with a bump on its upper left and a taper on its lower right, sitting at the
	# opposite end of the animal from a head that measures 74 × 52. A cranium, an
	# ear and a muzzle, at four fifths scale. The blind reviewer called it a
	# pushmi-pullyu and the pixels agree.
	#
	# The gap under the arc was not the fixable part, and that is the thing worth
	# writing down. A curl encloses a *hole*, and a hole has two edges that both
	# grow a coat fringe inward: the tail's own runs at 2.1× the species length
	# (0.040 rig units) and the loin's at 1.0× (0.019), so 0.059 of any authored
	# gap is gone before antialiasing. On the last build the authored clearance
	# was 0.064 — nine rendered pixels of geometry, and zero after the fringes
	# met. Every extra unit of daylight has to be paid for twice, and it has to be
	# paid on an animal that is only 146 px per rig unit at ship size.
	#
	# A sickle encloses nothing. The tail leaves the croup going up and back, so
	# the space in front of it is not a hole between two edges — it is the open
	# sky above the dog's back, which opens all the way to the frame. There is no
	# clearance to lose, at any downscale, ever. That is the whole argument for
	# the change, and it is why the sickle is worth the curl.
	#
	# Two other things carried over, because they were right:
	#   * it must not read as a raised hind leg. It cannot here — it stands above
	#     the topline where no leg reaches, and the tip is 0.020 where a pastern
	#     is 0.046.
	#   * it must be a long taper rather than a mass. 0.084 at the root down to
	#     0.020 at the point over 0.44 of rise is a 4:1 spike; the curl was 1.33:1.
	#
	# The tip still hooks forward over the last segment. That is what keeps it a
	# Shiba tail rather than a pointer's: the animal reads as carrying its tail
	# *over* its back, but at a height where the daylight under it is a third of
	# the body rather than a hairline.
	var tail_a := _part(&"tail_0", Vector2(-0.446, -0.854), Vector2(-0.556, -0.996), 0.086, 0.066, COL_COAT, 2)
	var tail_b := _part(&"tail_1", Vector2(-0.556, -0.996), Vector2(-0.596, -1.166), 0.066, 0.042, COL_COAT, 2)
	var tail_c := _part(&"tail_2", Vector2(-0.596, -1.166), Vector2(-0.520, -1.318), 0.042, 0.015, COL_COAT, 2)
	for t in [tail_a, tail_b, tail_c]:
		t.blend = 0.052
		# Down from 2.1. A brush fringe is what stops the tail ending in a blunt
		# leg-like cap, but 2.1 put 0.040 of coat on every side of a capsule only
		# 0.084 across — the plume was as wide as the tail and the two together
		# were the blob. 1.45 still carries a visibly softer outline than anything
		# else on the animal without inflating the silhouette by half.
		t.coat_length = 1.45
	# The last hand's-breadth is the exception, and it is the one place the extra
	# fringe is worth its width: a capsule that tapers to 0.015 ends in a rounded
	# cap two pixels across, which at ship size is a full stop. Spikes indexed
	# along the outline break that cap into a soft point instead, and a soft point
	# is the difference between a tail and a stick.
	tail_c.coat_length = 1.95
	parts.append_array([tail_a, tail_b, tail_c])

	# Puppy proportions. A Shiba puppy is a different shape from a kitten, not a
	# smaller one: it is a barrel on four stumps with a head it has not grown into
	# and ears that have not finished standing up. Legs shorten harder than the
	# cat's (0.62 against 0.70) and the ears shrink instead of merely scaling,
	# because a puppy's ear really is small and soft before the cartilage sets.
	# The skull group is left near 1.0 — `stage_head_bias` already multiplies it
	# by 1.52, and stacking a second factor makes a loaf.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.baby_length_scale = 0.62
			p.baby_radius_scale = 1.16
		elif id.begins_with("tail"):
			p.baby_length_scale = 0.55
			p.baby_radius_scale = 1.10
		elif id.begins_with("ear"):
			# Soft and only half up: the cartilage has not set. Shrunk further
			# than this the ear disappeared under the puppy's own head fluff and
			# the face read as a seal's.
			p.baby_radius_scale = 0.84
			p.baby_length_scale = 0.70
		elif id in ["muzzle", "chin"]:
			# The muzzle is the last thing to arrive. A short blunt one under a
			# huge cranium is the whole puppy face.
			p.baby_length_scale = 0.74
			p.baby_radius_scale = 1.02
		elif id in ["head", "cheek", "nose"]:
			p.baby_radius_scale = 1.04
		elif id == "neck":
			p.baby_length_scale = 0.72
			p.baby_radius_scale = 1.10
		elif id in ["hip", "torso", "chest", "belly"]:
			p.baby_length_scale = 0.84
			p.baby_radius_scale = 1.16
		else:
			p.baby_radius_scale = 1.04

	# Grooming direction. Fur flows back along the body and down the legs as it
	# does on the cat, but the ears and tail follow their own axes: a pricked ear
	# is combed up toward the tip, and the coat on a curled tail has to rotate
	# with the curl or the brush ends up combed against itself.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.groom_angle = PI * 0.5
		elif id.begins_with("tail") or id.begins_with("ear"):
			p.groom_angle = (p.b - p.a).angle()
		else:
			p.groom_angle = PI

	s.parts = parts

	# Round pupils, small dark irises, and lids slanted up at the outer corner —
	# a Shiba's eye is a triangle, not the cat's wide oval, and it is set deep
	# enough that the brow shades it. Small eyes on a broad skull read as canine;
	# enlarging them here would walk the face straight back toward the cat.
	var eye_near: E = E.new()
	eye_near.id = &"eye_near"
	eye_near.bone = &"head"
	eye_near.center = Vector2(0.622, -1.072)
	eye_near.radius = 0.033
	eye_near.tilt = -0.30
	eye_near.iris_ratio = 0.80
	eye_near.pupil_ratio = 0.52
	eye_near.pupil_slit = 0.0
	eye_near.iris_color = Color(0.26, 0.15, 0.08)
	eye_near.limbal_color = Color(0.05, 0.03, 0.02)
	eye_near.socket_depth = 0.36
	eye_near.lid_palette_index = COL_COAT
	eye_near.baby_radius_scale = 1.62
	eye_near.baby_pupil_scale = 1.35

	# Foreshortened rather than merely small, the same four terms as the cat's. A
	# three-quarter head shows the far eye as a sliver behind the bridge of the
	# nose: less ball, more lid over it, a deeper socket, and no catchlight,
	# because the far cornea is not facing the key. Two eyes of the same shape at
	# different sizes is the tell that says a face was assembled rather than seen.
	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.524, -1.086)
	eye_far.radius = 0.0196
	eye_far.tilt = -0.48
	eye_far.iris_ratio = 0.80
	eye_far.pupil_ratio = 0.52
	eye_far.pupil_slit = 0.0
	eye_far.iris_color = Color(0.19, 0.11, 0.06)
	eye_far.limbal_color = Color(0.03, 0.02, 0.02)
	eye_far.sclera_color = Color(0.72, 0.70, 0.68)
	eye_far.lid_open = 0.76
	eye_far.socket_depth = 0.70
	eye_far.lid_palette_index = COL_COAT
	eye_far.baby_radius_scale = 1.62
	eye_far.baby_pupil_scale = 1.35

	s.eyes = [eye_far, eye_near]
	s.blink_interval = 3.4
	return s
