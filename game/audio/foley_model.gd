class_name FoleyModel
extends AudioVoice

## Non-vocal sound: paws, claws, impacts, fur, wings.
##
## Physically these are all the same event — something excites a resonance and
## the resonance dies — so they are all one model with three ingredients:
##
##   NOISE   A burst through a sweeping bandpass. This is the contact itself:
##           the scuff of a pad, the grit of a claw, the air moved by a wing.
##   RING    A single very high-Q resonator, excited by the same noise. This is
##           what the surface is *made of*, and it is the whole difference
##           between stepping on an icon and stepping on a window edge.
##   BODY    A sine with a downward pitch sweep. This is mass. A landing thud
##           without it is a snare hit; with it, something with weight arrived.
##
## Foley fires far more often than any voice does — a walking cat is four
## footfalls a second — so everything here is deliberately quiet, short and
## cheap. The player should notice it only if it were missing.

var dur: float = 0.12
## Repeats give a claw skitter, a double-tap, or a wing beating twice, without
## the mixer having to schedule three separate voices for one gesture.
var repeats: int = 1
var gap: float = 0.09
var repeat_falloff: float = 0.82

var attack: float = 0.002
var decay: float = 0.05
var sustain: float = 0.0
var release: float = 0.03
## Seconds the envelope is held before release. Zero for an impact, most of the
## duration for a rustle.
var hold: float = 0.0

var noise_amt: float = 1.0
## 0 = pink (fur, air, cloth), 1 = white (grit, glass, claw).
var noise_tilt: float = 0.5
var bp_hz0: float = 1800.0
var bp_hz1: float = 900.0
var bp_q: float = 1.4

var ring_hz: float = 0.0
var ring_q: float = 18.0
var ring_amt: float = 0.0

var body_hz0: float = 120.0
var body_hz1: float = 60.0
var body_amt: float = 0.0
var body_decay: float = 0.05

## Amplitude granulation. A rustle is not a noise burst, it is several hundred
## individual hairs; modulating the burst at ~20 Hz with a random shape is what
## keeps it from sounding like a hi-hat.
var grain_hz: float = 0.0
var grain_depth: float = 0.0

var _noise := AudioDSP.NoiseGen.new()
var _bp := AudioDSP.SVF.new()
var _ring := AudioDSP.SVF.new()
var _body := AudioDSP.Osc.new()
var _env := AudioDSP.ADSR.new()
var _grain := AudioDSP.LFO.new()

var _t: float = 0.0
var _end: float = 0.2
var _hit: int = -1
var _hit_t0: float = 0.0
var _hit_amp: float = 1.0
var _gated: bool = false
var _amp: float = 0.0
var _amp_target: float = 0.0
var _body_amp: float = 0.0
var _body_target: float = 0.0
var _done: bool = false


func setup(sample_rate: float) -> void:
	super.setup(sample_rate)
	repeats = maxi(repeats, 1)
	_end = float(repeats - 1) * gap + dur + release
	_env.attack = attack
	_env.decay = decay
	_env.sustain = sustain
	_env.release = release
	var s: int = int(bp_hz0 * 31.0) ^ int(dur * 104729.0) ^ int(ring_hz)
	_noise.seed_with(s * 2246822519)
	_grain.shape = AudioDSP.LFO.Shape.RANDOM
	_grain.hz = maxf(grain_hz, 0.01)
	_grain.reset(0.0, (s * 11) | 1)
	_bp.reset()
	_ring.reset()
	_body.reset(0.0)


func is_finished() -> bool:
	return _done


func max_seconds() -> float:
	return _end + 0.3


func render_add(left: PackedFloat32Array, right: PackedFloat32Array, count: int) -> void:
	if _done:
		return
	var i: int = 0
	while i < count:
		var n: int = mini(AudioDSP.BLOCK, count - i)
		_update_block(float(n) / _sr)
		# Two independent ramps: the contact noise and the body thump decay at
		# different rates in the real world, and forcing them to share an
		# envelope is what makes a synthetic impact sound like a drum machine.
		var step: float = (_amp_target - _amp) / float(n)
		var bstep: float = (_body_target - _body_amp) / float(n)
		var nz_amt: float = noise_amt
		var tilt: float = noise_tilt
		var ring_g: float = ring_amt
		for k in n:
			var v: float = 0.0
			if nz_amt > 0.0:
				var nz: float = _noise.tilted(tilt)
				_bp.process(nz)
				v = _bp.bpn * nz_amt * _amp
				if ring_g > 0.0:
					# The ring is deliberately *not* normalised: a high-Q
					# resonator ringing louder than the strike that excited it is
					# exactly what a hard surface does.
					_ring.process(nz)
					v += _ring.bp * ring_g * _amp
			if _body_amp > 0.0:
				v += _body.sine() * _body_amp
			v = AudioDSP.soft_clip(v)
			var idx: int = i + k
			left[idx] += v * _gl
			right[idx] += v * _gr
			_amp += step
			_body_amp += bstep
		_amp = _amp_target
		_body_amp = _body_target
		i += n
	elapsed += float(count) / _sr
	if _t >= _end or elapsed > max_seconds():
		_done = true


func _update_block(dt: float) -> void:
	_t += dt

	# --- Which hit are we in, if any ---
	var idx: int = mini(int(_t / maxf(gap, 0.0001)), repeats - 1) if repeats > 1 else 0
	var t0: float = float(idx) * gap
	if idx != _hit and _t >= t0:
		_hit = idx
		_hit_t0 = t0
		_hit_amp = pow(repeat_falloff, float(idx))
		_env.hard_reset()
		_env.gate_on()
		_gated = true
		# Retuning the resonators per hit is what stops a repeated tap sounding
		# like a loop: two claws on the same icon are never the same claw.
		_body.reset(0.0)
	var ht: float = _t - _hit_t0
	# Release only once the attack has actually happened. Gating off in the same
	# block it was gated on — which is what a bare `hold` of zero does — leaves
	# the envelope at zero forever, and the sound never exists.
	if _gated and ht >= hold + attack:
		_env.gate_off()
		_gated = false

	# --- Sweeps, exponential because pitch is heard that way ---
	var u: float = clampf(ht / maxf(dur, 0.001), 0.0, 1.0)
	_bp.set_params(bp_hz0 * pow(bp_hz1 / maxf(bp_hz0, 1.0), u), bp_q, _sr)
	if ring_amt > 0.0 and ring_hz > 0.0:
		_ring.set_params(ring_hz, ring_q, _sr)
	if body_amt > 0.0:
		_body.set_hz(body_hz0 * pow(body_hz1 / maxf(body_hz0, 1.0), u), _sr)
		_body_target = body_amt * exp(-ht / maxf(body_decay, 0.001)) * _hit_amp * gain
	else:
		_body_target = 0.0

	var env: float = _env.process(dt) * _hit_amp
	if grain_depth > 0.0:
		env *= 1.0 - grain_depth + grain_depth * (0.5 + 0.5 * _grain.process(dt))
	_amp_target = env * gain
	if fading_out:
		gain *= 0.7
		if gain < 0.002:
			_done = true
