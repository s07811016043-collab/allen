class_name AmbienceBed
extends AudioVoice

## The room the pet lives in.
##
## This is the quietest thing in the game and the easiest to get wrong. Its only
## job is to stop the silence between calls from being *digital* silence, so that
## a meow arrives in a space rather than out of a vacuum. If a listener can
## describe it, it is too loud; the ceiling below is roughly -34 dBFS, which on a
## laptop at a normal working volume is under the noise floor of the room the
## user is actually sitting in.
##
## It is generative for the same reason the voices are: this plays for eight
## hours. A loop would be noticed by lunchtime.
##
## It is also the only voice that renders on every sample of every hour the app
## is open, which is why the inner loop below is hand-inlined instead of being
## built out of `AudioDSP` primitives the way every other voice is. Five method
## calls per source sample measured as more than half of what the whole mixer
## costs while a pet is idle — all day, for a sound nobody is meant to notice.
## The arithmetic is `NoiseGen.pink` and `SVF.process` verbatim; if you change
## one, change both.

## Hard ceiling on the bed's own output, before the master gain. Deliberately a
## constant and not a setting — the ambience slider scales *within* this.
const PEAK := 0.02

## xorshift32, inlined from `AudioDSP.NoiseGen`.
const MASK := 0xFFFFFFFF
const SCALE := 2.0 / 4294967295.0

## Three unrelated periods, none of them a whole multiple of another, so the bed
## never lines up with itself. These tick once per control block, which is a
## thousand times more often than they need, so they stay objects.
var _drift := AudioDSP.LFO.new()
var _swell := AudioDSP.LFO.new()
var _air := AudioDSP.LFO.new()

## Independent noise per channel: an xorshift state, Paul Kellet's three pink
## poles, and the one-pole highpass that stops the slowest of them wandering off
## centre. Two decorrelated sources are what make a bed sound like air in a room
## instead of a mono hiss pinned between the speakers.
var _nl_state: int = 0x51ED270B
var _nl_b0: float = 0.0
var _nl_b1: float = 0.0
var _nl_b2: float = 0.0
var _nl_p: float = 0.0
var _nl_hp: float = 0.0
var _nr_state: int = 0x2545F491
var _nr_b0: float = 0.0
var _nr_b1: float = 0.0
var _nr_b2: float = 0.0
var _nr_p: float = 0.0
var _nr_hp: float = 0.0

## The two channel lowpasses and the air band, as TPT state and coefficients.
## Coefficients move once per control block; state moves once per sample.
var _lpl_s1: float = 0.0
var _lpl_s2: float = 0.0
var _lpl_a1: float = 0.0
var _lpl_a2: float = 0.0
var _lpl_a3: float = 0.0
var _lpr_s1: float = 0.0
var _lpr_s2: float = 0.0
var _lpr_a1: float = 0.0
var _lpr_a2: float = 0.0
var _lpr_a3: float = 0.0
var _air_s1: float = 0.0
var _air_s2: float = 0.0
var _air_a1: float = 0.0
var _air_a2: float = 0.0
var _air_a3: float = 0.0
var _air_k: float = 1.0

var _cut: float = 700.0
## Previous source sample per channel, for the half-rate interpolation.
var _pl: float = 0.0
var _pr: float = 0.0
var _air_amp: float = 0.0
var _amp: float = 0.0
var _amp_target: float = 0.0


func _init() -> void:
	priority = Priority.AMBIENCE
	gain = 0.0


func setup(sample_rate: float) -> void:
	super.setup(sample_rate)
	# Fixed seeds, and both odd: zero is a fixed point of xorshift, and the bed
	# has to come up the same way on every launch so the headless test has a
	# repeatable buffer to measure.
	_nl_state = 0x51ED270B
	_nr_state = 0x2545F491
	_drift.shape = AudioDSP.LFO.Shape.RANDOM
	_drift.hz = 0.043
	_drift.reset(0.0, 7717)
	_swell.shape = AudioDSP.LFO.Shape.SINE
	_swell.hz = 0.017
	_swell.reset(0.3, 104729)
	_air.shape = AudioDSP.LFO.Shape.RANDOM
	_air.hz = 0.031
	_air.reset(0.0, 15485863)


func is_finished() -> bool:
	# The bed outlives every other voice; the mixer removes it by muting it.
	return false


## Whether the bed is still making sound, including the ramp down after it is
## muted. The mixer asks before it decides to skip the graph entirely, so that
## turning the ambience off fades rather than cuts.
func is_audible() -> bool:
	return gain > 0.0001 or _amp > 0.0001


func max_seconds() -> float:
	return INF


func render_add(left: PackedFloat32Array, right: PackedFloat32Array, count: int) -> void:
	if gain <= 0.0001 and _amp <= 0.0001:
		# Silent and asked to stay silent: skip the whole graph rather than burn
		# a per-sample loop producing zeroes all day.
		elapsed += float(count) / _sr
		return
	var i: int = 0
	while i < count:
		var n: int = mini(AudioDSP.BLOCK, count - i)
		_update_block(float(n) / _sr)
		var step: float = (_amp_target - _amp) / float(n)
		var air: float = _air_amp
		# Everything the sample loop touches, hoisted. A member lookup through
		# `self` costs about as much as the multiply it feeds, and there are
		# thirty of them per source sample below.
		var sl: int = _nl_state
		var lb0: float = _nl_b0
		var lb1: float = _nl_b1
		var lb2: float = _nl_b2
		var lp: float = _nl_p
		var lhp: float = _nl_hp
		var sr_: int = _nr_state
		var rb0: float = _nr_b0
		var rb1: float = _nr_b1
		var rb2: float = _nr_b2
		var rp: float = _nr_p
		var rhp: float = _nr_hp
		var ls1: float = _lpl_s1
		var ls2: float = _lpl_s2
		var la1: float = _lpl_a1
		var la2: float = _lpl_a2
		var la3: float = _lpl_a3
		var rs1: float = _lpr_s1
		var rs2: float = _lpr_s2
		var ra1: float = _lpr_a1
		var ra2: float = _lpr_a2
		var ra3: float = _lpr_a3
		var as1: float = _air_s1
		var as2: float = _air_s2
		var aa1: float = _air_a1
		var aa2: float = _air_a2
		var aa3: float = _air_a3
		var ak: float = _air_k
		var amp: float = _amp
		var prev_l: float = _pl
		var prev_r: float = _pr
		var k: int = 0
		while k < n:
			# One source sample per two output samples, linearly interpolated.
			# The bed is a lowpassed hiss with nothing above 5 kHz in it, so
			# generating at half rate is inaudible — and this runs every sample
			# of every hour the app is open, which makes it the one place in the
			# mix where halving the cost is worth more than any fidelity it buys.
			sl ^= (sl << 13) & MASK
			sl ^= sl >> 17
			sl ^= (sl << 5) & MASK
			sl &= MASK
			var w: float = float(sl) * SCALE - 1.0
			lb0 = 0.99765 * lb0 + w * 0.0990460
			lb1 = 0.96300 * lb1 + w * 0.2965164
			lb2 = 0.57000 * lb2 + w * 1.0526913
			var p: float = (lb0 + lb1 + lb2 + w * 0.1848) * 0.32
			lhp = p - lp + 0.99 * lhp
			lp = p
			var d: float = lhp - ls2
			var v1: float = la1 * ls1 + la2 * d
			var v2: float = ls2 + la2 * ls1 + la3 * d
			ls1 = 2.0 * v1 - ls1
			ls2 = 2.0 * v2 - ls2
			var lo: float = v2

			sr_ ^= (sr_ << 13) & MASK
			sr_ ^= sr_ >> 17
			sr_ ^= (sr_ << 5) & MASK
			sr_ &= MASK
			w = float(sr_) * SCALE - 1.0
			rb0 = 0.99765 * rb0 + w * 0.0990460
			rb1 = 0.96300 * rb1 + w * 0.2965164
			rb2 = 0.57000 * rb2 + w * 1.0526913
			p = (rb0 + rb1 + rb2 + w * 0.1848) * 0.32
			rhp = p - rp + 0.99 * rhp
			rp = p
			d = rhp - rs2
			v1 = ra1 * rs1 + ra2 * d
			v2 = rs2 + ra2 * rs1 + ra3 * d
			rs1 = 2.0 * v1 - rs1
			rs2 = 2.0 * v2 - rs2
			var ro: float = v2

			# The air band is white rather than pink, and shared between the
			# channels: at 3.8 kHz and -40 dB there is no stereo image left to
			# preserve, and a second generator for it would cost more than it
			# could possibly be worth.
			sl ^= (sl << 13) & MASK
			sl ^= sl >> 17
			sl ^= (sl << 5) & MASK
			sl &= MASK
			d = (float(sl) * SCALE - 1.0) - as2
			v1 = aa1 * as1 + aa2 * d
			v2 = as2 + aa2 * as1 + aa3 * d
			as1 = 2.0 * v1 - as1
			as2 = 2.0 * v2 - as2
			var band: float = ak * v1 * air

			# Soft-clipped before the level is applied, which is what makes PEAK
			# a guarantee rather than an intention: noise is unbounded by nature,
			# and this is the one voice in the game nobody is listening to
			# closely enough to notice a fraction of a decibel of saturation.
			# `AudioDSP.soft_clip`'s rational form without its out-of-range
			# branches — the sources here are pink noise at a third of full
			# scale, decades inside the range where the two agree.
			var nl: float = lo + band
			var q: float = nl * nl
			nl = nl * (27.0 + q) / (27.0 + 9.0 * q)
			var nr: float = ro + band * 0.8
			q = nr * nr
			nr = nr * (27.0 + q) / (27.0 + 9.0 * q)

			var idx: int = i + k
			left[idx] += (prev_l + nl) * 0.5 * amp
			right[idx] += (prev_r + nr) * 0.5 * amp
			amp += step
			k += 1
			if k < n:
				idx += 1
				left[idx] += nl * amp
				right[idx] += nr * amp
				amp += step
				k += 1
			prev_l = nl
			prev_r = nr
		_nl_state = sl
		_nl_b0 = lb0
		_nl_b1 = lb1
		_nl_b2 = lb2
		_nl_p = lp
		_nl_hp = lhp
		_nr_state = sr_
		_nr_b0 = rb0
		_nr_b1 = rb1
		_nr_b2 = rb2
		_nr_p = rp
		_nr_hp = rhp
		_lpl_s1 = ls1
		_lpl_s2 = ls2
		_lpr_s1 = rs1
		_lpr_s2 = rs2
		_air_s1 = as1
		_air_s2 = as2
		_pl = prev_l
		_pr = prev_r
		_amp = _amp_target
		i += n
	elapsed += float(count) / _sr


func _update_block(dt: float) -> void:
	# Everything here moves over tens of seconds, so the control rate is already
	# a thousand times faster than it needs to be.
	# Coefficients are computed against the half rate the loop actually runs at.
	var hsr: float = _sr * 0.5
	_cut = 700.0 * pow(2.0, _drift.process(dt) * 0.8)
	var c: Vector3 = AudioDSP.tpt_coeffs(_cut, 0.6, hsr)
	_lpl_a1 = c.x
	_lpl_a2 = c.y
	_lpl_a3 = c.z
	c = AudioDSP.tpt_coeffs(_cut * 1.13, 0.6, hsr)
	_lpr_a1 = c.x
	_lpr_a2 = c.y
	_lpr_a3 = c.z
	c = AudioDSP.tpt_coeffs(3800.0, 0.9, hsr)
	_air_a1 = c.x
	_air_a2 = c.y
	_air_a3 = c.z
	_air_k = 1.0 / 0.9
	_air_amp = 0.06 + 0.05 * _air.process(dt)
	_amp_target = clampf(gain, 0.0, 1.0) * PEAK * (0.72 + 0.28 * (0.5 + 0.5 * _swell.process(dt)))
