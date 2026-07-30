extends Node

## Versioned, atomic save/load.
##
## The pet is the point of the app; losing it to a half-written file during a
## shutdown would be unforgivable. Writes therefore go to a temp file and are
## renamed into place, and the previous save is kept as a backup.

const SAVE_PATH := "user://pets.save"
const BACKUP_PATH := "user://pets.save.bak"
const TEMP_PATH := "user://pets.save.tmp"
const VERSION := 1

var _dirty := false
var _autosave_accum := 0.0
const AUTOSAVE_INTERVAL := 30.0


func _ready() -> void:
	Clock.ticked.connect(_on_tick)


func mark_dirty() -> void:
	_dirty = true


func _on_tick(delta: float) -> void:
	if not _dirty:
		return
	_autosave_accum += delta
	if _autosave_accum >= AUTOSAVE_INTERVAL:
		_autosave_accum = 0.0
		save(GameState.serialise())


func save(payload: Dictionary) -> bool:
	payload["version"] = VERSION
	payload["saved_at"] = Clock.now()
	var f := FileAccess.open(TEMP_PATH, FileAccess.WRITE)
	if f == null:
		Log.error("SaveSystem", "cannot open temp file: %s" % error_string(FileAccess.get_open_error()))
		return false
	f.store_string(JSON.stringify(payload))
	f.close()

	var dir := DirAccess.open("user://")
	if dir == null:
		return false
	if dir.file_exists(SAVE_PATH.get_file()):
		dir.remove(BACKUP_PATH.get_file())
		dir.rename(SAVE_PATH.get_file(), BACKUP_PATH.get_file())
	var err := dir.rename(TEMP_PATH.get_file(), SAVE_PATH.get_file())
	if err != OK:
		Log.error("SaveSystem", "rename failed: %s" % error_string(err))
		return false

	_dirty = false
	EventBus.game_saved.emit()
	return true


func load_save() -> Dictionary:
	var payload := _read(SAVE_PATH)
	if payload.is_empty():
		payload = _read(BACKUP_PATH)
		if not payload.is_empty():
			Log.warn("SaveSystem", "primary save unreadable, restored from backup")
	if payload.is_empty():
		return {}
	payload = _migrate(payload)
	EventBus.game_loaded.emit()
	return payload


func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		Log.warn("SaveSystem", "corrupt save at %s" % path)
		return {}
	return parsed


## Forward-migrate old saves. Each version bump appends a step; nothing is ever
## removed, so a save from any released build stays loadable.
func _migrate(payload: Dictionary) -> Dictionary:
	var v: int = int(payload.get("version", 0))
	if v > VERSION:
		Log.warn("SaveSystem", "save is from a newer build (v%d); loading defensively" % v)
	return payload


func wipe() -> void:
	var dir := DirAccess.open("user://")
	if dir == null:
		return
	dir.remove(SAVE_PATH.get_file())
	dir.remove(BACKUP_PATH.get_file())
