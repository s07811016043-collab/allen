class_name VoiceSynth
extends Node

## The audio engine: one output stream, one mix policy, no files.
##
## `AudioDirector` decides *whether* a sound happens; this node decides what it
## costs and how it reaches the speakers. Everything — voices, foley, ambience —
## is summed here into a single `AudioStreamGenerator` rather than given a player
## each, for three reasons that all matter on a desktop pet:
##
##   POLICY    One bus means one place where ducking, the voice cap and the
##             limiter apply. A pet that is quiet in a meeting has to be quiet in
##             *every* path, including the ones added next month.
##   COST      A voice costs a few hundred samples per millisecond of CPU in
##             GDScript, so a second of audio at the voice cap is a meaningful
##             fraction of a core. A single mix loop with a hard cap bounds that
##             exactly; N independent players do not.
##   ROOM      The early reflections are shared, so two animals sound like they
##             are in the same room instead of in two different ones.
##
## Cost is the reason so much of this layer is written the way it is. The hot
## loops here, in `VoiceModel` and in `AmbienceBed` inline their DSP instead of
## calling into `AudioDSP`, because at 22 050 calls per second per primitive the
## call is as expensive as the arithmetic inside it. `tests/test_audio.gd`
## measures the result and fails if it regresses.
##
## The fill is chunked: `_process` tops the ring buffer up by at most `MAX_FILL`
## frames. That is 46 ms of audio, which costs about 2 ms of work for one pet and
## about 5 ms with four animals talking at once — an acceptable spike after the
## main thread has already stalled, which is the only time the cap binds. Never
## render the whole buffer in one go: a 250 ms burst of synthesis is a dropped
## frame, and the pet visibly stutters when it speaks.

## 22 050 Hz. Half the usual rate, on purpose: the per-sample cost of a
## GDScript voice is the binding constraint, and 11 kHz of bandwidth is more
## than an animal call needs. Everything is band-limited anyway, so the tradeoff
## is a slightly softer hiss against half the CPU — and audible dropouts are a
## far worse artefact than a soft hiss.
const MIX_RATE := 22050.0
## Enough slack to survive a 200 ms hitch in the main thread without a gap.
const BUFFER_SECONDS := 0.25
## Frames per `_process`. Caps the worst-case synthesis burst.
const MAX_FILL := 1024

## Concurrency ceiling for anything that is not the ambience bed. Four is a CPU
## budget as much as a taste decision: at the cap the mixer costs roughly a
## quarter of one core for as long as the pile-up lasts, against about a tenth
## for the one-pet case that actually runs all day. It is also about the point
## past which more simultaneous animal noises stop reading as more animals and
## start reading as a mess.
const MAX_VOICES := 4

## Master headroom. The mix is built to peak well below full scale so the
## limiter is a safety net rather than part of the sound.
const OUTPUT_TRIM := 0.62
## How much of the mix goes to the early reflections.
const ER_SEND := 0.18
## Pole of the master DC blockers. 0.9975 at 22 kHz puts the corner near 9 Hz —
## below anything an animal produces, above where a bias can accumulate.
const DC_POLE := 0.9975
## Largest sample the limiter will treat as audio rather than as a symptom. The
## mix is trimmed to peak near 0.5, so anything past this is a bug upstream.
const SANE := 1.0e6

## The app fades its own voice in over its first minute. The first sound Petalia
## ever makes is the one most likely to happen in a meeting, in a library, or at
## 2 a.m. with headphones on — so it happens at a third of the level, and full
## level is only reached once the user has had a chance to reach for the slider.
const INTRO_SECONDS := 60.0
const INTRO_START := 0.34

## Ducking while the user types. Fast to engage, slow to let go, so a burst of
## typing does not turn into a tremolo on the pet.
const DUCK_LEVEL := 0.28
const DUCK_HOLD := 0.9
const DUCK_ATTACK := 0.06
const DUCK_RELEASE := 0.55

var max_voices: int = MAX_VOICES
## Scaled by `set_mix`; the bed reads it every block.
var ambience_gain: float = 0.0

var _player: AudioStreamPlayer = null
var _playback: AudioStreamGeneratorPlayback = null
var _voices: Array[AudioVoice] = []
var _bed: AmbienceBed = null
var _rng := RandomNumberGenerator.new()

var _mix_l := PackedFloat32Array()
var _mix_r := PackedFloat32Array()
var _out := PackedVector2Array()
var _er := AudioDSP.EarlyReflections.new()
## First-order DC blocker per channel, as four bare floats rather than a pair of
## objects. Every source in the game can leave a bias — an asymmetric pulse
## train, a one-sided noise burst, a formant bank asked for a 90 Hz F1 — and DC
## costs headroom, upsets the limiter, and on some hardware parks a speaker cone
## off centre. Two multiplies each removes it, which is cheap enough that the
## method call wrapping them was costing more than the filter.
var _dc_x1_l: float = 0.0
var _dc_y1_l: float = 0.0
var _dc_x1_r: float = 0.0
var _dc_y1_r: float = 0.0

var _gain: float = 0.0
var _duck: float = 1.0
var _duck_until: float = -1.0
var _age: float = 0.0
## Set when the engine could not open an output. Everything still runs — the
## game must not care — it simply never pushes a buffer.
var _offline: bool = false


func _ready() -> void:
	_rng.randomize()
	_er.configure(MIX_RATE)
	_bed = AmbienceBed.new()
	_bed.setup(MIX_RATE)
	_voices.append(_bed)
	_open_output()
	set_process(true)


func _open_output() -> void:
	var gen := AudioStreamGenerator.new()
	# The default mode already follows this property, but say it out loud: a
	# future engine default of "follow the output device" would silently double
	# the synthesis cost on a 48 kHz machine.
	gen.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_SECONDS
	_player = AudioStreamPlayer.new()
	_player.name = "VoiceOut"
	_player.stream = gen
	_player.bus = &"Master"
	add_child(_player)
	_player.play()
	var pb: Object = _player.get_stream_playback()
	if pb is AudioStreamGeneratorPlayback:
		_playback = pb
	else:
		# No audio device (containers, CI, a user with everything muted at the
		# OS level). Not an error: the pet is a visual companion first.
		_offline = true
		Log.info("VoiceSynth", "no generator playback; synthesis is idle")


func _process(_delta: float) -> void:
	if _offline or _playback == null:
		return
	var want: int = mini(_playback.get_frames_available(), MAX_FILL)
	if want <= 0:
		return
	_playback.push_buffer(_render(want))


# --- Public API used by AudioDirector ----------------------------------------

## Play a vocalisation. `opts` may carry `family`, `baby`, `timbre` and `pan`;
## anything absent falls back to a plausible adult cat, because a missing key
## must degrade to a sound rather than to silence.
func play_call(call_id: StringName, pitch_hz: float, intensity: float, gain: float,
		opts: Dictionary = {}) -> bool:
	var m := CallLibrary.build(call_id, StringName(opts.get("family", &"cat")),
		pitch_hz, intensity, float(opts.get("baby", 0.0)),
		float(opts.get("timbre", 0.5)), _rng)
	m.priority = AudioVoice.Priority.VOICE
	m.gain *= maxf(gain, 0.0)
	m.pan = clampf(float(opts.get("pan", 0.0)) + _rng.randf_range(-0.12, 0.12), -1.0, 1.0)
	return _add_voice(m)


## Footfalls, impacts, fur, wings. `opts` may carry `pan`.
func play_foley(foley_id: StringName, intensity: float, gain: float,
		opts: Dictionary = {}) -> bool:
	var f := FoleyLibrary.build(foley_id, intensity, _rng)
	f.gain *= maxf(gain, 0.0)
	f.pan = clampf(float(opts.get("pan", 0.0)) + _rng.randf_range(-0.18, 0.18), -1.0, 1.0)
	return _add_voice(f)


## Master and ambience levels, pushed from `Settings` whenever they change.
## Voice level is applied by the caller at trigger time instead, so that moving
## the slider never changes the level of a call that is already in the air.
func set_mix(master: float, _voice: float, ambience: float) -> void:
	ambience_gain = clampf(master * ambience, 0.0, 1.0)


## Pull everything down for `seconds`. Called when the user is typing, and
## available to anything else that needs the desktop back.
func duck(seconds: float = DUCK_HOLD) -> void:
	_duck_until = maxf(_duck_until, _age + maxf(seconds, 0.0))


func stop_all(immediate: bool = false) -> void:
	for v in _voices:
		if v == _bed:
			continue
		if immediate:
			v.gain = 0.0
		v.fading_out = true


## Live voices excluding the ambience bed. Read by the diagnostics overlay and
## by the headless test.
func active_voices() -> int:
	var n: int = 0
	for v in _voices:
		if v != _bed and not v.fading_out:
			n += 1
	return n


## Render without an audio device, for the headless test. Same path the engine
## takes, so what the test measures is what the speaker would get.
func render_offline(frames: int) -> PackedVector2Array:
	return _render(maxi(frames, 1))


# --- Mixing ------------------------------------------------------------------

## Admission control. A new voice never simply steals a slot: it has to be worth
## at least as much as the cheapest thing already playing, or it is dropped.
## Dropping a footfall is invisible; interrupting a meow to play a footfall is
## not.
func _add_voice(v: AudioVoice) -> bool:
	var live: int = active_voices()
	# Voices two and up are built cheaper. The cap bounds how many there are;
	# this bounds what each one costs, so the worst case is a mix that thins
	# rather than a buffer that runs dry.
	v.fidelity = 1.0 if live < 2 else 0.6
	v.setup(MIX_RATE)
	if live >= max_voices:
		var victim: AudioVoice = null
		for c in _voices:
			if c == _bed or c.fading_out:
				continue
			if victim == null or c.priority < victim.priority \
					or (c.priority == victim.priority and c.elapsed > victim.elapsed):
				victim = c
		if victim == null or victim.priority > v.priority:
			return false
		victim.fading_out = true
	_voices.append(v)
	return true


func _render(frames: int) -> PackedVector2Array:
	if _mix_l.size() < frames:
		_mix_l.resize(frames)
		_mix_r.resize(frames)
		_out.resize(frames)
	elif _out.size() != frames:
		_out.resize(frames)

	_bed.gain = ambience_gain
	# Retire finished voices here rather than only after a render pass: an idle
	# pet takes the silent path below, and a dead voice that is never swept up
	# holds a slot in the cap forever.
	var keep: Array[AudioVoice] = []
	for v in _voices:
		if v == _bed or (not v.is_finished() and v.elapsed <= v.max_seconds()):
			keep.append(v)
	_voices = keep

	# Nothing to say and nothing in the room: push silence without walking the
	# graph. An idle pet is the common case by a wide margin.
	var busy: bool = _bed.is_audible()
	var sounding: bool = false
	for v in _voices:
		if v != _bed:
			busy = true
			sounding = true
	if not busy:
		var quiet := PackedVector2Array()
		quiet.resize(frames)
		_advance_clock(frames)
		_gain = _target_gain()
		return quiet

	for i in frames:
		_mix_l[i] = 0.0
		_mix_r[i] = 0.0

	for v in _voices:
		v.render_add(_mix_l, _mix_r, frames)

	# --- Master chain ---
	# Advance the duck first, then ramp to where it lands: ramping toward a
	# target that is itself moving is how a gain stage ends up with a step at
	# every block boundary.
	_advance_clock(frames)
	var target: float = _target_gain()
	var g: float = _gain
	var step: float = (target - _gain) / float(frames)
	# The ambience bed already *is* the room; sending it through the reflections
	# would only smear it, and it is the one thing that plays all day. So the
	# early reflections run when there is something in the room to reflect.
	if sounding:
		_er.mix_block(_mix_l, _mix_r, frames, ER_SEND)
	# The DC blockers and the limiter are inlined below rather than called. This
	# loop runs on every sample the engine ever emits, and at that rate four
	# method calls per sample cost more than everything else in the master chain
	# put together.
	var xl: float = _dc_x1_l
	var yl: float = _dc_y1_l
	var xr: float = _dc_x1_r
	var yr: float = _dc_y1_r
	for i in frames:
		var x: float = _mix_l[i]
		yl = x - xl + DC_POLE * yl
		xl = x
		var l: float = yl * g
		x = _mix_r[i]
		yr = x - xr + DC_POLE * yr
		xr = x
		var r: float = yr * g
		# `AudioDSP.soft_clip` unrolled, with the in-range case first because it
		# is the only one that ever normally happens, and with the engine's last
		# line of defence folded into the same branches.
		#
		# A merely loud sample is limited to full scale. Anything absurd is
		# silenced instead, and the `SANE` test is what separates the two:
		# infinity passes `> 3.0` but fails `< SANE`, and NaN fails every
		# comparison there is, so both land in the final branch. That distinction
		# is the whole point — a blown-up filter emits infinities by the
		# thousand, and limiting those to full scale would hand the user a
		# sustained square wave at maximum volume. The filters upstream are
		# modulated fast enough that "cannot happen" is not a claim worth betting
		# somebody's hearing on.
		if l >= -3.0 and l <= 3.0:
			var l2: float = l * l
			l = l * (27.0 + l2) / (27.0 + 9.0 * l2)
		elif l > 3.0 and l < SANE:
			l = 1.0
		elif l < -3.0 and l > -SANE:
			l = -1.0
		else:
			l = 0.0
		if r >= -3.0 and r <= 3.0:
			var r2: float = r * r
			r = r * (27.0 + r2) / (27.0 + 9.0 * r2)
		elif r > 3.0 and r < SANE:
			r = 1.0
		elif r < -3.0 and r > -SANE:
			r = -1.0
		else:
			r = 0.0
		_out[i] = Vector2(l, r)
		g += step
	_dc_x1_l = xl
	_dc_y1_l = yl
	_dc_x1_r = xr
	_dc_y1_r = yr
	_gain = target
	return _out


## Where the master gain is heading: output trim, the intro fade, and the duck.
func _target_gain() -> float:
	var intro: float = clampf(_age / INTRO_SECONDS, 0.0, 1.0)
	return OUTPUT_TRIM * lerpf(INTRO_START, 1.0, intro * intro) * _duck


## The engine's clock is rendered audio, not frame time: a stalled main thread
## must not fast-forward the intro fade or shorten a duck.
func _advance_clock(frames: int) -> void:
	var dt: float = float(frames) / MIX_RATE
	_age += dt
	var want: float = DUCK_LEVEL if _age < _duck_until else 1.0
	var tc: float = DUCK_ATTACK if want < _duck else DUCK_RELEASE
	_duck += (want - _duck) * clampf(dt / tc, 0.0, 1.0)
