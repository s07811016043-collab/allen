extends Node

## Tiny levelled logger. Autoloaded first so every other singleton can use it
## during its own _ready().

enum Level { DEBUG, INFO, WARN, ERROR }

var min_level: Level = Level.INFO
var _to_stdout := true

## Captured in-memory so the diagnostics panel and the automated visual-review
## harness can both read back what happened without scraping the console.
var history: Array[String] = []
const HISTORY_CAP := 400


func _ready() -> void:
	if OS.has_feature("editor") or OS.is_debug_build():
		min_level = Level.DEBUG


func debug(tag: String, msg: String) -> void: _emit(Level.DEBUG, tag, msg)
func info(tag: String, msg: String) -> void: _emit(Level.INFO, tag, msg)
func warn(tag: String, msg: String) -> void: _emit(Level.WARN, tag, msg)
func error(tag: String, msg: String) -> void: _emit(Level.ERROR, tag, msg)


func _emit(level: Level, tag: String, msg: String) -> void:
	if level < min_level:
		return
	var names := ["DBG", "INF", "WRN", "ERR"]
	var line := "[%s][%s] %s" % [names[level], tag, msg]
	history.append(line)
	if history.size() > HISTORY_CAP:
		history.remove_at(0)
	if not _to_stdout:
		return
	if level >= Level.WARN:
		printerr(line)
	else:
		print(line)
