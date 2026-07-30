extends Node2D

## Application entry point. Configures the desktop-overlay window, then hands
## off to the world scene. Kept deliberately thin so the capture harness can
## bypass it entirely.

func _ready() -> void:
	_configure_window()
	var world_path := "res://scenes/world.tscn"
	if ResourceLoader.exists(world_path):
		var world: Node = (load(world_path) as PackedScene).instantiate()
		add_child(world)
	else:
		Log.info("Boot", "world scene not present yet")


func _configure_window() -> void:
	var w := get_window()
	w.borderless = true
	w.transparent = true
	w.always_on_top = bool(Settings.get_value(&"always_on_top", true))
	w.transparent_bg = true
	var idx := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(idx)
	w.position = usable.position
	w.size = usable.size
