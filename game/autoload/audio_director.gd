extends Node

## Audio front-end.
##
## Petalia synthesises every sound at runtime — there are no wav files. A
## desktop pet lives in the corner of someone's working day, so the audio has
## to be small, never repetitive, and instantly duckable. Procedural voices give
## us all three: each meow is a fresh sample of a parameterised model, so the
## hundredth one does not sound like the first.
##
## The synthesis lives in `res://audio/`; this singleton is the routing and
## policy layer that the rest of the game talks to. Policy here means four
## things, in order of how much trouble they save:
##
##   QUIET      The app fades its own voice in over its first minute and never
##              plays anything at full scale. Petalia runs all day on a machine
##              that also joins meetings.
##   DUCK       Anything the user does that means "I am working" — typing, for
##              now — pulls the mix down for a second.
##   LIMIT      Per-pet, per-call rate limiting up here; a hard voice cap down
##              in the mixer. A stroke gesture fires every frame and must not
##              turn into a machine-gun of purrs.
##   CONTEXT    Callers pass a call id and a pitch. Which species is speaking,
##              how young it is and how nasal its voice should be are looked up
##              here, so no caller has to know how the synthesiser is shaped.

## Hard ceiling on simultaneous voices, enforced by the mixer. Four is a CPU
## budget as much as a taste decision — see `VoiceSynth.MAX_VOICES`.
const MAX_VOICES := 4

## Minimum gap between two identical calls from one pet.
const CALL_COOLDOWN_MS := 140
## Foley is far more frequent than speech, and footfalls in particular arrive on
## a gait timer that can briefly outrun the ear. Per-id minimums, in ms.
const FOLEY_COOLDOWN_MS := {
	&"rustle": 190, &"stroke": 190, &"flap": 120, &"claw": 70, &"claw_tap": 70,
}
const FOLEY_COOLDOWN_DEFAULT := 55

## How long the mix stays down after a keystroke.
const TYPING_DUCK_SECONDS := 1.1

var master := 0.8
var voice_gain := 1.0
var ambience_gain := 0.5
var muted := false

var _synth: Node = null
var _last_call_at := {}
var _last_foley_at := {}
## Pet id -> the ledge kind it is standing on, so a footfall knows whether it
## landed on an icon, the taskbar or the edge of a window. Whoever moves the pet
## is the only thing that knows this; it is pushed in rather than polled.
var _surface := {}


func _ready() -> void:
	_apply_settings()
	EventBus.settings_changed.connect(func(_k: StringName) -> void: _apply_settings())
	var synth_path := "res://audio/voice_synth.gd"
	if ResourceLoader.exists(synth_path):
		var s: Script = load(synth_path)
		_synth = s.new()
		_synth.name = "VoiceSynth"
		add_child(_synth)
		_synth.set(&"max_voices", MAX_VOICES)
		_push_mix()
	else:
		Log.info("AudioDirector", "voice synth not present yet; audio is silent")
	# Fur under the cursor is the one foley the bus can already tell us about.
	# Connected by name, the way the VFX director does it, so this file keeps
	# parsing while someone else is extending the bus.
	if EventBus.has_signal(&"pet_stroked"):
		EventBus.connect(&"pet_stroked", _on_pet_stroked)
	set_process_unhandled_key_input(true)


## Typing is the clearest signal we get that the user is working rather than
## playing with the pet. Only keys the game did not consume reach here, so this
## costs nothing while the player is driving the UI.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.is_echo():
		note_typing()


func _apply_settings() -> void:
	master = float(Settings.get_value(&"master_volume", 0.8))
	voice_gain = float(Settings.get_value(&"voice_volume", 1.0))
	ambience_gain = float(Settings.get_value(&"ambience_volume", 0.5))
	_push_mix()


func _push_mix() -> void:
	if _synth != null and _synth.has_method("set_mix"):
		_synth.call("set_mix", 0.0 if muted else master, voice_gain, ambience_gain)


## Play a creature vocalisation. `call_id` selects the model (&"meow", &"purr",
## &"chirp", &"hiss"...), `pitch_hz` and `intensity` come from the creature's
## spec and current mood so the same call reads differently for a scared baby
## and a contented adult.
func vocalise(pet_id: StringName, call_id: StringName, pitch_hz: float,
		intensity: float) -> void:
	if muted or _synth == null:
		return
	# Rate-limit per pet so a stroke gesture cannot machine-gun purrs.
	var now := Time.get_ticks_msec()
	var key := "%s/%s" % [pet_id, call_id]
	if now - int(_last_call_at.get(key, -9999)) < CALL_COOLDOWN_MS:
		return
	_last_call_at[key] = now
	if _synth.has_method("play_call"):
		_synth.call("play_call", call_id, pitch_hz, clampf(intensity, 0.0, 1.0),
			master * voice_gain, _voice_context(pet_id))
	EventBus.pet_vocalised.emit(pet_id, call_id, intensity)


## Non-vocal foley: footfalls, a landing thud, claws on an icon.
func foley(foley_id: StringName, intensity: float = 1.0) -> void:
	if muted or _synth == null:
		return
	var now := Time.get_ticks_msec()
	var gap: int = int(FOLEY_COOLDOWN_MS.get(foley_id, FOLEY_COOLDOWN_DEFAULT))
	if now - int(_last_foley_at.get(foley_id, -9999)) < gap:
		return
	_last_foley_at[foley_id] = now
	if _synth.has_method("play_foley"):
		_synth.call("play_foley", foley_id, clampf(intensity, 0.0, 1.0), master)


## A paw landed. The surface decides the timbre, which is why the pet has to
## tell us where it is standing — an icon, the taskbar and a window edge are
## three different materials and they are what makes the pet feel *on* the
## desktop rather than in front of it.
func footstep(pet_id: StringName, force: float = 1.0) -> void:
	var kind: StringName = _surface.get(pet_id, &"")
	foley(FoleyLibrary.step_for_surface(kind), clampf(force, 0.0, 1.0))


## Tell the audio layer what a pet is standing on. Cheap enough to call every
## time a navigator changes ledge.
func set_surface(pet_id: StringName, ledge_kind: StringName) -> void:
	_surface[pet_id] = ledge_kind


## Hook a creature's rig up to the foley layer. Guarded end to end: the creature
## is built by another part of the project and may not have grown a `footfall`
## signal yet, in which case the pet simply walks quietly.
func bind_creature(pet_id: StringName, creature: Node) -> void:
	if creature == null or not creature.has_signal(&"footfall"):
		return
	# A bound method rather than a lambda: two lambdas are never equal, so
	# `is_connected` would never catch a second bind of the same creature.
	var cb := Callable(self, "_on_footfall").bind(pet_id)
	if not creature.is_connected(&"footfall", cb):
		creature.connect(&"footfall", cb)


func _on_footfall(_slot: int, force: float, pet_id: StringName) -> void:
	footstep(pet_id, clampf(force, 0.0, 1.0))


## Pull the mix down for a moment. Public because "the user needs the desktop
## back" is not a thing only the keyboard can mean.
func note_typing() -> void:
	duck(TYPING_DUCK_SECONDS)


func duck(seconds: float) -> void:
	if _synth != null and _synth.has_method("duck"):
		_synth.call("duck", seconds)


func set_muted(value: bool) -> void:
	if muted == value:
		return
	muted = value
	_push_mix()
	if muted and _synth != null and _synth.has_method("stop_all"):
		_synth.call("stop_all", false)


## Live voice count, for the diagnostics overlay.
func voice_count() -> int:
	if _synth != null and _synth.has_method("active_voices"):
		return int(_synth.call("active_voices"))
	return 0


func _on_pet_stroked(_pet_id: StringName, _region: StringName, speed: float) -> void:
	# A hand moving through fur, not a hand resting on it. The rate limit in
	# `foley` does the rest; this signal fires every frame the cursor moves.
	if speed > 40.0:
		foley(&"rustle", clampf(speed / 900.0, 0.15, 1.0))


## Everything the synthesiser needs to know about who is speaking. Resolved from
## the save record rather than passed in, so call sites stay two arguments long.
func _voice_context(pet_id: StringName) -> Dictionary:
	var out := {"family": &"cat", "baby": 0.0, "timbre": 0.5}
	if not GameState.has_method("pet_by_id"):
		return out
	var r: Variant = GameState.pet_by_id(pet_id)
	if r == null or not GameState.has_method("spec_for"):
		return out
	# The spec is read duck-typed. `core/creature` is edited by other agents, and
	# an autoload that fails to parse takes the whole game down with it.
	var spec: Variant = GameState.spec_for(r.species)
	out["family"] = _family_of(r.species, spec)
	if spec != null:
		out["timbre"] = float(spec.get(&"voice_timbre"))
		if spec.has_method("babyness_at"):
			out["baby"] = float(spec.call("babyness_at", r.growth))
	return out


## Species to voice family. Deliberately a local four-line table rather than a
## call into the interaction layer's equivalent: this file has to keep parsing
## while the rest of the project is being edited around it, and the cost of the
## duplication is four lines.
func _family_of(species: StringName, spec: Variant) -> StringName:
	match species:
		&"cat", &"dog", &"bird", &"reptile":
			return species
	if spec != null:
		if bool(spec.get(&"can_fly")):
			return &"bird"
		if bool(spec.get(&"can_climb")):
			return &"cat"
	return &"dog"
