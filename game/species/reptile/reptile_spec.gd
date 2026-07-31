extends RefCounted

## Bearded dragon (Pogona vitticeps).
##
## Rig space convention used by every species:
##   * +x is forward (the creature faces right at rotation 0),
##   * +y is down (matching Godot's 2D axes),
##   * the origin sits between the feet on the ground plane,
##   * 1.0 unit ≈ adult shoulder height.
##
## Why a beardie and not "a lizard": this is the species that exercises the SCALE
## surface, and squamation only reads if the animal has shapes big enough to
## carry it. A gecko is a smooth soft-skinned tube at desktop size. A bearded
## dragon has four things a cat, a dog and a bird all lack — a head that is a
## flat wedge wider than it is tall, a spiny gular pouch under the jaw, a pale
## keratin skirt along the flank, and limbs that go *out* before they go down.
## Every one of those survives being 100 px tall.
##
## Built in code rather than as a .tres so a species reads as a document: you can
## see the whole animal's proportions in one screen and diff a change to its
## sprawl angle.

const P := preload("res://core/creature/sdf_part.gd")
const S := preload("res://core/creature/creature_spec.gd")
const E := preload("res://core/creature/eye_spec.gd")

# Palette slots, referenced by every part below. A wild-type "sandfire" beardie
# is one warm ochre run through four values plus bone-pale keratin: the spikes,
# the fringe and the lip are all the same dead-white horn, and keeping them on
# one slot is what makes them read as the *same material* appearing in three
# places rather than as three decorations.
const COL_HIDE := 0
const COL_HIDE_DARK := 1
const COL_BAND := 2
const COL_BELLY := 3
const COL_SPINE := 4
const COL_BEARD := 5
const COL_JAW := 6
const COL_LIMB := 7
const COL_TOE := 8
const COL_CLAW := 9


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
	p.surface = P.Surface.SCALE
	p.blend = 0.06
	# Nothing on a reptile stands off its own outline. The species-wide
	# `coat_length` is already zero; this keeps it zero after `Growth` multiplies
	# the two together, so the silhouette stays a hard edge at every stage.
	p.coat_length = 0.0
	return p


static func build() -> S:
	var s: S = S.new()
	s.species_id = &"reptile"
	s.display_name = "Bearded Dragon"
	s.blurb = "Picks the warmest rectangle on your screen and occupies it. Blinks at you on a delay long enough to feel like a judgement, then puffs its beard at a notification and goes back to sleep."

	s.palette = PackedColorArray([
		Color(0.640, 0.470, 0.290),   # dorsum: warm desert ochre
		Color(0.395, 0.285, 0.180),   # far side, dark tail bands. Only a step
		                              # down from the dorsum — the BEHIND layer
		                              # is already shaded as far-side, and a
		                              # genuinely dark pigment on top of that
		                              # turns the off limbs into holes
		Color(0.735, 0.415, 0.185),   # rust saddle over the hips
		Color(0.795, 0.740, 0.640),   # ventral scutes: pale grey-cream
		Color(0.855, 0.800, 0.680),   # keratin: nuchal spikes, lateral fringe
		Color(0.250, 0.212, 0.200),   # gular pouch. Smoky rather than black: a
		                              # relaxed beard is grey and only goes to
		                              # ink when the animal flares it
		Color(0.830, 0.775, 0.660),   # lower lip / jaw line
		Color(0.505, 0.375, 0.245),   # limbs
		Color(0.585, 0.520, 0.430),   # toes, dry and bleached
		Color(0.185, 0.160, 0.140),   # claws
	])

	s.adult_height = 1.0
	# The lowest of any species we ship, and it has to be. This animal is 5.9
	# units long where the cat is 1.9, so matching the cat's 190 px/unit would
	# draw a pet 1100 px wide. 126 puts it at ~740 px long and 126 px tall — the
	# biggest footprint on the desktop, which is honest for a lizard, without
	# being a piece of furniture.
	s.pixels_per_unit = 126.0

	s.coat_surface = P.Surface.SCALE
	# Zero, not "small". A scale is not a fibre standing off the body; it is the
	# body's own outline. Any silhouette displacement here would read as fuzz.
	s.coat_length = 0.0
	# Plate size is `0.030 / coat_density` rig units and `pet_scale` only fades a
	# plate in once it clears about 6 screen pixels. At 126 px/unit that puts the
	# usable *ceiling* on density at 0.60 — the exact inverse of the songbird's
	# problem, where too much density went sub-Nyquist. 0.60 gives a 0.050-unit
	# plate, so roughly a dozen rows of squamation across the flank, which is
	# what a photograph of a beardie's side actually shows.
	s.coat_density = 0.60
	# A reptile is dry. The only places light gets through are the toe webbing,
	# the trailing edge of the beard and the last centimetre of tail, and the
	# body shader gates transmission on part radius and flatness — so keeping the
	# species number this low means those three places are the *only* ones that
	# glow, instead of the whole animal looking like wet resin.
	s.translucency = 0.14
	s.roughness = 0.30

	# Reptiles grow on a geological timescale next to a kitten. 30 hours a stage
	# is half again the cat's, and the payoff is that the hatchling is around
	# long enough to be worth authoring properly.
	s.hours_per_stage = 30.0
	# A hatchling beardie is genuinely tiny — 9 cm against an adult's 47, so a
	# true 0.19 — but at 0.19 it would be 24 px tall on the desktop and the
	# squamation would vanish entirely. 0.34 is the compromise, still well under
	# the cat's 0.40 because a hatchling reptile *should* read as startlingly
	# small next to its adult.
	s.stage_scale = PackedFloat32Array([0.34, 0.56, 0.80, 1.0])
	s.stage_head_bias = PackedFloat32Array([1.55, 1.30, 1.12, 1.0])
	s.stage_eye_bias = PackedFloat32Array([1.62, 1.34, 1.14, 1.0])

	s.locomotion = S.Locomotion.SPRAWLING
	# On-screen speed, not real-world speed, is what a desktop pet is judged on:
	# 1.30 × 126 px is 164 px/s, within a whisker of the cat's 162. The
	# difference the player sees is in the *step*, not the pace — 1.30/0.52 is
	# 2.5 Hz against the cat's 2.0, so the dragon scuttles where the cat flows.
	s.walk_speed = 1.30
	s.run_speed = 4.60
	s.stride = 0.52
	# A third of the cat's. A sprawling animal carries its weight on splayed
	# limbs and pays for it by keeping the trunk almost dead level; the motion
	# that should read is the lateral wave `Gait` writes into `undulation`, and
	# any vertical bob competing with it makes the walk look mammalian.
	s.bob = 0.022
	# It climbs by hooking claws into a texture, not by leaping — which is
	# exactly what `can_climb` without `jump_height` describes.
	s.jump_height = 0.90
	s.can_climb = true
	s.can_fly = false

	# An ectotherm's whole behavioural budget: sit in the warm place, do nothing,
	# then commit absolutely for two seconds. Low energy with a high run speed is
	# that curve expressed in two numbers.
	s.energy = 0.22
	s.affection_drive = 0.30
	s.curiosity = 0.55
	s.skittishness = 0.55

	# Reptiles do not call. Everything they say is moving air: a hiss, a chuff, a
	# jaw-gape. So the pitch sits an octave under the dog and the timbre goes as
	# close to pure breath as the synthesiser allows.
	s.voice_hz = 150.0
	s.baby_voice_scale = 1.60
	s.voice_timbre = 0.08

	var parts: Array[P] = []

	# Proportions are the whole ballgame, and a lizard's are further from a cat's
	# than any other species we ship. Reference figures for an adult Pogona
	# standing on all fours, converted against a 7.0 cm shoulder height:
	#
	#   ground → top of back        7.0 cm   ← this is 1.0 rig unit
	#   snout → vent (SVL)         23   cm   → 3.29
	#   vent → tail tip            24   cm   → 3.43
	#   trunk depth, belly to back  4.6 cm   → 0.66
	#   belly clearance, walking    1.7 cm   → 0.24
	#   head                        4.6 × 2.6 tall × 4.2 wide → 0.66 × 0.37 × 0.60
	#
	# So the target is length / height ≈ 6.7 — nearly four times the cat's 1.75,
	# and the single number that decides whether this reads as a lizard or as a
	# green dachshund. As drawn the span is 5.9 rather than 6.7, because the tail
	# is authored resting on the floor in a shallow curve rather than held out
	# straight; its arc length is the full 3.0 units, it just does not spend all
	# of that on x.
	#
	# The other half of the read is posture, and it is structural rather than
	# proportional. A sprawling limb leaves the body sideways before it goes
	# down, so in side view the elbow and the knee both sit ABOVE the line of the
	# belly — around y = -0.62, level with the middle of the flank — and the foot
	# lands outside the shoulder. The limb is a Λ, not the ⌐ of a mammal. That,
	# plus a belly riding 0.20 off the floor, is the whole silhouette.
	#
	# Withers sit at y = -0.95, the skull crown reaches -0.99, the belly bottoms
	# out at -0.20, and the body spans x = -4.32 (tail tip) to +1.44 (snout).

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# Three segments each, not two, and it is a rig constraint rather than an
	# aesthetic one: with the elbow held *above* the shoulder, a two-capsule limb
	# has to cover the whole drop to the floor in its second segment, which makes
	# the two IK lengths so unequal that `LegIK.solve_two` spends the walk cycle
	# pinned against its own fold limit. A wrist to break the drop fixes it, and
	# it is what the animal has anyway.
	var ff_u := _part(&"leg_fore_far_upper", Vector2(0.42, -0.455), Vector2(0.14, -0.630), 0.070, 0.056, COL_HIDE_DARK, 0)
	var ff_l := _part(&"leg_fore_far_lower", Vector2(0.14, -0.630), Vector2(0.32, -0.215), 0.056, 0.042, COL_HIDE_DARK, 0)
	var ff_f := _part(&"leg_fore_far_foot", Vector2(0.32, -0.215), Vector2(0.52, -0.036), 0.042, 0.036, COL_HIDE_DARK, 0)
	var hf_u := _part(&"leg_hind_far_upper", Vector2(-1.10, -0.470), Vector2(-0.72, -0.645), 0.086, 0.062, COL_HIDE_DARK, 0)
	var hf_l := _part(&"leg_hind_far_lower", Vector2(-0.72, -0.645), Vector2(-1.04, -0.230), 0.062, 0.046, COL_HIDE_DARK, 0)
	var hf_f := _part(&"leg_hind_far_foot", Vector2(-1.04, -0.230), Vector2(-0.80, -0.038), 0.046, 0.038, COL_HIDE_DARK, 0)
	for p in [ff_u, ff_l, ff_f, hf_u, hf_l, hf_f]:
		p.blend = 0.038
	parts.append_array([ff_u, ff_l, ff_f, hf_u, hf_l, hf_f])

	# --- trunk --------------------------------------------------------------
	# Three capsules on one nearly flat axis. A cat's back dips behind the
	# shoulder blades and a bird's is an unbroken convex egg; a lizard's is
	# neither — it is a straight plank from the shoulder to the hip, and any
	# curve at all in this line immediately reads as mammal.
	#
	# `height_scale` above 1.0 everywhere on the trunk is the one place this
	# species departs from the others, and it is load-bearing. A beardie is 8 cm
	# wide and 4.6 cm deep: dorsoventrally flattened, so the silhouette is
	# shallow while the mass toward the camera is enormous. Lifting the height
	# field past the silhouette is exactly how you say "this is wider than it
	# looks" in an implicit body.
	var hip := _part(&"hip", Vector2(-1.26, -0.585), Vector2(-0.92, -0.595), 0.300, 0.325, COL_BAND)
	hip.blend = 0.100
	hip.height_scale = 1.18
	var torso := _part(&"torso", Vector2(-0.92, -0.595), Vector2(-0.24, -0.605), 0.325, 0.350, COL_HIDE)
	torso.blend = 0.105
	torso.height_scale = 1.20
	# Runs all the way up under the skull. There is no neck capsule, and that is
	# deliberate rather than a budget casualty: a beardie's nuchal spikes carry
	# straight off the back of the head onto the shoulder with no waist in
	# between, and authoring a neck here produced a visible pinch the animal does
	# not have. The dewlap fills the underside of the same junction.
	var chest := _part(&"chest", Vector2(-0.24, -0.605), Vector2(0.52, -0.655), 0.350, 0.290, COL_HIDE)
	chest.blend = 0.100
	chest.height_scale = 1.18
	# The belly is its own volume slung under the trunk, not a colour band on it.
	# It has to bottom out below the flank — a lizard's weight sits on its gut,
	# and 0.20 of ground clearance against a 0.75 trunk depth is what "rides low"
	# means numerically.
	var belly := _part(&"belly", Vector2(-0.82, -0.355), Vector2(0.02, -0.375), 0.155, 0.145, COL_BELLY)
	belly.blend = 0.090
	parts.append_array([hip, torso, chest, belly])

	# --- head ---------------------------------------------------------------
	# A flat wedge, and the wedge is in the *height field*: 0.43 tall in
	# silhouette against 0.60 wide across, so `height_scale` runs to 1.35 — the
	# highest number in the file. Read in profile the skull is a broad triangle
	# tapering to a blunt snout, with the widest point at the jaw hinge.
	var skull := _part(&"head", Vector2(0.74, -0.775), Vector2(1.02, -0.790), 0.215, 0.170, COL_HIDE)
	skull.blend = 0.055
	skull.height_scale = 1.35
	var snout := _part(&"snout", Vector2(1.02, -0.790), Vector2(1.32, -0.788), 0.170, 0.118, COL_HIDE)
	snout.blend = 0.038
	snout.height_scale = 1.18
	# The jaw line. Authored to hang 0.03–0.06 proud of the skull's lower edge
	# rather than inside it, so it is real geometry with a smooth-union crease
	# along its top instead of a painted stripe — that crease *is* the jaw line,
	# and dropping the blend to 0.022 is what keeps it a line rather than a
	# gradient. Pale, because a beardie's lower lip is bone-coloured and the
	# boundary is one of the few hard edges on the whole animal.
	var jaw := _part(&"jaw", Vector2(0.86, -0.640), Vector2(1.30, -0.700), 0.110, 0.062, COL_JAW)
	jaw.blend = 0.022
	jaw.height_scale = 1.10
	parts.append_array([skull, snout, jaw])

	# --- lateral fringe -----------------------------------------------------
	# The row of spines along the flank, as one flattened blade rather than as a
	# row of capsules. Eight authored spikes would cost eight of the twenty-eight
	# uniform slots to draw eight bumps four pixels tall; one blade with
	# `height_scale` 0.28 and a 0.014 blend gives a hard-edged pale skirt
	# standing proud of the lower flank, and the SCALE plates running along it do
	# the serration for free. CLAW rather than SCALE because it is the same dead
	# keratin as the spikes, and the claw model pipes light down the fibre, which
	# is why the skirt catches a rim the flank does not.
	var fringe := _part(&"flank_fringe", Vector2(0.34, -0.345), Vector2(-0.88, -0.290), 0.068, 0.052, COL_SPINE)
	fringe.surface = P.Surface.CLAW
	fringe.blend = 0.014
	fringe.height_scale = 0.28
	parts.append_array([fringe])

	# --- tail ---------------------------------------------------------------
	# Four capsules over three units, thick as the hip where it leaves the vent
	# and down to a 0.024 point — it has to taper across essentially the whole
	# animal, because a tail that keeps its thickness reads as a second body.
	# Authored dropping to the floor rather than held out: a resting beardie
	# trails its tail on the ground, and the spring chain then only has to add
	# the sway rather than fight an unnaturally level bind pose.
	#
	# The alternating palette is the tail banding. Four bands across three units
	# is coarser than life, but at 126 px/unit a truer eight-band pattern would
	# be three pixels a band, and banding you cannot resolve is just noise.
	var tail_0 := _part(&"tail_0", Vector2(-1.30, -0.545), Vector2(-2.00, -0.470), 0.265, 0.190, COL_HIDE)
	tail_0.blend = 0.075
	tail_0.height_scale = 1.05
	var tail_1 := _part(&"tail_1", Vector2(-2.00, -0.470), Vector2(-2.72, -0.360), 0.190, 0.128, COL_HIDE_DARK)
	tail_1.blend = 0.055
	var tail_2 := _part(&"tail_2", Vector2(-2.72, -0.360), Vector2(-3.48, -0.215), 0.128, 0.070, COL_HIDE)
	tail_2.blend = 0.038
	var tail_3 := _part(&"tail_3", Vector2(-3.48, -0.215), Vector2(-4.30, -0.075), 0.070, 0.024, COL_HIDE_DARK)
	tail_3.blend = 0.022
	parts.append_array([tail_0, tail_1, tail_2, tail_3])

	# --- beard and nuchal spikes (front layer) ------------------------------
	# The gular pouch. SKIN rather than SCALE: its scales are so fine they are
	# below the plate model's resolution at any size we draw, and `pet_skin`'s
	# pebbling is a truer description of soft expandable throat leather than a
	# shingled plate is. Flattened to 0.60 so it reads as a hanging sheet, which
	# also opens the transmission gate — with the species translucency at 0.14
	# the beard's thin trailing edge is one of the only places on the animal that
	# lights up from behind.
	var dewlap := _part(&"dewlap", Vector2(0.78, -0.560), Vector2(1.18, -0.612), 0.115, 0.072, COL_BEARD, 2)
	dewlap.surface = P.Surface.SKIN
	dewlap.blend = 0.028
	dewlap.height_scale = 0.60
	# One spike, not a fan, and it is the largest of the nuchal row — placed at
	# the back corner of the skull pointing back and up so it breaks the outline
	# in the notch between head and shoulder. At this size a fan of five would be
	# a pale smudge; a single spike with a wide base and a 0.016 point is legible
	# and implies the rest.
	var spike := _part(&"crest_nuchal", Vector2(0.715, -0.890), Vector2(0.545, -0.958), 0.082, 0.016, COL_SPINE, 2)
	spike.surface = P.Surface.CLAW
	spike.blend = 0.016
	spike.height_scale = 0.55
	parts.append_array([dewlap, spike])

	# --- near limbs ---------------------------------------------------------
	# The sprawl, in four numbers per limb. Shoulder low on the side of the
	# ribcage; elbow back and 0.21 *higher* than the shoulder, tucked against the
	# flank; wrist dropping almost vertically; foot planted ahead of and outside
	# the shoulder. The elbow and knee both land near y = -0.62, level with the
	# middle of the flank, which is where photographs of a walking beardie put
	# them.
	#
	# The two projected segment lengths are deliberately kept within about 25% of
	# each other (0.39 / 0.56 fore, 0.44 / 0.55 hind). `LegIK.solve_two` clamps
	# the root→ankle span to at least |l1 − l2|, and a Λ limb has a *short* span
	# by construction — the ankle is barely 0.26 from the shoulder. Unbalanced
	# segments would sit against that clamp for the whole stance phase and the
	# elbow would snap rather than swing.
	var fl_u := _part(&"leg_fore_near_upper", Vector2(0.46, -0.420), Vector2(0.13, -0.630), 0.082, 0.064, COL_LIMB, 2)
	var fl_l := _part(&"leg_fore_near_lower", Vector2(0.13, -0.630), Vector2(0.44, -0.160), 0.064, 0.046, COL_LIMB, 2)
	var fl_f := _part(&"leg_fore_near_foot", Vector2(0.44, -0.160), Vector2(0.62, -0.055), 0.046, 0.040, COL_TOE, 2)
	# Toes get their own capsule on both limbs and they are the thinnest parts on
	# the animal, which is the point: the transmission term keys off radius, so a
	# 0.016 toe tip is where the low species translucency finally shows.
	var fl_t := _part(&"leg_fore_near_toe", Vector2(0.62, -0.055), Vector2(0.82, -0.016), 0.040, 0.016, COL_TOE, 2)
	fl_t.surface = P.Surface.CLAW
	# The hind foot points forward, not back. A lizard's long fourth toe rakes
	# anterolaterally, so in side view the foot reaches ahead of the ankle — the
	# opposite of a cat's hock, and one of the cheapest sprawl cues available.
	var hl_u := _part(&"leg_hind_near_upper", Vector2(-1.06, -0.440), Vector2(-0.66, -0.620), 0.098, 0.070, COL_LIMB, 2)
	var hl_l := _part(&"leg_hind_near_lower", Vector2(-0.66, -0.620), Vector2(-1.00, -0.185), 0.070, 0.050, COL_LIMB, 2)
	var hl_f := _part(&"leg_hind_near_foot", Vector2(-1.00, -0.185), Vector2(-0.78, -0.062), 0.050, 0.044, COL_TOE, 2)
	var hl_t := _part(&"leg_hind_near_toe", Vector2(-0.78, -0.062), Vector2(-0.52, -0.018), 0.044, 0.018, COL_TOE, 2)
	hl_t.surface = P.Surface.CLAW
	for p in [fl_u, fl_l, fl_f, hl_u, hl_l, hl_f]:
		p.blend = 0.040
	fl_t.blend = 0.018
	hl_t.blend = 0.018
	parts.append_array([fl_u, fl_l, fl_f, fl_t, hl_u, hl_l, hl_f, hl_t])

	# Hatchling proportions, and they invert the mammal rule the cat and the dog
	# both follow. A kitten is compact: short limbs, short tail, thick body. A
	# hatchling lizard is the opposite — a spindly, tail-heavy sliver with a
	# head too big for it. Its tail is proportionally *longer* than an adult's
	# (a hatchling's tail is about 1.25 × its snout-vent length against an
	# adult's 1.05) and everything else is thinner, so the growth curves push
	# length up and radius down where a mammal's do the reverse.
	#
	# The beard and the spikes are the loudest age cue on the animal and they
	# work by absence: a hatchling has soft nubs and no pouch at all, and both
	# arrive over the first two stages.
	for p in parts:
		var id := String(p.id)
		if id == "dewlap":
			p.baby_radius_scale = 0.42
			p.baby_length_scale = 0.68
		elif id == "crest_nuchal":
			# `Growth` already gives anything crest-shaped the head bias, so 0.40
			# here nets out near 0.62 — a nub, not a spike.
			p.baby_radius_scale = 0.40
			p.baby_length_scale = 0.45
		elif id == "flank_fringe":
			p.baby_radius_scale = 0.48
			p.baby_length_scale = 0.90
		elif id.begins_with("tail"):
			p.baby_length_scale = 1.10
			p.baby_radius_scale = 0.80
		elif id.ends_with("toe"):
			# Comically long feet, which every juvenile reptile has and which is
			# most of why they look like they are wearing gloves.
			p.baby_length_scale = 1.08
			p.baby_radius_scale = 0.88
		elif id.begins_with("leg"):
			p.baby_length_scale = 0.94
			p.baby_radius_scale = 0.82
		elif id in ["head", "snout", "jaw"]:
			# Left near 1.0 on purpose: `stage_head_bias` is already 1.55, and
			# stacking a second multiplier on top swallows the jaw line inside
			# the skull and the hatchling loses its face.
			p.baby_radius_scale = 1.04
		elif id in ["hip", "torso", "chest", "belly"]:
			p.baby_length_scale = 0.88
			p.baby_radius_scale = 0.90
		else:
			p.baby_radius_scale = 0.96

	# Squamation direction. `SDFPart.groom_angle` is documented as fur-only, but
	# the body shader builds every non-fur family's local frame out of it too:
	# `arc` runs along the groom vector and the plate rows tile across it. So
	# this is what decides whether the scales lie in longitudinal rows down the
	# body — which is what a lizard has — or in rings around it.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("tail") or id == "crest_nuchal":
			# Along the limb or segment, so the plates ring it the way real
			# limb and caudal scales do.
			p.groom_angle = (p.b - p.a).angle()
		else:
			# Backwards along the body axis: rows from the shoulder to the vent.
			p.groom_angle = PI

	s.parts = parts

	# A near eye and a sliver of the far one, same as the cat — but everything
	# about them is different. A beardie's eye is set high and far back on a wide
	# skull, deep under a bony brow, and it is diurnal, so the pupil is round
	# rather than the cat's slit. What it has instead is an iris: a coppery gold
	# ring wide enough to actually read at this size, which no other species here
	# has, and a heavy lower lid that never fully opens.
	var eye_near: E = E.new()
	eye_near.id = &"eye_near"
	eye_near.bone = &"head"
	eye_near.center = Vector2(0.950, -0.865)
	eye_near.radius = 0.052
	eye_near.tilt = -0.10
	eye_near.iris_ratio = 0.86
	eye_near.pupil_ratio = 0.40
	eye_near.pupil_slit = 0.10
	eye_near.iris_color = Color(0.66, 0.49, 0.20)
	eye_near.limbal_color = Color(0.10, 0.07, 0.04)
	eye_near.sclera_color = Color(0.86, 0.82, 0.74)
	eye_near.socket_depth = 0.42
	eye_near.lid_open = 0.86
	eye_near.lid_palette_index = COL_HIDE
	eye_near.baby_radius_scale = 1.75

	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.800, -0.872)
	eye_far.radius = 0.026
	eye_far.tilt = -0.14
	eye_far.iris_ratio = 0.86
	eye_far.pupil_ratio = 0.40
	eye_far.pupil_slit = 0.10
	eye_far.iris_color = Color(0.56, 0.41, 0.17)
	eye_far.limbal_color = Color(0.08, 0.06, 0.03)
	eye_far.sclera_color = Color(0.80, 0.76, 0.69)
	eye_far.socket_depth = 0.66
	eye_far.lid_open = 0.86
	eye_far.lid_palette_index = COL_HIDE
	eye_far.baby_radius_scale = 1.75

	s.eyes = [eye_far, eye_near]
	# Half again the cat's. A lizard's blink is slow, deliberate and rare, and
	# the long gap between them is a large part of why a reptile reads as
	# watching you rather than as looking at you.
	s.blink_interval = 6.5
	return s
