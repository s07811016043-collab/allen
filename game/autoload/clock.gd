extends Node

## Time authority.
##
## A pet that grows over real days has to survive the app being closed, the
## laptop sleeping, and the player fiddling with the system clock. Everything
## time-related therefore goes through here rather than through
## `Time.get_unix_time_from_system()` scattered across the codebase.

## Emitted once per in-game "tick" (default 1 s) for cheap periodic work.
signal ticked(delta: float)
## Emitted when the app resumes after being away, with the elapsed wall time.
signal caught_up(away_seconds: float)

const TICK_SECONDS := 1.0
## Wall-clock gaps larger than this are treated as the app having been closed
## rather than as a stutter, and are fed through the offline-progress path.
const AWAY_THRESHOLD := 20.0
## Never award more than three days of offline growth in one go; beyond that a
## returning player should get a "welcome back" moment, not a fully grown adult.
const MAX_AWAY_SECONDS := 3.0 * 24.0 * 3600.0

var _accum := 0.0
var _last_wall := 0.0

## Debug/testing multiplier. The capture harness sets this very high to render
## a pet at every life stage without waiting a day.
var time_scale := 1.0


func _ready() -> void:
	_last_wall = Time.get_unix_time_from_system()


func _process(delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	var wall_gap := now - _last_wall
	_last_wall = now
	if wall_gap > AWAY_THRESHOLD:
		var away: float = clampf(wall_gap, 0.0, MAX_AWAY_SECONDS)
		Log.info("Clock", "resumed after %.0f s away" % away)
		caught_up.emit(away)

	_accum += delta * time_scale
	while _accum >= TICK_SECONDS:
		_accum -= TICK_SECONDS
		ticked.emit(TICK_SECONDS)


func now() -> float:
	return Time.get_unix_time_from_system()
