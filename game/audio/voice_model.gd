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

var _osc := AudioDSP.Osc.new()
var _sub := AudioDSP.Osc.new()
var _noise := AudioDSP.NoiseGen.new()
var _tract := AudioDSP.FormantBank.new()
var _filter := AudioDSP.SVF.new()
var _env := AudioDSP.ADSR.new()
var _vib := AudioDSP.LFO.new()
var _trem := AudioDSP.LFO.new()
var _cyc := AudioDSP.LFO.new()
var _drift := AudioDSP.LFO.new()

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
	_filter.reset()
	# Every oscillator starts at a different point in its cycle, otherwise two
	# calls that overlap phase-cancel each other's fundamental.
	var s: int = int(f0 * 977.0) ^ int(_end * 7919.0)
	_noise.seed_with(s * 2654435761)
	_osc.reset(fposmod(float(s) * 0.618034, 1.0))
	_sub.reset(0.5)
	_osc.width = pulse_width
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
		var vsub: float = sub_amount
		var vmix: float = _voiced_amp
		var bmix: float = _breath
		var tilt: float = breath_tilt
		var tmix: float = tract_mix
		var hmix: float = hp_mix
		for k in n:
			var src: float = 0.0
			if vmix > 0.0:
				src = _osc.pulse() * vmix
				if vsub > 0.0:
					src += _sub.saw() * vsub * vmix
			if bmix > 0.0:
				# One generator, two colours: pink for anything that came out of
				# a chest, white for turbulence at the teeth.
				src += _noise.tilted(tilt) * bmix
			var shaped: float = _tract.process(src)
			var v: float = lerpf(src, shaped, tmix)
			_filter.process(v)
			v = _filter.lp if hmix <= 0.0 else lerpf(_filter.lp, _filter.hp, hmix)
			v = AudioDSP.soft_clip(v * _amp)
			var idx: int = i + k
			left[idx] += v * _gl
			right[idx] += v * _gr
			_amp += step
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
	_osc.set_hz(_pitch, _sr)
	_osc.width = clampf(pulse_width + jit * 0.05, 0.05, 0.9)
	if sub_amount > 0.0:
		_sub.set_hz(_pitch * 0.5, _sr)

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
	_filter.set_params(lp_hz * lerpf(1.0, lp_open, env), lp_q, _sr)

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
