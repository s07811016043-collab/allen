extends Node

## User settings, persisted separately from save data so wiping a pet never
## resets the player's window preferences.

const PATH := "user://settings.cfg"

var data := {
	"ui_scale": 1.0,
	"pet_scale": 1.0,
	"quality": 2,            # 0 low, 1 medium, 2 high, 3 ultra
	"master_volume": 0.8,
	"voice_volume": 1.0,
	"ambience_volume": 0.5,
	"click_through": true,   # cursor passes through the pet window when idle
	"always_on_top": true,
	"reduced_motion": false,
	"frame_cap": 60,
	"desktop_bounds_inset": 8,
}

## Quality presets consumed by the render stack. Kept here rather than in the
## renderer so the diagnostics overlay and the capture harness agree on names.
const QUALITY_NAMES := ["Low", "Medium", "High", "Ultra"]


func _ready() -> void:
	load_settings()


func get_value(key: StringName, fallback: Variant = null) -> Variant:
	return data.get(String(key), fallback)


func set_value(key: StringName, value: Variant) -> void:
	if data.get(String(key)) == value:
		return
	data[String(key)] = value
	EventBus.settings_changed.emit(key)
	save_settings()


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for k in data.keys():
		if cfg.has_section_key("petalia", k):
			data[k] = cfg.get_value("petalia", k)
	Log.info("Settings", "loaded")


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in data.keys():
		cfg.set_value("petalia", k, data[k])
	cfg.save(PATH)
