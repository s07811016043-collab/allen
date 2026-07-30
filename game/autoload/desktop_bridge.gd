extends Node

## Everything the pet knows about the world outside the game window.
##
## A desktop pet is only convincing if it interacts with the *actual* desktop:
## it should sit on top of an icon, walk along the taskbar, and duck behind a
## window edge. Those facts are OS-specific, so this node presents one stable
## interface and picks a provider underneath.
##
## Providers live in `core/nav/providers/`. When no provider can enumerate real
## icons — a locked-down Linux desktop, a Wayland session, a first run before
## permission is granted — the bridge falls back to a plausible simulated
## desktop so the pet still has furniture to climb on and the experience never
## degrades to "floats in a void". The simulation is deliberately shaped like a
## real desktop (grid on the left, windows in the middle, taskbar at the bottom)
## so that the moment a provider does come online, nothing about the pet's
## behaviour visibly changes.

## Ledges are defined in `core/nav/ledge.gd` so the providers can build them
## without importing this singleton — a provider that preloads the autoload that
## loads the provider is a parse-time cycle. Re-exported here because
## `DesktopBridge.Ledge` is the name the rest of the game already uses.
const Ledge := preload("res://core/nav/ledge.gd")

## One physical display. Multi-monitor matters more for a desktop pet than for a
## game: the pet lives in *virtual desktop* space that spans every screen, and
## walking off the right edge of one monitor onto the next is a feature, not an
## edge case.
class ScreenInfo:
	var index: int = 0
	## Full bounds in virtual-desktop pixels.
	var rect: Rect2 = Rect2()
	## Bounds minus taskbar/Dock/menu bar.
	var work_area: Rect2 = Rect2()
	var dpi: int = 96
	## Backing-store scale (2.0 on a Retina panel). Combined with `dpi` this is
	## what keeps a pet the same *apparent* size on mismatched monitors.
	var scale: float = 1.0
	var primary: bool = false

	## Pixels per logical point. A pet sized in rig units is multiplied by this
	## so it covers the same fraction of a 4K screen as of a 1080p one.
	func content_scale() -> float:
		return maxf(scale, float(dpi) / 96.0)


## Fired only when the topology genuinely changed — see `_signature()`. Rescans
## happen every few seconds; firing on every one of them would make every pet
## re-plan its route several times a minute for no reason.
signal topology_changed()

var ledges: Array[Ledge] = []
var screens: Array[ScreenInfo] = []
## The screen the overlay window is currently on. `screen_rect` and `work_area`
## track it, so single-monitor callers can keep ignoring the rest.
var current_screen := 0
var screen_rect := Rect2(0, 0, 1920, 1080)
var work_area := Rect2(0, 0, 1920, 1040)
## Union of every display: the coordinate space ledges and pets actually live in.
var virtual_desktop := Rect2(0, 0, 1920, 1080)
## Bumped on every real topology change. Cheap for a navigator to poll, which is
## how pets notice the world moved without holding a reference to this node.
var topology_revision := 0

## Average colour of what is behind the pet, fed into the shader as bounce
## light. See `_sample_backdrop()` for the privacy considerations — this is
## opt-in and defaults to a neutral value.
var backdrop_color := Color(0.14, 0.15, 0.18)
## Where to sample around. Whoever is drawing the pet sets this to the pet's
## position; leaving it at zero samples the middle of the work area.
var backdrop_focus := Vector2.ZERO

var _provider: RefCounted = null
var _rescan_accum := 0.0
var _poll_accum := 0.0
var _backdrop_accum := 0.0
var _signature_hash := 0
## Fallback used when the sampler is disabled or unavailable, so the shader
## never sees a black bounce term on a bright desktop.
const NEUTRAL_BACKDROP := Color(0.14, 0.15, 0.18)
const RESCAN_INTERVAL := 4.0
## Providers publish asynchronously; polling faster than the rescan interval is
## what makes real furniture appear about a second after launch rather than
## four. Cheap: it is one bool read behind a mutex.
const PROVIDER_POLL := 0.25
const BACKDROP_INTERVAL := 0.25
## Ledge rects are rounded to this many pixels before hashing. Providers report
## sub-pixel jitter on some window managers, and without the rounding every
## rescan would look like a change.
const SIGNATURE_QUANTUM := 2.0


func _ready() -> void:
	_pick_provider()
	rescan()
	Clock.ticked.connect(_on_tick)


func _exit_tree() -> void:
	# A probe may be mid-flight on the worker pool. Letting the pool tear down
	# underneath it is how you get a crash on quit that only happens on Windows.
	if _provider != null and _provider.has_method("shutdown"):
		_provider.call("shutdown")


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum >= PROVIDER_POLL:
		_poll_accum = 0.0
		if _provider != null and _provider.has_method("has_fresh_results") \
				and _provider.call("has_fresh_results"):
			rescan()
	_backdrop_accum += delta
	if _backdrop_accum >= BACKDROP_INTERVAL:
		_backdrop_accum = 0.0
		_sample_backdrop()


func _on_tick(delta: float) -> void:
	_rescan_accum += delta
	if _rescan_accum >= RESCAN_INTERVAL:
		_rescan_accum = 0.0
		rescan()


func _pick_provider() -> void:
	var candidates := [
		"res://core/nav/providers/win32_provider.gd",
		"res://core/nav/providers/macos_provider.gd",
		"res://core/nav/providers/linux_provider.gd",
	]
	for path in candidates:
		if not ResourceLoader.exists(path):
			continue
		var script: Script = load(path)
		if script == null:
			continue
		var inst: RefCounted = script.new()
		if inst.has_method("is_available") and inst.is_available():
			_provider = inst
			Log.info("DesktopBridge", "using provider %s" % path.get_file())
			return
	Log.info("DesktopBridge", "no native provider; using simulated desktop")


## Refresh screen geometry and the ledge graph. Safe to call at any rate: the
## provider throttles its own probing and the change signal is de-duplicated.
func rescan() -> void:
	_update_screens()
	var found: Array = []
	if _provider != null and _provider.has_method("enumerate_ledges"):
		found = _provider.call("enumerate_ledges", screen_rect, work_area)
	if found.is_empty():
		found = _simulated_ledges()
	ledges.clear()
	var next_id := 0
	for l in found:
		if l is Ledge:
			l.id = next_id
			next_id += 1
			ledges.append(l)
	_link_neighbours()

	var sig := _signature()
	if sig == _signature_hash:
		return
	_signature_hash = sig
	topology_revision += 1
	topology_changed.emit()
	EventBus.desktop_topology_changed.emit()


# --- Screens -----------------------------------------------------------------

func _update_screens() -> void:
	screens.clear()
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		# Headless (tests, the capture harness). Keep a plausible desktop so the
		# nav graph is still exercised rather than degenerating to nothing.
		var s := ScreenInfo.new()
		s.rect = Rect2(0, 0, 1920, 1080)
		s.work_area = Rect2(0, 0, 1920, 1040)
		s.primary = true
		screens.append(s)
	else:
		var primary := DisplayServer.get_primary_screen()
		for i in count:
			var s := ScreenInfo.new()
			s.index = i
			s.rect = Rect2(DisplayServer.screen_get_position(i), DisplayServer.screen_get_size(i))
			var usable := DisplayServer.screen_get_usable_rect(i)
			s.work_area = Rect2(usable.position, usable.size)
			s.dpi = DisplayServer.screen_get_dpi(i)
			s.scale = DisplayServer.screen_get_scale(i)
			s.primary = i == primary
			screens.append(s)

	current_screen = clampi(DisplayServer.window_get_current_screen(), 0, screens.size() - 1)
	var cur := screens[current_screen]
	screen_rect = cur.rect
	work_area = cur.work_area
	virtual_desktop = screens[0].rect
	for s in screens:
		virtual_desktop = virtual_desktop.merge(s.rect)


## Pixels-per-logical-point for a screen, for sizing pets and jump distances.
## A pet that jumps "two icons" should jump two icons on every monitor, which
## means the nav mobility profile has to be scaled by this, not by a constant.
func dpi_scale_for(screen_index: int = -1) -> float:
	if screens.is_empty():
		return 1.0
	var i := clampi(screen_index if screen_index >= 0 else current_screen, 0, screens.size() - 1)
	return screens[i].content_scale()


func screen_at(point: Vector2) -> ScreenInfo:
	for s in screens:
		if s.rect.has_point(point):
			return s
	return screens[current_screen] if not screens.is_empty() else null


# --- Backdrop sampling -------------------------------------------------------

## Average the desktop behind the pet, for the bounce-light term in the shader.
##
## PRIVACY. Reading the framebuffer means reading whatever the user has on
## screen — a password manager, a private message, a medical record. Petalia
## therefore: (1) leaves this off unless `backdrop_sampling` is explicitly
## enabled in settings; (2) keeps nothing but a single averaged `Color`, never
## an image, never a history; (3) never writes it to disk and never sends it
## anywhere. Nine averaged pixels are not recoverable content — but the
## *capability* is the thing that matters, so it stays opt-in and stays here,
## in one function, where it can be audited.
func _sample_backdrop() -> void:
	if not bool(Settings.get_value(&"backdrop_sampling", false)):
		backdrop_color = backdrop_color.lerp(NEUTRAL_BACKDROP, 0.2)
		return
	# Headless and the capture harness both report zero screens; asking those for
	# a pixel is an engine error, not a black sample.
	if not DisplayServer.has_method("screen_get_pixel") or DisplayServer.get_screen_count() <= 0:
		return
	var focus := backdrop_focus
	if focus == Vector2.ZERO:
		focus = work_area.get_center()
	# Sample a ring well outside the pet's own silhouette. Our overlay window is
	# transparent there, so the composited pixel that comes back is the desktop
	# underneath rather than the pet's own colours feeding back on themselves.
	var radius := 90.0
	var total := Color(0, 0, 0, 0)
	var taken := 0
	for i in 8:
		var a := TAU * float(i) / 8.0
		var p := focus + Vector2(cos(a), sin(a)) * radius
		p.x = clampf(p.x, virtual_desktop.position.x + 1.0, virtual_desktop.end.x - 2.0)
		p.y = clampf(p.y, virtual_desktop.position.y + 1.0, virtual_desktop.end.y - 2.0)
		var c: Color = DisplayServer.screen_get_pixel(Vector2i(p))
		if c.a <= 0.0:
			continue
		total += c
		taken += 1
	if taken == 0:
		return
	var avg := total / float(taken)
	avg.a = 1.0
	# Ease rather than snap: bounce light that pops as the pet crosses a window
	# border is more distracting than no bounce light at all.
	backdrop_color = backdrop_color.lerp(avg, 0.25)


# --- Simulated desktop -------------------------------------------------------

## A believable stand-in desktop: an icon grid on the left, two application
## windows with climbable edges, a taskbar and the screen floor. Spacing matches
## Windows' default 76x90 cell so the simulated layout lines up with the real
## one if a provider appears later, and every piece carries a stable key so a
## navigator can be tested against it exactly as against a real desktop.
func _simulated_ledges() -> Array:
	var out: Array = []
	var cell := Vector2(76.0, 90.0)
	var origin := work_area.position + Vector2(16.0, 16.0)
	# Fill the column the way a real desktop does — all the way down. It matters
	# for more than looks: the bottom icon of a full column is within one hop of
	# the screen floor, and that is the only rung connecting a ground animal to
	# the icon grid at all.
	var rows: int = clampi(int(floor((work_area.size.y - 40.0) / cell.y)), 1, 12)
	var names := ["Recycle Bin", "This PC", "Downloads", "Projects", "Notes.txt",
		"Screenshots", "Music", "Archive", "Scratch", "Reference", "Invoices", "Trash"]
	var n := 0
	for col in 2:
		for row in rows:
			var l := Ledge.new()
			l.rect = Rect2(origin + Vector2(col * cell.x, row * cell.y), Vector2(48.0, 48.0))
			l.kind = &"icon"
			l.label = names[n % names.size()]
			l.key = "sim:icon:%d" % n
			l.approximate = true
			l.climb_left = true
			l.climb_right = true
			out.append(l)
			n += 1

	# Two overlapping windows, sized and placed the way a person actually leaves
	# them: one large and central, one small and offset. Their side faces give a
	# climber somewhere to go and a ground animal something to path around.
	var win_defs := [
		[Rect2(work_area.position + Vector2(work_area.size.x * 0.30, work_area.size.y * 0.22),
			Vector2(work_area.size.x * 0.42, work_area.size.y * 0.52)), "Editor"],
		[Rect2(work_area.position + Vector2(work_area.size.x * 0.58, work_area.size.y * 0.48),
			Vector2(work_area.size.x * 0.30, work_area.size.y * 0.36)), "Notes"],
	]
	for i in win_defs.size():
		var r: Rect2 = win_defs[i][0]
		for d in DesktopProvider.window_ledges(r, String(win_defs[i][1]), "sim:win:%d" % i, i + 1):
			out.append(Ledge.from_dict(d))

	for d in DesktopProvider.screen_furniture(screen_rect, work_area, current_screen):
		out.append(Ledge.from_dict(d))
	return out


# --- Queries -----------------------------------------------------------------

## Connect ledges that are close enough to hop between. `LedgeGraph` does the
## real, species-aware reachability test; this is a coarse seed for anything
## that wants a neighbour list without building a graph.
func _link_neighbours() -> void:
	var hop := Vector2(190.0, 170.0) * dpi_scale_for()
	for a in ledges:
		var n := PackedInt32Array()
		for b in ledges:
			if b.id == a.id:
				continue
			var d: Vector2 = (b.rect.get_center() - a.rect.get_center()).abs()
			if d.x <= hop.x and d.y <= hop.y:
				n.append(b.id)
		a.neighbours = n


## Identity of the current topology. Anything that would change a pet's route
## goes in; anything that would not, stays out. Rects are quantised because
## several window managers report sub-pixel geometry that dithers frame to frame.
func _signature() -> int:
	var parts := PackedStringArray()
	for s in screens:
		parts.append("S%d %d %d %d %d %d %d %d %d" % [s.index,
			int(s.rect.position.x), int(s.rect.position.y),
			int(s.rect.size.x), int(s.rect.size.y),
			int(s.work_area.position.x), int(s.work_area.position.y),
			int(s.work_area.size.x), int(s.work_area.size.y)])
	for l in ledges:
		parts.append("L%s %s %d %d %d %d" % [l.kind, l.key,
			int(l.rect.position.x / SIGNATURE_QUANTUM),
			int(l.rect.position.y / SIGNATURE_QUANTUM),
			int(l.rect.size.x / SIGNATURE_QUANTUM),
			int(l.rect.size.y / SIGNATURE_QUANTUM)])
	return "\n".join(parts).hash()


## Duck-typed accessors used by `Navigator`, so a pet can be pointed at a
## synthetic desktop in a test without knowing this singleton exists.
func get_ledges() -> Array:
	return ledges


func get_topology_revision() -> int:
	return topology_revision


func ledge_by_id(id: int) -> Ledge:
	for l in ledges:
		if l.id == id:
			return l
	return null


## Look-up by rescan-stable identity. Ids are renumbered by every scan; keys are
## not, which is what lets a pet keep chasing an icon the user just dragged.
func ledge_by_key(key: String) -> Ledge:
	if key == "":
		return null
	for l in ledges:
		if l.key == key:
			return l
	return null


func ledges_of_kind(kind: StringName) -> Array[Ledge]:
	var out: Array[Ledge] = []
	for l in ledges:
		if l.kind == kind:
			out.append(l)
	return out


## Nearest walkable surface below `point`, used when a pet is dropped.
func ground_below(point: Vector2) -> Ledge:
	var best: Ledge = null
	var best_dy := INF
	for l in ledges:
		if not l.is_standable():
			continue
		if l.rect.position.y < point.y - 1.0:
			continue
		if point.x < l.rect.position.x - 8.0 or point.x > l.rect.end.x + 8.0:
			continue
		var dy: float = l.rect.position.y - point.y
		if dy < best_dy:
			best_dy = dy
			best = l
	return best


func nearest_ledge(point: Vector2) -> Ledge:
	var best: Ledge = null
	var best_d := INF
	for l in ledges:
		if not l.is_standable():
			continue
		var d: float = l.surface_point(point.x).distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = l
	return best
