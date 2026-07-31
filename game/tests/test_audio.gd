extends Node

## Headless test for the runtime synthesiser.
##
##     .tools/Godot_v4.5-stable_linux.x86_64 --path game --headless \
##         res://tests/test_audio.tscn
##
## There is no audio device in CI and there is none in the container this game
## is developed in, so nothing here goes near one: every call and every foley
## recipe is rendered straight into a buffer through exactly the code path the
## speaker would get, and then measured.
##
## What it is actually protecting is the four ways synthesised audio fails
## silently — silently in the sense that the developer, who cannot hear it,
## finds out from a user:
##
##   SILENCE   A recipe that produces nothing, usually a filter tuned past
##             Nyquist or an envelope that never opens.
##   NaN       One bad coefficient poisons a filter's state and stays there. On
##             real hardware that is a full-scale click, then silence forever.
##   CLIPPING  Anything outside [-1, 1] is distortion the user did not ask for,
##             on a program that runs all day.
##   DC        A bias eats headroom, upsets the limiter, and pushes a speaker
##             cone off centre. It is inaudible on a laptop and obvious on
##             anything good.
##
## It also checks the two policy promises that matter more than fidelity: the
## first sound the app makes is quiet, and the voice cap actually caps.

const RATE := 22050.0

## Every call id the game can currently ask for, per family. Includes the ids
## `touch_response.gd` uses, the ids the brain uses, and the ones each family is
## supposed to have — a family asked for something it does not own must still
## make a sound, and that fallback is exactly the path that rots unnoticed.
const CALLS := {
	&"cat": [&"meow", &"mrrp", &"trill", &"chirp", &"purr", &"hiss", &"yowl", &"sigh"],
	&"dog": [&"bark", &"whine", &"pant", &"huff", &"growl", &"yelp", &"sigh"],
	&"bird": [&"chirp", &"warble", &"song", &"chip", &"churr", &"squawk", &"screech"],
	&"reptile": [&"hiss", &"click", &"chuff", &"puff", &"meow"],
}

const FOLEY := [
	&"step_icon", &"step_taskbar", &"step_glass", &"step_desk", &"claw", &"land",
	&"flop", &"rustle", &"flap", &"knock", &"unmapped_thing",
]

## Base pitch per family, roughly what the specs carry.
const PITCH := {&"cat": 480.0, &"dog": 240.0, &"bird": 2600.0, &"reptile": 300.0}

var _failed := 0
var _passed := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	Log.min_level = Log.Level.WARN
	_rng.seed = 20260731

	_test_calls()
	_test_foley()
	_test_variation()
	_test_age_and_intensity()
	_test_levels_are_balanced()
	_test_ambience_is_quiet()
	_test_master_chain()
	_test_voice_cap()
	_test_intro_is_quiet()
	_test_cost()

	print("TESTS %d passed, %d failed" % [_passed, _failed])
	print("TESTS_OK" if _failed == 0 else "TESTS_FAILED")
	get_tree().quit(1 if _failed > 0 else 0)


# --- Harness -----------------------------------------------------------------

func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		return
	_failed += 1
	print("FAIL  %s%s" % [label, "  (%s)" % detail if detail != "" else ""])


## Render a voice to completion and report what came out. Runs in the same
## block sizes the mixer uses, so a bug that only appears at a block boundary
## has somewhere to appear here too.
func _measure(v: AudioVoice, label: String) -> Dictionary:
	v.setup(RATE)
	var chunk := 512
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	l.resize(chunk)
	r.resize(chunk)
	var peak := 0.0
	var sum := 0.0
	var sq := 0.0
	var n := 0
	var bad := 0
	var guard := int(v.max_seconds() * RATE / float(chunk)) + 4
	while not v.is_finished() and guard > 0:
		guard -= 1
		for i in chunk:
			l[i] = 0.0
			r[i] = 0.0
		v.render_add(l, r, chunk)
		for i in chunk:
			var a := l[i]
			var b := r[i]
			if not is_finite(a) or not is_finite(b):
				bad += 2
				continue
			peak = maxf(peak, maxf(absf(a), absf(b)))
			sum += a + b
			sq += a * a + b * b
			n += 2
	_check(guard > 0, "%s terminates" % label)
	return {
		"peak": peak,
		"rms": sqrt(sq / maxf(float(n), 1.0)),
		"dc": sum / maxf(float(n), 1.0),
		"bad": bad,
		"frames": n / 2,
	}


## The four invariants, in one place so every recipe is held to the same bar.
func _assert_sane(m: Dictionary, label: String, min_peak: float = 0.008) -> void:
	_check(int(m["bad"]) == 0, "%s is free of NaN/inf" % label, "%d bad samples" % m["bad"])
	_check(float(m["peak"]) >= min_peak, "%s is audible" % label,
		"peak %.5f" % m["peak"])
	_check(float(m["peak"]) <= 1.0, "%s does not clip" % label, "peak %.4f" % m["peak"])
	_check(float(m["rms"]) > 0.0004, "%s has body" % label, "rms %.6f" % m["rms"])
	# 2 % of the peak is well under audibility and well under what any real
	# source drifts to; anything past that is a bug in a filter, not a sound.
	_check(absf(float(m["dc"])) < 0.02 * maxf(float(m["peak"]), 0.02),
		"%s has no DC offset" % label, "dc %.6f vs peak %.4f" % [m["dc"], m["peak"]])


# --- Voices ------------------------------------------------------------------

func _test_calls() -> void:
	for family in CALLS:
		var hz: float = PITCH[family]
		for call_id in CALLS[family]:
			# Adult, ordinary intensity: the common case.
			var m := CallLibrary.build(call_id, family, hz, 0.6, 0.0, 0.4, _rng)
			var r := _measure(m, "%s/%s" % [family, call_id])
			_assert_sane(r, "%s/%s" % [family, call_id])
			_check(int(r["frames"]) > int(0.02 * RATE), "%s/%s has duration" % [family, call_id],
				"%d frames" % r["frames"])


func _test_foley() -> void:
	for id in FOLEY:
		for i in [0.0, 1.0]:
			var f := FoleyLibrary.build(id, i, _rng)
			var label := "foley/%s@%.0f" % [id, i]
			var r := _measure(f, label)
			# Foley is deliberately faint; a footfall at zero force is meant to
			# be near the floor of audibility, not at it.
			_assert_sane(r, label, 0.002)
	# The whole point of the surface table: three surfaces, three sounds.
	_check(FoleyLibrary.step_for_surface(&"icon") == &"step_icon", "icons sound like icons")
	_check(FoleyLibrary.step_for_surface(&"window_edge") == &"step_glass",
		"window edges sound like glass")
	_check(FoleyLibrary.step_for_surface(&"nonsense") == &"step_desk",
		"an unknown surface falls back to the desk")


## A sampled-sounding pet is a dead pet: the same call twice must not be the
## same waveform. Compared on gross features, because that is what an ear
## notices — two meows that differ only in the sixth decimal are one meow.
func _test_variation() -> void:
	for family in [&"cat", &"dog", &"bird"]:
		var hz: float = PITCH[family]
		var call_id: StringName = CALLS[family][0]
		var seen := []
		for i in 6:
			var m := CallLibrary.build(call_id, family, hz, 0.6, 0.0, 0.4, _rng)
			var r := _measure(m, "%s/%s var" % [family, call_id])
			seen.append([float(r["peak"]), float(r["rms"]), int(r["frames"])])
		var same := 0
		for i in range(1, seen.size()):
			if absf(seen[i][0] - seen[0][0]) < 0.0005 and seen[i][2] == seen[0][2]:
				same += 1
		_check(same == 0, "%s/%s is different every time" % [family, call_id],
			"%d of %d repeats identical" % [same, seen.size() - 1])


## Age and intensity have to reach the waveform, not just the parameters.
func _test_age_and_intensity() -> void:
	var adult_len := 0
	var baby_len := 0
	var runs := 8
	for i in runs:
		# Same pitch on purpose: the test is that babyness does something
		# *besides* the pitch scale the caller already applied.
		adult_len += int(_measure(CallLibrary.build(&"meow", &"cat", 700.0, 0.6, 0.0, 0.4, _rng),
			"adult meow")["frames"])
		baby_len += int(_measure(CallLibrary.build(&"meow", &"cat", 700.0, 0.6, 1.0, 0.4, _rng),
			"baby meow")["frames"])
	_check(baby_len < adult_len, "a baby's call is shorter than an adult's",
		"%d vs %d frames" % [baby_len, adult_len])

	var soft := 0.0
	var loud := 0.0
	for i in runs:
		soft += float(_measure(CallLibrary.build(&"bark", &"dog", 240.0, 0.05, 0.0, 0.5, _rng),
			"soft bark")["rms"])
		loud += float(_measure(CallLibrary.build(&"bark", &"dog", 240.0, 1.0, 0.0, 0.5, _rng),
			"loud bark")["rms"])
	_check(loud > soft * 1.5, "intensity reaches the waveform",
		"rms %.4f vs %.4f" % [loud / runs, soft / runs])


## Level balance, which is the difference between a pet and a hazard.
##
## Every recipe's gain was calibrated by measurement rather than by ear — there
## are no ears in this container — so the band below is the calibration itself.
## A call that drifts out of it is either inaudible under a fan or loud enough to
## make someone in headphones flinch, and neither shows up in any other check.
func _test_levels_are_balanced() -> void:
	var peaks := {}
	for family in CALLS:
		for call_id in CALLS[family]:
			var label := "%s/%s" % [family, call_id]
			var worst := 0.0
			for take in 3:
				var m := CallLibrary.build(call_id, family, PITCH[family], 1.0, 0.0, 0.4, _rng)
				worst = maxf(worst, float(_measure(m, label)["peak"]))
			peaks[label] = worst
			_check(worst >= 0.12 and worst <= 0.78, "%s sits in the level band" % label,
				"peak %.3f" % worst)
	# Intent has to survive the calibration: the two calls a pet makes when it is
	# content must stay under the two it makes when it is not.
	_check(float(peaks["cat/purr"]) < float(peaks["cat/yowl"]) * 0.7,
		"a purr is quieter than a yowl")
	_check(float(peaks["dog/pant"]) < float(peaks["dog/bark"]) * 0.7,
		"panting is quieter than barking")

	var step := 0.0
	var land := 0.0
	for take in 3:
		step = maxf(step, float(_measure(FoleyLibrary.build(&"step_icon", 1.0, _rng),
			"step")["peak"]))
		land = maxf(land, float(_measure(FoleyLibrary.build(&"land", 1.0, _rng),
			"land")["peak"]))
	_check(step < 0.16, "a footfall stays discreet", "peak %.3f" % step)
	_check(land > step * 2.5, "a landing does not", "%.3f vs %.3f" % [land, step])


func _test_ambience_is_quiet() -> void:
	var bed := AmbienceBed.new()
	bed.gain = 1.0
	bed.setup(RATE)
	var l := PackedFloat32Array()
	var r := PackedFloat32Array()
	l.resize(4096)
	r.resize(4096)
	var peak := 0.0
	var sum := 0.0
	var bad := 0
	for block in 12:
		for i in 4096:
			l[i] = 0.0
			r[i] = 0.0
		bed.render_add(l, r, 4096)
		for i in 4096:
			if not is_finite(l[i]) or not is_finite(r[i]):
				bad += 1
				continue
			peak = maxf(peak, maxf(absf(l[i]), absf(r[i])))
			sum += l[i] + r[i]
	_check(bad == 0, "the ambience bed is free of NaN/inf", "%d bad samples" % bad)
	_check(peak > 0.0008, "the ambience bed is not silent", "peak %.5f" % peak)
	_check(peak <= AmbienceBed.PEAK, "the ambience bed stays under its ceiling",
		"peak %.5f vs %.5f" % [peak, AmbienceBed.PEAK])
	_check(absf(sum / (12.0 * 8192.0)) < 0.0005, "the ambience bed has no DC offset")

	bed.gain = 0.0
	for i in 4096:
		l[i] = 0.0
		r[i] = 0.0
	# Two blocks: the first ramps down from the previous level, the second is
	# the steady state a muted bed is supposed to be.
	bed.render_add(l, r, 4096)
	for i in 4096:
		l[i] = 0.0
		r[i] = 0.0
	bed.render_add(l, r, 4096)
	var off := 0.0
	for i in 4096:
		off = maxf(off, absf(l[i]))
	_check(off == 0.0, "ambience at zero gain is actually silent", "peak %.6f" % off)


## The full engine path — voices, early reflections, DC blocker, limiter — is
## what actually reaches a speaker, so it gets its own pass.
func _test_master_chain() -> void:
	var synth := VoiceSynth.new()
	add_child(synth)
	synth.set_mix(1.0, 1.0, 1.0)
	for i in 4:
		synth.play_call(&"yowl", 520.0, 1.0, 1.0, {"family": &"cat"})
	synth.play_foley(&"land", 1.0, 1.0)
	var peak := 0.0
	var sum := 0.0
	var n := 0
	var bad := 0
	for block in 40:
		var buf := synth.render_offline(512)
		for f in buf:
			if not is_finite(f.x) or not is_finite(f.y):
				bad += 1
				continue
			peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
			sum += f.x + f.y
			n += 2
	_check(bad == 0, "the master chain is free of NaN/inf", "%d bad samples" % bad)
	_check(peak > 0.005, "the master chain passes audio", "peak %.5f" % peak)
	_check(peak <= 1.0, "the master chain never clips", "peak %.5f" % peak)
	_check(absf(sum / float(maxi(n, 1))) < 0.001, "the master chain has no DC offset",
		"dc %.6f" % (sum / float(maxi(n, 1))))
	synth.queue_free()


## Four voices is the budget. Twenty simultaneous events must cost four voices,
## and the ones that survive must be the vocalisations rather than the footfalls.
func _test_voice_cap() -> void:
	var synth := VoiceSynth.new()
	add_child(synth)
	for i in 20:
		synth.play_foley(&"step_icon", 0.6, 1.0)
	_check(synth.active_voices() <= VoiceSynth.MAX_VOICES, "foley respects the voice cap",
		"%d voices" % synth.active_voices())
	var took: bool = synth.play_call(&"meow", 480.0, 0.8, 1.0, {"family": &"cat"})
	_check(took, "a voice may steal a slot from foley")
	_check(synth.active_voices() <= VoiceSynth.MAX_VOICES, "and the cap still holds",
		"%d voices" % synth.active_voices())
	# ...but foley may not steal from a voice. Fill up with calls first.
	var synth2 := VoiceSynth.new()
	add_child(synth2)
	for i in VoiceSynth.MAX_VOICES:
		synth2.play_call(&"meow", 480.0, 0.8, 1.0, {"family": &"cat"})
	_check(not synth2.play_foley(&"step_icon", 0.5, 1.0),
		"a footfall never interrupts a vocalisation")
	synth.queue_free()
	synth2.queue_free()


## The promise that keeps this app off someone's HR record: whatever else
## happens, the first thing it ever plays is quiet.
func _test_intro_is_quiet() -> void:
	var young := VoiceSynth.new()
	add_child(young)
	young.play_call(&"bark", 240.0, 1.0, 1.0, {"family": &"dog"})
	var first := _peak_of(young, 30)

	var old := VoiceSynth.new()
	add_child(old)
	# Age it past the intro fade by rendering a minute of silence, which is what
	# an idle pet does anyway.
	for i in 70:
		old.render_offline(int(RATE))
	old.play_call(&"bark", 240.0, 1.0, 1.0, {"family": &"dog"})
	var later := _peak_of(old, 30)

	_check(first < later * 0.6, "the first sound the app makes is quiet",
		"%.4f vs %.4f" % [first, later])
	_check(first > 0.0, "but it is not silent", "%.5f" % first)
	young.queue_free()
	old.queue_free()


## The whole design rests on synthesis being cheap enough to do on the main
## thread, in GDScript, inside a frame. The bound is deliberately loose — this
## runs on a shared software-rendered container — because what it is there to
## catch is a structural regression: a raised mix rate, a formant bank moved to
## per-sample coefficients, a voice cap quietly lifted.
func _test_cost() -> void:
	var synth := VoiceSynth.new()
	add_child(synth)
	synth.set_mix(1.0, 1.0, 1.0)
	var seconds := 2.0
	var blocks := int(seconds * RATE / 512.0)
	var t0 := Time.get_ticks_usec()
	for b in blocks:
		if b % 24 == 0:
			for i in VoiceSynth.MAX_VOICES:
				synth.play_call(&"yowl", 520.0, 1.0, 1.0, {"family": &"cat"})
		synth.render_offline(512)
	var saturated := float(Time.get_ticks_usec() - t0) / 1000.0 / seconds

	# The case that actually runs all day: one pet, speaking now and then, with
	# the room bed underneath. This is the number that has to be small.
	var one := VoiceSynth.new()
	add_child(one)
	one.set_mix(0.8, 1.0, 0.5)
	t0 = Time.get_ticks_usec()
	for b in blocks:
		if b % 40 == 0:
			one.play_call(&"meow", 480.0, 0.6, 1.0, {"family": &"cat"})
		one.render_offline(512)
	var typical := float(Time.get_ticks_usec() - t0) / 1000.0 / seconds

	# And the case that runs for the other twenty-three hours.
	var idle := VoiceSynth.new()
	add_child(idle)
	t0 = Time.get_ticks_usec()
	for b in blocks:
		idle.render_offline(512)
	var quiet := float(Time.get_ticks_usec() - t0) / 1000.0 / seconds

	print("      cost per second of audio: %.1f ms saturated, %.1f ms typical, %.1f ms idle"
		% [saturated, typical, quiet])
	# Bounds sit about 50 % above what this container measures, because the
	# machine is shared and the point is to catch a structural regression — a
	# raised mix rate, per-sample filter coefficients, a lifted voice cap — not
	# to police a few milliseconds.
	_check(saturated < 480.0, "the synthesiser fits in a frame budget at the cap",
		"%.1f ms per audio second" % saturated)
	_check(typical < 200.0, "one talkative pet plus the room bed stays cheap",
		"%.1f ms" % typical)
	_check(quiet < 20.0, "and an idle pet costs nothing at all", "%.1f ms" % quiet)
	synth.queue_free()
	one.queue_free()
	idle.queue_free()


func _peak_of(synth: VoiceSynth, blocks: int) -> float:
	var peak := 0.0
	for i in blocks:
		for f in synth.render_offline(512):
			peak = maxf(peak, maxf(absf(f.x), absf(f.y)))
	return peak
