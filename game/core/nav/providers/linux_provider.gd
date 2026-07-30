class_name LinuxDesktopProvider
extends DesktopProvider

## Linux/BSD: window geometry from whatever X11 tooling is installed, and icon
## positions from whichever desktop environment happens to be running.
##
## There is no "the Linux desktop". Window geometry is at least tractable —
## `wmctrl` and `xdotool` both speak EWMH and one of them is usually present —
## but icon positions are stored by each file manager in its own private place:
## Nautilus and Nemo in gvfs metadata, Plasma in an INI file, and several DEs do
## not draw desktop icons at all. So this provider is a ladder: take the best
## source available, fall through to the next, and flag anything it had to
## reconstruct as `approximate` so the rest of the game knows not to claim the
## pet is really sniffing that particular file.
##
## Wayland note: a native Wayland compositor deliberately refuses to tell any
## client where other clients' windows are. Under XWayland these tools still see
## X11 windows, which is most of what a user has open, so the provider stays
## enabled — it just quietly returns less.

## Reading more than this off the desktop is not worth the syscalls.
const MAX_ICONS := 200
## Cell used when positions have to be reconstructed. Matches the default
## Nautilus/Plasma desktop grid closely enough to look deliberate.
const FALLBACK_CELL := Vector2(106.0, 118.0)
const FALLBACK_ICON := Vector2(64.0, 64.0)

var _wmctrl := ""
var _xdotool := ""
var _gio := ""
var _desktop_dir := ""
var _icon_attr := "metadata::nautilus-icon-position"
var _plasma_config := ""


func is_available() -> bool:
	var os_name := OS.get_name()
	if os_name != "Linux" and os_name != "FreeBSD" and os_name != "NetBSD" \
			and os_name != "OpenBSD" and os_name != "BSD":
		return false
	if OS.get_environment("DISPLAY").is_empty() and OS.get_environment("WAYLAND_DISPLAY").is_empty():
		last_error = "no display server"
		return false
	_wmctrl = _exe_in_path("wmctrl")
	_xdotool = _exe_in_path("xdotool")
	if _wmctrl == "" and _xdotool == "":
		# Without one of these there is nothing here the simulated desktop does
		# not already do better, and pretending otherwise would just be slower.
		last_error = "neither wmctrl nor xdotool installed"
		return false
	_gio = _exe_in_path("gio")
	_desktop_dir = _find_desktop_dir()
	_icon_attr = _icon_attribute_for_desktop()
	_plasma_config = OS.get_environment("HOME").path_join(
		".config/plasma-org.kde.plasma.desktop-appletsrc")
	return true


func _probe(screen_rect: Rect2, work_area: Rect2) -> Array:
	var windows := _query_windows()
	var icons := _query_icons(work_area)
	if windows.is_empty() and icons.is_empty():
		# A floor and a panel is a bare desktop. Reporting nothing hands the pet
		# back to the bridge's simulated grid, which is a better place to live
		# and is indistinguishable to the player.
		return []
	var out := screen_furniture(screen_rect, work_area, 0)
	out.append_array(windows)
	out.append_array(icons)
	return out


# --- Windows -----------------------------------------------------------------

func _query_windows() -> Array:
	if _wmctrl != "":
		var wm := _run(_wmctrl, PackedStringArray(["-lG"]), 2.0)
		var parsed := _parse_wmctrl(String(wm.get("text", "")))
		if not parsed.is_empty():
			return parsed
	if _xdotool != "":
		# `%@` applies the chained command to every window the search returned,
		# so this is one process for the whole desktop rather than one per window.
		var xd := _run(_xdotool, PackedStringArray([
			"search", "--onlyvisible", "--name", ".", "getwindowgeometry", "--shell", "%@",
		]), 2.5)
		return _parse_xdotool(String(xd.get("text", "")))
	return []


## `wmctrl -lG`: id, desktop, x, y, w, h, host, then the title (which may itself
## contain spaces, so the split is bounded).
func _parse_wmctrl(text: String) -> Array:
	var out: Array = []
	var z := 0
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		var f := _split_ws(line, 8)
		if f.size() < 7:
			continue
		var r := Rect2(float(f[2]), float(f[3]), float(f[4]), float(f[5]))
		var title: String = f[7].strip_edges() if f.size() > 7 else ""
		if not _is_real_window(r, title):
			continue
		# The X window id is stable for the life of the window, which is exactly
		# the identity a re-plan needs when the user drags it.
		out.append_array(window_ledges(r, title, "win:%s" % f[0], z))
		z += 1
	return out


## `xdotool getwindowgeometry --shell` emits KEY=VALUE blocks. No title, so the
## label stays generic — a pet on an unnamed window still walks correctly, it
## just has nothing to be narrated about.
func _parse_xdotool(text: String) -> Array:
	var out: Array = []
	var cur := {}
	var z := 0
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		var eq := line.find("=")
		if eq <= 0:
			continue
		var key := line.substr(0, eq)
		var value := line.substr(eq + 1)
		if key == "WINDOW" and not cur.is_empty():
			z = _flush_xdotool(cur, out, z)
			cur = {}
		cur[key] = value
	if not cur.is_empty():
		_flush_xdotool(cur, out, z)
	return out


func _flush_xdotool(cur: Dictionary, out: Array, z: int) -> int:
	if not (cur.has("X") and cur.has("Y") and cur.has("WIDTH") and cur.has("HEIGHT")):
		return z
	var r := Rect2(float(cur["X"]), float(cur["Y"]), float(cur["WIDTH"]), float(cur["HEIGHT"]))
	if not _is_real_window(r, ""):
		return z
	out.append_array(window_ledges(r, "Window", "win:%s" % cur.get("WINDOW", z), z))
	return z + 1


## Reject panels, the desktop window itself, and our own overlay. A pet standing
## on a full-screen "window" that is really the wallpaper looks like a bug.
func _is_real_window(r: Rect2, title: String) -> bool:
	if r.size.x < 80.0 or r.size.y < 60.0:
		return false
	if r.size.x > 16000.0 or r.size.y > 16000.0:
		return false
	var t := title.to_lower()
	if t == "desktop" or t.begins_with("petalia") or t == "plasma" or t == "xfdesktop":
		return false
	return true


static func _split_ws(line: String, limit: int) -> PackedStringArray:
	# `String.split` cannot collapse runs of spaces, and wmctrl pads its columns.
	var out := PackedStringArray()
	var i := 0
	var n := line.length()
	while i < n and out.size() < limit - 1:
		while i < n and line[i] == " ":
			i += 1
		var start := i
		while i < n and line[i] != " ":
			i += 1
		if i > start:
			out.append(line.substr(start, i - start))
	while i < n and line[i] == " ":
		i += 1
	if i < n:
		out.append(line.substr(i))
	return out


# --- Icons -------------------------------------------------------------------

func _query_icons(work_area: Rect2) -> Array:
	var names := _list_desktop_entries()
	if names.is_empty():
		return []
	var placed := _query_gvfs_positions(names, work_area)
	if placed.is_empty():
		placed = _query_plasma_positions(names, work_area)
	if placed.is_empty():
		# Nothing knows where they are, but we do know *what* they are. A grid of
		# correctly named icons is a far better desktop for a pet than an empty
		# one, and `approximate` keeps anything that would narrate it honest.
		placed = _grid_positions(names, work_area, true)
	return placed


func _find_desktop_dir() -> String:
	var home := OS.get_environment("HOME")
	if home.is_empty():
		return ""
	var configured := OS.get_environment("XDG_DESKTOP_DIR")
	if not configured.is_empty() and DirAccess.dir_exists_absolute(configured):
		return configured
	var dirs_file := home.path_join(".config/user-dirs.dirs")
	if FileAccess.file_exists(dirs_file):
		var f := FileAccess.open(dirs_file, FileAccess.READ)
		if f != null:
			var found := ""
			while not f.eof_reached() and found.is_empty():
				var line := f.get_line().strip_edges()
				if not line.begins_with("XDG_DESKTOP_DIR="):
					continue
				found = line.substr(16).strip_edges().trim_prefix("\"").trim_suffix("\"")
				found = found.replace("$HOME", home)
			f.close()
			if not found.is_empty() and DirAccess.dir_exists_absolute(found):
				return found
	var fallback := home.path_join("Desktop")
	return fallback if DirAccess.dir_exists_absolute(fallback) else ""


## Which gvfs attribute holds the icon position depends on the file manager.
func _icon_attribute_for_desktop() -> String:
	var de := (OS.get_environment("XDG_CURRENT_DESKTOP") + " " + OS.get_environment("DESKTOP_SESSION")).to_lower()
	if de.contains("cinnamon"):
		return "metadata::nemo-icon-position"
	if de.contains("mate"):
		return "metadata::caja-icon-position"
	return "metadata::nautilus-icon-position"


func _list_desktop_entries() -> PackedStringArray:
	var out := PackedStringArray()
	if _desktop_dir.is_empty():
		return out
	var dir := DirAccess.open(_desktop_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty() and out.size() < MAX_ICONS:
		if not name.begins_with("."):
			out.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## Nautilus/Nemo/Caja store the icon position in gvfs metadata. One `gio info`
## call covers the whole desktop, which keeps this to a single process.
func _query_gvfs_positions(names: PackedStringArray, work_area: Rect2) -> Array:
	if _gio == "" or _desktop_dir.is_empty():
		return []
	var args := PackedStringArray(["info", "-a", _icon_attr])
	for n in names:
		args.append(_desktop_dir.path_join(n))
	var res := _run(_gio, args, 3.0)
	var text := String(res.get("text", ""))
	if text.is_empty():
		return []

	var out: Array = []
	var current := ""
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.begins_with("display name:"):
			current = line.substr(13).strip_edges()
			continue
		var marker := _icon_attr + ":"
		if not line.begins_with(marker):
			continue
		var xy := line.substr(marker.length()).strip_edges().split(",")
		if xy.size() != 2 or current.is_empty():
			continue
		var l := NavLedge.new()
		# gvfs positions are relative to the desktop area, which starts at the
		# top-left of the work area on every DE that writes this attribute.
		l.rect = Rect2(work_area.position + Vector2(float(xy[0]), float(xy[1])), FALLBACK_ICON)
		l.kind = &"icon"
		l.label = current
		l.key = "icon:%s" % current
		l.climb_left = true
		l.climb_right = true
		out.append(l.to_dict())
	return out


## Plasma keeps Folder View placements in its appletsrc as a JSON blob of screen
## resolution -> flat list. The shape has changed across Plasma versions, so this
## reads what it recognises, uses it as *ordering* rather than as pixels, and
## admits the result is approximate.
func _query_plasma_positions(names: PackedStringArray, work_area: Rect2) -> Array:
	if _plasma_config.is_empty() or not FileAccess.file_exists(_plasma_config):
		return []
	var f := FileAccess.open(_plasma_config, FileAccess.READ)
	if f == null:
		return []
	var order := PackedStringArray()
	while not f.eof_reached() and order.is_empty():
		var line := f.get_line().strip_edges()
		if not line.begins_with("positions="):
			continue
		var blob: Variant = JSON.parse_string(line.substr(10))
		if typeof(blob) != TYPE_DICTIONARY:
			continue
		for key in (blob as Dictionary).keys():
			var arr: Variant = (blob as Dictionary)[key]
			if typeof(arr) != TYPE_ARRAY:
				continue
			# Entries run "Desktop", col, row, name, col, row, name, ...
			var i := 1
			while i + 2 < (arr as Array).size():
				order.append(str((arr as Array)[i + 2]))
				i += 3
			if not order.is_empty():
				break
	f.close()
	if order.is_empty():
		return []
	# Keep only names that still exist, in the order Plasma recorded them.
	var known := {}
	for n in names:
		known[n] = true
	var kept := PackedStringArray()
	for n in order:
		if known.has(n):
			kept.append(n)
	if kept.is_empty():
		return []
	return _grid_positions(kept, work_area, true)


## Lay names out on the desktop grid, top-to-bottom then left-to-right, the way
## every DE fills its desktop.
func _grid_positions(names: PackedStringArray, work_area: Rect2, approximate: bool) -> Array:
	var out: Array = []
	var origin := work_area.position + Vector2(18.0, 16.0)
	var rows: int = maxi(1, int(floor((work_area.size.y - 32.0) / FALLBACK_CELL.y)))
	for i in names.size():
		var col := i / rows
		var row := i % rows
		var pos := origin + Vector2(float(col) * FALLBACK_CELL.x, float(row) * FALLBACK_CELL.y)
		if pos.x + FALLBACK_ICON.x > work_area.end.x:
			break
		var l := NavLedge.new()
		l.rect = Rect2(pos, FALLBACK_ICON)
		l.kind = &"icon"
		l.label = names[i]
		l.key = "icon:%s" % names[i]
		l.approximate = approximate
		l.climb_left = true
		l.climb_right = true
		out.append(l.to_dict())
	return out
