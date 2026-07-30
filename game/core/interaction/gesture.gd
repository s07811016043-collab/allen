class_name PetGesture
extends RefCounted

## Reads the pointer's path and decides what kind of touch it is.
##
## A tap, a stroke, a scratch, a tickle and a grab are all "the mouse moved with
## the button down". They feel completely different to give and they must feel
## completely different to receive, so the difference has to be recovered from
## the path itself: how far it went, how fast, how tightly it doubles back, and
## how long it stayed.
##
## The classifier is deliberately continuous — `classify()` may be called every
## frame while the button is down, and the answer is allowed to change mid-drag,
## because a real hand does drift from stroking to scratching without letting go.

enum Kind { NONE, TAP, DOUBLE_TAP, STROKE, SCRATCH, TICKLE, GRAB }

## Movement under this many pixels over the whole press is still a tap.
const TAP_SLOP := 9.0
## ...and it has to be over this quickly.
const TAP_TIME := 0.26
## Two taps closer together than this are a double tap.
const DOUBLE_TAP_WINDOW := 0.36

## A stroke is long and reasonably quick.
const STROKE_MIN_SPEED := 55.0
const STROKE_MIN_PATH := 34.0

## A scratch is small, fast and reverses constantly — fingers working one spot.
const SCRATCH_MAX_AMPLITUDE := 40.0
const SCRATCH_MIN_SPEED := 170.0
const SCRATCH_MIN_REVERSALS := 2.4

## A tickle is smaller and faster still, and usually barely touches down.
const TICKLE_MAX_AMPLITUDE := 17.0
const TICKLE_MIN_REVERSALS := 4.5

## Window over which reversals and amplitude are measured.
const WINDOW := 0.45
const MAX_SAMPLES := 48

var pressed := false
var grabbed := false
## Screen-space pointer state, refreshed by `feed`.
var position := Vector2.ZERO
var velocity := Vector2.ZERO
var speed := 0.0
## Total distance travelled since the press began.
var path_length := 0.0
## Extent of the recent path, in pixels.
var amplitude := 0.0
## Direction reversals per second over the recent path.
var reversal_rate := 0.0
var duration := 0.0

var _pos: PackedVector2Array = PackedVector2Array()
var _time: PackedFloat32Array = PackedFloat32Array()
var _started_at := 0.0
var _last_tap_at := -99.0
var _last_pos := Vector2.ZERO
var _has_last := false


func begin(at: Vector2, now: float) -> void:
	pressed = true
	grabbed = false
	path_length = 0.0
	duration = 0.0
	_started_at = now
	_pos.clear()
	_time.clear()
	_last_pos = at
	_has_last = true
	feed(at, now)


## Push one pointer sample. Safe to call while the button is up: hovering is how
## a tickle is delivered with a mouse.
func feed(at: Vector2, now: float) -> void:
	if _has_last:
		var step: float = at.distance_to(_last_pos)
		if pressed:
			path_length += step
	_last_pos = at
	_has_last = true
	position = at

	_pos.append(at)
	_time.append(now)
	while _pos.size() > MAX_SAMPLES or (_time.size() > 2 and now - _time[0] > WINDOW * 2.0):
		_pos.remove_at(0)
		_time.remove_at(0)

	if pressed:
		duration = now - _started_at
	_measure(now)


## Finish the press. Returns the gesture the whole press should be remembered as
## — which for anything sustained is what it already was, and for a quick dab is
## a tap.
func end(at: Vector2, now: float) -> Kind:
	feed(at, now)
	pressed = false
	var kind: Kind = classify()
	if kind == Kind.NONE and path_length <= TAP_SLOP and duration <= TAP_TIME:
		kind = Kind.DOUBLE_TAP if now - _last_tap_at <= DOUBLE_TAP_WINDOW else Kind.TAP
		_last_tap_at = now
	grabbed = false
	return kind


## What is happening *right now*.
func classify() -> Kind:
	if grabbed:
		return Kind.GRAB
	if not pressed:
		# Hover: a mouse wiggled over the fur without pressing is a tickle, and
		# it is the only gesture that works without a button.
		if amplitude <= TICKLE_MAX_AMPLITUDE and reversal_rate >= TICKLE_MIN_REVERSALS \
				and speed > 60.0:
			return Kind.TICKLE
		return Kind.NONE
	if duration < TAP_TIME and path_length <= TAP_SLOP:
		# Undecided: could still become a tap, a hold or a stroke.
		return Kind.NONE
	if amplitude <= TICKLE_MAX_AMPLITUDE and reversal_rate >= TICKLE_MIN_REVERSALS:
		return Kind.TICKLE
	if amplitude <= SCRATCH_MAX_AMPLITUDE and reversal_rate >= SCRATCH_MIN_REVERSALS \
			and speed >= SCRATCH_MIN_SPEED:
		return Kind.SCRATCH
	if speed >= STROKE_MIN_SPEED and path_length >= STROKE_MIN_PATH:
		return Kind.STROKE
	return Kind.NONE


static func name_of(kind: Kind) -> StringName:
	match kind:
		Kind.TAP: return &"tap"
		Kind.DOUBLE_TAP: return &"double_tap"
		Kind.STROKE: return &"stroke"
		Kind.SCRATCH: return &"scratch"
		Kind.TICKLE: return &"tickle"
		Kind.GRAB: return &"grab"
		_: return &"none"


## Is this gesture a sustained contact (charged per second) rather than a single
## event? Strokes build affection over time; taps do not.
static func is_continuous(kind: Kind) -> bool:
	return kind == Kind.STROKE or kind == Kind.SCRATCH or kind == Kind.TICKLE


func _measure(now: float) -> void:
	var n: int = _pos.size()
	if n < 2:
		velocity = Vector2.ZERO
		speed = 0.0
		amplitude = 0.0
		reversal_rate = 0.0
		return

	# Instantaneous velocity from the last pair, which is what "how fast is the
	# hand moving" means to a startled animal.
	var dt: float = maxf(_time[n - 1] - _time[n - 2], 0.0005)
	velocity = (_pos[n - 1] - _pos[n - 2]) / dt
	speed = velocity.length()

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var reversals := 0
	var prev := Vector2.ZERO
	var have_prev := false
	var window_start: float = now
	for i in range(n - 1, -1, -1):
		if now - _time[i] > WINDOW:
			break
		window_start = _time[i]
		lo = lo.min(_pos[i])
		hi = hi.max(_pos[i])
		if i > 0:
			var step: Vector2 = _pos[i] - _pos[i - 1]
			if step.length_squared() > 1.0:
				# A reversal is a step that mostly undoes the previous one.
				# Doubling back is the signature of scratching and tickling and
				# it is what separates them from a long stroke.
				if have_prev and step.dot(prev) < 0.0:
					reversals += 1
				prev = step
				have_prev = true
	if lo.x == INF:
		amplitude = 0.0
	else:
		amplitude = (hi - lo).length()
	var span: float = maxf(now - window_start, 0.05)
	reversal_rate = float(reversals) / span
