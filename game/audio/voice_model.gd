class_name VoiceModel
extends AudioVoice

## One vocalisation: a source, a vocal tract, and a story about how both move.
##
## The model is a deliberately shallow caricature of how an animal actually makes
## a sound, because that is the level at which it stays controllable:
##
##   SOURCE   A band-limited pulse train stands in for the glottis, plus an
##            optional half-rate sub-oscillator (the vocal-fold irregularity you
##            hear as a growl) and a noise generator (breath, and the whole of a
##            hiss). `voiced` and `breath` cross-fade between them.
##   TRACT    Two or three formants. Their centres move as the mouth opens,
##            which is not a decoration: "mee-ow" *is* a formant sweep. Play the
##            same source with a static tract and you get a synthesiser tone.
##   STORY    A list of syllables, each with its own pitch arc, mouth arc and
##            envelope. One syllable is a meow; five short ones are a pant; a
##            dozen glides are a bird's song phrase.
##
## Every field is set per utterance by `CallLibrary` with fresh randomisation.
## Nothing here is a constant that would make two meows the same meow — that is
## the entire reason the game synthesises audio instead of shipping four wav
## files and hoping nobody notices by Tuesday.

## One unit of utterance. Pitch runs as a quadratic through three multipliers of
## `f0`, which is the cheapest curve that can rise-then-fall — and rise-then-fall
## is what almost every animal call does.
class Syl:
	var t0: float = 0.0
	var dur: float = 0.22
	var a: float = 1.0
	var b: float = 1.12
	var c: float = 0.86
	var amp: float = 1.0
	## Mouth openness through the syllable, in [0, 1], on the same quadratic as
	## the pitch. "Mee-ow" needs all three points: closed, open, rounded.
	var open_a: float = 0.25
	var open_b: float = 0.85
	var open_c: float = 0.5
	## Noise mixed into the source for this syllable.
	var breath: float = 0.12
	var attack: float = 0.018
	var decay: float = 0.10
	var sustain: float = 0.78
	var release: float = 0.10

# --- Source ------------------------------------------------------------------

var f0: float = 420.0
## Cross-fade between the glottal pulse and the noise generator.
var voiced: float = 1.0
var breath_gain: float = 1.0
## 0 = pink (breath, fur, room), 1 = white (a sharp hiss).
var breath_tilt: float = 0.4
## Duty cycle of the glottal pulse. Narrow is bright and nasal; a cat is around
## 0.22, a dog's chest is nearer 0.4.
var pulse_width: float = 0.28
## Half-frequency oscillator. Vocal folds that cannot hold a regular cycle drop
## to period doubling — that is what a growl physically is.
var sub_amount: float = 0.0

# --- Tract -------------------------------------------------------------------

var f1_closed: float = 340.0
var f2_closed: float = 2100.0
var f3_closed: float = 3200.0
var f1_open: float = 820.0
var f2_open: float = 1300.0
var f3_open: float = 2700.0
var formant_q: float = 7.0
## Scales the whole tract. A smaller head has a shorter tube and higher formants,
## which is most of why a kitten sounds like a kitten even at the same pitch.
var formant_scale: float = 1.0
var formant_gains := Vector3(1.0, 0.65, 0.3)
## How much of the signal goes through the tract. A hiss keeps some raw noise so
## it stays broadband instead of turning into three whistles.
var tract_mix: float = 0.85

# --- Filter ------------------------------------------------------------------

var lp_hz: float = 4200.0
## Cutoff multiplier at full envelope: loud calls open up, quiet ones stay dark.
var lp_open: float = 1.6
var lp_q: float = 0.9
## Blend toward the highpass output of the same filter, for thin airy calls.
var hp_mix: float = 0.0

# --- Modulation --------------------------------------------------------------

var vibrato_hz: float = 5.5
var vibrato_depth: float = 0.012
## Fast pitch instability. Babies and distressed animals have a lot of it; a
## contented adult almost none. This is the single most effective knob for
## "young" and for "means it".
var jitter: float = 0.006
## Amplitude modulation. At 25 Hz this is a purr; at 40 Hz a growl's rattle; at
## 6 Hz a warble's flutter.
var trem_hz: float = 0.0
var trem_depth: float = 0.0
## A slower breathing cycle over the top: a purr fades between inhale and
## exhale, and a pant swells and drops across a run of syllables.
var cycle_hz: float = 0.0
var cycle_depth: float = 0.0
## Slow drift applied to the formants, so a long call never sits still.
var drift_hz: float = 1.7
var drift_depth: float = 0.06

var syllables: Array[Syl] = []
## Tail after the last syllable's release, so the room has something to ring on.
var tail: float = 0.12

## The vocal tract stays an object: it is already unrolled internally, it is the
## one part of the voice with a name a reader would recognise, and it is set up
## once per block like everything else here.
var _tract := AudioDSP.FormantBank.new()
var _env := AudioDSP.ADSR.new()
var _vib := AudioDSP.LFO.new()
var _trem := AudioDSP.LFO.new()
var _cyc := AudioDSP.LFO.new()
var _drift := AudioDSP.LFO.new()

## The glottal pulse, its sub-oscillator, the breath generator and the output
## filter, held as bare state rather than as `AudioDSP` objects.
##
## Those four run once per sample per voice, four voices deep, on the main
## thread, in GDScript — and a method call there measured as costing about as
## much as the arithmetic inside it. So the render loop inlines all four and
## keeps their state in locals for the length of a block. The arithmetic is
## `Osc.pulse`, `Osc.saw`, `NoiseGen.tilted` and `SVF.process` verbatim; if you
## change one, change both. The tract is the exception above, and the envelopes
## and LFOs are updated per block, so they stay objects too.
var _osc_phase: float = 0.0
var _osc_inc: float = 0.0
var _osc_width: float = 0.28
var _sub_phase: float = 0.5
var _sub_inc: float = 0.0
var _nz_state: int = 0x9E3779B9
var _nz_b0: float = 0.0
var _nz_b1: float = 0.0
var _nz_b2: float = 0.0
var _nz_p: float = 0.0
var _nz_hp: float = 0.0
var _flt_s1: float = 0.0
var _flt_s2: float = 0.0
var _flt_a1: float = 0.0
var _flt_a2: float = 0.0
var _flt_a3: float = 0.0
var _flt_k: float = 1.0

var _t: float = 0.0
var _end: float = 0.6
var _syl: int = -1
var _gated: bool = false
var _amp: float = 0.0
var _amp_target: float = 0.0
var _pitch: float = 420.0
var _breath: float = 0.0
var _voiced_amp: float = 1.0
var _done: bool = false


func setup(sample_rate: float) -> void:
	super.setup(sample_rate)
	if syllables.is_empty():
		syllables.append(Syl.new())
	var last: Syl = syllables[syllables.size() - 1]
	_end = last.t0 + last.dur + last.release + tail
	_tract.g1 = formant_gains.x
	_tract.g2 = formant_gains.y
	_tract.g3 = formant_gains.z
	# The third formant is what makes a voice sound like a specific animal, but a
	# 60 ms chirp is over before it can matter. Skipping it there buys a third of
	# the tract cost on exactly the calls that fire most often.
	_tract.use_third = _end > 0.14 and fidelity >= 0.75
	if fidelity < 0.75:
		sub_amount = 0.0
	_tract.reset()
	_flt_s1 = 0.0
	_flt_s2 = 0.0
	# Every oscillator starts at a different point in its cycle, otherwise two
	# calls that overlap phase-cancel each other's fundamental.
	var s: int = int(f0 * 977.0) ^ int(_end * 7919.0)
	# Zero is a fixed point of xorshift; force a live state, as `NoiseGen` does.
	_nz_state = ((s * 2654435761) & 0xFFFFFFFF) | 1
	_nz_b0 = 0.0
	_nz_b1 = 0.0
	_nz_b2 = 0.0
	_nz_p = 0.0
	_nz_hp = 0.0
	_osc_phase = fposmod(float(s) * 0.618034, 1.0)
	_sub_phase = 0.5
	_osc_width = pulse_width
	_vib.shape = AudioDSP.LFO.Shape.SINE
	_vib.hz = vibrato_hz
	_vib.reset(0.0, s | 1)
	_trem.shape = AudioDSP.LFO.Shape.SINE
	_trem.hz = trem_hz
	_trem.reset(0.0, (s * 3) | 1)
	_cyc.shape = AudioDSP.LFO.Shape.SINE
	_cyc.hz = cycle_hz
	_cyc.reset(0.75, (s * 5) | 1)
	# Formant drift is a random walk rather than a sine: a mouth that wobbles
	# periodically sounds like a machine imitating an animal.
	_drift.shape = AudioDSP.LFO.Shape.RANDOM
	_drift.hz = drift_hz
	_drift.reset(0.0, (s * 7) | 1)
	_env.hard_reset()


func is_finished() -> bool:
	return _done


func max_seconds() -> float:
	return _end + 0.5


func render_add(left: PackedFloat32Array, right: PackedFloat32Array, count: int) -> void:
	if _done:
		return
	var i: int = 0
	while i < count:
		var n: int = mini(AudioDSP.BLOCK, count - i)
		_update_block(float(n) / _sr)
		var step: float = (_amp_target - _amp) / float(n)
		var vsub: float = sub_amount * _voiced_amp
		var vmix: float = _voiced_amp
		var bmix: float = _breath
		var tilt: float = breath_tilt
		var tmix: float = tract_mix
		var hmix: float = hp_mix
		# State into locals for the length of the block; back out at the end.
		var ph: float = _osc_phase
		var inc: float = _osc_inc
		var pw: float = _osc_width
		var sph: float = _sub_phase
		var sinc: float = _sub_inc
		var ns: int = _nz_state
		var nb0: float = _nz_b0
		var nb1: float = _nz_b1
		var nb2: float = _nz_b2
		var np: float = _nz_p
		var nhp: float = _nz_hp
		var fs1: float = _flt_s1
		var fs2: float = _flt_s2
		var fa1: float = _flt_a1
		var fa2: float = _flt_a2
		var fa3: float = _flt_a3
		var fk: float = _flt_k
		var amp: float = _amp
		var gl: float = _gl
		var gr: float = _gr
		for k in n:
			var src: float = 0.0
			if vmix > 0.0:
				# The glottal pulse, band-limited on both edges, with the duty
				# cycle's DC removed. `AudioDSP.Osc.pulse`, inlined.
				var pv: float = 1.0 if ph < pw else -1.0
				if ph < inc:
					var a: float = ph / inc
					pv += a + a - a * a - 1.0
				elif ph > 1.0 - inc:
					var a2: float = (ph - 1.0) / inc
					pv += a2 * a2 + a2 + a2 + 1.0
				var e: float = ph - pw
				if e < 0.0:
					e += 1.0
				if e < inc:
					var b: float = e / inc
					pv -= b + b - b * b - 1.0
				elif e > 1.0 - inc:
					var b2: float = (e - 1.0) / inc
					pv -= b2 * b2 + b2 + b2 + 1.0
				ph += inc
				if ph >= 1.0:
					ph -= 1.0
				src = (pv - (2.0 * pw - 1.0)) * vmix
				if vsub > 0.0:
					# Half-rate saw: the period doubling that is a growl.
					var sv: float = 2.0 * sph - 1.0
					if sph < sinc:
						var c: float = sph / sinc
						sv -= c + c - c * c - 1.0
					elif sph > 1.0 - sinc:
						var c2: float = (sph - 1.0) / sinc
						sv -= c2 * c2 + c2 + c2 + 1.0
					sph += sinc
					if sph >= 1.0:
						sph -= 1.0
					src += sv * vsub
			if bmix > 0.0:
				# One generator, two colours: pink for anything that came out of
				# a chest, white for turbulence at the teeth.
				ns ^= (ns << 13) & 0xFFFFFFFF
				ns ^= ns >> 17
				ns ^= (ns << 5) & 0xFFFFFFFF
				ns &= 0xFFFFFFFF
				var wn: float = float(ns) * (2.0 / 4294967295.0) - 1.0
				nb0 = 0.99765 * nb0 + wn * 0.0990460
				nb1 = 0.96300 * nb1 + wn * 0.2965164
				nb2 = 0.57000 * nb2 + wn * 1.0526913
				var pk: float = (nb0 + nb1 + nb2 + wn * 0.1848) * 0.32
				nhp = pk - np + 0.99 * nhp
				np = pk
				src += (nhp + (wn - nhp) * tilt) * bmix
			var v: float = src + (_tract.process(src) - src) * tmix
			# The output filter, `AudioDSP.SVF.process` inlined. Both responses
			# come out of the same two state words, which is why a thin airy call
			# can blend toward the highpass without a second filter.
			var d: float = v - fs2
			var v1: float = fa1 * fs1 + fa2 * d
			var v2: float = fs2 + fa2 * fs1 + fa3 * d
			fs1 = 2.0 * v1 - fs1
			fs2 = 2.0 * v2 - fs2
			if hmix > 0.0:
				var hp: float = v - fk * v1 - v2
				v = (v2 + (hp - v2) * hmix) * amp
			else:
				v = v2 * amp
			# `AudioDSP.soft_clip`, inlined. In range is the case that happens.
			if v >= -3.0 and v <= 3.0:
				var q: float = v * v
				v = v * (27.0 + q) / (27.0 + 9.0 * q)
			elif v > 3.0:
				v = 1.0
			elif v < -3.0:
				v = -1.0
			else:
				v = 0.0
			var idx: int = i + k
			left[idx] += v * gl
			right[idx] += v * gr
			amp += step
		_osc_phase = ph
		_sub_phase = sph
		_nz_state = ns
		_nz_b0 = nb0
		_nz_b1 = nb1
		_nz_b2 = nb2
		_nz_p = np
		_nz_hp = nhp
		_flt_s1 = fs1
		_flt_s2 = fs2
		_amp = _amp_target
		i += n
	elapsed += float(count) / _sr
	if _t >= _end or (elapsed > max_seconds()):
		_done = true


## Everything that moves slowly, once per 1.5 ms. Ordered the way the sound is
## built: pick the syllable, place the pitch, open the mouth, set the level.
func _update_block(dt: float) -> void:
	_t += dt

	# --- Syllable scheduling ---
	var idx: int = _syl
	var active: Syl = null
	for j in syllables.size():
		var s: Syl = syllables[j]
		if _t >= s.t0 and _t < s.t0 + s.dur:
			active = s
			idx = j
			break
	if active != null and idx != _syl:
		_syl = idx
		_env.attack = active.attack
		_env.decay = active.decay
		_env.sustain = active.sustain
		_env.release = active.release
		_env.gate_on()
		_gated = true
	elif active == null and _gated:
		_env.gate_off()
		_gated = false

	var cur: Syl = active
	if cur == null:
		cur = syllables[clampi(_syl, 0, syllables.size() - 1)]
	var u: float = clampf((_t - cur.t0) / maxf(cur.dur, 0.001), 0.0, 1.0)

	# --- Pitch: quadratic through a, b, c, plus the things that make it alive ---
	var ab: float = lerpf(cur.a, cur.b, u)
	var bc: float = lerpf(cur.b, cur.c, u)
	var mult: float = lerpf(ab, bc, u)
	var vib: float = _vib.process(dt)
	var jit: float = _drift.process(dt)
	_pitch = f0 * mult * (1.0 + vib * vibrato_depth + jit * jitter)
	# `Osc.set_hz`: cycles per sample, held below Nyquist.
	_osc_inc = clampf(_pitch / _sr, 0.0, 0.45)
	_osc_width = clampf(pulse_width + jit * 0.05, 0.05, 0.9)
	if sub_amount > 0.0:
		_sub_inc = clampf(_pitch * 0.5 / _sr, 0.0, 0.45)

	# --- Tract ---
	var oab: float = lerpf(cur.open_a, cur.open_b, u)
	var obc: float = lerpf(cur.open_b, cur.open_c, u)
	var open: float = clampf(lerpf(oab, obc, u) + jit * drift_depth, 0.0, 1.0)
	var sc: float = formant_scale * (1.0 + jit * drift_depth * 0.5)
	_tract.set_formants(
		lerpf(f1_closed, f1_open, open) * sc,
		lerpf(f2_closed, f2_open, open) * sc,
		lerpf(f3_closed, f3_open, open) * sc,
		formant_q, _sr)

	var env: float = _env.process(dt)
	var c: Vector3 = AudioDSP.tpt_coeffs(lp_hz * lerpf(1.0, lp_open, env), lp_q, _sr)
	_flt_a1 = c.x
	_flt_a2 = c.y
	_flt_a3 = c.z
	_flt_k = 1.0 / maxf(lp_q, 0.05)

	# --- Level ---
	var amp: float = env * cur.amp
	if trem_depth > 0.0:
		amp *= 1.0 - trem_depth + trem_depth * (0.5 + 0.5 * _trem.process(dt))
	if cycle_depth > 0.0:
		amp *= 1.0 - cycle_depth + cycle_depth * (0.5 + 0.5 * _cyc.process(dt))
	_amp_target = amp * gain
	_breath = cur.breath * breath_gain
	_voiced_amp = voiced * (1.0 - cur.breath * 0.55)
	if fading_out:
		# The mixer wants this voice gone. Ramp rather than cut: a stolen voice
		# that clicks is worse than the pile-up that caused the theft.
		gain *= 0.72
		if gain < 0.002:
			_done = true
