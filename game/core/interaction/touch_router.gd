class_name TouchRouter
extends Node

## Turns pointer input into things that happen to a pet.
##
## Everything the player does with their hands arrives here: where they touched,
## what kind of touch it was, whether the pet welcomed it, and whether they
## picked it up. The router owns the state machine and delegates the judgement —
## `BodyMap` for where, `PetGesture` for what, `TouchResponse` for how it lands,
## `DragBody` for the physics of being carried.
##
## It talks to the rest of the game only through `EventBus` and `GameState`, so
## the audio and VFX layers can hook a purr or a dust puff without either side
## knowing the other exists.

## Pointer held still on a grabbable region for this long is a deliberate pick-up.
const HOLD_TO_GRAB := 0.34
## ...and dragging this many body-heights away from the press point is the
## impatient version of the same thing. Comfortably past the silhouette, so no
## stroke — however long — can reach it.
const DRAG_TO_GRAB := 1.15
## Movement under this while holding still counts as "not moving".
const HOLD_SLOP := 12.0
## `pet_stroked` is a continuous signal; this is how often it actually fires.
const STROKE_EMIT_INTERVAL := 0.1
## Region charge bleeds off this fast when you stop working the same spot.
const CHARGE_DECAY := 0.7
## Cursor speeds that read as a toy being waved rather than a hand working.
const TOY_SPEED_MIN := 320.0
const TOY_RADIUS := 5.0

const GS := preload("res://autoload/game_state.gd")

var record: GS.PetRecord = null
var creature: Node = null
var brain: Node = null

var body := BodyMap.new()
var gesture := PetGesture.new()
var drag := DragBody.new()

## Pointer position in screen space. Read from the display server at runtime;
## tests and the capture harness set it directly with `read_display_pointer` off.
## When the pointer is synthetic so is time — gesture timing then advances by
## the delta passed to `_process`, which is what makes a scripted stroke
## reproducible frame for frame.
var pointer := Vector2.ZERO
var read_display_pointer := true
## Set false to stop the router touching the creature's transform, e.g. once the
## creature grows its own hold handling.
var drive_transform := true

var _pressed := false
var _press_at := 0.0
var _press_point := Vector2.ZERO
var _press_region: StringName = &""
var _press_rig := Vector2.ZERO
var _region: StringName = &""
var _last_kind: PetGesture.Kind = PetGesture.Kind.NONE
var _charge := {}
var _stroke_emit := 0.0
var _bad_latched := false
var _stroke_seconds := 0.0
var _clock := 0.0
var _rng := RandomNumberGenerator.new()


func setup(p_record: GS.PetRecord, p_creature: Node = null, p_brain: Node = null) -> void:
	record = p_record
	creature = p_creature
	brain = p_brain
	body.configure(GameState.spec_for(record.species))
	_rng.seed = record.variant_seed ^ 0x7a11


func _ready() -> void:
	set_process_unhandled_input(true)


func _unhandled_input(event: InputEvent) -> void:
	if record == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		# Trust the display-server pointer over the event's viewport-local
		# position: everything else in this file is in screen space.
		if not read_display_pointer:
			pointer = mb.position
		if mb.pressed:
			press()
		else:
			release()
	elif event is InputEventMouseMotion and not read_display_pointer:
		pointer = (event as InputEventMouseMotion).position


func _process(delta: float) -> void:
	if record == null:
		return
	if read_display_pointer:
		pointer = Vector2(DisplayServer.mouse_get_position())
	_clock += delta
	var now := _now()
	gesture.feed(pointer, now)

	if drag.is_active():
		_update_drag(delta, now)
		return

	if _pressed:
		_update_press(delta, now)
	else:
		_update_hover(delta, now)


# --- Pointer events ----------------------------------------------------------

## Begin a press at the current `pointer`. Public so a test or a synthetic input
## source can drive the router without an `InputEvent`.
func press() -> void:
	if drag.is_active():
		return
	var now := _now()
	gesture.begin(pointer, now)
	_pressed = true
	_press_at = now
	_press_point = pointer
	_bad_latched = false
	_press_region = _region_at(pointer)
	_press_rig = body.to_rig(creature, _fallback_position(), pointer, record.growth)
	_region = _press_region
	if _press_region == &"":
		return
	GameState.unlock(record, &"first_touch")
	GameState.mark_seen(record)
	EventBus.pet_touched.emit(record.id, _press_region, _press_rig)


func release() -> void:
	var now := _now()
	var kind: PetGesture.Kind = gesture.end(pointer, now)
	_pressed = false
	if drag.is_active():
		_release_grab()
		return
	if _press_region == &"":
		return
	if kind == PetGesture.Kind.TAP or kind == PetGesture.Kind.DOUBLE_TAP:
		_apply_discrete(kind, _press_region)
	_press_region = &""
	_last_kind = PetGesture.Kind.NONE


# --- Per-frame updates -------------------------------------------------------

func _update_press(delta: float, now: float) -> void:
	if _press_region == &"":
		return
	var travel: float = pointer.distance_to(_press_point)
	var body_px: float = maxf(body.pixels_per_unit(record.growth), 60.0)

	# Two ways to end up holding an animal: pick it up deliberately, or drag it
	# somewhere while your finger is still on it. "Deliberately" is measured
	# against the *path* rather than the displacement, because a stroke keeps
	# coming back over the same spot and must never be mistaken for a hold.
	var deliberate: bool = now - _press_at >= HOLD_TO_GRAB \
		and gesture.path_length < HOLD_SLOP
	var yanked: bool = travel > body_px * DRAG_TO_GRAB
	if deliberate or yanked:
		_begin_grab()
		return

	var region: StringName = _region_at(pointer)
	if region == &"":
		# The hand slid off the animal. Keep the press alive — it may come back —
		# but stop crediting it with a stroke.
		_decay_charges(delta, &"")
		return
	_region = region

	var kind: PetGesture.Kind = gesture.classify()
	if not PetGesture.is_continuous(kind):
		_decay_charges(delta, &"")
		return
	if kind != _last_kind:
		# Changing gesture mid-press is legitimate; reset the refusal latch so a
		# new kind of touch gets judged on its own merits.
		_bad_latched = false
		_last_kind = kind
	_apply_continuous(kind, region, delta, now)


func _update_hover(delta: float, now: float) -> void:
	var region: StringName = _region_at(pointer)
	# A wiggled cursor near the pet is a toy, whether or not it is touching.
	if brain != null and brain.has_method("offer_toy") \
			and gesture.speed > TOY_SPEED_MIN \
			and pointer.distance_to(_fallback_position()) \
				< body.pixels_per_unit(record.growth) * TOY_RADIUS:
		brain.call("offer_toy", &"cursor", pointer)
	if region == &"":
		_last_kind = PetGesture.Kind.NONE
		_decay_charges(delta, &"")
		return
	var kind: PetGesture.Kind = gesture.classify()
	if kind != PetGesture.Kind.TICKLE:
		_decay_charges(delta, &"")
		return
	_region = region
	_apply_continuous(kind, region, delta, now)


# --- Applying a reaction -----------------------------------------------------

func _apply_continuous(kind: PetGesture.Kind, region: StringName,
		delta: float, _now: float) -> void:
	_decay_charges(delta, region)
	var charge: float = float(_charge.get(region, 0.0))
	var re: TouchResponse.Reaction = TouchResponse.evaluate(
		body.spec, record.species, region, kind, record.trust, record.affection, charge)

	if re.is_bad():
		_apply_refusal(re)
		return

	GameState.add_affection(record, re.affection_rate * delta, &"touch")
	GameState.add_trust(record, re.trust_rate * delta)
	record.stress = maxf(0.0, record.stress - 0.12 * delta * maxf(re.valence, 0.0))
	if brain != null and brain.has_method("notice_touch"):
		brain.call("notice_touch", region, re.valence)

	# `strokes` counts seconds of contact, not signal emissions.
	_stroke_seconds += delta
	while _stroke_seconds >= 1.0:
		_stroke_seconds -= 1.0
		GameState.bump_stat(record, &"strokes")

	_stroke_emit -= delta
	if _stroke_emit <= 0.0:
		_stroke_emit = STROKE_EMIT_INTERVAL
		EventBus.pet_stroked.emit(record.id, region, gesture.speed)
		EventBus.pet_gesture.emit(record.id, PetGesture.name_of(kind), region, re.valence)
		EventBus.pet_reacted.emit(record.id, re.response, absf(re.valence))
		if re.vocal != &"":
			_say(re.vocal, clampf(0.3 + 0.6 * re.valence, 0.0, 1.0))
		if kind == PetGesture.Kind.STROKE and re.valence > 0.3:
			GameState.unlock(record, &"first_stroke")
		if re.response == &"purr":
			GameState.unlock(record, &"first_purr")
		GameState.mark_seen(record)


func _apply_discrete(kind: PetGesture.Kind, region: StringName) -> void:
	var charge: float = float(_charge.get(region, 0.0))
	var re: TouchResponse.Reaction = TouchResponse.evaluate(
		body.spec, record.species, region, kind, record.trust, record.affection, charge)
	if re.is_bad():
		_apply_refusal(re)
		return
	GameState.add_affection(record, re.affection_impulse, &"tap")
	GameState.add_trust(record, re.trust_impulse)
	EventBus.pet_gesture.emit(record.id, PetGesture.name_of(kind), region, re.valence)
	EventBus.pet_reacted.emit(record.id, re.response, absf(re.valence))
	if re.vocal != &"":
		_say(re.vocal, 0.45)
	if brain != null and brain.has_method("notice_touch"):
		brain.call("notice_touch", region, re.valence)


## A refusal fires once per gesture, not once per frame — being cross about a
## tail pull is an event. The latch is what keeps a two-second bad stroke from
## costing two seconds' worth of trust.
func _apply_refusal(re: TouchResponse.Reaction) -> void:
	if _bad_latched:
		return
	_bad_latched = true
	GameState.add_affection(record, re.affection_impulse, &"bad_touch")
	GameState.add_trust(record, re.trust_impulse)
	GameState.add_stress(record, re.stress_impulse)
	GameState.bump_stat(record, &"swipes")
	EventBus.pet_gesture.emit(record.id, re.gesture, re.region, re.valence)
	EventBus.pet_reacted.emit(record.id, re.response, absf(re.valence))
	if re.vocal != &"":
		_say(re.vocal, clampf(0.5 - 0.5 * re.valence, 0.0, 1.0))
	if brain != null:
		if brain.has_method("notice_touch"):
			brain.call("notice_touch", re.region, re.valence)
		if brain.has_method("add_startle"):
			brain.call("add_startle", re.startle)


func _decay_charges(delta: float, active: StringName) -> void:
	for k in _charge.keys():
		if k == active:
			continue
		_charge[k] = maxf(0.0, float(_charge[k]) - delta * CHARGE_DECAY)
	if active != &"":
		_charge[active] = float(_charge.get(active, 0.0)) + delta


# --- Carrying ----------------------------------------------------------------

func _begin_grab() -> void:
	var growth: float = record.growth
	drag.configure(GameState.spec_for(record.species), growth, record.trust,
		GameState.personality(record), body.centre_of_mass(growth),
		body.pixels_per_unit(growth))
	drag.grab(_press_rig, pointer)
	gesture.grabbed = true
	_last_kind = PetGesture.Kind.GRAB

	# Stop the creature walking to wherever it was going: it is in the air now.
	if creature != null and creature.has_method("stop"):
		creature.call("stop")

	EventBus.pet_grabbed.emit(record.id)
	EventBus.pet_gesture.emit(record.id, &"grab", _press_region, -0.2)
	# Being picked up is startling in proportion to how little the pet trusts
	# you with it; a bonded pet just goes floppy.
	var alarm: float = clampf(0.55 - 0.5 * record.trust, 0.0, 1.0)
	GameState.add_stress(record, alarm * 0.5)
	if brain != null:
		if brain.has_method("set_held"):
			brain.call("set_held", true)
		if brain.has_method("add_startle"):
			brain.call("add_startle", alarm * 0.5)
	if alarm > 0.3:
		_say(&"yowl" if record.trust < 0.2 else &"mrrp", alarm)


func _update_drag(delta: float, _now: float) -> void:
	drag.update(delta, pointer, gesture.velocity, _rng)
	if drag.phase == DragBody.Phase.HELD:
		# Struggling costs trust very slowly, so holding on to a pet that hates
		# it is a real (small) cost rather than a free action.
		GameState.add_trust(record, -0.004 * drag.struggle * delta)
		GameState.add_stress(record, 0.05 * drag.distress * delta)
		if drag.struggle > 0.6 and _rng.randf() < delta * 1.2:
			_say(&"yowl", clampf(drag.distress, 0.2, 1.0))
	_push_body_transform()
	if drag.phase == DragBody.Phase.LANDED:
		_finish_landing()


func _release_grab() -> void:
	gesture.grabbed = false
	drag.release(gesture.velocity)
	EventBus.pet_released.emit(record.id, gesture.velocity)


func _finish_landing() -> void:
	var impact: float = drag.impact
	var upright: bool = drag.upright
	EventBus.pet_landed.emit(record.id, impact, upright)
	AudioDirector.foley(&"land", clampf(0.25 + impact, 0.0, 1.0))
	if creature != null and creature.has_method("play_reaction"):
		creature.call("play_reaction", &"land", 0.5 + 1.1 * impact)
		if not upright:
			creature.call("play_reaction", &"shake", 0.8)

	if upright and impact < 0.3:
		# Set down neatly. Pets remember that too.
		GameState.add_trust(record, 0.004)
	else:
		GameState.add_trust(record, -0.02 - 0.08 * impact)
		GameState.add_stress(record, 0.2 + 0.5 * impact)
		GameState.bump_stat(record, &"drops")
		if brain != null and brain.has_method("add_startle"):
			brain.call("add_startle", 0.45 + 0.55 * impact)
		if brain != null and brain.has_method("notice_touch"):
			brain.call("notice_touch", &"", -0.35 - 0.5 * impact)
		_say(&"yowl", clampf(0.4 + impact, 0.0, 1.0))

	if brain != null:
		if brain.has_method("place_at"):
			brain.call("place_at", drag.position)
		if brain.has_method("set_held"):
			brain.call("set_held", false)
	drag.reset()
	_press_region = &""
	_last_kind = PetGesture.Kind.NONE


## Push the carried body onto whatever is drawing it. The creature gets first
## refusal; the direct transform write is the fallback for the window in which
## the creature exists but does not yet know about being held.
func _push_body_transform() -> void:
	if creature != null and creature.has_method("apply_hold"):
		creature.call("apply_hold", drag.position, drag.rotation, drag.struggle)
		return
	if brain != null and brain.has_method("place_held"):
		brain.call("place_held", drag.position, drag.rotation)
	if not drive_transform or creature == null or not (creature is Node2D):
		return
	var n := creature as Node2D
	n.global_position = drag.position - Vector2(DisplayServer.window_get_position())
	n.rotation = drag.rotation


# --- Helpers -----------------------------------------------------------------

## Region the pointer is currently over, or &"" when it is off the animal.
func current_region() -> StringName:
	return _region


## True while the pet is dangling from the cursor or falling from it.
func is_carrying() -> bool:
	return drag.is_active()


## Gesture timebase. See `read_display_pointer`.
func _now() -> float:
	return Clock.now() if read_display_pointer else _clock


func _region_at(p: Vector2) -> StringName:
	return body.region_at(creature, _fallback_position(), p, record.growth)


## Where the pet is, for the benefit of the hit test, when there is no creature
## node to ask. The brain always knows.
func _fallback_position() -> Vector2:
	if brain != null:
		# `get` rather than a direct property read: `brain` is typed as a plain
		# Node so this file never has to depend on the brain script.
		var c: Variant = brain.get("ctx")
		if c != null:
			return c.position
	return pointer


func _say(call_id: StringName, intensity: float) -> void:
	var spec: CreatureSpec = GameState.spec_for(record.species)
	var hz := 320.0
	if spec != null:
		hz = spec.voice_hz * lerpf(1.0, spec.baby_voice_scale, spec.babyness_at(record.growth))
	AudioDirector.vocalise(record.id, call_id, hz, intensity)
