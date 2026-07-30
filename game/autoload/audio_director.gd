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
## policy layer that the rest of the game talks to.

const MAX_VOICES := 6

var master := 0.8
var voice_gain := 1.0
var ambience_gain := 0.5
var muted := false

var _synth: Node = null
var _last_call_at := {}


func _ready() -> void:
	_apply_settings()
	EventBus.settings_changed.connect(func(_k: StringName) -> void: _apply_settings())
	var synth_path := "res://audio/voice_synth.gd"
	if ResourceLoader.exists(synth_path):
		var s: Script = load(synth_path)
		_synth = s.new()
		add_child(_synth)
	else:
		Log.info("AudioDirector", "voice synth not present yet; audio is silent")


func _apply_settings() -> void:
	master = float(Settings.get_value(&"master_volume", 0.8))
	voice_gain = float(Settings.get_value(&"voice_volume", 1.0))
	ambience_gain = float(Settings.get_value(&"ambience_volume", 0.5))


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
	if now - int(_last_call_at.get(key, -9999)) < 140:
		return
	_last_call_at[key] = now
	if _synth.has_method("play_call"):
		_synth.play_call(call_id, pitch_hz, clampf(intensity, 0.0, 1.0),
			master * voice_gain)
	EventBus.pet_vocalised.emit(pet_id, call_id, intensity)


## Non-vocal foley: footfalls, a landing thud, claws on an icon.
func foley(foley_id: StringName, intensity: float = 1.0) -> void:
	if muted or _synth == null:
		return
	if _synth.has_method("play_foley"):
		_synth.play_foley(foley_id, clampf(intensity, 0.0, 1.0), master)
