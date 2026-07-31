extends Node2D

## Application entry point. Configures the desktop-overlay window, then hands
## off to the world scene. Kept deliberately thin so the capture harness can
## bypass it entirely: everything that has an opinion about the running game
## lives in `world.gd`, and everything here is true before the first pet exists.

const WORLD_SCENE := "res://scenes/world.tscn"


func _ready() -> void:
	_configure_window()
	if not ResourceLoader.exists(WORLD_SCENE):
		Log.error("Boot", "world scene missing at %s" % WORLD_SCENE)
		return
	var world: Node = (load(WORLD_SCENE) as PackedScene).instantiate()
	add_child(world)


## Turn the game window into an overlay: no chrome, no background, on top of the
## player's work, and covering every monitor so a pet can walk from one screen to
## the next. `World` re-anchors this whenever the desktop is rearranged; all that
## is needed here is a first guess good enough to render the opening frame.
func _configure_window() -> void:
	var w := get_window()
	w.borderless = true
	w.transparent = true
	w.always_on_top = bool(Settings.get_value(&"always_on_top", true))
	w.transparent_bg = true
	if DisplayServer.get_name() == "headless":
		return
	var span := _virtual_desktop()
	w.position = Vector2i(span.position)
	w.size = Vector2i(span.size)


## Union of every attached display, in virtual-desktop pixels. Taken from the
## display server rather than from `DesktopBridge` because the bridge's first
## scan may not have happened yet, and the window has to be somewhere sensible
## for the very first frame.
func _virtual_desktop() -> Rect2i:
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		return Rect2i(Vector2i.ZERO, DisplayServer.window_get_size())
	var span := Rect2i(DisplayServer.screen_get_position(0), DisplayServer.screen_get_size(0))
	for i in range(1, count):
		span = span.merge(Rect2i(DisplayServer.screen_get_position(i),
			DisplayServer.screen_get_size(i)))
	return span
