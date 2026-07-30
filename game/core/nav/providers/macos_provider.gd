class_name MacOSDesktopProvider
extends DesktopProvider

## macOS: window frames via System Events, desktop icons via Finder — when the
## user has granted the permissions for either.
##
## macOS is the platform where a desktop pet has to be most willing to be told
## no. Enumerating other apps' windows needs Accessibility; asking Finder where
## the desktop icons are needs Automation. Both are per-app prompts the user can
## refuse, and neither can be worked around — nor should it be. So the strategy
## is: ask once, notice the specific refusal, never ask that question again this
## session, and keep whatever we did get.
##
## What always works, with no permission at all, is the screen furniture: the
## menu bar and the Dock are exactly the difference between the display bounds
## and the usable rect, which `DisplayServer` hands us for free. A pet that can
## walk the Dock and perch on the menu bar is already a desktop pet; windows and
## icons are the upgrade.

## Tab-separated so the parser is the same on every platform. Wrapped in `try`
## per window because a process can quit between the enumeration and the query.
const WINDOWS_SCRIPT := """
set out to ""
tell application "System Events"
	repeat with p in (every process whose visible is true and background only is false)
		set pname to name of p
		try
			repeat with w in (every window of p)
				try
					set pos to position of w
					set sz to size of w
					set out to out & "WINDOW" & tab & (item 1 of pos) & tab & (item 2 of pos) & tab & (item 1 of sz) & tab & (item 2 of sz) & tab & pname & " - " & (name of w) & linefeed
				end try
			end repeat
		end try
	end repeat
end tell
return out
"""

## `desktop position` is in the desktop view's own coordinate space, not screen
## space. It is close enough to be worth having — the origin is the top-left of
## the desktop area — but the exact inset depends on the icon view's arrangement
## settings, so everything from here is flagged `approximate`.
const ICONS_SCRIPT := """
set out to ""
tell application "Finder"
	try
		set isize to icon size of icon view options of desktop
	on error
		set isize to 64
	end try
	set out to "ICONSIZE" & tab & isize & linefeed
	repeat with itm in (items of desktop)
		try
			set p to desktop position of itm
			set out to out & "ICON" & tab & (item 1 of p) & tab & (item 2 of p) & tab & (name of itm) & linefeed
		end try
	end repeat
end tell
return out
"""

var _osascript := ""
## Set once a refusal is seen. Re-asking would re-prompt the user every two
## seconds, which is the single most obnoxious thing an overlay app can do.
var _accessibility_denied := false
var _finder_denied := false


func is_available() -> bool:
	if OS.get_name() != "macOS":
		return false
	_osascript = _exe_in_path("osascript")
	if _osascript == "":
		_osascript = "/usr/bin/osascript"
		if not FileAccess.file_exists(_osascript):
			last_error = "osascript not found"
			return false
	return true


func _probe(screen_rect: Rect2, work_area: Rect2) -> Array:
	var windows := _query_windows()
	var icons := _query_icons(work_area)
	if windows.is_empty() and icons.is_empty():
		# Furniture alone is a bare desktop. Returning nothing lets the bridge
		# fall back to its simulated grid, which is a better home for a pet than
		# an empty screen and is indistinguishable to the player.
		return []
	var out := screen_furniture(screen_rect, work_area, 0)
	out.append_array(windows)
	out.append_array(icons)
	return out


func _query_windows() -> Array:
	if _accessibility_denied:
		return []
	var res := _run(_osascript, PackedStringArray(["-e", WINDOWS_SCRIPT]), 4.0)
	var text := String(res.get("text", ""))
	if _is_denied(text, res):
		_accessibility_denied = true
		_set_error("Accessibility permission not granted; window edges unavailable")
		return []
	var out: Array = []
	var z := 0
	for raw in text.split("\n", false):
		var f := _fields(raw)
		if f.size() < 6 or f[0] != "WINDOW":
			continue
		var r := Rect2(_num(f, 1), _num(f, 2), _num(f, 3), _num(f, 4))
		if r.size.x < 80.0 or r.size.y < 60.0:
			continue
		var title := f[5]
		# System Events gives no window id, so identity has to come from the
		# title. It is stable enough for "the window I was walking on", and a
		# retitled window simply reads as a new one.
		out.append_array(window_ledges(r, title, "win:%s" % title.md5_text().left(12), z))
		z += 1
	return out


func _query_icons(work_area: Rect2) -> Array:
	if _finder_denied:
		return []
	var res := _run(_osascript, PackedStringArray(["-e", ICONS_SCRIPT]), 4.0)
	var text := String(res.get("text", ""))
	if _is_denied(text, res):
		_finder_denied = true
		_set_error("Finder scripting not permitted; desktop icons unavailable")
		return []
	var out: Array = []
	var icon_size := 64.0
	for raw in text.split("\n", false):
		var f := _fields(raw)
		if f.is_empty():
			continue
		if f[0] == "ICONSIZE":
			icon_size = clampf(_num(f, 1, 64.0), 16.0, 512.0)
			continue
		if f[0] != "ICON" or f.size() < 4:
			continue
		var l := NavLedge.new()
		# Finder reports the icon's top-left within the desktop view; shifting by
		# the usable rect's origin puts it back into screen space under the menu
		# bar. The glyph occupies the top square of the cell, the label the rest.
		var pos := work_area.position + Vector2(_num(f, 1), _num(f, 2))
		l.rect = Rect2(pos, Vector2(icon_size, icon_size))
		l.kind = &"icon"
		l.label = f[3]
		l.key = "icon:%s" % l.label
		l.approximate = true
		l.climb_left = true
		l.climb_right = true
		out.append(l.to_dict())
	return out


## Distinguish "the user said no" from "that failed this time". Only the former
## should stop us asking again.
func _is_denied(text: String, res: Dictionary) -> bool:
	if int(res.get("code", 0)) == 0:
		return false
	var t := text.to_lower()
	return t.contains("not allowed assistive access") \
		or t.contains("not authorized to send apple events") \
		or t.contains("-25211") or t.contains("-1743") or t.contains("-1728")
