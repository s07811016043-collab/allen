class_name AudioDSP
extends RefCounted

## Sample-level building blocks for the runtime synthesiser.
##
## Petalia ships no audio files, so every sound the player hears is built here
## one float at a time, in GDScript. That constraint shapes the whole file: the
## mixer runs these primitives 22 050 times a second per voice, inside the frame
## budget of a program that is supposed to be invisible on someone's desktop.
##
## Two rules keep that affordable, and both are load-bearing:
##
##   CONTROL RATE  Anything that can be computed once per block — envelopes,
##                 filter coefficients, LFOs, pitch contours — is not computed
##                 per sample. `VoiceModel` updates those every `BLOCK` samples
##                 and ramps the result across the block, which is inaudible at
##                 1.5 ms and roughly halves the cost of a voice.
##   NO GARBAGE    No primitive allocates while it runs. Buffers are sized once
##                 at construction; the render path only writes into them.
##
## Anti-aliasing matters more here than in a music synth. A cat's yowl sweeps
## across an octave in a third of a second, and a naive saw sweeping like that
## turns into a shower of aliased partials sliding the *wrong* way — the single
## most obvious "cheap synth" tell there is. Hence PolyBLEP on every edge.

## Samples between control updates. 32 at 22 kHz is 1.45 ms: fast enough that a
## plosive attack still lands on the right sample, slow enough to pay for the
## trigonometry in a filter coefficient only 690 times a second.
const BLOCK := 32


## Band-limited oscillator.
##
## PolyBLEP subtracts a two-sample polynomial approximation of a band-limited
## step at each discontinuity. It is not perfect — a real BLEP table is better —
## but it costs two branches and kills the top ~40 dB of aliasing, which is the
## difference between "an animal" and "a 1980s toy".
class Osc:
	var phase: float = 0.0
	## Cycles per sample. Clamped below Nyquist by `set_hz`.
	var inc: float = 0.0
	## Duty cycle for `pulse`. 0.5 is a square; 0.1 is thin and nasal.
	var width: float = 0.5

	func set_hz(hz: float, sr: float) -> void:
		inc = clampf(hz / sr, 0.0, 0.45)

	func reset(start_phase: float = 0.0) -> void:
		phase = start_phase

	func _advance() -> void:
		phase += inc
		if phase >= 1.0:
			phase -= 1.0

	## The polynomial correction, applied at each edge.
	static func blep(t: float, dt: float) -> float:
		if dt <= 0.0:
			return 0.0
		if t < dt:
			var a: float = t / dt
			return a + a - a * a - 1.0
		if t > 1.0 - dt:
			var b: float = (t - 1.0) / dt
			return b * b + b + b + 1.0
		return 0.0

	func saw() -> float:
		var v: float = 2.0 * phase - 1.0
		v -= blep(phase, inc)
		_advance()
		return v

	func pulse() -> float:
		var v: float = 1.0 if phase < width else -1.0
		# `blep` inlined on both edges. This is the glottal source: once per
		# sample for every voiced call in the game, which makes two static calls
		# per sample worth removing even at the cost of the repetition.
		if phase < inc:
			var a: float = phase / inc
			v += a + a - a * a - 1.0
		elif phase > 1.0 - inc:
			var a2: float = (phase - 1.0) / inc
			v += a2 * a2 + a2 + a2 + 1.0
		# The falling edge sits `width` later in the cycle; correct it there too,
		# otherwise narrow pulses alias worse than the saw they were meant to fix.
		var t: float = phase - width
		if t < 0.0:
			t += 1.0
		if t < inc:
			var b: float = t / inc
			v -= b + b - b * b - 1.0
		elif t > 1.0 - inc:
			var b2: float = (t - 1.0) / inc
			v -= b2 * b2 + b2 + b2 + 1.0
		phase += inc
		if phase >= 1.0:
			phase -= 1.0
		# A duty-cycle pulse has a mean of 2w-1 — at the 0.26 width a cat's voice
		# uses, that is a -0.48 bias sitting under the sound. Removing it here is
		# exact and free; a DC blocker downstream would only catch it after it had
		# already eaten most of the headroom in the lowpass path.
		return v - (2.0 * width - 1.0)

	func sine() -> float:
		var v: float = sin(TAU * phase)
		_advance()
		return v

	## Triangle by integrating nothing — the cheap direct form is alias-free
	## enough for sub-oscillators and LFOs, which is all it is used for.
	func tri() -> float:
		var v: float = 4.0 * absf(phase - 0.5) - 1.0
		_advance()
		return v


## Deterministic white/pink noise. Named for the generator rather than the
## signal because Godot already has a native `Noise` class.
##
## `RandomNumberGenerator` through the binding costs more than the whole filter
## it feeds; xorshift32 inline is about twice as fast and, being ours, gives the
## headless test bit-identical runs.
class NoiseGen:
	var _state: int = 0x9E3779B9
	var _b0: float = 0.0
	var _b1: float = 0.0
	var _b2: float = 0.0
	var _p1: float = 0.0
	var _hp: float = 0.0

	func seed_with(s: int) -> void:
		# Zero is a fixed point of xorshift; force a live state.
		_state = (s & 0xFFFFFFFF) | 1

	func white() -> float:
		_state ^= (_state << 13) & 0xFFFFFFFF
		_state ^= _state >> 17
		_state ^= (_state << 5) & 0xFFFFFFFF
		_state &= 0xFFFFFFFF
		return float(_state) * (2.0 / 4294967295.0) - 1.0

	## Pink and white from the same draw, blended by `tilt` (0 pink, 1 white).
	## Breathy sources want both; asking for them separately meant two calls
	## through the binding per sample for every hiss in the game.
	func tilted(tilt: float) -> float:
		var w: float = white()
		_b0 = 0.99765 * _b0 + w * 0.0990460
		_b1 = 0.96300 * _b1 + w * 0.2965164
		_b2 = 0.57000 * _b2 + w * 1.0526913
		var p: float = (_b0 + _b1 + _b2 + w * 0.1848) * 0.32
		_hp = p - _p1 + 0.99 * _hp
		_p1 = p
		return _hp + (w - _hp) * tilt

	## Paul Kellet's three-pole pink approximation. Fur, breath and room tone all
	## want the -3 dB/octave tilt; white noise for those reads as tape hiss.
	##
	## The slowest pole is effectively an integrator, so the raw output wanders
	## around zero over tens of milliseconds — which reads as a DC offset on any
	## sound short enough to be foley, eats headroom, and is below anything an
	## animal can actually produce. One pole at ~35 Hz (at the engine's 22 kHz)
	## removes the wander without touching the tilt where it matters.
	func pink() -> float:
		var w: float = white()
		_b0 = 0.99765 * _b0 + w * 0.0990460
		_b1 = 0.96300 * _b1 + w * 0.2965164
		_b2 = 0.57000 * _b2 + w * 1.0526913
		var p: float = (_b0 + _b1 + _b2 + w * 0.1848) * 0.32
		_hp = p - _p1 + 0.99 * _hp
		_p1 = p
		return _hp


## Topology-preserving-transform state variable filter (Zavalishin/Cytomic).
##
## Chosen over a biquad because every parameter here is modulated: a yowl sweeps
## its cutoff, a formant drifts as the mouth opens. A direct-form biquad blows up
## when its coefficients move that fast; this one stays stable at any cutoff and
## resonance, and hands out all three responses from the same two state words.
class SVF:
	var lp: float = 0.0
	var bp: float = 0.0
	## Bandpass normalised to unity gain at resonance. The raw `bp` output grows
	## with Q, which would make a formant's level depend on how narrow it is —
	## and the recipes want to set "how loud" and "how narrow" independently.
	var bpn: float = 0.0
	var hp: float = 0.0
	var _ic1: float = 0.0
	var _ic2: float = 0.0
	var _a1: float = 0.0
	var _a2: float = 0.0
	var _a3: float = 0.0
	var _k: float = 1.0

	func set_params(cutoff_hz: float, q: float, sr: float) -> void:
		var g: float = tan(PI * clampf(cutoff_hz, 12.0, sr * 0.47) / sr)
		_k = 1.0 / maxf(q, 0.05)
		_a1 = 1.0 / (1.0 + g * (g + _k))
		_a2 = g * _a1
		_a3 = g * _a2

	func reset() -> void:
		_ic1 = 0.0
		_ic2 = 0.0
		lp = 0.0
		bp = 0.0
		bpn = 0.0
		hp = 0.0

	func process(x: float) -> float:
		var v3: float = x - _ic2
		var v1: float = _a1 * _ic1 + _a2 * v3
		var v2: float = _ic2 + _a2 * _ic1 + _a3 * v3
		_ic1 = 2.0 * v1 - _ic1
		_ic2 = 2.0 * v2 - _ic2
		lp = v2
		bp = v1
		bpn = _k * v1
		hp = x - _k * v1 - v2
		return v2


## Three parallel resonators standing in for a vocal tract.
##
## A larynx makes a buzz; the throat, mouth and nose turn that buzz into a
## *voice*. Two formants already read as an animal, three read as a specific
## animal — F1 and F2 carry the vowel, F3 carries species and body size, which is
## why a kitten and a cat saying the same thing are recognisably related.
class FormantBank:
	var g1: float = 1.0
	var g2: float = 0.7
	var g3: float = 0.35
	## Third band costs a third of the bank; short foley-ish calls skip it.
	var use_third: bool = true

	# Three TPT filters, unrolled into plain floats rather than three `SVF`
	# instances. This is the hottest loop in the game — it runs three times per
	# sample per voice — and three method calls through the binding cost more
	# than all the arithmetic in the bank put together. The maths below is
	# `SVF.process` verbatim; if you change one, change both.
	var _a1: float = 0.0
	var _a2: float = 0.0
	var _a3: float = 0.0
	var _k1: float = 1.0
	var _b1: float = 0.0
	var _b2: float = 0.0
	var _b3: float = 0.0
	var _k2: float = 1.0
	var _c1: float = 0.0
	var _c2: float = 0.0
	var _c3: float = 0.0
	var _k3: float = 1.0
	var _s1a: float = 0.0
	var _s1b: float = 0.0
	var _s2a: float = 0.0
	var _s2b: float = 0.0
	var _s3a: float = 0.0
	var _s3b: float = 0.0

	func set_formants(hz1: float, hz2: float, hz3: float, q: float, sr: float) -> void:
		var g: float = tan(PI * clampf(hz1, 12.0, sr * 0.47) / sr)
		_k1 = 1.0 / maxf(q, 0.05)
		_a1 = 1.0 / (1.0 + g * (g + _k1))
		_a2 = g * _a1
		_a3 = g * _a2
		var q2: float = maxf(q * 0.85, 0.05)
		g = tan(PI * clampf(hz2, 12.0, sr * 0.47) / sr)
		_k2 = 1.0 / q2
		_b1 = 1.0 / (1.0 + g * (g + _k2))
		_b2 = g * _b1
		_b3 = g * _b2
		if not use_third:
			return
		var q3: float = maxf(q * 0.7, 0.05)
		g = tan(PI * clampf(hz3, 12.0, sr * 0.47) / sr)
		_k3 = 1.0 / q3
		_c1 = 1.0 / (1.0 + g * (g + _k3))
		_c2 = g * _c1
		_c3 = g * _c2

	func reset() -> void:
		_s1a = 0.0
		_s1b = 0.0
		_s2a = 0.0
		_s2b = 0.0
		_s3a = 0.0
		_s3b = 0.0

	## Sum of the normalised bandpasses, so `g1..g3` are the formant amplitudes
	## the recipes think they are, whatever Q the voice is using.
	func process(x: float) -> float:
		var d: float = x - _s1b
		var v1: float = _a1 * _s1a + _a2 * d
		var v2: float = _s1b + _a2 * _s1a + _a3 * d
		_s1a = 2.0 * v1 - _s1a
		_s1b = 2.0 * v2 - _s1b
		var out: float = _k1 * v1 * g1

		d = x - _s2b
		v1 = _b1 * _s2a + _b2 * d
		v2 = _s2b + _b2 * _s2a + _b3 * d
		_s2a = 2.0 * v1 - _s2a
		_s2b = 2.0 * v2 - _s2b
		out += _k2 * v1 * g2

		if use_third:
			d = x - _s3b
			v1 = _c1 * _s3a + _c2 * d
			v2 = _s3b + _c2 * _s3a + _c3 * d
			_s3a = 2.0 * v1 - _s3a
			_s3b = 2.0 * v2 - _s3b
			out += _k3 * v1 * g3
		return out


## Attack/decay/sustain/release envelope, ticked once per control block.
##
## Attack is linear because a linear ramp is what a percussive onset wants;
## decay and release are exponential because that is what everything physical
## does, and because an exponential tail can be cut off early without a click.
class ADSR:
	enum Phase { IDLE, ATTACK, DECAY, SUSTAIN, RELEASE }

	var attack: float = 0.01
	var decay: float = 0.08
	var sustain: float = 0.6
	var release: float = 0.15
	var value: float = 0.0
	var phase: int = Phase.IDLE

	func gate_on() -> void:
		phase = Phase.ATTACK

	func gate_off() -> void:
		if phase != Phase.IDLE:
			phase = Phase.RELEASE

	func hard_reset() -> void:
		value = 0.0
		phase = Phase.IDLE

	func is_done() -> bool:
		return phase == Phase.IDLE and value <= 0.0001

	func process(dt: float) -> float:
		match phase:
			Phase.ATTACK:
				value += dt / maxf(attack, 0.0005)
				if value >= 1.0:
					value = 1.0
					phase = Phase.DECAY
			Phase.DECAY:
				var kd: float = 1.0 - exp(-dt / maxf(decay, 0.0005))
				value += (sustain - value) * kd
				if absf(value - sustain) < 0.002:
					value = sustain
					phase = Phase.SUSTAIN
			Phase.RELEASE:
				var kr: float = 1.0 - exp(-dt / maxf(release, 0.0005))
				value -= value * kr
				if value <= 0.0008:
					value = 0.0
					phase = Phase.IDLE
		return value


## Low-frequency modulator: vibrato, tremolo, the purr's rumble, mouth drift.
##
## The RANDOM shape is a smoothed sample-and-hold rather than white noise, which
## is what makes a baby sound *unsteady* rather than noisy — real infant calls
## wander over tens of milliseconds, not per sample.
class LFO:
	enum Shape { SINE, TRI, RANDOM }

	var shape: int = Shape.SINE
	var hz: float = 5.0
	var depth: float = 1.0
	var value: float = 0.0
	var _phase: float = 0.0
	var _target: float = 0.0
	var _current: float = 0.0
	var _noise := NoiseGen.new()

	func reset(start_phase: float = 0.0, seed_value: int = 12345) -> void:
		_phase = start_phase
		_noise.seed_with(seed_value)
		_target = _noise.white()
		_current = _target
		value = 0.0

	func process(dt: float) -> float:
		_phase += hz * dt
		while _phase >= 1.0:
			_phase -= 1.0
			_target = _noise.white()
		match shape:
			Shape.SINE:
				value = sin(TAU * _phase) * depth
			Shape.TRI:
				value = (4.0 * absf(_phase - 0.5) - 1.0) * depth
			_:
				# Glide toward the held value so the modulation is continuous.
				_current += (_target - _current) * clampf(dt * hz * 6.0, 0.0, 1.0)
				value = _current * depth
		return value


## Short multi-tap early-reflection tail.
##
## Not a reverb — a *placement*. Six taps under 45 ms with a damped, alternating
## polarity put the animal in a room with a desk and a wall behind it. Without
## them a synthesised call sounds like it is happening inside the speaker rather
## than somewhere on the desktop, and no amount of work on the voice itself
## fixes that. Left and right use different tap times, which is the whole of the
## stereo image; a desktop pet has no business with a real panner.
class EarlyReflections:
	const TAPS_L := [0.0073, 0.0119, 0.0171, 0.0237, 0.0313, 0.0431]
	const TAPS_R := [0.0091, 0.0134, 0.0193, 0.0251, 0.0344, 0.0467]
	const GAINS := [0.50, -0.42, 0.33, -0.25, 0.19, -0.13]

	var wet_l: float = 0.0
	var wet_r: float = 0.0
	## Tap gains as floats rather than the `GAINS` constant: a `const Array` is
	## an array of Variants, and unboxing six of them per sample costs more than
	## the six delay reads they multiply.
	var _gains := PackedFloat32Array()
	var _buf := PackedFloat32Array()
	var _size: int = 0
	var _write: int = 0
	var _idx_l := PackedInt32Array()
	var _idx_r := PackedInt32Array()
	## One-pole damping so the tail loses its top end the way a real small room
	## does. A bright tail on a desktop pet sounds like a bathroom.
	var _damp_l: float = 0.0
	var _damp_r: float = 0.0
	var damping: float = 0.42

	func configure(sr: float) -> void:
		_size = int(sr * 0.06) + 4
		_buf.resize(_size)
		_buf.fill(0.0)
		_write = 0
		_idx_l.resize(TAPS_L.size())
		_idx_r.resize(TAPS_R.size())
		_gains.resize(GAINS.size())
		for i in TAPS_L.size():
			_idx_l[i] = maxi(1, int(float(TAPS_L[i]) * sr))
			_idx_r[i] = maxi(1, int(float(TAPS_R[i]) * sr))
			_gains[i] = float(GAINS[i])

	func reset() -> void:
		_buf.fill(0.0)
		_damp_l = 0.0
		_damp_r = 0.0

	func process(x: float) -> void:
		if _size == 0:
			wet_l = 0.0
			wet_r = 0.0
			return
		_buf[_write] = x
		var l: float = 0.0
		var r: float = 0.0
		for i in _idx_l.size():
			var g: float = _gains[i]
			var a: int = _write - _idx_l[i]
			if a < 0:
				a += _size
			var b: int = _write - _idx_r[i]
			if b < 0:
				b += _size
			l += _buf[a] * g
			r += _buf[b] * g
		_damp_l += (l - _damp_l) * (1.0 - damping)
		_damp_r += (r - _damp_r) * (1.0 - damping)
		wet_l = _damp_l
		wet_r = _damp_r
		_write += 1
		if _write >= _size:
			_write = 0


## First-order DC blocker.
##
## Every source here can leave a bias — an asymmetric pulse train, a one-sided
## noise burst, a formant bank asked for a 90 Hz F1. DC costs headroom, makes the
## limiter behave strangely, and on some hardware makes a speaker cone sit off
## centre. One pole on the master removes it for two multiplies.
class DCBlock:
	var _x1: float = 0.0
	var _y1: float = 0.0

	func reset() -> void:
		_x1 = 0.0
		_y1 = 0.0

	func process(x: float) -> float:
		var y: float = x - _x1 + 0.9975 * _y1
		_x1 = x
		_y1 = y
		return y


## Rational tanh approximation, accurate to ~0.3 % over [-3, 3] and roughly six
## times cheaper. Used as the master's last line of defence: the mix is already
## conservative, so this only ever engages on a pile-up.
static func soft_clip(x: float) -> float:
	if x < -3.0:
		return -1.0
	if x > 3.0:
		return 1.0
	var x2: float = x * x
	return x * (27.0 + x2) / (27.0 + 9.0 * x2)


static func db_to_linear(db: float) -> float:
	return pow(10.0, db * 0.05)


## Equal-power pan, so a call crossing the stereo field does not dip in the
## middle. `pan` is -1 left, 0 centre, +1 right.
static func pan_gains(pan: float) -> Vector2:
	var a: float = (clampf(pan, -1.0, 1.0) + 1.0) * 0.25 * PI
	return Vector2(cos(a), sin(a))
