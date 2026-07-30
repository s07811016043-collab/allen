class_name NavLedge
extends RefCounted

## One surface on the real desktop that a pet can stand on, grab, or perch atop.
##
## This is a top-level script rather than an inner class of `DesktopBridge`
## because the platform providers construct ledges, and a provider that
## preloads the singleton which loads the provider is a parse-time cycle.
## `DesktopBridge` re-exports it as `DesktopBridge.Ledge` so older call sites
## keep working.
##
## Everything here is in *virtual desktop* pixels — the coordinate space that
## spans every monitor — because a pet that walks off the right edge of one
## screen onto the next has to be expressible in one number line.

## Screen-space rectangle of the supporting surface. `position.y` is the
## walkable top edge for every kind except &"window_edge", which is a wall and
## is only ever grabbed, never stood on.
var rect: Rect2 = Rect2()
## Which edge of `rect` is walkable, as a unit normal (usually UP).
var normal: Vector2 = Vector2.UP
## &"icon", &"taskbar", &"window_top", &"window_edge", &"screen_floor",
## &"screen_edge", &"menu_bar", &"dock".
var kind: StringName = &"icon"
## Human-readable label when known, e.g. the icon's filename. Used for flavour
## ("your cat is sniffing Recycle Bin").
var label: String = ""
## Dense index into `DesktopBridge.ledges`. A rescan renumbers everything, so
## never persist an id — persist `key`.
var id: int = 0
## Identity that survives a rescan. An icon dragged 40 px keeps its key, so the
## navigator can retarget rather than declare its goal destroyed. Providers
## derive it from something durable (window handle, icon filename); the
## simulator uses its grid slot.
var key: String = ""
## Ledges the pet can reach from here without pathfinding help. Seeded by
## `DesktopBridge`; the real reachability test lives in `LedgeGraph`, which
## knows the species' jump height.
var neighbours: PackedInt32Array = PackedInt32Array()
## Which monitor this surface belongs to. -1 when it straddles two.
var screen_index: int = 0
## Stacking order — a window on top of another window has a higher value. Used
## to reject ledges that are visually buried and would look wrong to stand on.
var z: int = 0
## True when the position is inferred rather than measured: a KDE icon grid we
## reconstructed from filenames, a simulated desktop. The brain uses this to
## avoid narrating ("sniffing Documents") about something it cannot really see.
var approximate: bool = false
## Whether the left/right vertical faces can be grabbed by a climber. Window
## sides and icon stacks yes; the screen floor no.
var climb_left: bool = false
var climb_right: bool = false


func top_y() -> float:
	return rect.position.y


func walk_span() -> Vector2:
	return Vector2(rect.position.x, rect.position.x + rect.size.x)


func width() -> float:
	return rect.size.x


## Centre of the walkable top edge — the canonical "stand here" point.
func center_top() -> Vector2:
	return Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y)


## A standing position at a fraction along the ledge, inset so the pet is not
## balanced on the very corner.
func point_at(frac: float, inset: float = 0.0) -> Vector2:
	var lo: float = rect.position.x + inset
	var hi: float = rect.end.x - inset
	if hi < lo:
		var mid: float = rect.position.x + rect.size.x * 0.5
		lo = mid
		hi = mid
	return Vector2(lerpf(lo, hi, clampf(frac, 0.0, 1.0)), rect.position.y)


## Nearest standing x on this ledge to an arbitrary x.
func clamp_x(x: float, inset: float = 0.0) -> float:
	var lo: float = rect.position.x + inset
	var hi: float = rect.end.x - inset
	if hi < lo:
		return rect.position.x + rect.size.x * 0.5
	return clampf(x, lo, hi)


func surface_point(x: float, inset: float = 0.0) -> Vector2:
	return Vector2(clamp_x(x, inset), rect.position.y)


## Horizontal clearance between two spans: 0 when they overlap, otherwise the
## size of the gap. The sign is dropped deliberately — callers ask "how far do
## I have to jump", not "which way".
func gap_x(other: NavLedge) -> float:
	if rect.end.x < other.rect.position.x:
		return other.rect.position.x - rect.end.x
	if other.rect.end.x < rect.position.x:
		return rect.position.x - other.rect.end.x
	return 0.0


## Signed direction from this ledge to another, +1 right, -1 left, 0 overlapping.
func dir_to(other: NavLedge) -> float:
	if rect.end.x < other.rect.position.x:
		return 1.0
	if other.rect.end.x < rect.position.x:
		return -1.0
	return signf(other.rect.get_center().x - rect.get_center().x)


func contains_x(x: float, slack: float = 0.0) -> bool:
	return x >= rect.position.x - slack and x <= rect.end.x + slack


## Can a pet actually rest here, or is it only something to hold on to?
func is_standable() -> bool:
	return kind != &"window_edge"


## Round-trip form used to hand results back from a worker thread. Providers
## parse shell output off the main thread and must not touch RefCounted graphs
## that the main thread is walking, so they emit plain dictionaries and the
## bridge inflates them here.
func to_dict() -> Dictionary:
	return {
		"rect": rect, "normal": normal, "kind": String(kind), "label": label,
		"key": key, "screen_index": screen_index, "z": z,
		"approximate": approximate,
		"climb_left": climb_left, "climb_right": climb_right,
	}


static func from_dict(d: Dictionary) -> NavLedge:
	var l := NavLedge.new()
	l.rect = d.get("rect", Rect2())
	l.normal = d.get("normal", Vector2.UP)
	l.kind = StringName(d.get("kind", "icon"))
	l.label = String(d.get("label", ""))
	l.key = String(d.get("key", ""))
	l.screen_index = int(d.get("screen_index", 0))
	l.z = int(d.get("z", 0))
	l.approximate = bool(d.get("approximate", false))
	l.climb_left = bool(d.get("climb_left", false))
	l.climb_right = bool(d.get("climb_right", false))
	return l


## Convenience constructor for the simulator and the tests.
static func make(r: Rect2, kind_: StringName, label_: String = "",
		key_: String = "") -> NavLedge:
	var l := NavLedge.new()
	l.rect = r
	l.kind = kind_
	l.label = label_
	l.key = key_ if key_ != "" else "%s:%s" % [kind_, label_]
	return l


func _to_string() -> String:
	return "<NavLedge %d %s '%s' %s>" % [id, kind, label, rect]
