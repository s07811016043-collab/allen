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

	# Proportions are the whole ballgame. A domestic cat is roughly 1.75 times as
	# long from nose to rump as it is tall at the withers, with legs a little over
	# half its standing height. Get that ratio wrong and no amount of coat shading
	# rescues it — a short, tall body reads as a generic quadruped toy, which is
	# exactly what the first pass produced.
	#
	# Withers sit at y = -0.90, the ear tips reach -1.16, and the body spans
	# x = -0.81 (rump) to +0.77 (nose).

	# --- far-side limbs (drawn behind the torso) ----------------------------
	var fl_far_u := _part(&"leg_fl_far_upper", Vector2(0.24, -0.66), Vector2(0.26, -0.40), 0.054, 0.041, COL_COAT_DARK, 0)
	var fl_far_l := _part(&"leg_fl_far_lower", Vector2(0.26, -0.40), Vector2(0.25, -0.13), 0.039, 0.030, COL_COAT_DARK, 0)
	var fl_far_p := _part(&"paw_fl_far", Vector2(0.25, -0.13), Vector2(0.30, -0.035), 0.030, 0.031, COL_COAT_DARK, 0)
	var bl_far_u := _part(&"leg_bl_far_upper", Vector2(-0.52, -0.66), Vector2(-0.62, -0.42), 0.078, 0.049, COL_COAT_DARK, 0)
	var bl_far_l := _part(&"leg_bl_far_lower", Vector2(-0.62, -0.42), Vector2(-0.49, -0.19), 0.043, 0.031, COL_COAT_DARK, 0)
	var bl_far_p := _part(&"paw_bl_far", Vector2(-0.49, -0.19), Vector2(-0.44, -0.035), 0.030, 0.031, COL_COAT_DARK, 0)
	var ear_far := _part(&"ear_far", Vector2(0.585, -1.005), Vector2(0.555, -1.155), 0.062, 0.016, COL_COAT_DARK, 0)
	ear_far.height_scale = 0.30
	ear_far.blend = 0.03
	parts.append_array([fl_far_u, fl_far_l, fl_far_p, bl_far_u, bl_far_l, bl_far_p, ear_far])

	# --- torso --------------------------------------------------------------
	# Four capsules rather than three: a cat's back is not a single tube, it dips
	# behind the shoulder blades and rises again over the hips, and that dip is
	# most of what reads as "cat" in silhouette.
	var rump := _part(&"hip", Vector2(-0.62, -0.705), Vector2(-0.44, -0.735), 0.180, 0.196, COL_COAT)
	rump.blend = 0.11
	var torso := _part(&"torso", Vector2(-0.44, -0.735), Vector2(0.02, -0.728), 0.196, 0.190, COL_COAT)
	torso.blend = 0.12
	var chest := _part(&"chest", Vector2(0.02, -0.728), Vector2(0.26, -0.700), 0.190, 0.163, COL_COAT)
	chest.blend = 0.11
	var belly := _part(&"belly", Vector2(-0.38, -0.560), Vector2(0.10, -0.575), 0.078, 0.072, COL_BELLY)
	belly.blend = 0.10
	belly.coat_length = 1.35
	var neck := _part(&"neck", Vector2(0.26, -0.745), Vector2(0.45, -0.858), 0.128, 0.110, COL_COAT)
	neck.blend = 0.10
	parts.append_array([rump, torso, chest, belly, neck])

	# --- head ---------------------------------------------------------------
	var skull := _part(&"head", Vector2(0.480, -0.902), Vector2(0.620, -0.886), 0.134, 0.127, COL_COAT)
	skull.blend = 0.078
	var cheek := _part(&"cheek", Vector2(0.550, -0.846), Vector2(0.655, -0.845), 0.104, 0.087, COL_COAT)
	cheek.blend = 0.072
	var muzzle := _part(&"muzzle", Vector2(0.658, -0.845), Vector2(0.733, -0.838), 0.061, 0.049, COL_MUZZLE, 2)
	muzzle.blend = 0.045
	muzzle.coat_length = 0.5
	var chin := _part(&"chin", Vector2(0.652, -0.795), Vector2(0.700, -0.796), 0.042, 0.032, COL_BELLY, 2)
	chin.blend = 0.04
	var nose := _part(&"nose", Vector2(0.740, -0.853), Vector2(0.747, -0.849), 0.016, 0.013, COL_NOSE, 2)
	nose.surface = P.Surface.SKIN
	nose.blend = 0.012
	nose.coat_length = 0.0
	parts.append_array([skull, cheek, muzzle, chin, nose])

	# --- near ear -----------------------------------------------------------
	var ear_base := _part(&"ear_near", Vector2(0.500, -1.000), Vector2(0.455, -1.160), 0.068, 0.017, COL_COAT, 2)
	ear_base.height_scale = 0.32
	ear_base.blend = 0.032
	var ear_inner := _part(&"ear_near_inner", Vector2(0.492, -1.015), Vector2(0.462, -1.135), 0.042, 0.010, COL_INNER_EAR, 2)
	ear_inner.height_scale = 0.14
	ear_inner.blend = 0.02
	ear_inner.coat_length = 0.25
	parts.append_array([ear_base, ear_inner])

	# --- near limbs ---------------------------------------------------------
	var fl_u := _part(&"leg_fl_upper", Vector2(0.290, -0.665), Vector2(0.315, -0.400), 0.058, 0.043, COL_COAT, 2)
	var fl_l := _part(&"leg_fl_lower", Vector2(0.315, -0.400), Vector2(0.305, -0.130), 0.041, 0.032, COL_COAT, 2)
	var fl_paw := _part(&"paw_fl", Vector2(0.305, -0.130), Vector2(0.360, -0.032), 0.032, 0.033, COL_COAT, 2)
	fl_paw.blend = 0.03
	var bl_u := _part(&"leg_bl_upper", Vector2(-0.560, -0.680), Vector2(-0.660, -0.440), 0.086, 0.053, COL_COAT, 2)
	bl_u.blend = 0.085
	var bl_l := _part(&"leg_bl_lower", Vector2(-0.660, -0.440), Vector2(-0.520, -0.190), 0.046, 0.034, COL_COAT, 2)
	var bl_paw := _part(&"paw_bl", Vector2(-0.520, -0.190), Vector2(-0.455, -0.032), 0.033, 0.034, COL_COAT, 2)
	bl_paw.blend = 0.03
	parts.append_array([fl_u, fl_l, fl_paw, bl_u, bl_l, bl_paw])

	# --- tail ---------------------------------------------------------------
	var tail_a := _part(&"tail_0", Vector2(-0.630, -0.730), Vector2(-0.790, -0.800), 0.054, 0.046, COL_COAT, 2)
	var tail_b := _part(&"tail_1", Vector2(-0.790, -0.800), Vector2(-0.905, -0.940), 0.046, 0.038, COL_COAT, 2)
	var tail_c := _part(&"tail_2", Vector2(-0.905, -0.940), Vector2(-0.935, -1.090), 0.038, 0.027, COL_COAT_DARK, 2)
	for t in [tail_a, tail_b, tail_c]:
		t.blend = 0.05
		t.coat_length = 1.6
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
		elif id.begins_with("tail"):
			p.baby_length_scale = 0.52
			p.baby_radius_scale = 1.18
		elif id.begins_with("ear"):
			p.baby_radius_scale = 0.80
			p.baby_length_scale = 0.70
		elif id in ["head", "cheek", "muzzle", "chin", "nose"]:
			p.baby_radius_scale = 1.06
		elif id in ["hip", "torso", "chest", "belly"]:
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
	eye_near.center = Vector2(0.606, -0.888)
	eye_near.radius = 0.040
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
	eye_far.center = Vector2(0.502, -0.900)
	eye_far.radius = 0.029
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
