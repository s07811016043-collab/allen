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
##   COST      GDScript synthesises about a thousand samples per millisecond.
##             A single mix loop with a hard voice cap bounds that exactly; N
##             independent players do not.
##   ROOM      The early reflections are shared, so two animals sound like they
##             are in the same room instead of in two different ones.
##
## The fill is chunked: `_process` tops the ring buffer up by at most
## `MAX_FILL` frames, which is 46 ms of audio for about a millisecond of work.
## Never render the whole buffer in one go — a 250 ms burst of synthesis is a
## dropped frame, and the pet visibly stutters when it speaks.

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

## Concurrency ceiling for anything that is not the ambience bed. Four voices of
## GDScript DSP is roughly 3 ms per second of audio on a slow laptop; it is also
## about the point past which more simultaneous animal noises stop reading as
## more animals and start reading as a mess.
const MAX_VOICES := 4

## Master headroom. The mix is built to peak well below full scale so the
## limiter is a safety net rather than part of the sound.
const OUTPUT_TRIM := 0.62
## How much of the mix goes to the early reflections.
const ER_SEND := 0.18

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
var _dc_l := AudioDSP.DCBlock.new()
var _dc_r := AudioDSP.DCBlock.new()

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
	var send: float = ER_SEND if sounding else 0.0
	for i in frames:
		var l: float = _mix_l[i]
		var r: float = _mix_r[i]
		if send > 0.0:
			_er.process((l + r) * 0.5)
			l += _er.wet_l * send
			r += _er.wet_r * send
		l = _dc_l.process(l) * g
		r = _dc_r.process(r) * g
		# One comparison pair catches NaN and infinity together. A single bad
		# sample reaching an output device is a click at full scale, and the
		# filters here are modulated fast enough that "cannot happen" is not a
		# claim worth betting a user's ears on.
		if not (l > -8.0 and l < 8.0):
			l = 0.0
		if not (r > -8.0 and r < 8.0):
			r = 0.0
		_out[i] = Vector2(AudioDSP.soft_clip(l), AudioDSP.soft_clip(r))
		g += step
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
