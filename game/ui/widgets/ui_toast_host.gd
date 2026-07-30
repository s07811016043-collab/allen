class_name UIToastHost
extends Control

## The toast stack: placement, ordering, and — mostly — refusal.
##
## Most of this class's job is *not* showing things. A pet with four needs, a
## growth clock and a milestone table can easily generate a notification a
## minute, and that is precisely the app people delete. So:
##
##   * at most three on screen; a fourth dismisses the oldest early,
##   * one message per subject per cooldown window, so a hungry pet asks once
##     and then waits,
##   * needs are rate-limited far harder than milestones, because a milestone is
##     news and a need is a nag,
##   * nothing at all while a panel is open — the player is already looking at
##     the pet's state, and telling them what they can see is noise.
##
## Toasts stack upward from the bottom-right by default, the corner where
## desktop notifications already live, and slide down into the gap when one
## above them leaves.

const MAX_VISIBLE := 3
const GAP := 10.0
const MARGIN := 22.0
## Per-subject silence. A need may not speak again for four minutes; a
## milestone can follow another after twelve seconds.
const COOLDOWN_NEED := 240.0
const COOLDOWN_DEFAULT := 12.0

## Set by `UIRoot` while any panel is open.
var muted: bool = false

var _toasts: Array[UIToast] = []
var _last_at := {}
var _slots := {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


## Show a message. `subject` is the rate-limiting key — a need name, a milestone
## id — not the text, so rewording a message cannot accidentally defeat the
## cooldown.
func notify(subject: StringName, message: String, glyph: StringName,
		tone: UIToast.Tone = UIToast.Tone.NOTE) -> void:
	if muted or message.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var cooldown: float = COOLDOWN_NEED if tone == UIToast.Tone.NEED \
		else COOLDOWN_DEFAULT
	if now - float(_last_at.get(subject, -9999.0)) < cooldown:
		return
	_last_at[subject] = now

	while _toasts.size() >= MAX_VISIBLE:
		_toasts[0].dismiss()
		_toasts.remove_at(0)

	var t := UIToast.new()
	t.message = message
	t.glyph = glyph
	t.tone = tone
	add_child(t)
	t.expired.connect(_on_expired)
	_toasts.append(t)
	_reflow(true)


func clear() -> void:
	for t in _toasts:
		t.dismiss()
	_toasts.clear()


func _on_expired(t: UIToast) -> void:
	_toasts.erase(t)
	_reflow(false)


func _process(_delta: float) -> void:
	_settle()


## Target positions, bottom-right, newest nearest the corner.
func _reflow(instant: bool) -> void:
	var y: float = size.y - UITokens.s(MARGIN)
	for i in range(_toasts.size() - 1, -1, -1):
		var t := _toasts[i]
		if not is_instance_valid(t):
			continue
		y -= t.size.y
		var target := Vector2(size.x - t.size.x - UITokens.s(MARGIN), y)
		_slots[t] = target
		if instant and t.position == Vector2.ZERO:
			t.position = target
		y -= UITokens.s(GAP)


## Toasts glide to their slot rather than snapping when one above them leaves.
## The gap closing is the only motion in this widget that the player did not
## cause, and it is slow enough not to draw the eye.
func _settle() -> void:
	var delta := get_process_delta_time()
	for t in _toasts:
		if not is_instance_valid(t) or not _slots.has(t):
			continue
		var target: Vector2 = _slots[t]
		if UITokens.reduced_motion:
			t.position = target
			continue
		t.position = t.position.lerp(target, 1.0 - exp(-13.0 * delta))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_reflow(false)
