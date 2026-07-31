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

## Hard ceiling on the bed's own output, before the master gain. Deliberately a
## constant and not a setting — the ambience slider scales *within* this.
const PEAK := 0.02

## Independent noise per channel. Two decorrelated sources are what make a bed
## sound like air in a room instead of a mono hiss pinned between the speakers.
var _nl := AudioDSP.NoiseGen.new()
var _nr := AudioDSP.NoiseGen.new()
var _lpl := AudioDSP.SVF.new()
var _lpr := AudioDSP.SVF.new()
var _airl := AudioDSP.SVF.new()
## Three unrelated periods, none of them a whole multiple of another, so the bed
## never lines up with itself.
var _drift := AudioDSP.LFO.new()
var _swell := AudioDSP.LFO.new()
var _air := AudioDSP.LFO.new()

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
	_nl.seed_with(0x51ED270B)
	_nr.seed_with(0x2545F491)
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
		var k: int = 0
		while k < n:
			# One source sample per two output samples, linearly interpolated.
			# The bed is a lowpassed hiss with nothing above 5 kHz in it, so
			# generating at half rate is inaudible — and this runs every sample
			# of every hour the app is open, which makes it the one place in the
			# mix where halving the cost is worth more than any fidelity it buys.
			_lpl.process(_nl.tilted(0.0))
			_lpr.process(_nr.tilted(0.0))
			_airl.process(_nl.white())
			# Soft-clipped before the level is applied, which is what makes PEAK
			# a guarantee rather than an intention: noise is unbounded by nature,
			# and this is the one voice in the game nobody is listening to closely
			# enough to notice a fraction of a decibel of saturation. The air band
			# is shared between the channels; at 4 kHz and -40 dB there is no
			# stereo image left to preserve.
			var nl: float = AudioDSP.soft_clip(_lpl.lp + _airl.bpn * air)
			var nr: float = AudioDSP.soft_clip(_lpr.lp + _airl.bpn * air * 0.8)
			var idx: int = i + k
			left[idx] += (_pl + nl) * 0.5 * _amp
			right[idx] += (_pr + nr) * 0.5 * _amp
			_amp += step
			k += 1
			if k < n:
				idx += 1
				left[idx] += nl * _amp
				right[idx] += nr * _amp
				_amp += step
				k += 1
			_pl = nl
			_pr = nr
		_amp = _amp_target
		i += n
	elapsed += float(count) / _sr


func _update_block(dt: float) -> void:
	# Everything here moves over tens of seconds, so the control rate is already
	# a thousand times faster than it needs to be.
	# Coefficients are computed against the half rate the loop actually runs at.
	var hsr: float = _sr * 0.5
	_cut = 700.0 * pow(2.0, _drift.process(dt) * 0.8)
	_lpl.set_params(_cut, 0.6, hsr)
	_lpr.set_params(_cut * 1.13, 0.6, hsr)
	_airl.set_params(3800.0, 0.9, hsr)
	_air_amp = 0.06 + 0.05 * _air.process(dt)
	_amp_target = clampf(gain, 0.0, 1.0) * PEAK * (0.72 + 0.28 * (0.5 + 0.5 * _swell.process(dt)))
