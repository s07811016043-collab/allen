class_name Win32DesktopProvider
extends DesktopProvider

## Windows: real desktop icons, real window frames, real taskbars.
##
## Windows is the platform where a desktop pet can be most convincing, because
## the icon positions are actually obtainable — Explorer draws them with a plain
## SysListView32 and that control answers LVM_GETITEMRECT like any other. The
## catch is that the control lives in Explorer's address space, so the query has
## to be made with a buffer allocated *inside* Explorer. GDScript cannot do that;
## `win32_desktop_probe.ps1` can, via P/Invoke, and shelling out to it is both
## the shortest honest route and the one that keeps the unsafe code in a file a
## human can read and audit.
##
## The probe is read-only and takes 150-400 ms including PowerShell start-up,
## which is why it only ever runs on a worker thread (see `DesktopProvider`).

## Where the helper lives in the repo. It is copied out to `user://` before use:
## inside an exported PCK `res://` is not a real filesystem path, so PowerShell
## could not open it. Note for whoever sets up the export presets — `*.ps1` has
## to be in the non-resource include filter, or this provider correctly reports
## itself unavailable and the pet falls back to the simulated desktop.
const SCRIPT_RES := "res://core/nav/providers/win32_desktop_probe.ps1"
const SCRIPT_USER_DIR := "user://nav"
const SCRIPT_USER := "user://nav/win32_desktop_probe.ps1"
## Enumerating a desktop with a thousand icons on it is not worth the syscalls;
## a pet cannot meaningfully use more furniture than this anyway.
const MAX_ICONS := 240

var _shell := ""
var _script_path := ""
var _own_pid := 0


func is_available() -> bool:
	if OS.get_name() != "Windows":
		return false
	_shell = _exe_in_path("powershell")
	if _shell == "":
		_shell = _exe_in_path("pwsh")
	if _shell == "":
		last_error = "no powershell on PATH"
		return false
	_script_path = _materialise_script()
	if _script_path == "":
		last_error = "probe script missing (check export filters for *.ps1)"
		return false
	_own_pid = OS.get_process_id()
	return true


## Copy the helper out of the project and onto the real filesystem. Rewritten
## only when the contents differ, so a locked file or a slow disk is not touched
## on every launch.
func _materialise_script() -> String:
	if not ResourceLoader.exists(SCRIPT_RES) and not FileAccess.file_exists(SCRIPT_RES):
		return ""
	var src := FileAccess.open(SCRIPT_RES, FileAccess.READ)
	if src == null:
		return ""
	var text := src.get_as_text()
	src.close()
	if text.strip_edges().is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(SCRIPT_USER_DIR)
	var existing := ""
	if FileAccess.file_exists(SCRIPT_USER):
		var old := FileAccess.open(SCRIPT_USER, FileAccess.READ)
		if old != null:
			existing = old.get_as_text()
			old.close()
	if existing != text:
		var dst := FileAccess.open(SCRIPT_USER, FileAccess.WRITE)
		if dst == null:
			return ""
		dst.store_string(text)
		dst.close()
	return ProjectSettings.globalize_path(SCRIPT_USER)


func _probe(screen_rect: Rect2, work_area: Rect2) -> Array:
	var res := _run(_shell, PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", _script_path,
		"-ExcludePid", str(_own_pid),
		"-MaxIcons", str(MAX_ICONS),
	]), 6.0)
	var text := String(res.get("text", ""))
	if text.strip_edges().is_empty():
		_set_error("probe returned nothing (exit %s)" % res.get("code", -1))
		return []
	return _parse(text, screen_rect, work_area)


func _parse(text: String, screen_rect: Rect2, work_area: Rect2) -> Array:
	var monitors: Array[Rect2] = []
	var works: Array[Rect2] = []
	var icons: Array = []
	var windows: Array = []
	var taskbars: Array[Rect2] = []
	var notes := PackedStringArray()

	for raw in text.split("\n", false):
		var f := _fields(raw)
		if f.is_empty():
			continue
		match f[0]:
			"MONITOR":
				monitors.append(Rect2(_num(f, 1), _num(f, 2), _num(f, 3), _num(f, 4)))
				works.append(Rect2(_num(f, 5), _num(f, 6), _num(f, 7), _num(f, 8)))
			"TASKBAR":
				taskbars.append(Rect2(_num(f, 1), _num(f, 2), _num(f, 3), _num(f, 4)))
			"WINDOW":
				windows.append(f)
			"ICON":
				icons.append(f)
			"NOTE":
				notes.append(f[1] if f.size() > 1 else "?")

	if monitors.is_empty():
		monitors.append(screen_rect)
		works.append(work_area)
	_set_error("" if notes.is_empty() else ", ".join(notes))

	var out: Array = []
	# The taskbar rects from the shell are exact, so the derived panel guess is
	# suppressed when we have them; otherwise fall back to the work-area diff.
	var have_bars := not taskbars.is_empty()
	for i in monitors.size():
		out.append_array(screen_furniture(monitors[i], works[i], i, not have_bars))
	for i in taskbars.size():
		var bar := NavLedge.new()
		bar.rect = taskbars[i]
		bar.kind = &"taskbar"
		bar.label = "Taskbar"
		bar.key = "taskbar:%d" % i
		bar.screen_index = _screen_for(taskbars[i].get_center(), monitors)
		out.append(bar.to_dict())

	for f in windows:
		var r := Rect2(_num(f, 2), _num(f, 3), _num(f, 4), _num(f, 5))
		var title: String = f[7] if f.size() > 7 else ""
		# Windows are keyed by HWND, which survives a move or a resize — that is
		# what lets a pet keep walking along a title bar the user is dragging.
		out.append_array(window_ledges(r, title, "win:%s" % f[1], int(_num(f, 6)),
			_screen_for(r.get_center(), monitors)))

	for f in icons:
		var l := NavLedge.new()
		l.rect = Rect2(_num(f, 1), _num(f, 2), _num(f, 3), _num(f, 4))
		l.kind = &"icon"
		l.label = f[5] if f.size() > 5 else ""
		# Keyed by name, not by position: dragging "Recycle Bin" across the
		# screen is the same object arriving somewhere else, and the navigator
		# should follow it rather than declare its destination destroyed.
		l.key = "icon:%s" % l.label
		l.screen_index = _screen_for(l.rect.get_center(), monitors)
		l.climb_left = true
		l.climb_right = true
		out.append(l.to_dict())
	return out


static func _screen_for(point: Vector2, monitors: Array[Rect2]) -> int:
	for i in monitors.size():
		if monitors[i].has_point(point):
			return i
	return 0
