class_name CallLibrary
extends RefCounted

## Every noise an animal in Petalia can make, as parameters rather than files.
##
## Read this the way you would read a species spec: each call is a short
## description of a real animal behaviour, written in the vocabulary
## `VoiceModel` understands. The numbers are chosen from recordings and from
## listening, not derived — a cat's meow really does start closed and nasal,
## bend up, and open into a rounded vowel, and a dog's bark really is a
## down-chirp with its energy in the first 40 ms.
##
## Two things every recipe must do, because they are what separate a pet from a
## sound effect:
##
##   VARY     Nothing is a constant. Duration, pitch contour, breathiness,
##            formant placement and even the *number of syllables* are drawn
##            fresh every time. The player will hear a given call thousands of
##            times; the tenth identical one is the moment the animal dies.
##   AGE      `baby` is not a pitch shift. A young animal has a shorter tract
##            (formants up), less breath support (shorter calls), and much worse
##            control of its own larynx (jitter and vibrato up). Pitch alone
##            reads as a chipmunk; all four read as a kitten.

## Which call each family reaches for when it is asked for something it does not
## have — a bird told to bark, a reptile told to meow. Silence would be a bug
## report; a plausible noise is not.
const FALLBACK := {
	&"cat": &"meow", &"dog": &"bark", &"bird": &"chirp", &"reptile": &"hiss",
}


static func build(call_id: StringName, family: StringName, hz: float, intensity: float,
		baby: float, timbre: float, rng: RandomNumberGenerator) -> VoiceModel:
	var m := VoiceModel.new()
	m.f0 = maxf(hz, 40.0)
	var fam: StringName = family if FALLBACK.has(family) else &"cat"
	var call: StringName = call_id
	match fam:
		&"dog":     _dog(m, call, rng)
		&"bird":    _bird(m, call, rng)
		&"reptile": _reptile(m, call, rng)
		_:          _cat(m, call, rng)
	_apply_age(m, baby, rng)
	_apply_timbre(m, timbre)
	_apply_intensity(m, intensity)
	return m


# --- Cat ---------------------------------------------------------------------

static func _cat(m: VoiceModel, call: StringName, rng: RandomNumberGenerator) -> void:
	# A cat's tract: a small, strongly nasal tube. F2 falling as the mouth opens
	# is the "ee → ow" glide that makes a meow a meow.
	m.f1_closed = 300.0
	m.f2_closed = 1980.0
	m.f3_closed = 3150.0
	m.f1_open = 900.0
	m.f2_open = 1480.0
	m.f3_open = 2850.0
	m.formant_q = 7.5
	m.pulse_width = 0.26
	m.lp_hz = 5200.0

	match call:
		&"purr":
			# Not a voice at all: a chest rumble chopped at 25 Hz by the larynx.
			# The AM *is* the sound, so the source is deliberately dull and the
			# tremolo does the work. The carrier has to sit well above the
			# tremolo rate — a 25 Hz carrier modulated at 25 Hz beats down to
			# something near DC, which is inaudible, eats headroom, and is the
			# one place in this file where the physics and the arithmetic
			# disagree about what a purr is.
			m.f0 = 88.0 + m.f0 * 0.055 + rng.randf_range(-7.0, 7.0)
			m.voiced = 1.0
			m.pulse_width = 0.42
			m.f1_closed = 170.0
			m.f2_closed = 620.0
			m.f3_closed = 1250.0
			m.f1_open = 260.0
			m.f2_open = 880.0
			m.f3_open = 1500.0
			m.formant_q = 3.2
			m.tract_mix = 0.55
			m.lp_hz = 430.0
			m.lp_open = 1.25
			m.trem_hz = rng.randf_range(23.0, 29.0)
			m.trem_depth = rng.randf_range(0.55, 0.75)
			m.cycle_hz = rng.randf_range(0.75, 1.25)
			m.cycle_depth = rng.randf_range(0.22, 0.38)
			m.breath_gain = 1.4
			m.breath_tilt = 0.15
			m.jitter = 0.02
			m.gain = 0.38
			var s := _syl(0.0, rng.randf_range(1.1, 1.9), 1.0, 1.02, 0.98)
			_mouth(s, 0.35, 0.6, 0.4)
			_shape(s, 0.30, 0.4, 0.95, 0.45)
			s.breath = 0.30
			m.syllables.append(s)
			m.tail = 0.25
		&"hiss":
			# Pure turbulence. No larynx involved, so `voiced` is zero and the
			# tract is wide and high — teeth and tongue, not chest.
			m.voiced = 0.0
			m.breath_tilt = 0.85
			m.breath_gain = 1.0
			m.f1_closed = 1500.0
			m.f2_closed = 3400.0
			m.f3_closed = 5600.0
			m.f1_open = 2300.0
			m.f2_open = 4300.0
			m.f3_open = 6400.0
			m.formant_q = 2.1
			m.formant_gains = Vector3(0.9, 0.8, 0.5)
			m.tract_mix = 0.55
			m.lp_hz = 8500.0
			m.lp_open = 1.1
			m.hp_mix = 0.32
			m.gain = 0.92
			var s := _syl(0.0, rng.randf_range(0.42, 0.78), 1.0, 1.0, 1.0)
			_mouth(s, 0.15, 0.8, 0.55)
			_shape(s, 0.035, 0.14, 0.85, 0.22)
			s.breath = 1.0
			m.syllables.append(s)
		&"yowl":
			# The one call a cat pushes air behind. Strained: the folds start to
			# double their period, which is `sub_amount`.
			m.sub_amount = rng.randf_range(0.08, 0.18)
			m.jitter = 0.03
			m.vibrato_hz = rng.randf_range(5.5, 7.5)
			m.vibrato_depth = 0.045
			m.lp_hz = 6200.0
			m.gain = 1.70
			var dur: float = rng.randf_range(0.75, 1.25)
			var s := _syl(0.0, dur, rng.randf_range(0.66, 0.78), rng.randf_range(1.25, 1.45),
				rng.randf_range(0.82, 0.96))
			_mouth(s, 0.45, 1.0, 0.62)
			_shape(s, 0.06, 0.22, 0.88, 0.28)
			s.breath = 0.16
			m.syllables.append(s)
			m.tail = 0.18
		&"trill", &"mrrp", &"chirp":
			# The rolled greeting: a short rising call with the mouth shut, its
			# roll produced by fluttering the folds rather than the tongue.
			var roll: bool = call != &"chirp"
			m.trem_hz = rng.randf_range(24.0, 34.0)
			m.trem_depth = rng.randf_range(0.42, 0.62) if roll else 0.0
			m.f0 *= rng.randf_range(1.05, 1.3)
			m.pulse_width = 0.2
			m.tract_mix = 0.95
			m.gain = 1.20
			var dur: float = rng.randf_range(0.16, 0.32) if roll else rng.randf_range(0.08, 0.14)
			var s := _syl(0.0, dur, rng.randf_range(0.72, 0.86), rng.randf_range(1.15, 1.35),
				rng.randf_range(1.02, 1.22))
			_mouth(s, 0.2, 0.45, 0.25)
			_shape(s, 0.02, 0.09, 0.8, 0.09)
			s.breath = 0.14
			m.syllables.append(s)
		&"sigh":
			m.voiced = 0.35
			m.breath_gain = 1.5
			m.breath_tilt = 0.25
			m.lp_hz = 2400.0
			m.gain = 0.57
			var s := _syl(0.0, rng.randf_range(0.5, 0.8), 1.02, 0.94, 0.72)
			_mouth(s, 0.6, 0.75, 0.4)
			_shape(s, 0.14, 0.3, 0.7, 0.35)
			s.breath = 0.72
			m.syllables.append(s)
			m.tail = 0.2
		_:
			# Meow. Sometimes it comes out as two syllables — a cat asking twice
			# in one breath — which is most of why real meows never tire.
			m.gain = 0.77
			m.jitter = 0.012
			var dur: float = rng.randf_range(0.30, 0.52)
			var s := _syl(0.0, dur, rng.randf_range(0.82, 0.92), rng.randf_range(1.08, 1.22),
				rng.randf_range(0.68, 0.82))
			_mouth(s, rng.randf_range(0.05, 0.16), rng.randf_range(0.85, 1.0),
				rng.randf_range(0.28, 0.5))
			_shape(s, 0.025, 0.13, 0.82, 0.16)
			s.breath = rng.randf_range(0.07, 0.16)
			if rng.randf() < 0.28:
				var pre := _syl(0.0, dur * 0.32, 0.78, 0.95, 1.0)
				_mouth(pre, 0.12, 0.3, 0.2)
				_shape(pre, 0.02, 0.07, 0.85, 0.05)
				pre.breath = 0.1
				pre.amp = 0.75
				m.syllables.append(pre)
				s.t0 = pre.dur + 0.03
			m.syllables.append(s)
			m.tail = 0.14


# --- Dog ---------------------------------------------------------------------

static func _dog(m: VoiceModel, call: StringName, rng: RandomNumberGenerator) -> void:
	# Longer tract than a cat, more chest in it: lower formants, wider glottal
	# pulse, and a lot less nasal resonance.
	m.f1_closed = 400.0
	m.f2_closed = 1450.0
	m.f3_closed = 2500.0
	m.f1_open = 980.0
	m.f2_open = 1250.0
	m.f3_open = 2350.0
	m.formant_q = 5.5
	m.pulse_width = 0.36
	m.lp_hz = 4200.0

	match call:
		&"whine":
			# Nasal, high, and unstable on purpose: a whine that holds its pitch
			# sounds like a theremin, not an animal asking for something.
			m.f0 *= rng.randf_range(1.5, 1.9)
			m.pulse_width = 0.15
			m.tract_mix = 0.96
			m.formant_q = 8.5
			m.vibrato_hz = rng.randf_range(6.0, 8.5)
			m.vibrato_depth = rng.randf_range(0.03, 0.055)
			m.jitter = 0.022
			m.lp_hz = 3600.0
			m.gain = 1.35
			var n: int = rng.randi_range(1, 2)
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.35, 0.6)
				var s := _syl(t, dur, rng.randf_range(0.86, 0.95), rng.randf_range(1.1, 1.3),
					rng.randf_range(0.9, 1.05))
				_mouth(s, 0.2, 0.42, 0.28)
				_shape(s, 0.07, 0.2, 0.85, 0.18)
				s.breath = 0.12
				s.amp = 1.0 if i == 0 else 0.8
				m.syllables.append(s)
				t += dur + rng.randf_range(0.06, 0.14)
		&"growl":
			# Period-doubled folds plus a 45 Hz rattle. Everything above 1.5 kHz
			# is removed: a growl you hear in the top end reads as a machine.
			m.f0 = maxf(m.f0 * rng.randf_range(0.34, 0.46), 55.0)
			m.sub_amount = rng.randf_range(0.45, 0.65)
			m.trem_hz = rng.randf_range(38.0, 58.0)
			m.trem_depth = rng.randf_range(0.28, 0.45)
			m.cycle_hz = rng.randf_range(0.6, 1.1)
			m.cycle_depth = 0.18
			m.jitter = 0.05
			m.pulse_width = 0.44
			m.f1_closed = 240.0
			m.f2_closed = 780.0
			m.f3_closed = 1600.0
			m.f1_open = 520.0
			m.f2_open = 1050.0
			m.f3_open = 1900.0
			m.formant_q = 4.0
			m.lp_hz = 1500.0
			m.lp_open = 1.3
			m.gain = 0.78
			var s := _syl(0.0, rng.randf_range(0.6, 1.15), 0.98, 1.04, 0.94)
			_mouth(s, 0.25, 0.4, 0.3)
			_shape(s, 0.09, 0.25, 0.9, 0.3)
			s.breath = 0.22
			m.syllables.append(s)
			m.tail = 0.2
		&"pant":
			# Breath only, alternating out and in, swelling over the run. The
			# asymmetry matters: the out-breath is louder and brighter.
			m.voiced = 0.12
			m.breath_gain = 1.25
			m.breath_tilt = 0.35
			m.f0 *= 0.7
			m.formant_q = 2.4
			m.tract_mix = 0.7
			m.lp_hz = 3200.0
			m.cycle_hz = rng.randf_range(0.5, 0.9)
			m.cycle_depth = 0.25
			m.gain = 0.48
			var n: int = rng.randi_range(4, 7)
			var t: float = 0.0
			for i in n:
				var out_breath: bool = i % 2 == 0
				var dur: float = rng.randf_range(0.07, 0.11)
				var s := _syl(t, dur, 1.0, 1.0, 1.0)
				_mouth(s, 0.75 if out_breath else 0.35, 0.9 if out_breath else 0.45, 0.6)
				_shape(s, 0.015, 0.05, 0.7, 0.07)
				s.breath = 1.0
				s.amp = 1.0 if out_breath else 0.55
				m.syllables.append(s)
				t += dur + rng.randf_range(0.05, 0.09)
		&"huff":
			# The happy huff: one voiced puff with the mouth nearly shut. Short
			# enough that it reads as punctuation rather than speech.
			m.voiced = 0.35
			m.breath_gain = 1.2
			m.f0 *= 0.8
			m.lp_hz = 2200.0
			m.gain = 1.05
			var n: int = 1 if rng.randf() < 0.65 else 2
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.09, 0.16)
				var s := _syl(t, dur, 1.05, 0.98, 0.88)
				_mouth(s, 0.5, 0.7, 0.4)
				_shape(s, 0.008, 0.06, 0.55, 0.09)
				s.breath = 0.78
				s.amp = 1.0 if i == 0 else 0.7
				m.syllables.append(s)
				t += dur + 0.08
		&"yelp":
			m.f0 *= rng.randf_range(1.7, 2.1)
			m.jitter = 0.04
			m.lp_hz = 5200.0
			m.gain = 1.30
			var s := _syl(0.0, rng.randf_range(0.09, 0.16), 1.18, 1.05, 0.6)
			_mouth(s, 0.85, 0.7, 0.35)
			_shape(s, 0.004, 0.05, 0.4, 0.1)
			s.breath = 0.2
			m.syllables.append(s)
		_:
			# Bark. One to three, each a hard transient with a falling pitch and
			# a mouth that shuts as it goes — the shut is what stops it sounding
			# like a shout.
			m.sub_amount = rng.randf_range(0.1, 0.22)
			m.jitter = 0.025
			m.lp_open = 2.1
			m.gain = 1.22
			var n: int = 1
			var roll: float = rng.randf()
			if roll > 0.75:
				n = 3
			elif roll > 0.35:
				n = 2
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.13, 0.2)
				var s := _syl(t, dur, rng.randf_range(1.15, 1.35), rng.randf_range(0.95, 1.05),
					rng.randf_range(0.55, 0.7))
				_mouth(s, rng.randf_range(0.8, 0.95), 0.6, rng.randf_range(0.2, 0.35))
				_shape(s, 0.004, 0.055, 0.28, 0.11)
				s.breath = rng.randf_range(0.14, 0.24)
				s.amp = 1.0 if i == 0 else rng.randf_range(0.72, 0.92)
				m.syllables.append(s)
				t += dur + rng.randf_range(0.11, 0.19)


# --- Bird --------------------------------------------------------------------

static func _bird(m: VoiceModel, call: StringName, rng: RandomNumberGenerator) -> void:
	# A syrinx is nearly a pure tone: the interesting content is in how fast the
	# pitch moves, not in the spectrum. So the tract barely participates
	# (`tract_mix` low) and the lowpass keeps only the first harmonic or two.
	m.f1_closed = 2400.0
	m.f2_closed = 3900.0
	m.f3_closed = 5600.0
	m.f1_open = 3000.0
	m.f2_open = 4400.0
	m.f3_open = 6000.0
	m.formant_q = 3.0
	m.pulse_width = 0.45
	m.tract_mix = 0.35
	m.lp_hz = 6800.0
	m.vibrato_hz = 14.0
	m.vibrato_depth = 0.008

	match call:
		&"churr", &"purr", &"trill":
			# The contented, throaty one: low for a bird, heavily fluttered.
			m.f0 *= rng.randf_range(0.34, 0.46)
			m.trem_hz = rng.randf_range(26.0, 38.0)
			m.trem_depth = rng.randf_range(0.5, 0.7)
			m.tract_mix = 0.7
			m.pulse_width = 0.3
			m.lp_hz = 2600.0
			m.gain = 0.36
			var s := _syl(0.0, rng.randf_range(0.35, 0.65), 0.97, 1.05, 0.95)
			_mouth(s, 0.3, 0.55, 0.35)
			_shape(s, 0.05, 0.18, 0.85, 0.16)
			s.breath = 0.3
			m.syllables.append(s)
		&"warble":
			# Six to ten glides, each landing somewhere else. The pitch jumps are
			# drawn per syllable, which is why no two warbles repeat.
			m.gain = 0.50
			var n: int = rng.randi_range(6, 10)
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.05, 0.11)
				var lo: float = rng.randf_range(0.72, 1.0)
				var hi: float = lo * rng.randf_range(1.1, 1.55)
				var s := _syl(t, dur, lo, hi, rng.randf_range(lo, hi))
				_mouth(s, 0.4, 0.7, 0.5)
				_shape(s, 0.006, 0.04, 0.7, 0.05)
				s.breath = 0.06
				s.amp = rng.randf_range(0.7, 1.0)
				m.syllables.append(s)
				t += dur + rng.randf_range(0.015, 0.06)
		&"song":
			# A phrase, not a noise: a three-note motif repeated two or three
			# times with variation, then a flourish. Structure is the only thing
			# that distinguishes birdsong from a bird panicking.
			m.gain = 0.50
			var motif := PackedFloat32Array()
			for i in 3:
				motif.append(rng.randf_range(0.8, 1.45))
			var t: float = 0.0
			var reps: int = rng.randi_range(2, 3)
			for r in reps:
				for i in motif.size():
					var dur: float = rng.randf_range(0.07, 0.13)
					var base: float = motif[i] * rng.randf_range(0.97, 1.03)
					var s := _syl(t, dur, base * 0.92, base, base * rng.randf_range(0.9, 1.08))
					_mouth(s, 0.35, 0.65, 0.45)
					_shape(s, 0.008, 0.05, 0.75, 0.06)
					s.breath = 0.05
					s.amp = rng.randf_range(0.75, 1.0)
					m.syllables.append(s)
					t += dur + rng.randf_range(0.03, 0.07)
				t += rng.randf_range(0.06, 0.14)
			var flourish := _syl(t, rng.randf_range(0.14, 0.24), 1.0, 1.5, 1.2)
			_mouth(flourish, 0.4, 0.8, 0.55)
			_shape(flourish, 0.01, 0.07, 0.7, 0.12)
			flourish.breath = 0.06
			m.syllables.append(flourish)
			m.tail = 0.16
		&"chip", &"alarm":
			# Alarm chips: three to five, hard, high, evenly spaced. Evenness is
			# the alarm signal — everything else a bird does is irregular.
			m.f0 *= rng.randf_range(1.15, 1.35)
			m.tract_mix = 0.45
			m.formant_q = 2.2
			m.gain = 0.76
			var n: int = rng.randi_range(3, 5)
			var gap: float = rng.randf_range(0.075, 0.11)
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.028, 0.045)
				var s := _syl(t, dur, 1.1, 1.25, 0.85)
				_mouth(s, 0.6, 0.8, 0.5)
				_shape(s, 0.003, 0.02, 0.5, 0.035)
				s.breath = 0.22
				m.syllables.append(s)
				t += dur + gap
		&"squawk", &"screech":
			# Harsh: the syrinx overdriven into period doubling and noise. The
			# only bird call with real spectral mess in it.
			m.f0 *= rng.randf_range(0.55, 0.8)
			m.sub_amount = rng.randf_range(0.4, 0.6)
			m.jitter = rng.randf_range(0.05, 0.09)
			m.tract_mix = 0.6
			m.pulse_width = 0.2
			m.lp_hz = 7000.0
			m.gain = 0.72
			var s := _syl(0.0, rng.randf_range(0.22, 0.45), 1.1, 1.0, 0.8)
			_mouth(s, 0.7, 0.9, 0.6)
			_shape(s, 0.006, 0.07, 0.7, 0.14)
			s.breath = 0.32
			m.syllables.append(s)
		_:
			# Chirp: one swooping note, 60 ms, sometimes doubled.
			m.gain = 0.56
			var n: int = 2 if rng.randf() < 0.35 else 1
			var t: float = 0.0
			for i in n:
				var dur: float = rng.randf_range(0.045, 0.085)
				var s := _syl(t, dur, rng.randf_range(0.7, 0.85), rng.randf_range(1.15, 1.4),
					rng.randf_range(0.88, 1.02))
				_mouth(s, 0.45, 0.75, 0.5)
				_shape(s, 0.005, 0.035, 0.72, 0.05)
				s.breath = 0.08
				s.amp = 1.0 if i == 0 else rng.randf_range(0.6, 0.85)
				m.syllables.append(s)
				t += dur + rng.randf_range(0.04, 0.08)


# --- Reptile -----------------------------------------------------------------

static func _reptile(m: VoiceModel, call: StringName, rng: RandomNumberGenerator) -> void:
	# Reptiles have no larynx worth the name. Everything here is air, a resonant
	# throat, or a tongue click, which is why `voiced` stays near zero: a pitched
	# reptile is the fastest way to break the illusion.
	m.voiced = 0.0
	m.breath_gain = 1.0
	m.breath_tilt = 0.55
	m.f1_closed = 900.0
	m.f2_closed = 2300.0
	m.f3_closed = 4200.0
	m.f1_open = 1700.0
	m.f2_open = 3100.0
	m.f3_open = 5000.0
	m.formant_q = 2.0
	m.tract_mix = 0.6
	m.lp_hz = 7000.0

	match call:
		&"click", &"tick":
			# A tongue or jaw click: 25 ms, one sharp resonance, nothing else.
			m.breath_tilt = 0.9
			m.formant_q = 11.0
			m.formant_gains = Vector3(1.0, 0.5, 0.2)
			m.f1_closed = rng.randf_range(1700.0, 2900.0)
			m.f2_closed = m.f1_closed * 2.1
			m.f3_closed = m.f1_closed * 3.4
			m.f1_open = m.f1_closed * 1.15
			m.f2_open = m.f2_closed
			m.f3_open = m.f3_closed
			m.tract_mix = 0.9
			m.hp_mix = 0.25
			m.gain = 2.50
			var n: int = rng.randi_range(1, 3)
			var t: float = 0.0
			for i in n:
				var s := _syl(t, rng.randf_range(0.016, 0.03), 1.0, 1.0, 1.0)
				_mouth(s, 0.2, 0.6, 0.4)
				_shape(s, 0.001, 0.012, 0.15, 0.02)
				s.breath = 1.0
				s.amp = rng.randf_range(0.7, 1.0)
				m.syllables.append(s)
				t += s.dur + rng.randf_range(0.05, 0.13)
		&"chuff", &"huff":
			# A short pressurised cough from the throat. Low, dull, and over
			# before it has a chance to sound like a voice.
			m.breath_tilt = 0.2
			m.f1_closed = 320.0
			m.f2_closed = 900.0
			m.f3_closed = 1800.0
			m.f1_open = 620.0
			m.f2_open = 1250.0
			m.f3_open = 2100.0
			m.formant_q = 2.6
			m.lp_hz = 1400.0
			m.voiced = 0.18
			m.f0 = maxf(m.f0 * 0.4, 60.0)
			m.gain = 0.85
			var n: int = 1 if rng.randf() < 0.7 else 2
			var t: float = 0.0
			for i in n:
				var s := _syl(t, rng.randf_range(0.11, 0.19), 1.0, 0.96, 0.9)
				_mouth(s, 0.7, 0.85, 0.45)
				_shape(s, 0.006, 0.045, 0.5, 0.08)
				s.breath = 0.92
				s.amp = 1.0 if i == 0 else 0.7
				m.syllables.append(s)
				t += s.dur + rng.randf_range(0.09, 0.16)
		&"puff", &"throat_puff":
			# The throat pouch inflating: a slow swell of low air with no attack
			# at all. It should be felt more than heard.
			m.breath_tilt = 0.1
			m.f1_closed = 260.0
			m.f2_closed = 700.0
			m.f3_closed = 1400.0
			m.f1_open = 480.0
			m.f2_open = 950.0
			m.f3_open = 1700.0
			m.formant_q = 3.4
			m.lp_hz = 950.0
			m.gain = 0.45
			var s := _syl(0.0, rng.randf_range(0.22, 0.38), 1.0, 1.0, 1.0)
			_mouth(s, 0.25, 0.7, 0.85)
			_shape(s, 0.11, 0.16, 0.9, 0.16)
			s.breath = 1.0
			m.syllables.append(s)
			m.tail = 0.14
		_:
			# Hiss: longer and lower than a cat's, and it swells rather than
			# snapping — a snake has a lot more air to spend.
			m.breath_tilt = rng.randf_range(0.5, 0.7)
			m.formant_gains = Vector3(0.95, 0.75, 0.45)
			m.hp_mix = 0.22
			m.lp_hz = 7600.0
			m.gain = 0.92
			var s := _syl(0.0, rng.randf_range(0.7, 1.35), 1.0, 1.0, 1.0)
			_mouth(s, 0.1, 0.75, 0.5)
			_shape(s, 0.13, 0.25, 0.9, 0.3)
			s.breath = 1.0
			m.syllables.append(s)
			m.tail = 0.18


# --- Global modifiers --------------------------------------------------------

## Age. Four separate consequences of one number, none of which is a pitch
## shift — the caller already handled pitch through `spec.baby_voice_scale`.
static func _apply_age(m: VoiceModel, baby: float, rng: RandomNumberGenerator) -> void:
	if baby <= 0.001:
		return
	# A shorter tract puts every resonance up.
	m.formant_scale *= lerpf(1.0, 1.38, baby)
	# And a larynx that cannot hold a note yet wanders.
	m.jitter = m.jitter * lerpf(1.0, 2.4, baby) + 0.012 * baby
	m.vibrato_depth *= lerpf(1.0, 1.9, baby)
	m.vibrato_hz *= lerpf(1.0, 1.25, baby)
	m.drift_depth *= lerpf(1.0, 1.7, baby)
	# Less breath support: everything is shorter and less even.
	var k: float = lerpf(1.0, rng.randf_range(0.6, 0.78), baby)
	for s in m.syllables:
		s.t0 *= k
		s.dur *= k
		s.attack *= k
		s.decay *= k
		s.release *= k
		s.amp *= rng.randf_range(0.88, 1.0)
	m.tail *= k


## `spec.voice_timbre`: 0 breathy and airy, 1 nasal and buzzy. Applied as a
## multiplier on whatever the recipe chose, so a hiss stays a hiss.
static func _apply_timbre(m: VoiceModel, timbre: float) -> void:
	var t: float = clampf(timbre, 0.0, 1.0)
	m.pulse_width = clampf(m.pulse_width * lerpf(1.35, 0.62, t), 0.06, 0.9)
	m.breath_gain *= lerpf(1.3, 0.72, t)
	m.formant_q *= lerpf(0.8, 1.35, t)
	m.tract_mix = clampf(m.tract_mix * lerpf(0.85, 1.12, t), 0.0, 1.0)


## Intensity in [0, 1]: how much the animal means it. Louder, brighter, longer,
## and less controlled — the same four things that change in a real animal when
## it stops being polite.
static func _apply_intensity(m: VoiceModel, intensity: float) -> void:
	var i: float = clampf(intensity, 0.0, 1.0)
	m.gain *= lerpf(0.42, 1.0, i)
	m.lp_hz *= lerpf(0.72, 1.3, i)
	m.jitter *= lerpf(0.75, 1.5, i)
	m.f0 *= lerpf(0.94, 1.07, i)
	for s in m.syllables:
		s.dur *= lerpf(0.86, 1.12, i)
		s.t0 *= lerpf(0.86, 1.12, i)


# --- Syllable helpers --------------------------------------------------------

static func _syl(t0: float, dur: float, a: float, b: float, c: float) -> VoiceModel.Syl:
	var s := VoiceModel.Syl.new()
	s.t0 = t0
	s.dur = dur
	s.a = a
	s.b = b
	s.c = c
	return s


static func _mouth(s: VoiceModel.Syl, a: float, b: float, c: float) -> void:
	s.open_a = a
	s.open_b = b
	s.open_c = c


static func _shape(s: VoiceModel.Syl, attack: float, decay: float, sustain: float,
		release: float) -> void:
	s.attack = attack
	s.decay = decay
	s.sustain = sustain
	s.release = release
