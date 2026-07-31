class_name FoleyLibrary
extends RefCounted

## The physical sounds of a pet living on a desktop.
##
## A desktop pet has a foley problem no other game has: the surfaces are the
## user's own furniture. Walking across a row of icons, along the taskbar and
## up the edge of a window has to sound like three different materials, or the
## illusion that the animal is *on* those things collapses — and that illusion is
## the entire product.
##
## Everything here is quiet by design. Footfalls in particular sit around -30 dB:
## four a second, all day, in a room where someone is working. If you can pick a
## single footstep out while reading email, it is too loud.

## Ledge kind (`core/nav/ledge.gd`) to step recipe. Anything unmapped walks on
## the desk, which is the safest-sounding default.
const SURFACE_STEPS := {
	&"icon": &"step_icon",
	&"taskbar": &"step_taskbar",
	&"window_edge": &"step_glass",
	&"window_top": &"step_glass",
	&"screen_floor": &"step_desk",
}


## What a pet standing on `kind` sounds like when it takes a step.
static func step_for_surface(kind: StringName) -> StringName:
	return SURFACE_STEPS.get(kind, &"step_desk")


static func build(foley_id: StringName, intensity: float,
		rng: RandomNumberGenerator) -> FoleyModel:
	var f := FoleyModel.new()
	var i: float = clampf(intensity, 0.0, 1.0)
	f.priority = AudioVoice.Priority.FOLEY

	match foley_id:
		&"step_icon":
			# A desktop icon is a thin glossy plate. Short, mid-bright, with a
			# small amount of plate ring on top of the pad contact.
			f.dur = 0.05
			f.decay = rng.randf_range(0.028, 0.042)
			f.noise_tilt = 0.55
			f.bp_hz0 = rng.randf_range(1700.0, 2500.0)
			f.bp_hz1 = f.bp_hz0 * 0.55
			f.bp_q = 1.6
			f.ring_hz = rng.randf_range(2900.0, 3600.0)
			f.ring_q = 13.0
			f.ring_amt = 0.22
			f.body_hz0 = rng.randf_range(200.0, 260.0)
			f.body_hz1 = f.body_hz0 * 0.7
			f.body_amt = 0.12
			f.body_decay = 0.03
			f.gain = 0.24
		&"step_taskbar":
			# Wider, denser, damped — a strip with a whole screen behind it.
			f.dur = 0.06
			f.decay = rng.randf_range(0.035, 0.055)
			f.noise_tilt = 0.3
			f.bp_hz0 = rng.randf_range(800.0, 1200.0)
			f.bp_hz1 = f.bp_hz0 * 0.6
			f.bp_q = 1.1
			f.body_hz0 = rng.randf_range(130.0, 170.0)
			f.body_hz1 = f.body_hz0 * 0.72
			f.body_amt = 0.22
			f.body_decay = 0.045
			f.gain = 0.30
		&"step_glass":
			# The edge of a window: bright, hard, and it rings. High Q and a long
			# resonator decay do all the work; the contact noise is almost nothing.
			f.dur = 0.09
			f.decay = rng.randf_range(0.012, 0.022)
			f.release = 0.09
			f.noise_tilt = 0.9
			f.bp_hz0 = rng.randf_range(3200.0, 4200.0)
			f.bp_hz1 = f.bp_hz0 * 0.8
			f.bp_q = 2.4
			f.ring_hz = rng.randf_range(4600.0, 6200.0)
			f.ring_q = 34.0
			f.ring_amt = 0.34
			f.body_amt = 0.0
			f.gain = 0.09
		&"claw", &"claw_tap":
			# Keratin on a hard surface: almost pure high transient, and rarely
			# alone — a cat placing a foot puts down two or three claws.
			f.repeats = rng.randi_range(1, 3)
			f.gap = rng.randf_range(0.026, 0.05)
			f.dur = 0.02
			f.decay = 0.012
			f.release = 0.02
			f.noise_tilt = 0.95
			f.bp_hz0 = rng.randf_range(3800.0, 5200.0)
			f.bp_hz1 = f.bp_hz0 * 0.9
			f.bp_q = 2.8
			f.ring_hz = rng.randf_range(6000.0, 7600.0)
			f.ring_q = 26.0
			f.ring_amt = 0.3
			f.gain = 0.085
		&"land":
			# Scaled by fall height, which arrives as `intensity`. Height buys
			# three things at once: level, low-end weight, and a longer tail —
			# the same three things that tell you how far something fell.
			f.dur = 0.16 + 0.1 * i
			f.decay = rng.randf_range(0.05, 0.075) + 0.05 * i
			f.release = 0.1
			f.noise_tilt = 0.15 + 0.35 * i
			f.bp_hz0 = rng.randf_range(700.0, 1100.0) * lerpf(0.8, 1.5, i)
			f.bp_hz1 = f.bp_hz0 * 0.35
			f.bp_q = 1.0
			f.noise_amt = 0.55 + 0.35 * i
			f.body_hz0 = rng.randf_range(150.0, 190.0) * lerpf(0.85, 1.15, i)
			f.body_hz1 = rng.randf_range(48.0, 62.0)
			f.body_amt = 0.45 + 0.4 * i
			f.body_decay = 0.08 + 0.09 * i
			f.gain = lerpf(0.18, 0.57, i)
		&"flop":
			# A body giving up on standing: soft, low, and mostly fur.
			f.dur = 0.3
			f.attack = 0.006
			f.decay = 0.09
			f.hold = 0.04
			f.release = 0.18
			f.noise_tilt = 0.1
			f.bp_hz0 = rng.randf_range(500.0, 800.0)
			f.bp_hz1 = 240.0
			f.bp_q = 0.9
			f.noise_amt = 0.7
			f.grain_hz = 24.0
			f.grain_depth = 0.35
			f.body_hz0 = rng.randf_range(105.0, 135.0)
			f.body_hz1 = 55.0
			f.body_amt = 0.4
			f.body_decay = 0.11
			f.gain = 0.54
		&"rustle", &"stroke":
			# Fur under a hand. Slow in, slow out, granulated: this one plays
			# while the player is holding still, so any periodicity in it becomes
			# obvious within a second.
			f.dur = rng.randf_range(0.22, 0.4)
			f.attack = 0.06
			f.decay = 0.12
			f.sustain = 0.7
			f.hold = 0.12
			f.release = 0.16
			f.noise_tilt = 0.12
			f.bp_hz0 = rng.randf_range(1600.0, 2600.0)
			f.bp_hz1 = rng.randf_range(600.0, 1000.0)
			f.bp_q = 0.8
			f.grain_hz = rng.randf_range(16.0, 26.0)
			f.grain_depth = 0.55
			f.gain = lerpf(0.12, 0.31, i)
		&"flap", &"wing":
			# Two beats of air. The sweep runs downward through each beat, which
			# is the pressure wave arriving and passing.
			f.repeats = rng.randi_range(2, 3)
			f.gap = rng.randf_range(0.16, 0.22)
			f.dur = 0.1
			f.attack = 0.02
			f.decay = 0.05
			f.hold = 0.03
			f.release = 0.07
			f.repeat_falloff = 0.9
			f.noise_tilt = 0.05
			f.bp_hz0 = rng.randf_range(700.0, 1000.0)
			f.bp_hz1 = rng.randf_range(200.0, 300.0)
			f.bp_q = 0.7
			f.grain_hz = 40.0
			f.grain_depth = 0.25
			f.gain = lerpf(0.23, 0.51, i)
		&"knock":
			# A cat's whole reason for existing: something small leaves a ledge.
			# A hollow tap plus a little grit, and no low end at all — whatever
			# was knocked off has not landed yet.
			f.dur = 0.1
			f.decay = 0.035
			f.release = 0.07
			f.noise_tilt = 0.6
			f.bp_hz0 = rng.randf_range(1500.0, 2200.0)
			f.bp_hz1 = 900.0
			f.bp_q = 1.8
			f.ring_hz = rng.randf_range(700.0, 1100.0)
			f.ring_q = 15.0
			f.ring_amt = 0.28
			f.body_hz0 = rng.randf_range(300.0, 380.0)
			f.body_hz1 = 190.0
			f.body_amt = 0.25
			f.body_decay = 0.06
			f.gain = lerpf(0.34, 0.73, i)
		_:
			# Default step: a pad on a desk. Soft, dark, no ring, barely there.
			f.dur = 0.06
			f.decay = rng.randf_range(0.03, 0.05)
			f.noise_tilt = 0.25
			f.bp_hz0 = rng.randf_range(600.0, 950.0)
			f.bp_hz1 = f.bp_hz0 * 0.5
			f.bp_q = 1.0
			f.body_hz0 = rng.randf_range(95.0, 125.0)
			f.body_hz1 = f.body_hz0 * 0.7
			f.body_amt = 0.2
			f.body_decay = 0.04
			f.gain = 0.28

	# Steps and taps are the only sounds the player hears hundreds of times an
	# hour, so they get the extra variation: a fixed-level footfall reads as a
	# metronome within about ten paces.
	f.gain *= rng.randf_range(0.82, 1.18) * lerpf(0.55, 1.15, i)
	return f
