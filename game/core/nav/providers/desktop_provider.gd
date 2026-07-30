class_name DesktopProvider
extends RefCounted

## Base class for the platform layers that discover real desktop furniture.
##
## Every one of them works the same way: shell out to something the OS already
## ships, parse tab-separated text, turn it into ledges. The interesting part is
## the threading contract. `OS.execute()` blocks until the child process exits,
## and PowerShell's start-up alone is 80-300 ms — running that on the main
## thread would drop twenty frames every rescan, which on an always-visible
## desktop overlay is the most noticeable stutter a user can be shown.
##
## So `enumerate_ledges()` never blocks. It returns the most recent snapshot and
## schedules the next probe on `WorkerThreadPool`. The worker produces plain
## Dictionaries — no `NavLedge`, no nodes, nothing the main thread might be
## walking at the same time — and the main thread inflates them. First call
## returns nothing, `DesktopBridge` falls back to the simulated desktop, and a
## second or so later the real furniture takes over. That transition is
## invisible because the fallback is deliberately shaped like a real desktop.

## Seconds between probes. Icons and windows move on human timescales; probing
## faster buys nothing and costs a process spawn.
var probe_interval := 2.0
## Last failure, surfaced by the diagnostics overlay. Empty when healthy.
var last_error := ""
## Set by a subclass when a permission was refused. Nothing is retried after
## this: re-prompting the user for Accessibility access every two seconds would
## be hostile.
var permission_denied := false

var _mutex := Mutex.new()
var _snapshot: Array = []
var _fresh := false
var _task := -1
var _last_probe_ms := -100000
var _timeout_bin := ""


func _init() -> void:
	# coreutils `timeout` is the only portable kill switch we have: `OS.execute`
	# has no timeout of its own, and a wedged helper would pin a pool thread for
	# the lifetime of the app.
	if OS.get_name() != "Windows":
		_timeout_bin = _exe_in_path("timeout")


# --- Contract ----------------------------------------------------------------

## Can this provider run here at all? Must be cheap — no process spawning — and
## is called once at start-up.
func is_available() -> bool:
	return false


## Latest known ledges. Never blocks; schedules a refresh if the snapshot is
## stale. Returns an empty array until the first probe lands.
func enumerate_ledges(screen_rect: Rect2, work_area: Rect2) -> Array:
	_reap()
	_maybe_probe(screen_rect, work_area)
	_mutex.lock()
	var snap: Array = _snapshot.duplicate()
	_fresh = false
	_mutex.unlock()
	var out: Array[NavLedge] = []
	for d in snap:
		if typeof(d) == TYPE_DICTIONARY:
			out.append(NavLedge.from_dict(d))
	return out


## True when a probe landed since the last `enumerate_ledges()` — lets the
## bridge rebuild immediately instead of waiting for the next rescan tick.
func has_fresh_results() -> bool:
	_reap()
	_mutex.lock()
	var f := _fresh
	_mutex.unlock()
	return f


## Block until any in-flight probe finishes. Called on shutdown so the pool is
## not torn down underneath a running task.
func shutdown() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Worker-thread hook. Runs off the main thread; must return plain Dictionaries
## in `NavLedge.to_dict()` shape and touch nothing else.
func _probe(_screen_rect: Rect2, _work_area: Rect2) -> Array:
	return []


# --- Threading ---------------------------------------------------------------

func _maybe_probe(screen_rect: Rect2, work_area: Rect2) -> void:
	if _task >= 0 or permission_denied:
		return
	var now := Time.get_ticks_msec()
	if now - _last_probe_ms < int(probe_interval * 1000.0):
		return
	_last_probe_ms = now
	# Rects are passed by value into the bind, so the worker never reads a field
	# the main thread might be rewriting.
	_task = WorkerThreadPool.add_task(_probe_task.bind(screen_rect, work_area),
		false, "petalia_desktop_probe")


func _probe_task(screen_rect: Rect2, work_area: Rect2) -> void:
	var result := _probe(screen_rect, work_area)
	_mutex.lock()
	_snapshot = result
	_fresh = true
	_mutex.unlock()


func _reap() -> void:
	if _task < 0:
		return
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1


# --- Shared helpers ----------------------------------------------------------

## Run a helper and capture stdout. Worker thread only.
func _run(cmd: String, args: PackedStringArray, timeout_s: float = 3.0) -> Dictionary:
	var out: Array = []
	var real_cmd := cmd
	var real_args := args
	if _timeout_bin != "":
		real_cmd = _timeout_bin
		var wrapped := PackedStringArray(["-k", "1", "%.1f" % timeout_s, cmd])
		wrapped.append_array(args)
		real_args = wrapped
	var code := OS.execute(real_cmd, real_args, out, true, false)
	var text := "" if out.is_empty() else String(out[0])
	return {"code": code, "text": text}


## Record a diagnostic from the worker thread. `last_error` is read by the main
## thread's diagnostics overlay, so it goes under the same lock as the snapshot.
func _set_error(msg: String) -> void:
	_mutex.lock()
	last_error = msg
	_mutex.unlock()


## Find an executable on PATH without spawning anything. `which` would itself
## cost a process, and `is_available()` has to stay free.
static func _exe_in_path(name: String) -> String:
	var windows := OS.get_name() == "Windows"
	var sep := ";" if windows else ":"
	var suffixes := PackedStringArray([""])
	if windows:
		suffixes = PackedStringArray([".exe", ".cmd", ".bat", ""])
	for entry in OS.get_environment("PATH").split(sep, false):
		for suffix in suffixes:
			var candidate := entry.path_join(name + suffix)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


## Turn a window rectangle into the ledges a pet can actually use: the title bar
## strip on top, and the two side faces as climbing walls. The window body is
## deliberately not a ledge — a pet standing in the middle of a document would
## look like it was floating, because it would be.
static func window_ledges(rect: Rect2, title: String, key: String, z: int = 1,
		screen_index: int = 0) -> Array:
	var out: Array = []
	if rect.size.x < 24.0 or rect.size.y < 24.0:
		return out
	var bar_h: float = minf(30.0, rect.size.y * 0.5)
	var top := NavLedge.new()
	top.rect = Rect2(rect.position, Vector2(rect.size.x, bar_h))
	top.kind = &"window_top"
	top.label = title
	top.key = key + ":top"
	top.z = z
	top.screen_index = screen_index
	top.climb_left = true
	top.climb_right = true
	out.append(top.to_dict())

	# Side faces, thin and tall. They are graph nodes, not standing spots, so a
	# climber can traverse a window from the desktop up to its title bar.
	var face_w := 6.0
	for side in 2:
		var face := NavLedge.new()
		var x: float = rect.position.x if side == 0 else rect.end.x - face_w
		face.rect = Rect2(Vector2(x, rect.position.y), Vector2(face_w, rect.size.y))
		face.kind = &"window_edge"
		face.label = title
		face.key = "%s:%s" % [key, "left" if side == 0 else "right"]
		face.z = z
		face.screen_index = screen_index
		face.climb_left = side == 1
		face.climb_right = side == 0
		out.append(face.to_dict())
	return out


## The furniture every platform has: the bottom of the usable area is a floor,
## and whatever the work area gives up to the screen is a panel — taskbar, Dock
## or menu bar depending on which side it was taken from. Deriving it from the
## work-area difference rather than from a platform API means it is right on a
## vertical Windows taskbar and a left-hand Ubuntu dock for free.
static func screen_furniture(screen_rect: Rect2, work_area: Rect2, screen_index: int = 0,
		include_panels: bool = true) -> Array:
	var out: Array = []
	var floor_l := NavLedge.new()
	floor_l.rect = Rect2(Vector2(work_area.position.x, work_area.end.y - 2.0),
		Vector2(work_area.size.x, 2.0))
	floor_l.kind = &"screen_floor"
	floor_l.label = "Desktop"
	floor_l.key = "floor:%d" % screen_index
	floor_l.screen_index = screen_index
	out.append(floor_l.to_dict())
	if not include_panels:
		return out

	var panels := [
		[Rect2(Vector2(screen_rect.position.x, work_area.end.y),
			Vector2(screen_rect.size.x, screen_rect.end.y - work_area.end.y)), &"taskbar", "Taskbar"],
		[Rect2(screen_rect.position,
			Vector2(screen_rect.size.x, work_area.position.y - screen_rect.position.y)),
			&"menu_bar", "Menu bar"],
		[Rect2(screen_rect.position,
			Vector2(work_area.position.x - screen_rect.position.x, screen_rect.size.y)),
			&"dock", "Dock"],
		[Rect2(Vector2(work_area.end.x, screen_rect.position.y),
			Vector2(screen_rect.end.x - work_area.end.x, screen_rect.size.y)),
			&"dock", "Dock"],
	]
	var n := 0
	for entry in panels:
		var r: Rect2 = entry[0]
		if r.size.x < 4.0 or r.size.y < 4.0:
			continue
		var l := NavLedge.new()
		l.rect = r
		l.kind = entry[1]
		l.label = entry[2]
		l.key = "panel:%d:%d" % [screen_index, n]
		l.screen_index = screen_index
		out.append(l.to_dict())
		n += 1
	return out


## Split a tab-separated probe line, tolerating the ragged output real shell
## helpers produce (trailing \r on Windows, blank lines, comment lines).
static func _fields(line: String) -> PackedStringArray:
	var clean := line.strip_edges()
	if clean.is_empty() or clean.begins_with("#"):
		return PackedStringArray()
	return clean.split("\t", true)


static func _num(fields: PackedStringArray, i: int, fallback: float = 0.0) -> float:
	if i < 0 or i >= fields.size():
		return fallback
	return float(fields[i].strip_edges())
