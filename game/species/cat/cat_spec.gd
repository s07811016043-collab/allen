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

	# --- far-side limbs (drawn behind the torso) ----------------------------
	var fl_far_u := _part(&"leg_fl_far_upper", Vector2(0.10, -0.52), Vector2(0.12, -0.28), 0.052, 0.040, COL_COAT_DARK, 0)
	var fl_far_l := _part(&"leg_fl_far_lower", Vector2(0.12, -0.28), Vector2(0.14, -0.03), 0.038, 0.030, COL_COAT_DARK, 0)
	var bl_far_u := _part(&"leg_bl_far_upper", Vector2(-0.24, -0.50), Vector2(-0.30, -0.27), 0.075, 0.048, COL_COAT_DARK, 0)
	var bl_far_l := _part(&"leg_bl_far_lower", Vector2(-0.30, -0.27), Vector2(-0.22, -0.03), 0.042, 0.031, COL_COAT_DARK, 0)
	var ear_far := _part(&"ear_far", Vector2(0.40, -0.86), Vector2(0.36, -1.02), 0.062, 0.016, COL_COAT_DARK, 0)
	ear_far.height_scale = 0.30
	ear_far.blend = 0.03
	parts.append_array([fl_far_u, fl_far_l, bl_far_u, bl_far_l, ear_far])

	# --- torso --------------------------------------------------------------
	var hip := _part(&"hip", Vector2(-0.28, -0.55), Vector2(-0.14, -0.57), 0.165, 0.175, COL_COAT)
	hip.blend = 0.10
	var torso := _part(&"torso", Vector2(-0.16, -0.57), Vector2(0.12, -0.58), 0.175, 0.160, COL_COAT)
	torso.blend = 0.11
	var chest := _part(&"chest", Vector2(0.10, -0.58), Vector2(0.20, -0.53), 0.155, 0.130, COL_COAT)
	chest.blend = 0.10
	var belly := _part(&"belly", Vector2(-0.14, -0.44), Vector2(0.10, -0.45), 0.075, 0.070, COL_BELLY)
	belly.blend = 0.09
	belly.coat_length = 1.3
	var neck := _part(&"neck", Vector2(0.19, -0.60), Vector2(0.30, -0.71), 0.115, 0.105, COL_COAT)
	neck.blend = 0.09
	parts.append_array([hip, torso, chest, belly, neck])

	# --- head ---------------------------------------------------------------
	var skull := _part(&"head", Vector2(0.31, -0.75), Vector2(0.41, -0.74), 0.128, 0.122, COL_COAT)
	skull.blend = 0.075
	var cheek_l := _part(&"cheek", Vector2(0.36, -0.70), Vector2(0.44, -0.70), 0.096, 0.082, COL_COAT)
	cheek_l.blend = 0.07
	var muzzle := _part(&"muzzle", Vector2(0.44, -0.70), Vector2(0.505, -0.695), 0.062, 0.050, COL_MUZZLE, 2)
	muzzle.blend = 0.045
	muzzle.coat_length = 0.5
	var chin := _part(&"chin", Vector2(0.44, -0.655), Vector2(0.48, -0.655), 0.042, 0.032, COL_BELLY, 2)
	chin.blend = 0.04
	var nose := _part(&"nose", Vector2(0.512, -0.706), Vector2(0.519, -0.702), 0.016, 0.013, COL_NOSE, 2)
	nose.surface = P.Surface.SKIN
	nose.blend = 0.012
	nose.coat_length = 0.0
	parts.append_array([skull, cheek_l, muzzle, chin, nose])

	# --- near ear -----------------------------------------------------------
	var ear_base := _part(&"ear_near", Vector2(0.33, -0.85), Vector2(0.285, -1.01), 0.066, 0.017, COL_COAT, 2)
	ear_base.height_scale = 0.32
	ear_base.blend = 0.032
	var ear_inner := _part(&"ear_near_inner", Vector2(0.322, -0.865), Vector2(0.292, -0.985), 0.040, 0.010, COL_INNER_EAR, 2)
	ear_inner.height_scale = 0.14
	ear_inner.blend = 0.02
	ear_inner.coat_length = 0.25
	parts.append_array([ear_base, ear_inner])

	# --- near limbs ---------------------------------------------------------
	var fl_u := _part(&"leg_fl_upper", Vector2(0.13, -0.52), Vector2(0.16, -0.28), 0.056, 0.042, COL_COAT, 2)
	var fl_l := _part(&"leg_fl_lower", Vector2(0.16, -0.28), Vector2(0.18, -0.035), 0.040, 0.031, COL_COAT, 2)
	var fl_paw := _part(&"paw_fl", Vector2(0.175, -0.035), Vector2(0.215, -0.030), 0.034, 0.030, COL_COAT, 2)
	fl_paw.blend = 0.03
	var bl_u := _part(&"leg_bl_upper", Vector2(-0.22, -0.50), Vector2(-0.28, -0.27), 0.082, 0.052, COL_COAT, 2)
	bl_u.blend = 0.08
	var bl_l := _part(&"leg_bl_lower", Vector2(-0.28, -0.27), Vector2(-0.20, -0.035), 0.045, 0.033, COL_COAT, 2)
	var bl_paw := _part(&"paw_bl", Vector2(-0.205, -0.035), Vector2(-0.165, -0.030), 0.036, 0.031, COL_COAT, 2)
	bl_paw.blend = 0.03
	parts.append_array([fl_u, fl_l, fl_paw, bl_u, bl_l, bl_paw])

	# --- tail ---------------------------------------------------------------
	var tail_a := _part(&"tail_0", Vector2(-0.30, -0.58), Vector2(-0.44, -0.66), 0.052, 0.045, COL_COAT, 2)
	var tail_b := _part(&"tail_1", Vector2(-0.44, -0.66), Vector2(-0.55, -0.80), 0.045, 0.038, COL_COAT, 2)
	var tail_c := _part(&"tail_2", Vector2(-0.55, -0.80), Vector2(-0.57, -0.96), 0.038, 0.028, COL_COAT_DARK, 2)
	for t in [tail_a, tail_b, tail_c]:
		t.blend = 0.05
		t.coat_length = 1.6
	parts.append_array([tail_a, tail_b, tail_c])

	# Baby proportions: bigger head, shorter limbs, stubbier tail.
	for p in parts:
		var id := String(p.id)
		if id.begins_with("leg") or id.begins_with("paw"):
			p.baby_length_scale = 0.62
			p.baby_radius_scale = 1.12
		elif id.begins_with("tail"):
			p.baby_length_scale = 0.55
			p.baby_radius_scale = 1.25
		elif id.begins_with("ear"):
			p.baby_radius_scale = 0.86
			p.baby_length_scale = 0.7
		elif id in ["head", "cheek", "muzzle", "chin", "nose"]:
			p.baby_radius_scale = 1.30
		else:
			p.baby_radius_scale = 1.06

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
	eye_near.center = Vector2(0.408, -0.762)
	eye_near.radius = 0.036
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
	eye_far.center = Vector2(0.318, -0.775)
	eye_far.radius = 0.026
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
