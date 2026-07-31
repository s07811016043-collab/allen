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
## survive being 60 px tall — small pricked triangular ears, a thick tail curled
## over the back, a blunt wedge muzzle under a broad skull, and a deep chest over
## a hard tuck-up. Every one of those is something a cat does not have, which is
## the actual brief: the dog must not read as a recoloured cat.

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
	var ff_far_u := _part(&"leg_fore_far_upper", Vector2(0.150, -0.700), Vector2(0.204, -0.470), 0.080, 0.054, COL_COAT_DARK, 0)
	var ff_far_l := _part(&"leg_fore_far_lower", Vector2(0.204, -0.470), Vector2(0.196, -0.145), 0.054, 0.044, COL_COAT_DARK, 0)
	var ff_far_p := _part(&"paw_fore_far", Vector2(0.196, -0.145), Vector2(0.240, -0.047), 0.044, 0.047, COL_COAT_DARK, 0)
	var hf_far_u := _part(&"leg_hind_far_upper", Vector2(-0.360, -0.772), Vector2(-0.462, -0.348), 0.132, 0.060, COL_COAT_DARK, 0)
	var hf_far_l := _part(&"leg_hind_far_lower", Vector2(-0.462, -0.348), Vector2(-0.420, -0.130), 0.056, 0.044, COL_COAT_DARK, 0)
	var hf_far_p := _part(&"paw_hind_far", Vector2(-0.420, -0.130), Vector2(-0.380, -0.047), 0.044, 0.047, COL_COAT_DARK, 0)
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
	parts.append_array([ff_far_u, ff_far_l, ff_far_p, hf_far_u, hf_far_l, hf_far_p, ear_far])

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
	# The urajiro underline: a narrow band riding about 0.02 proud of the body's
	# own belly line, so it unions rather than hiding inside — a marking that
	# never breaks the silhouette is a marking nobody sees. Kept thin on purpose.
	# The first pass used radius 0.072→0.098 and the cream painted a 0.20-tall
	# swathe up the flank, which cut the animal in half lengthways and made a
	# deep-chested dog read as a shallow, leggy one.
	var belly := _part(&"belly", Vector2(-0.300, -0.622), Vector2(0.175, -0.520), 0.038, 0.052, COL_CREAM)
	belly.blend = 0.055
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
	# Foreleg: a heavy column. Shoulder to elbow leans forward, then the forearm
	# drops within 0.010 of plumb over 0.330 of length. Straight front legs under
	# a deep chest are a dog; a cat's forelegs are lighter and set further back.
	# The upper is deliberately slim. It is a FRONT-layer part crossing a BODY-layer
	# chest, so whatever of it lies inside the chest's outline still shades as a
	# raised lobe — at 0.086 it read as a bicep strapped to the ribs.
	var ff_u := _part(&"leg_fore_near_upper", Vector2(0.238, -0.706), Vector2(0.296, -0.462), 0.062, 0.054, COL_COAT, 2)
	ff_u.blend = 0.100
	var ff_l := _part(&"leg_fore_near_lower", Vector2(0.296, -0.462), Vector2(0.286, -0.138), 0.058, 0.046, COL_COAT, 2)
	ff_l.blend = 0.050
	var ff_p := _part(&"paw_fore_near", Vector2(0.286, -0.138), Vector2(0.334, -0.050), 0.046, 0.050, COL_CREAM, 2)
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
	parts.append_array([ff_u, ff_l, ff_p, hf_u, hf_l, hf_p])

	# --- tail ---------------------------------------------------------------
	# Set high on the croup: up and slightly back, over the top, then forward and
	# down so the tip finishes at x = -0.140, deep *inside* the body's own outline
	# and clearing the loin by only 0.05.
	#
	# Three things had to be true before this stopped reading as a raised hind
	# leg, which is what it did for three passes:
	#   * it has to cross the body it belongs to. A curl carried straight up and
	#     hooked at the top sits outside the silhouette at exactly the height a
	#     leg does, and the eye files it as one.
	#   * it has to be twice a leg's thickness. At 0.062 it matched the pastern
	#     radius almost exactly; at 0.086 it is unmistakably a different kind of
	#     object.
	#   * it cannot end in a small dark blunt cap, which is a paw. All three
	#     segments are coat-coloured now, and the coat runs at 2.1x so the brush
	#     carries a soft fringe no leg in the animal has.
	#   * the turn has to be spread evenly — roughly 60° per segment, describing
	#     one arc of radius 0.12. Concentrating it into a single corner between
	#     two straight runs builds a knee, and a knee is a leg.
	# The gap under the arc still has to survive all of that, or the curl fuses
	# to the back and becomes a hump.
	var tail_a := _part(&"tail_0", Vector2(-0.462, -0.876), Vector2(-0.516, -0.992), 0.086, 0.082, COL_COAT, 2)
	var tail_b := _part(&"tail_1", Vector2(-0.516, -0.992), Vector2(-0.448, -1.090), 0.082, 0.074, COL_COAT, 2)
	var tail_c := _part(&"tail_2", Vector2(-0.448, -1.090), Vector2(-0.236, -1.042), 0.074, 0.046, COL_COAT, 2)
	for t in [tail_a, tail_b, tail_c]:
		t.blend = 0.052
		t.coat_length = 2.10
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

	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.524, -1.086)
	eye_far.radius = 0.024
	eye_far.tilt = -0.36
	eye_far.iris_ratio = 0.80
	eye_far.pupil_ratio = 0.52
	eye_far.pupil_slit = 0.0
	eye_far.iris_color = Color(0.23, 0.13, 0.07)
	eye_far.limbal_color = Color(0.04, 0.03, 0.02)
	eye_far.socket_depth = 0.48
	eye_far.lid_palette_index = COL_COAT
	eye_far.baby_radius_scale = 1.62
	eye_far.baby_pupil_scale = 1.35

	s.eyes = [eye_far, eye_near]
	s.blink_interval = 3.4
	return s
