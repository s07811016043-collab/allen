extends Node

## Everything the pet knows about the world outside the game window.
##
## A desktop pet is only convincing if it interacts with the *actual* desktop:
## it should sit on top of an icon, walk along the taskbar, and duck behind a
## window edge. Those facts are OS-specific, so this node presents one stable
## interface and picks a provider underneath.
##
## Providers are added by the platform layer under `core/nav/providers/`. When
## no provider can enumerate real icons — a locked-down Linux desktop, a
## Wayland session, a first run before permission is granted — the bridge falls
## back to a plausible simulated grid so the pet still has furniture to climb
## on and the experience never degrades to "floats in a void".

## An interactable surface the pet can stand on, climb, or perch atop.
class Ledge:
	var id: int = 0
	## Screen-space rectangle of the supporting surface.
	var rect: Rect2 = Rect2()
	## Which edge of `rect` is walkable, as a unit normal (usually UP).
	var normal: Vector2 = Vector2.UP
	## &"icon", &"taskbar", &"window_top", &"screen_floor", &"screen_edge".
	var kind: StringName = &"icon"
	## Human-readable label when known, e.g. the icon's filename. Used for
	## flavour ("your cat is sniffing Recycle Bin").
	var label: String = ""
	## Ledges the pet can reach from here without pathfinding help.
	var neighbours: PackedInt32Array = PackedInt32Array()

	func top_y() -> float:
		return rect.position.y

	func walk_span() -> Vector2:
		return Vector2(rect.position.x, rect.position.x + rect.size.x)


signal topology_changed()

var ledges: Array[Ledge] = []
var screen_rect := Rect2(0, 0, 1920, 1080)
var work_area := Rect2(0, 0, 1920, 1040)
## Average colour of what is behind the pet, fed into the shader as bounce
## light. Sampling the real screen is a privacy-sensitive operation, so it is
## opt-in and falls back to a neutral value.
var backdrop_color := Color(0.14, 0.15, 0.18)

var _provider: RefCounted = null
var _rescan_accum := 0.0
const RESCAN_INTERVAL := 4.0


func _ready() -> void:
	_pick_provider()
	rescan()
	Clock.ticked.connect(_on_tick)


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


## Refresh screen geometry and the ledge graph.
func rescan() -> void:
	_update_screen()
	var found: Array = []
	if _provider != null and _provider.has_method("enumerate_ledges"):
		found = _provider.enumerate_ledges(screen_rect, work_area)
	if found.is_empty():
		found = _simulated_ledges()
	var changed := found.size() != ledges.size()
	ledges.clear()
	for l in found:
		ledges.append(l)
	_link_neighbours()
	if changed:
		topology_changed.emit()
		EventBus.desktop_topology_changed.emit()


func _update_screen() -> void:
	var idx := DisplayServer.window_get_current_screen()
	var pos := DisplayServer.screen_get_position(idx)
	var size := DisplayServer.screen_get_size(idx)
	screen_rect = Rect2(pos, size)
	var usable := DisplayServer.screen_get_usable_rect(idx)
	work_area = Rect2(usable.position, usable.size)


## A believable stand-in desktop: a left-hand icon grid plus a taskbar and the
## screen floor. Spacing matches Windows' default 75x75 cell so the simulated
## layout lines up with the real one if a provider appears later.
func _simulated_ledges() -> Array:
	var out: Array = []
	var cell := Vector2(76.0, 90.0)
	var origin := work_area.position + Vector2(16.0, 16.0)
	var rows := int(maxf(1.0, floorf(work_area.size.y / cell.y)) )
	var id := 0
	for col in 2:
		for row in mini(rows, 8):
			var l := Ledge.new()
			l.id = id
			id += 1
			l.rect = Rect2(origin + Vector2(col * cell.x, row * cell.y), Vector2(48.0, 48.0))
			l.kind = &"icon"
			l.label = "Icon %d" % l.id
			out.append(l)

	var floor_l := Ledge.new()
	floor_l.id = id
	id += 1
	floor_l.rect = Rect2(Vector2(work_area.position.x, work_area.end.y - 2.0),
		Vector2(work_area.size.x, 2.0))
	floor_l.kind = &"screen_floor"
	floor_l.label = "Desktop"
	out.append(floor_l)

	if work_area.end.y < screen_rect.end.y:
		var bar := Ledge.new()
		bar.id = id
		bar.rect = Rect2(Vector2(screen_rect.position.x, work_area.end.y),
			Vector2(screen_rect.size.x, screen_rect.end.y - work_area.end.y))
		bar.kind = &"taskbar"
		bar.label = "Taskbar"
		out.append(bar)
	return out


## Connect ledges that are close enough to hop between. The navigator does the
## actual pathfinding; this just seeds the adjacency.
func _link_neighbours() -> void:
	const MAX_HOP := Vector2(190.0, 170.0)
	for a in ledges:
		var n := PackedInt32Array()
		for b in ledges:
			if b.id == a.id:
				continue
			var d: Vector2 = (b.rect.get_center() - a.rect.get_center()).abs()
			if d.x <= MAX_HOP.x and d.y <= MAX_HOP.y:
				n.append(b.id)
		a.neighbours = n


func ledge_by_id(id: int) -> Ledge:
	for l in ledges:
		if l.id == id:
			return l
	return null


## Nearest walkable surface below `point`, used when a pet is dropped.
func ground_below(point: Vector2) -> Ledge:
	var best: Ledge = null
	var best_dy := INF
	for l in ledges:
		if l.rect.position.y < point.y - 1.0:
			continue
		if point.x < l.rect.position.x - 8.0 or point.x > l.rect.end.x + 8.0:
			continue
		var dy: float = l.rect.position.y - point.y
		if dy < best_dy:
			best_dy = dy
			best = l
	return best
