extends RefCounted

## Bearded dragon (Pogona vitticeps).
##
## Rig space convention used by every species:
##   * +x is forward (the creature faces right at rotation 0),
##   * +y is down (matching Godot's 2D axes),
##   * the origin sits between the feet on the ground plane,
##   * 1.0 unit ≈ adult shoulder height.
##
## Why a beardie and not a gecko: this is the species that exercises the SCALE
## surface, and squamation only reads if the animal has shapes big enough to
## carry it. A leopard gecko is a smooth soft-skinned tube at desktop size. A
## bearded dragon has four things a cat, a dog and a bird all lack — a head that
## is a flat wedge wider than it is tall, a spiny gular pouch under the jaw, a
## keratin skirt along the flank, and limbs that go *out* before they go down.
## Every one of those survives being 118 px tall.
##
## Built in code rather than as a .tres so a species reads as a document: you can
## see the whole animal's proportions in one screen and diff a change to its
## sprawl angle.

const P := preload("res://core/creature/sdf_part.gd")
const S := preload("res://core/creature/creature_spec.gd")
const E := preload("res://core/creature/eye_spec.gd")

# Palette slots, referenced by every part below. A wild-type beardie is one warm
# ochre run through four values plus bone-pale keratin: the nuchal row, the
# lateral fringe and the lower lip are all the same dead horn, and keeping them
# on one slot is what makes them read as the *same material* appearing in three
# places rather than as three separate decorations.
const COL_HIDE := 0
const COL_HIDE_DARK := 1
const COL_BAND := 2
const COL_BELLY := 3
const COL_KERATIN := 4
const COL_BEARD := 5
const COL_LIP := 6
const COL_LIMB := 7
const COL_TOE := 8
const COL_CLAW := 9
const COL_TAILBAND := 10


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
		# Nothing pale in this palette is allowed near white, and that is a shader
		# constraint rather than a taste. `pet_scale` swings a plate's occlusion
		# from 0.62 to 1.08 across its own width; on a light albedo that lands as
		# black-and-white chequer and the fringe, the lip and the belly all come
		# out looking like chrome zips glued to the animal. Bone, sand and horn —
		# every "pale" slot here is a mid value with warmth still in it.
		#
		# Saturation is the second constraint and it was found the hard way. A blind
		# reviewer called this animal "a brass ornament" at 260 px, and rendering the
		# albedo on its own (`PETALIA_DEBUG_VIEW=6`) settled where that came from: the
		# albedo pass is a soft matte orange lizard, and everything metallic about the
		# shipped frame is added afterwards by the specular. But hue is half of what
		# makes a specular read as *metal* rather than as sheen — a white highlight on
		# a saturated golden-orange is the exact colour of polished brass, and the same
		# highlight on a grey-tan is the sheen on a dry hide. So every slot below is
		# pulled toward neutral: the dorsum went from saturation 0.55 to 0.34, which is
		# also closer to a wild-type Pogona, whose base colour is dull sandy grey-brown
		# and not gold. The other half of the fix is in the surface families further
		# down.
		Color(0.578, 0.494, 0.382),   # dorsum: dry sandy grey-tan
		Color(0.372, 0.312, 0.244),   # far side, dark caudal bands. Only a step
		                              # down from the dorsum — the BEHIND layer is
		                              # already shaded as far-side, and a genuinely
		                              # dark pigment on top of that turns the off
		                              # limbs into holes
		Color(0.442, 0.318, 0.206),   # rust saddle over the hips. The one slot
		                              # allowed to keep real warmth, because it is
		                              # the only large-shape *value* break the
		                              # animal has — and it has to be a break in
		                              # *value*, not in hue. The version this
		                              # replaces was 0.730/0.428/0.198, which
		                              # computes to luminance 0.486 against the
		                              # dorsum's 0.504: two per cent apart, so the
		                              # saddle existed only as a hue shift and a hue
		                              # shift is worth nothing at 42 px per rig unit.
		                              # This is 0.336, a third under the dorsum, and
		                              # it is the only shape on the trunk a viewer
		                              # can see at ship size
		Color(0.694, 0.652, 0.582),   # ventral scutes: warm sand
		Color(0.578, 0.538, 0.470),   # keratin: nuchal row, lateral fringe
		Color(0.238, 0.200, 0.186),   # gular pouch. Smoky rather than black: a
		                              # relaxed beard is grey and only goes to ink
		                              # when the animal flares it
		Color(0.612, 0.576, 0.510),   # lower lip / jaw line
		Color(0.452, 0.376, 0.290),   # limbs
		Color(0.512, 0.466, 0.404),   # toes, dry and bleached
		Color(0.185, 0.160, 0.140),   # claws
		Color(0.286, 0.224, 0.164),   # caudal band. Its own slot rather than
		                              # reusing the far-side brown, because those
		                              # two want opposite things: the far side has
		                              # to stay light or the off limbs become holes
		                              # in the animal, while a band has to be much
		                              # darker than looks right on the swatch. The
		                              # key plus the sky plus the bounce lift a
		                              # midtone a long way, and a band authored one
		                              # step under the dorsum came back out the same
		                              # colour as the dorsum. This is 45 per cent of
		                              # its luminance and only just reads
	])

	s.adult_height = 1.0
	# The lowest of any species we ship, and it has to be. This animal is 5.6
	# units long where the cat is 1.9, so matching the cat's 190 px/unit would
	# draw a pet 1070 px wide. 118 puts it at ~665 px long and 118 px tall — the
	# widest footprint on the desktop, which is honest for a lizard, without
	# being a piece of furniture.
	s.pixels_per_unit = 118.0

	s.coat_surface = P.Surface.SCALE
	# Zero, not "small". A scale is not a fibre standing off the body; it is the
	# body's own outline. Any silhouette displacement here would read as fuzz.
	s.coat_length = 0.0
	# `pet_scale` sizes a plate at `0.030 / coat_density` rig units and fades the
	# whole tier in over 2.5 → 6.0 screen pixels of plate. The temptation is to
	# size the plate so that ramp is saturated at desktop scale, and that is the
	# wrong instinct: a plate swings its own occlusion from 0.62 to 1.08 and its
	# specular from 0.35× to 1.9× across its width, so a *big* plate at full fade
	# is not squamation, it is basket weave. But the ramp cuts the other way just
	# as hard, and this is the number that had to be found by looking rather than
	# by reasoning: 0.92 puts the plate at 3.9 px on the desktop, a quarter of the
	# way up the ramp, and the pet renders as a smooth clay toy with no surface at
	# all. 0.68 is the compromise — a 0.044-unit plate, 5.2 px and about eighty
	# per cent faded in at 118 px/unit, so the desktop gets a dry pebbled hide,
	# and it resolves into individual shingles when the pet is scaled up.
	s.coat_density = 0.68
	# A reptile is dry. The only places light gets through are the toes, the
	# trailing edge of the beard and the last centimetre of tail, and the body
	# shader gates transmission on part radius and flatness — so keeping the
	# species number this low means those three places are the *only* ones that
	# glow, instead of the whole animal looking like wet resin.
	#
	# Raised from 0.14 anyway, and the reason is the terminator rather than the
	# glow. `translucency` also sets the diffuse wrap (`wrap = 0.26 + 0.44 * t`),
	# and at 0.14 the shadow line across this animal's flank was 0.32 wide — a hard
	# edge between a bright top and a dark underside on a surface with no texture
	# on it, which is the value signature of turned metal. 0.30 opens the wrap to
	# 0.39 and the light rolls round the barrel instead of breaking over it. The
	# transmission terms it also feeds are gated on radius and flatness, so the
	# only parts that gain any glow are still the toe tips and the beard's edge.
	s.translucency = 0.30
	# Unused by anything this species draws — the body shader's `roughness`
	# uniform only reaches `pet_hair_spec`, i.e. fur. Every non-fur family picks a
	# fixed roughness in the shader (SCALE 0.26, SKIN 0.42, CLAW 0.16), which is
	# why the surface-family block further down is the only gloss lever a reptile
	# actually has. Left at a sane value so nothing keys off a garbage number.
	s.roughness = 0.30

	# Reptiles grow on a geological timescale next to a kitten. 30 hours a stage
	# is half again the cat's, and the payoff is that the hatchling is around long
	# enough to be worth authoring properly.
	s.hours_per_stage = 30.0
	# A hatchling beardie is genuinely tiny — 9 cm against an adult's 47, so a
	# true 0.19 — but at 0.19 it would be 22 px tall on the desktop and the
	# squamation would vanish entirely. 0.34 is the compromise, still well under
	# the cat's 0.40 because a hatchling reptile *should* read as startlingly
	# small next to its adult.
	s.stage_scale = PackedFloat32Array([0.34, 0.56, 0.80, 1.0])
	s.stage_head_bias = PackedFloat32Array([1.52, 1.28, 1.11, 1.0])
	s.stage_eye_bias = PackedFloat32Array([1.62, 1.34, 1.14, 1.0])

	s.locomotion = S.Locomotion.SPRAWLING
	# On-screen speed, not real-world speed, is what a desktop pet is judged on:
	# 1.30 × 118 px is 153 px/s, within a whisker of the cat's 162. The difference
	# the player sees is in the *step*, not the pace — 1.30/0.52 is 2.5 Hz against
	# the cat's 2.0, so the dragon scuttles where the cat flows.
	s.walk_speed = 1.30
	s.run_speed = 4.60
	s.stride = 0.52
	# A third of the cat's. A sprawling animal carries its weight on splayed limbs
	# and pays for it by keeping the trunk almost dead level; the motion that
	# should read is the lateral wave `Gait` writes into `undulation`, and any
	# vertical bob competing with it makes the walk look mammalian.
	s.bob = 0.022
	# It climbs by hooking claws into a texture, not by leaping — which is exactly
	# what `can_climb` without `jump_height` describes.
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
	#   trunk depth, belly to back  4.5 cm   → 0.64
	#   head                        4.5 long × 2.4 deep × 4.0 wide → 0.64 × 0.34 × 0.57
	#
	# So the target is length / height ≈ 6.7 — nearly four times the cat's 1.75,
	# and the single number that decides whether this reads as a lizard or as a
	# green dachshund. As drawn the span is 5.6 rather than 6.7, because the tail
	# is authored trailing on the floor in a shallow curve rather than held out
	# straight: its arc is the full length, it just does not spend all of it on x.
	#
	# The other half of the read is posture, and it is structural rather than
	# proportional. It also has one hard constraint that is easy to get wrong, and
	# getting it wrong was what sank the first pass of this file.
	#
	# A sprawling limb leaves the body sideways before it goes down, so in side
	# view the elbow and the knee sit high — but "high" has to be measured against
	# the *belly*, not against the flank. The trunk here bottoms out at y = -0.36
	# and the belly at y = -0.31. An elbow at y = -0.35 is therefore above the
	# belly line, which is the sprawl cue, and simultaneously 0.05 *below* the
	# outline of the flank, which is what makes it a joint you can see instead of
	# a stripe painted on the ribs. The first pass put the elbows at y = -0.63,
	# dead in the middle of the flank, and every limb vanished into the torso —
	# the animal read as a legless skink no matter what the palette did.
	#
	# So: shoulder inside the ribcage, elbow poking out under it, forearm slanting
	# down and *forward*, foot flat with the toes raking ahead. The limb is a Λ
	# hung off the side of the body, not the ⌐ of a mammal, and the negative space
	# between the Λ and the belly is the whole silhouette.
	#
	# Withers sit at y = -1.00, the skull crown reaches -0.98, the belly bottoms
	# out at -0.31, and the body spans x = -4.16 (tail tip) to +1.44 (snout).
	#
	# One more thing constrains the numbers below, and it is invisible until you
	# render the head. `CreatureRenderer._pack_landmarks` finds the scapula and
	# the hip point geometrically — anything thinner than 0.62 of the widest body
	# part whose lower end hangs below the trunk's midline is taken for a limb
	# root, and roots within `core_r * 2.2` of each other in x are one limb. Those
	# thresholds are calibrated on a cat, whose whole body is 1.9 units long. On
	# an animal 5.6 units long the tolerance is a tenth of the body, so the jaw
	# and the gular pouch came out as a limb of their own and the renderer stamped
	# a scapula dome across the snout: a smooth bald crater in the middle of the
	# face, which is exactly as bad as it sounds.
	#
	# Three numbers below exist to steer that heuristic and are marked where they
	# occur: the jaw's axis is kept above the trunk midline so it is not a root at
	# all, the beard's tip and the belly's tip are placed so the beard falls
	# inside the *foreleg's* cluster, and the tail's first joint sits close enough
	# to the hip to fall inside the hind leg's. What comes out is two landmarks,
	# on the shoulder and on the hip, which is what the feature is for.

	# --- far-side limbs (drawn behind the torso) ----------------------------
	# Three segments each, not two, and it is a rig constraint rather than an
	# aesthetic one: with the elbow held out under the flank, a two-capsule limb
	# has to cover the whole drop to the floor in its second segment, which makes
	# the two IK lengths so unequal that `LegIK.solve_two` spends the walk cycle
	# pinned against its own fold limit. A wrist to break the drop fixes it, and
	# it is what the animal has anyway.
	#
	# The far feet are authored half a step out of phase with the near ones — far
	# fore behind near fore, far hind behind near hind. Mirroring them exactly is
	# the obvious thing and it hides two of the four legs completely; offsetting
	# them is what lets a viewer count to four without effort.
	var ff_u := _part(&"leg_fore_far_upper", Vector2(0.42, -0.545), Vector2(0.62, -0.335), 0.070, 0.054, COL_HIDE_DARK, 0)
	var ff_l := _part(&"leg_fore_far_lower", Vector2(0.62, -0.335), Vector2(0.28, -0.150), 0.054, 0.042, COL_HIDE_DARK, 0)
	var ff_f := _part(&"leg_fore_far_foot", Vector2(0.28, -0.150), Vector2(0.46, -0.058), 0.042, 0.030, COL_HIDE_DARK, 0)
	var hf_u := _part(&"leg_hind_far_upper", Vector2(-1.24, -0.545), Vector2(-1.64, -0.378), 0.084, 0.062, COL_HIDE_DARK, 0)
	var hf_l := _part(&"leg_hind_far_lower", Vector2(-1.64, -0.378), Vector2(-1.36, -0.168), 0.062, 0.048, COL_HIDE_DARK, 0)
	var hf_f := _part(&"leg_hind_far_foot", Vector2(-1.36, -0.168), Vector2(-1.14, -0.062), 0.048, 0.034, COL_HIDE_DARK, 0)
	for p in [ff_u, ff_l, ff_f, hf_u, hf_l, hf_f]:
		p.blend = 0.036
	parts.append_array([ff_u, ff_l, ff_f, hf_u, hf_l, hf_f])

	# --- trunk --------------------------------------------------------------
	# Three capsules on one nearly flat axis. A cat's back dips behind the
	# shoulder blades and a bird's is an unbroken convex egg; a lizard's is
	# neither — it is a straight plank from the shoulder to the hip, and any curve
	# at all in this line immediately reads as mammal.
	#
	# `height_scale` above 1.0 everywhere on the trunk is the one place this
	# species departs from the others, and it is load-bearing. A beardie is 8 cm
	# wide and 4.5 cm deep: dorsoventrally flattened, so the silhouette is shallow
	# while the mass toward the camera is enormous. Lifting the height field past
	# the silhouette is exactly how you say "this is wider than it looks" in an
	# implicit body — and the shallow silhouette is also what buys the legs the
	# 0.31 of clear air they need underneath.
	var hip := _part(&"hip", Vector2(-1.42, -0.660), Vector2(-0.98, -0.672), 0.290, 0.315, COL_BAND)
	hip.blend = 0.095
	hip.height_scale = 1.15
	var torso := _part(&"torso", Vector2(-0.98, -0.672), Vector2(-0.16, -0.678), 0.315, 0.320, COL_HIDE)
	torso.blend = 0.100
	torso.height_scale = 1.18
	# Runs all the way up under the skull. There is no neck capsule, and that is
	# deliberate rather than a budget casualty: a beardie's nuchal row carries
	# straight off the back of the head onto the shoulder with no waist in
	# between, and authoring a neck here produced a visible pinch the animal does
	# not have. The gular pouch fills the underside of the same junction.
	var chest := _part(&"chest", Vector2(-0.16, -0.678), Vector2(0.54, -0.700), 0.320, 0.255, COL_HIDE)
	chest.blend = 0.095
	chest.height_scale = 1.15
	# The belly is its own volume slung under the trunk, not a colour band on it.
	# It has to bottom out below the flank — a lizard's weight sits on its gut —
	# but only just: 0.05 proud of a trunk that is already the lowest of any
	# species here. Push it further and the elbows have nowhere left to be.
	#
	# Fattened from 0.140 → 0.128 with its *lower* surface pinned exactly where it
	# was, so the underline, the 0.05 of proudness and the clearance the elbows need
	# are all unchanged. The reason is the shared "white streak over black stipple
	# along the belly" the review reports on every species: a capture on the dog,
	# with the same capsule shrunk to nothing, showed that the streak is not the
	# pigment and not the marking path — it is a thin capsule hung along a fat one.
	# The height field blends its radius toward the thicker part with a strength
	# running on `(R_fat − R_thin)/(R_fat + R_thin)`, and above about 0.36 that digs
	# a groove down the whole underside whose two walls light as hard lines. This
	# capsule sat at 0.40. At 0.160 → 0.148 it sits at 0.34.
	var belly := _part(&"belly", Vector2(-0.88, -0.472), Vector2(0.14, -0.490), 0.160, 0.148, COL_BELLY)
	belly.blend = 0.085
	parts.append_array([hip, torso, chest, belly])

	# --- head ---------------------------------------------------------------
	# A flat wedge, and the wedge is in the *height field*: 0.39 deep in
	# silhouette against 0.57 wide across, so `height_scale` runs to 1.26 — the
	# highest number in the file. Read in profile the skull is a broad triangle
	# widest at the jaw hinge and tapering to a blunt snout, and it is carried
	# level with the back rather than lifted like a cat's.
	#
	# It is worth knowing why the head does not go flatter still. `pet_scale`
	# offsets its tiling by the surface normal to fake plate thickness, so the
	# taller the height field the harder the plates shear as the surface turns —
	# past about 1.3 the squamation stops tiling and smears into a smooth patch
	# on the cheek. 1.26 is where the wedge is as deep as it can be while the
	# scales still hold.
	var skull := _part(&"head", Vector2(0.70, -0.800), Vector2(1.00, -0.815), 0.195, 0.160, COL_HIDE)
	skull.blend = 0.072
	skull.height_scale = 1.26
	# The jaw hinge. A beardie's head is at its widest and deepest behind the eye,
	# where the adductor muscle packs out the cheek, and without this capsule the
	# skull tapers evenly from back to front and reads as a crocodile.
	var cheek := _part(&"cheek", Vector2(0.68, -0.735), Vector2(0.86, -0.748), 0.150, 0.120, COL_HIDE)
	cheek.blend = 0.062
	cheek.height_scale = 1.14
	# Blunt, not pointed. A beardie's snout ends in a rounded square; taper it to a
	# real point and the head stops being a wedge and becomes a monitor lizard's.
	var muzzle := _part(&"muzzle", Vector2(1.00, -0.815), Vector2(1.33, -0.802), 0.160, 0.114, COL_HIDE)
	muzzle.blend = 0.052
	muzzle.height_scale = 1.10
	# The jaw line. Authored to hang 0.02–0.04 proud of the skull's lower edge
	# rather than inside it, so it is real geometry with a smooth-union crease
	# along its top instead of a painted stripe — that crease *is* the jaw line,
	# and dropping the blend to 0.020 is what keeps it a line rather than a
	# gradient. It converges on the skull toward the snout, because that is where
	# a closed mouth actually meets. Pale, because a beardie's lower lip is
	# bone-coloured and the boundary is one of the few hard edges on the animal.
	#
	# Landmark steering: the axis is kept at -0.700, just above the trunk's
	# midline at -0.675, so the jaw is not mistaken for a limb root. The visible
	# overhang comes from the radius instead, which the root test does not read.
	var chin := _part(&"chin", Vector2(0.80, -0.700), Vector2(1.30, -0.745), 0.118, 0.060, COL_LIP)
	chin.blend = 0.020
	chin.height_scale = 1.02
	parts.append_array([skull, cheek, muzzle, chin])

	# --- gular pouch --------------------------------------------------------
	# The beard. Kept in the BODY layer and overlapped into the throat so it
	# smooth-unions with it: floated in the FRONT layer as its own field it became
	# a separate dark object stuck to the chin, which is precisely what a pouch is
	# not — it is the throat skin, hanging. Flattened to 0.78 so it still reads as
	# a sheet with slack in it, which also opens the transmission gate: with the
	# species translucency at 0.14 the beard's trailing edge is one of the only
	# places on the animal that lights up from behind.
	#
	# It stops at x = 1.10, well short of the 1.44 snout tip. The first pass ran
	# it forward to 1.25 and it read as a slug crawling up the animal's face.
	#
	# The tip's x is also one of the three landmark-steering numbers: at 1.02 the
	# beard's root falls inside the foreleg's cluster, and at 1.06 it starts one
	# of its own and the renderer puts a scapula on the snout.
	var dewlap := _part(&"dewlap", Vector2(0.72, -0.558), Vector2(1.02, -0.628), 0.136, 0.076, COL_BEARD)
	dewlap.blend = 0.030
	dewlap.height_scale = 0.78
	parts.append_array([dewlap])

	# --- keratin: nuchal row and lateral fringe ------------------------------
	# Both are single flattened blades rather than rows of capsules. A row of
	# eight authored spikes would cost eight of the twenty-eight uniform slots to
	# draw eight bumps four pixels tall; one blade riding just proud of the
	# outline gives a pale skirt, and the SCALE plates running along it do the
	# serration for free.
	#
	# The nuchal blade lies *along* the head-to-shoulder line rather than standing
	# off it. The first pass authored a single large spike pointing up and back,
	# and one pale cone on an otherwise smooth outline does not read as the front
	# of a spiny row — it reads as a tusk, or as a bug.
	#
	# Two things about these two parts were wrong for the same reason and are
	# worth writing down, because the FRONT layer looks like the obvious home for
	# a decoration and is a trap.
	#
	# `LayerCtx c2` hands the front layer shadow = 1, ao = 1, atmos = 0: it is the
	# one layer that receives the key completely unattenuated and never picks up a
	# crease. Put a pale part there and it becomes the brightest thing on the
	# animal by construction — these two rendered as strips of white chequered
	# tape stuck along the flank and the skull. In the BODY layer they smooth-
	# union with what they lie on, so they inherit its ambient occlusion, and
	# because each one is mostly buried in the part beneath it the shader's
	# marking path picks it up and gives it its own low dome. That is precisely
	# what a scale row is: a raised band of different keratin on the hide, not a
	# separate object floating in front of it.
	#
	# They also do not go as flat as they want to. A slab at `height_scale` 0.25
	# presents its whole face square to the viewer, so the plate tiling lands at
	# full contrast with no curvature to roll it off. 0.62 keeps them clearly
	# flatter than the body while giving the plates a surface to curve over.
	var crest := _part(&"crest_nuchal", Vector2(0.88, -0.948), Vector2(0.52, -0.918), 0.038, 0.062, COL_KERATIN)
	crest.blend = 0.018
	crest.height_scale = 0.62
	# The lateral fringe sits on the seam between flank and belly and hangs 0.02
	# below the trunk's outline, so it breaks the one long smooth curve the
	# silhouette would otherwise have between the shoulder and the hip.
	var fringe := _part(&"flank_fringe", Vector2(0.46, -0.428), Vector2(-0.84, -0.408), 0.052, 0.044, COL_KERATIN)
	fringe.blend = 0.018
	fringe.height_scale = 0.62
	parts.append_array([crest, fringe])

	# --- tail ---------------------------------------------------------------
	# Three capsules over 2.6 units, thick as the hip where it leaves the vent and
	# down to a 0.020 point — it has to taper across essentially the whole animal,
	# because a tail that keeps its thickness reads as a second body. Authored
	# trailing to the floor rather than held out: a resting beardie drags its tail
	# on the ground, and the spring chain then only has to add the sway rather
	# than fight an unnaturally level bind pose.
	#
	# The alternating palette is the caudal banding. Three bands across 2.6 units
	# is coarser than life, but at 118 px/unit a truer eight-band pattern would be
	# four pixels a band, and banding you cannot resolve is just noise.
	# Landmark steering again: the first joint sits at -2.10 rather than further
	# back so its root falls inside the hind leg's cluster. Past about -2.20 it
	# claims a landmark slot of its own and a scapula dome lands on the tail.
	var tail_0 := _part(&"tail_0", Vector2(-1.50, -0.640), Vector2(-2.10, -0.556), 0.250, 0.168, COL_HIDE)
	tail_0.blend = 0.070
	tail_0.height_scale = 1.02
	var tail_1 := _part(&"tail_1", Vector2(-2.10, -0.556), Vector2(-3.06, -0.360), 0.168, 0.076, COL_TAILBAND)
	tail_1.blend = 0.048
	var tail_2 := _part(&"tail_2", Vector2(-3.06, -0.360), Vector2(-4.16, -0.108), 0.076, 0.020, COL_HIDE)
	tail_2.blend = 0.026
	parts.append_array([tail_0, tail_1, tail_2])

	# --- near limbs ---------------------------------------------------------
	# The sprawl, in four points per limb. Shoulder buried low in the side of the
	# ribcage; elbow swinging out and *down* until it clears the flank by 0.13;
	# wrist folding back under the shoulder and almost to the floor; foot flat
	# with a long toe raking ahead of it. The hind limb is the same shape mirrored
	# front-to-back — knee behind the rump, shank forward, foot forward — which is
	# what makes the two pairs bracket the body the way a lizard's do instead of
	# both leaning the same way. Both elbow and knee land at y ≈ -0.34: above the
	# belly line at -0.31, which is the sprawl, and below the flank outline at
	# -0.46, which is what makes them visible.
	#
	# Which way the elbow points is not a free choice, and this is the trap in
	# this file. `Growth._relink_chains` rebuilds a limb outward from whichever
	# end of its first segment is nearer the trunk's centroid, so the elbow has to
	# be *further* from the middle of the body than the shoulder is. Tucking it
	# rearward — which is what a photograph shows — puts it nearer, and the
	# re-link then hangs the forearm off the shoulder instead of off the elbow:
	# two capsules radiating from one point, which is not a limb. So the fore
	# elbow leads forward and the forearm folds back under it. The hind limb wants
	# its knee behind the rump anyway, so it satisfies the rule for free.
	#
	# The two segment lengths are deliberately kept within about 15% of each other
	# (0.29 / 0.29 fore, 0.43 / 0.44 hind). `LegIK.solve_two` clamps the
	# root→ankle span to at least |l1 − l2|, and a Λ limb has a *short* span by
	# construction — the ankle is barely 0.42 from the shoulder. Unbalanced
	# segments would sit against that clamp for the whole stance phase and the
	# elbow would snap rather than swing.
	var fl_u := _part(&"leg_fore_near_upper", Vector2(0.44, -0.545), Vector2(0.63, -0.330), 0.086, 0.066, COL_LIMB, 2)
	var fl_l := _part(&"leg_fore_near_lower", Vector2(0.63, -0.330), Vector2(0.44, -0.128), 0.066, 0.048, COL_LIMB, 2)
	var fl_f := _part(&"leg_fore_near_foot", Vector2(0.44, -0.128), Vector2(0.68, -0.052), 0.048, 0.040, COL_TOE, 2)
	# Toes get their own capsule on both limbs and they are the thinnest parts on
	# the animal, which is the point: the transmission term keys off radius, so a
	# 0.018 toe tip is where the low species translucency finally shows.
	#
	# Kept short and put on the claw slot rather than the toe slot. `pet_claw`
	# pipes light to the point and hands the tip a 2.6× specular, so a long
	# capsule on a pale colour renders as a polished white needle sticking out of
	# the foot — which is what the first two passes drew, twice per animal, and it
	# read as a defect rather than as an animal. On the near-black claw colour
	# that same piping is the one thing it is for: a small wet glint on a dark
	# horn, stepping down off the paler foot at the toe joint.
	var fl_t := _part(&"leg_fore_near_toe", Vector2(0.68, -0.052), Vector2(0.85, -0.028), 0.030, 0.014, COL_CLAW, 2)
	fl_t.surface = P.Surface.CLAW
	# The hind foot points forward, not back. A lizard's long fourth toe rakes
	# anterolaterally, so in side view the foot reaches well ahead of the ankle —
	# the opposite of a cat's hock, and one of the cheapest sprawl cues available.
	var hl_u := _part(&"leg_hind_near_upper", Vector2(-1.16, -0.545), Vector2(-1.55, -0.360), 0.100, 0.074, COL_LIMB, 2)
	var hl_l := _part(&"leg_hind_near_lower", Vector2(-1.55, -0.360), Vector2(-1.16, -0.150), 0.074, 0.052, COL_LIMB, 2)
	var hl_f := _part(&"leg_hind_near_foot", Vector2(-1.16, -0.150), Vector2(-0.93, -0.058), 0.052, 0.044, COL_TOE, 2)
	var hl_t := _part(&"leg_hind_near_toe", Vector2(-0.93, -0.058), Vector2(-0.71, -0.026), 0.034, 0.015, COL_CLAW, 2)
	hl_t.surface = P.Surface.CLAW
	for p in [fl_u, fl_l, fl_f, hl_u, hl_l, hl_f]:
		p.blend = 0.038
	fl_t.blend = 0.016
	hl_t.blend = 0.016
	parts.append_array([fl_u, fl_l, fl_f, fl_t, hl_u, hl_l, hl_f, hl_t])

	# Hatchling proportions, and they invert the mammal rule the cat and the dog
	# both follow. A kitten is compact: short limbs, short tail, thick body. A
	# hatchling lizard is the opposite — a spindly, tail-heavy sliver with a head
	# too big for it. Its tail is proportionally *longer* than an adult's (about
	# 1.25 × snout-vent length against an adult's 1.05) and everything else is
	# thinner, so the growth curves push length up and radius down where a
	# mammal's do the reverse.
	#
	# The beard and the keratin are the loudest age cue on the animal and they
	# work by absence: a hatchling has soft nubs and no pouch at all, and both
	# arrive over the first two stages.
	for p in parts:
		var id := String(p.id)
		if id == "dewlap":
			p.baby_radius_scale = 0.42
			p.baby_length_scale = 0.68
		elif id == "crest_nuchal":
			# `Growth` already gives anything crest-shaped the head bias, so 0.42
			# here nets out near 0.64 — a row of nubs, not a row of spikes.
			p.baby_radius_scale = 0.42
			p.baby_length_scale = 0.72
		elif id == "flank_fringe":
			p.baby_radius_scale = 0.46
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
		elif id in ["head", "cheek", "muzzle", "chin"]:
			# Left near 1.0 on purpose: `stage_head_bias` is already 1.52, and
			# stacking a second multiplier on top swallows the jaw line inside the
			# skull and the hatchling loses its face.
			p.baby_radius_scale = 1.03
		elif id in ["hip", "torso", "chest", "belly"]:
			p.baby_length_scale = 0.88
			p.baby_radius_scale = 0.90
		else:
			p.baby_radius_scale = 0.96

	# --- surface families: where the animal is plated and where it is hide ------
	#
	# The body shader picks a fixed specular roughness per surface family, and
	# nothing in `CreatureSpec` overrides it — `spec.roughness` reaches fur only.
	# So the family a part declares *is* its gloss, and this is the only gloss
	# lever a species has:
	#
	#   CLAW  0.16 × 1.10   peak lobe ≈ 490     hard keratin, a wet glint
	#   SCALE 0.26 × 1.10   peak lobe ≈  3.1    plate, glitters at every boundary
	#   SKIN  0.42 × 0.55   peak lobe ≈  0.22   matte hide
	#
	# The belly, the beard and the jaw take hide, which is what they are: a
	# Pogona's venter and gular skin are soft and granular, and the conspicuous
	# keeled squamation is on the head, the nuchal row, the lateral spines, the
	# limbs, the trunk and the caudal whorls. Fourteen times the specular between
	# the two families is enough that they read as different materials.
	#
	# The trunk is *not* on the hide list, and that reversal is worth the space.
	#
	# The obvious reading of "reads as a brass ornament" is that the specular is
	# too hot, so the first attempt put the whole trunk on SKIN. Rendered at 260 px
	# it came back matte and grey — and bald. Where the shipped build had a smooth
	# glossy barrel it now had a smooth dull one: a bar of soap instead of a cast
	# ornament, which is a different wrong answer, not a better one.
	#
	# What actually removed the metal was the palette, and the mechanism is the
	# tonemap rather than the lighting rig. A 260 px A/B of three builds side by
	# side (`_captures/r7_rep_3way.png`) shows it in one look: on the old saturated
	# ochre the entire dorsal surface is *clipped* by the filmic curve, and a
	# clipped surface has no micro-contrast left — the squamation that `pet_scale`
	# is drawing right there is erased along with everything else, leaving a smooth
	# bright field with a hard shadow edge, which is exactly what polished metal
	# looks like. Desaturating the hide and dropping its value by a fifth puts the
	# lit face back inside the curve's usable range, and the plates reappear at
	# ship size with no change to the surface code at all.
	#
	# So the rule this species now runs on: a scaled animal has to be authored dark
	# enough that its lit side does not clip, because the squamation is the only
	# thing standing between it and an ornament, and clipping is what deletes it.
	const HIDE := [&"belly", &"dewlap", &"chin"]
	for p in parts:
		if p.id in HIDE:
			p.surface = P.Surface.SKIN

	# Squamation direction. `SDFPart.groom_angle` is documented as fur-only, but
	# the body shader builds every non-fur family's local frame out of it too:
	# `arc` runs along the groom vector and the plate rows tile across it. So this
	# is what decides whether the scales lie in longitudinal rows down the body —
	# which is what a lizard has — or in rings around it.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("tail") or id == "crest_nuchal":
			# Along the limb or segment, so the plates ring it the way real limb
			# and caudal scales do.
			p.groom_angle = (p.b - p.a).angle()
		else:
			# Backwards along the body axis: rows from the shoulder to the vent.
			p.groom_angle = PI

	s.parts = parts

	# A near eye and a sliver of the far one, same as the cat — but everything
	# about them is different. A beardie's eye is set high and far back on a wide
	# skull, sitting directly over the jaw hinge, and it is diurnal, so the pupil
	# is round rather than the cat's slit. What it has instead is an iris: a
	# coppery gold ring wide enough to actually read at this size, which no other
	# species here has, and a heavy lower lid that never fully opens. The lid is
	# the expression: a lizard with its eye wide is a lizard that has just decided
	# something is wrong.
	var eye_near: E = E.new()
	eye_near.id = &"eye_near"
	eye_near.bone = &"head"
	eye_near.center = Vector2(0.845, -0.848)
	eye_near.radius = 0.058
	eye_near.tilt = -0.12
	eye_near.iris_ratio = 0.88
	eye_near.pupil_ratio = 0.38
	eye_near.pupil_slit = 0.10
	eye_near.iris_color = Color(0.66, 0.49, 0.20)
	eye_near.limbal_color = Color(0.10, 0.07, 0.04)
	eye_near.sclera_color = Color(0.86, 0.82, 0.74)
	eye_near.socket_depth = 0.46
	eye_near.lid_open = 0.84
	eye_near.lid_palette_index = COL_HIDE
	eye_near.baby_radius_scale = 1.75

	var eye_far: E = E.new()
	eye_far.id = &"eye_far"
	eye_far.bone = &"head"
	eye_far.center = Vector2(0.678, -0.866)
	eye_far.radius = 0.022
	eye_far.tilt = -0.16
	eye_far.iris_ratio = 0.88
	eye_far.pupil_ratio = 0.38
	eye_far.pupil_slit = 0.10
	eye_far.iris_color = Color(0.56, 0.41, 0.17)
	eye_far.limbal_color = Color(0.08, 0.06, 0.03)
	eye_far.sclera_color = Color(0.80, 0.76, 0.69)
	eye_far.socket_depth = 0.68
	eye_far.lid_open = 0.84
	eye_far.lid_palette_index = COL_HIDE
	eye_far.baby_radius_scale = 1.75

	s.eyes = [eye_far, eye_near]
	# Half again the cat's. A lizard's blink is slow, deliberate and rare, and the
	# long gap between them is a large part of why a reptile reads as watching you
	# rather than as looking at you.
	s.blink_interval = 6.5
	return s
