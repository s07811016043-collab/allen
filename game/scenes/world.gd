class_name PetaliaWorld
extends Node2D

## The running application.
##
## Everything else in Petalia is a component that can be tested on its own: a
## brain with no body, a navigator with no pet, a renderer with no game. This is
## the one file that puts them together and admits that the product is an overlay
## living on somebody else's desktop.
##
## Three jobs, in order of how much they matter:
##
##   * **Sequence the frame.** `PetHost` owns the per-pet order; the world owns
##     the order between pets and the world around them. Nothing here processes
##     itself — the hosts, brains, routers and creatures all have engine
##     processing switched off — so the whole simulation advances through
##     `step()` and can be driven at a fixed rate by the world test.
##
##   * **Be a good guest.** The window covers the entire virtual desktop so a pet
##     can walk between monitors, which means it is sitting on top of every piece
##     of work the player is trying to do. It therefore stays click-through
##     everywhere except the few hundred pixels the pet actually occupies,
##     re-anchors itself when the desktop is rearranged, and stops simulating
##     entirely when it is not visible. A desktop pet that costs battery while
##     minimised is a desktop pet that gets uninstalled.
##
##   * **Wire the optional layers.** VFX and the interface are loaded by path and
##     probed before use, so the game runs — silently and plainly, but it runs —
##     if either of them is mid-rewrite.
##
## Coordinate spaces: the brain, the ledge graph, the pointer and this file all
## work in *virtual desktop* pixels. Nodes live in the window's viewport. The
## only conversion is the window's own position, and it happens in exactly two
## places (`PetHost._window_origin` and `_to_window` below).

const GS := preload("res://autoload/game_state.gd")

const VFX_SCRIPT := "res://vfx/vfx_director.gd"
const UI_SCRIPT := "res://ui/ui_root.gd"

## What a first-time player wakes up to. Adopting on their behalf rather than
## opening an empty adoption screen is deliberate: the pet is the product, and it
## should be on screen before anyone is asked to choose anything.
const STARTER_SPECIES := &"cat"

## Frame rate while the overlay is not visible. Not zero: the world still has to
## notice when it comes back.
const SLEEP_FPS := 6
## How far outside the desktop a pet may drift before it is put back. Generous,
## because a legitimate jump arc leaves the surface it started on.
const STRAY_MARGIN := 96.0
## Click-through is recomputed at most this often. It is a window-manager call,
## and doing it per frame while a pet walks is measurable.
const REGION_INTERVAL := 0.1

signal pet_spawned(pet_id: StringName)

## Anything exposing `get_ledges()` / `get_topology_revision()` and a `work_area`.
## Defaults to the `DesktopBridge` autoload; the world test injects a synthetic
## desktop here so a run does not depend on the machine it runs on.
var desktop: Object = null
var hosts: Array[PetHost] = []
## `VfxDirector` and `UIRoot`, or null when either is unavailable.
var vfx: Node = null
var ui: Node = null

var _pets_layer: Node2D
var _awake := true
var _region_accum := 0.0
var _confine_rect := Rect2()
var _confine_revision := -1
## Last click-through region pushed to the window manager, and whether it was the
## "take everything" one. Cached so an idle pet costs no X round trips.
var _region := Rect2()
## Starts true because that is the window's genuine state before anything is
## pushed: with no passthrough polygon set, the window intercepts everything.
var _region_open := true
## Fallback state, for platforms with no passthrough region — see
## `_degrade_to_full_passthrough`. Starts false: the flag is off by default.
var _full_passthrough := false
var _passthrough_warned := false
var _saved_on_exit := false
var _simulated := false
## Whether the desktop source wants to be told where to sample bounce light.
## Probed once: this is asked every frame.
var _desktop_samples_backdrop := false


# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

func _ready() -> void:
	if desktop == null:
		desktop = get_node_or_null(^"/root/DesktopBridge")
	_desktop_samples_backdrop = desktop != null and desktop.get("backdrop_focus") != null

	_pets_layer = Node2D.new()
	_pets_layer.name = "Pets"
	add_child(_pets_layer)

	_build_vfx()
	_build_ui()
	_populate()
	_connect_signals()

	_apply_settings()
	_anchor_window()
	_refresh_click_through()
	Log.info("World", "running with %d pet%s on %d ledges"
		% [hosts.size(), "" if hosts.size() == 1 else "s", _ledges().size()])


func _build_vfx() -> void:
	if not ResourceLoader.exists(VFX_SCRIPT):
		Log.info("World", "no VFX layer present")
		return
	var script: Script = load(VFX_SCRIPT)
	if script == null:
		return
	vfx = script.new()
	vfx.name = "Vfx"
	add_child(vfx)


func _build_ui() -> void:
	if not ResourceLoader.exists(UI_SCRIPT):
		Log.info("World", "no interface layer present")
		return
	var script: Script = load(UI_SCRIPT)
	if script == null:
		return
	ui = script.new()
	ui.name = "UI"
	add_child(ui)
	if ui.has_signal("action_requested"):
		ui.connect("action_requested", _on_ui_action)
	if ui.has_signal("adoption_requested"):
		ui.connect("adoption_requested", _on_adoption_requested)
	if ui.has_signal("interaction_region_changed"):
		ui.connect("interaction_region_changed", _refresh_click_through)


func _populate() -> void:
	if GameState.pets.is_empty():
		var starter := GameState.adopt(STARTER_SPECIES)
		Log.info("World", "empty save; adopted a starter %s" % starter.species)
	# `GameState.pets` is duplicated because adopting from the adoption panel
	# appends to it, and mutating the array being iterated is how you lose a pet.
	for record in GameState.pets.duplicate():
		spawn(record)


## Build one pet and put it somewhere it can stand.
func spawn(record: GS.PetRecord) -> PetHost:
	var host := PetHost.new()
	_pets_layer.add_child(host)
	if not host.setup(record, desktop):
		host.queue_free()
		return null
	host.place_at(_spawn_point())
	if _simulated:
		host.set_simulated(true)
	if vfx != null:
		host.attach_vfx(vfx)
	hosts.append(host)
	pet_spawned.emit(record.id)
	return host


## Where a pet with no remembered position starts: the widest thing on the
## desktop that is not an icon, which is the floor on a bare desktop and the
## taskbar on a Windows session. Matching `PetBrain._default_spawn` matters —
## the brain and the navigator have to agree about where the pet already is.
func _spawn_point() -> Vector2:
	var best: Object = null
	for l in _ledges():
		if l.kind == &"icon":
			continue
		if best == null or l.rect.size.x > best.rect.size.x:
			best = l
	if best == null:
		return _work_area().get_center()
	return Vector2(best.rect.get_center().x, best.top_y())


func _connect_signals() -> void:
	if EventBus.has_signal(&"desktop_topology_changed"):
		EventBus.desktop_topology_changed.connect(_on_topology_changed)
	if EventBus.has_signal(&"settings_changed"):
		EventBus.settings_changed.connect(_on_settings_changed)
	if EventBus.has_signal(&"pet_landed"):
		EventBus.pet_landed.connect(_on_pet_landed)


# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var awake := _is_awake()
	if awake != _awake:
		_awake = awake
		_on_wakefulness_changed(awake)
	if not awake:
		return
	step(delta)


## One frame of the whole world. Public and separate from `_process` so the world
## test can drive simulated minutes at a fixed step, and so a paused overlay can
## still be advanced deliberately.
func step(delta: float) -> void:
	for host in hosts:
		host.step(delta)
		_confine(host)

	_region_accum += delta
	if _region_accum >= REGION_INTERVAL:
		_region_accum = 0.0
		_refresh_click_through()
	_publish_backdrop_focus()


## Keep the pet on the desktop.
##
## The navigator will not walk a pet off the world, but the world moves: a
## monitor is unplugged, the resolution drops, an icon the pet was standing on is
## deleted while it is mid-arc. Rather than clamping the position — which would
## leave a pet hovering in empty space — the pet is put back down on the nearest
## real surface, which is the same thing that happens when the player drops it.
func _confine(host: PetHost) -> void:
	if host.is_carried():
		# The player is holding it. Where they choose to dangle it is their
		# business; it is put back on a surface when they let go.
		return
	var bounds := _allowed_rect()
	if bounds.size == Vector2.ZERO:
		return
	var here := host.position_of()
	if bounds.grow(STRAY_MARGIN).has_point(here):
		return
	var home := Vector2(
		clampf(here.x, bounds.position.x + 1.0, bounds.end.x - 1.0),
		clampf(here.y, bounds.position.y + 1.0, bounds.end.y - 1.0))
	Log.debug("World", "%s strayed to (%.0f, %.0f); putting it back"
		% [host.record.id, here.x, here.y])
	host.place_at(home)


## Everywhere a pet is allowed to be: the work area, plus every surface the
## desktop actually offers. The union is the point — a taskbar or a dock sits
## *outside* the work area by definition, and standing on one is a feature.
func _allowed_rect() -> Rect2:
	var revision := _topology_revision()
	if revision == _confine_revision and _confine_rect.size != Vector2.ZERO:
		return _confine_rect
	_confine_revision = revision
	_confine_rect = _work_area()
	for l in _ledges():
		_confine_rect = _confine_rect.merge(l.rect)
	return _confine_rect


## Tell the bridge where to sample the desktop behind the pet, so the bounce
## light in the body shader comes from the wallpaper the pet is standing on
## rather than from the middle of the screen.
func _publish_backdrop_focus() -> void:
	if not _desktop_samples_backdrop or hosts.is_empty():
		return
	desktop.set("backdrop_focus", hosts[0].position_of())


# ---------------------------------------------------------------------------
# Living on somebody else's desktop
# ---------------------------------------------------------------------------

## Cover the whole virtual desktop, so a pet can walk from one monitor onto the
## next without the window having to move underneath it. Re-run whenever the
## topology changes: a resolution switch or an unplugged monitor otherwise leaves
## the overlay covering a rectangle that no longer exists.
func _anchor_window() -> void:
	if not _has_window_server():
		return
	var w := get_window()
	if w == null:
		return
	var target := _desktop_rect()
	if target.size.x < 16.0 or target.size.y < 16.0:
		return
	var pos := Vector2i(target.position.round())
	var size := Vector2i(target.size.round())
	if w.position != pos:
		w.position = pos
	if w.size != size:
		w.size = size


## Hand the cursor back to the desktop everywhere the pet is not.
##
## This is the single most important thing the overlay does. The window is on top
## of everything the player owns; if it swallowed clicks, the pet would be a bug
## report rather than a companion. The passthrough polygon is therefore the
## *only* region the window accepts the mouse in, and it is recomputed as the pet
## moves.
##
## An open panel is the one exception: while the interface is up the player is
## deliberately interacting with us, so the whole window takes the mouse and the
## panels' own hit testing decides what happens.
func _refresh_click_through() -> void:
	if not _has_window_server():
		return
	if not _region_passthrough_supported():
		_degrade_to_full_passthrough()
		return
	# An empty polygon is how "take every click" is spelled.
	var wants_all: bool = not bool(Settings.get_value(&"click_through", true))
	if not wants_all and ui != null and ui.has_method("wants_mouse"):
		wants_all = bool(ui.call("wants_mouse"))

	var region := Rect2()
	if not wants_all:
		var any := false
		for host in hosts:
			var r: Rect2 = host.hit_rect()
			region = r if not any else region.merge(r)
			any = true
		if not any:
			# No pets on screen. A degenerate box off the top-left corner is how
			# you say "intercept nothing" — an empty polygon would say the
			# opposite and swallow the player's entire desktop.
			region = Rect2(_window_origin() - Vector2(4, 4), Vector2(1, 1))
		region = region.grow(1.0).abs()

	# Pushing an unchanged region is a wasted round trip to the window manager,
	# and this runs ten times a second for as long as the app is open.
	if wants_all == _region_open and region.is_equal_approx(_region):
		return
	_region_open = wants_all
	_region = region
	if wants_all:
		DisplayServer.window_set_mouse_passthrough(PackedVector2Array())
		return
	var lo := region.position - _window_origin()
	var hi := region.end - _window_origin()
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array([
		lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y)]))


## Does this display server implement a passthrough *region* rather than just an
## all-or-nothing flag? There is no capability to query, so it is answered by
## name: the three desktop backends that carve an input shape out of a window.
func _region_passthrough_supported() -> bool:
	if not DisplayServer.has_method("window_set_mouse_passthrough"):
		return false
	var server := DisplayServer.get_name().to_lower()
	return server == "x11" or server == "windows" or server == "macos"


## The fallback when the window cannot be made selectively transparent to the
## mouse. The whole overlay becomes click-through and the pet stops being
## touchable — it is a decoration until the platform grows the capability.
##
## That is a real loss, and it is still obviously the right trade: the window
## covers the player's entire desktop, and the alternative failure is that every
## click they make for the rest of the session goes nowhere.
func _degrade_to_full_passthrough() -> void:
	if not _passthrough_warned:
		_passthrough_warned = true
		Log.warn("World", "%s offers no passthrough region; the pet cannot be clicked"
			% DisplayServer.get_name())
	var want := bool(Settings.get_value(&"click_through", true))
	if want == _full_passthrough:
		return
	_full_passthrough = want
	var w := get_window()
	if w != null:
		w.set_flag(Window.FLAG_MOUSE_PASSTHROUGH, want)


## Is anyone actually looking at us? Focus is the wrong question — an overlay is
## unfocused essentially all the time, by design. Visibility and minimisation are
## the honest ones.
func _is_awake() -> bool:
	var w := get_window()
	if w == null:
		return true
	if not w.visible:
		return false
	if not _has_window_server():
		return true
	if DisplayServer.has_method("window_get_mode"):
		return DisplayServer.window_get_mode(w.get_window_id()) \
			!= DisplayServer.WINDOW_MODE_MINIMIZED
	return true


func _on_wakefulness_changed(awake: bool) -> void:
	_pets_layer.visible = awake
	if vfx != null:
		vfx.set_process(awake)
	if awake:
		_apply_settings()
		# The desktop may have been rearranged out of sight; re-measure before the
		# first frame anyone can see.
		_anchor_window()
		for host in hosts:
			host.reground()
		_refresh_click_through()
	else:
		Engine.max_fps = SLEEP_FPS
	Log.debug("World", "overlay %s" % ["awake" if awake else "asleep"])


func _apply_settings() -> void:
	Engine.max_fps = maxi(int(Settings.get_value(&"frame_cap", 60)), 10)
	if not _has_window_server():
		return
	var w := get_window()
	if w != null:
		w.always_on_top = bool(Settings.get_value(&"always_on_top", true))


func _on_settings_changed(key: StringName) -> void:
	match key:
		&"frame_cap", &"always_on_top":
			_apply_settings()
		&"click_through":
			_refresh_click_through()


func _on_topology_changed() -> void:
	_confine_revision = -1
	_anchor_window()
	for host in hosts:
		host.reground()
	_refresh_click_through()


## A dropped pet has landed. The router and the drag simulation agreed where;
## the navigator has not heard about it yet, and `PetHost` re-anchors on the next
## frame. All that is left here is the world-level consequence: the pet may have
## been put down somewhere it is not allowed to be.
func _on_pet_landed(pet_id: StringName, _impact: float, _upright: bool) -> void:
	var host := host_by_id(pet_id)
	if host != null:
		_confine(host)


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

## Right-clicking the animal opens its menu on its head, which is what a player
## expects and what `UIRoot`'s own fallback cannot do because it does not know
## where the pets are. Handled in `_input` rather than `_unhandled_input` so it
## takes precedence over that fallback; everything else — including every left
## click, which belongs to the touch router — is left strictly alone.
func _input(event: InputEvent) -> void:
	if ui == null or not ui.has_method("summon_radial"):
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	var screen_point: Vector2 = mb.position + _window_origin()
	for host in hosts:
		if not host.contains_point(screen_point):
			continue
		var box: Rect2 = host.hit_rect()
		var head := Vector2(box.get_center().x, box.position.y)
		ui.call("summon_radial", head - _window_origin(), false)
		get_viewport().set_input_as_handled()
		return


func _on_ui_action(action: StringName, pet_id: StringName) -> void:
	var host := host_by_id(pet_id)
	if host == null and not hosts.is_empty():
		host = hosts[0]
	if host == null:
		return
	match action:
		&"feed":
			GameState.feed(host.record)
			host.react(&"perk", 0.8)
		&"play":
			GameState.play(host.record)
			host.offer_toy(&"toy", host.position_of())
			host.provoke(&"play_with_toy")
		&"pet":
			# The menu's version of a stroke. It is worth much less than actually
			# reaching out and touching the animal, on purpose.
			GameState.add_affection(host.record, 0.006, &"menu")
			GameState.add_trust(host.record, 0.003)
			EventBus.pet_stroked.emit(host.record.id, &"head", 0.0)
			host.react(&"perk", 0.5)
		&"sleep":
			host.provoke(&"nap")


func _on_adoption_requested(species: StringName, pet_name: String) -> void:
	var record: GS.PetRecord = GameState.adopt(species, pet_name)
	var host := spawn(record)
	if host == null:
		Log.warn("World", "adopted a %s but could not build it" % species)
	if ui != null and ui.has_method("refresh_pet"):
		ui.call("refresh_pet")


# ---------------------------------------------------------------------------
# Queries and lifecycle
# ---------------------------------------------------------------------------

func host_by_id(pet_id: StringName) -> PetHost:
	for host in hosts:
		if host.record != null and host.record.id == pet_id:
			return host
	return null


## Drive the pets from the caller's clock instead of the wall clock, and stop
## the routers reading the real pointer. Applies to pets adopted later too.
func set_simulated(on: bool) -> void:
	_simulated = on
	for host in hosts:
		host.set_simulated(on)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_EXIT_TREE, NOTIFICATION_CRASH:
			_shutdown()


## The pet is the point of the app; losing an evening of it to a hard quit is
## unforgivable. `SaveSystem` writes atomically, so calling this more than once
## on the way out is harmless — the flag is only there to keep it cheap.
func _shutdown() -> void:
	if _saved_on_exit:
		return
	_saved_on_exit = true
	for host in hosts:
		if host.record != null:
			GameState.mark_seen(host.record)
	SaveSystem.save(GameState.serialise())


# ---------------------------------------------------------------------------
# Desktop accessors
# ---------------------------------------------------------------------------
#
# All four are duck-typed the same way `Navigator` reads its world, so a test can
# hand this scene a synthetic desktop and never touch the autoload.

func _ledges() -> Array:
	if desktop == null:
		return []
	if desktop.has_method("get_ledges"):
		var got: Variant = desktop.call("get_ledges")
		return got if typeof(got) == TYPE_ARRAY else []
	var v: Variant = desktop.get("ledges")
	return v if typeof(v) == TYPE_ARRAY else []


func _topology_revision() -> int:
	if desktop == null:
		return 0
	if desktop.has_method("get_topology_revision"):
		return int(desktop.call("get_topology_revision"))
	var v: Variant = desktop.get("topology_revision")
	return int(v) if typeof(v) == TYPE_INT else 0


func _work_area() -> Rect2:
	if desktop != null:
		var v: Variant = desktop.get("work_area")
		if v is Rect2 and (v as Rect2).size.x > 1.0:
			return v
	return Rect2(Vector2.ZERO, get_viewport_rect().size)


## The rectangle the overlay window should cover: every monitor, unioned.
func _desktop_rect() -> Rect2:
	if desktop != null:
		var v: Variant = desktop.get("virtual_desktop")
		if v is Rect2 and (v as Rect2).size.x > 1.0:
			return v
	return _work_area()


static func _window_origin() -> Vector2:
	return Vector2(DisplayServer.window_get_position())


## Is there a real window manager behind us? The capture harness and the tests
## run on the headless driver, where every window call is a no-op that would
## still cost a round trip and, for passthrough, log a warning per frame.
static func _has_window_server() -> bool:
	return DisplayServer.get_name() != "headless"
