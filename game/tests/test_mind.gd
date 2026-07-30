extends Node

## Headless test for the pet's mind: simulation, touch and behaviour.
##
##     .tools/Godot_v4.5-stable_linux.x86_64 --path game --headless \
##         res://tests/test_mind.tscn
##
## Prints one line per check and exits non-zero if any failed. Everything here
## is deterministic: `Clock.time_scale` is zeroed so the real clock cannot
## interfere, the brain runs with `autonomous_senses = false` so its time and
## senses are inputs, and the touch router is driven from a synthetic pointer.
##
## What it is actually protecting: the numbers that make growth feel earned and
## affection feel warm. Those are easy to break by a tenth and impossible to
## notice by hand, because the whole point is that they move over days.

const GS := preload("res://autoload/game_state.gd")
const DB := preload("res://autoload/desktop_bridge.gd")

const HOUR := 3600.0
const DAY := 86400.0

var _failed := 0
var _passed := 0
## The test drives real `Clock.ticked` through `GameState`, which also drives
## `SaveSystem`. Snapshot whatever was on disk so a test run never leaves a
## developer's actual pet altered.
var _had_save := false
var _snapshot := {}


func _ready() -> void:
	Clock.time_scale = 0.0
	Log.min_level = Log.Level.WARN
	_had_save = FileAccess.file_exists(SaveSystem.SAVE_PATH)
	_snapshot = GameState.serialise()

	_test_need_decay()
	_test_offline_is_gentler()
	_test_growth_is_gated_by_care()
	_test_stage_advanced_fires_once()
	_test_affection_is_slow_to_earn()
	_test_affection_is_slow_to_lose()
	_test_milestones_and_journal()
	_test_mood_tracks_state()
	_test_absence_memory()
	_test_clock_tick_path()
	_test_serialisation_round_trip()
	_test_gesture_classification()
	_test_touch_response()
	_test_drag_physics()
	_test_brain_selection()
	_test_brain_interrupt_model()
	_test_brain_does_not_flip_flop()
	_test_touch_router_end_to_end()

	_restore_save()
	print("TESTS %d passed, %d failed" % [_passed, _failed])
	print("TESTS_OK" if _failed == 0 else "TESTS_FAILED")
	get_tree().quit(1 if _failed > 0 else 0)


# --- Harness -----------------------------------------------------------------

func _restore_save() -> void:
	if _had_save:
		SaveSystem.save(_snapshot)
	else:
		SaveSystem.wipe()


func _check(ok: bool, label: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		return
	_failed += 1
	print("FAIL  %s%s" % [label, "  (%s)" % detail if detail != "" else ""])


func _near(a: float, b: float, eps: float, label: String) -> void:
	_check(absf(a - b) <= eps, label, "%.4f vs %.4f" % [a, b])


## A pet outside `GameState.pets`, so the autoload's own tick never touches it.
func _pet(species: StringName = &"cat") -> GS.PetRecord:
	var r := GS.PetRecord.new()
	r.id = StringName("test_%d" % randi())
	r.species = species
	r.born_at = Clock.now()
	r.last_seen_at = Clock.now()
	r.variant_seed = 12345
	return r


func _top_up(r: GS.PetRecord) -> void:
	for k in GS.NEED_KEYS:
		r.needs[k] = 1.0


# --- Simulation --------------------------------------------------------------

func _test_need_decay() -> void:
	var r := _pet()
	GameState.advance(r, 12.0 * HOUR, true)
	_near(r.need(&"food"), 0.8 - 0.055 * 12.0, 0.001, "food decays at the stated rate")
	_near(r.need(&"clean"), 0.9 - 0.017 * 12.0, 0.001, "clean decays slowest")
	_check(r.need(&"food") < r.need(&"clean"), "hunger outruns grime")

	# A day and a half unattended empties the bowl but never goes below zero.
	GameState.advance(r, 36.0 * HOUR, true)
	_check(r.need(&"food") == 0.0, "needs clamp at zero")


func _test_offline_is_gentler() -> void:
	var watched := _pet()
	var away := _pet()
	GameState.advance(watched, 10.0 * HOUR, true)
	GameState.advance(away, 10.0 * HOUR, false)
	_check(away.need(&"food") > watched.need(&"food"),
		"a closed app costs the pet less",
		"%.3f vs %.3f" % [away.need(&"food"), watched.need(&"food")])
	_check(away.need(&"rest") > 0.9,
		"a pet left alone sleeps", "%.3f" % away.need(&"rest"))


func _test_growth_is_gated_by_care() -> void:
	var loved := _pet()
	var ignored := _pet()
	# Three real days, one hour at a time, one pet fed and one not.
	for i in 72:
		_top_up(loved)
		loved.affection = 0.7
		GameState.advance(loved, HOUR, true)
		GameState.advance(ignored, HOUR, true)

	_check(loved.growth >= 3.0, "20 h/stage reaches adult in three cared-for days",
		"%.2f" % loved.growth)
	_check(ignored.growth < loved.growth * 0.75,
		"neglect slows growth", "%.2f vs %.2f" % [ignored.growth, loved.growth])
	_check(ignored.growth > 0.8,
		"neglect never stops growth", "%.2f" % ignored.growth)


func _test_stage_advanced_fires_once() -> void:
	var seen: Array[int] = []
	var r := _pet()
	var cb := func(pet_id: StringName, stage: int) -> void:
		if pet_id == r.id:
			seen.append(stage)
	EventBus.stage_advanced.connect(cb)

	# Hour by hour to adulthood, then well past it.
	for i in 200:
		_top_up(r)
		GameState.advance(r, HOUR, true)
	_check(seen == [1, 2, 3], "one stage_advanced per crossing, in order",
		str(seen))

	# And a single catch-up spanning every stage still fires exactly three times.
	seen.clear()
	var jumped := _pet()
	var cb2 := func(pet_id: StringName, stage: int) -> void:
		if pet_id == jumped.id:
			seen.append(stage)
	EventBus.stage_advanced.connect(cb2)
	GameState.advance(jumped, 10.0 * DAY, false)
	_check(seen == [1, 2, 3], "a multi-stage catch-up announces each stage once",
		str(seen))
	EventBus.stage_advanced.disconnect(cb)
	EventBus.stage_advanced.disconnect(cb2)


func _test_affection_is_slow_to_earn() -> void:
	var r := _pet()
	var start: float = r.affection
	# Two solid minutes of perfect petting, at the per-second rate TouchResponse
	# pays for finding exactly the right spot.
	for i in 120:
		GameState.add_affection(r, 0.0021)
	_check(r.affection - start < 0.3,
		"a marathon session cannot buy a bond", "%.3f" % r.affection)
	_check(r.affection - start > 0.05,
		"...but it does count for something", "%.3f" % r.affection)

	# The budget refills over a day, so tomorrow's session works again.
	var after_day_one: float = r.affection
	# A well-kept day: the budget refills and nothing is lost to neglect.
	for i in 4:
		_top_up(r)
		GameState.advance(r, 6.0 * HOUR, true)
	for i in 120:
		GameState.add_affection(r, 0.0021)
	_check(r.affection > after_day_one, "affection keeps growing day over day")
	_check(r.affection < 0.85, "and never in one sitting", "%.3f" % r.affection)


func _test_affection_is_slow_to_lose() -> void:
	var r := _pet()
	r.affection = 0.9
	r.affection_peak = 0.9
	# A week away, needs bottoming out the whole time.
	for i in 7:
		GameState.advance(r, DAY, false)
	_check(r.affection < 0.9, "neglect does cost something", "%.3f" % r.affection)
	_check(r.affection > 0.55,
		"a week away costs less than half the bond", "%.3f" % r.affection)
	_check(r.affection >= GameState.bond_floor(r),
		"affection never falls through the bond floor")

	# And the floor genuinely holds, however long it goes on.
	for i in 60:
		GameState.advance(r, DAY, false)
	_check(r.affection >= GameState.bond_floor(r) - 0.0001,
		"two months away still leaves a friend", "%.3f" % r.affection)
	_check(GameState.bond_floor(r) > 0.25, "the floor scales with the peak bond")


func _test_milestones_and_journal() -> void:
	var r := _pet()
	var fired: Array[StringName] = []
	var cb := func(pet_id: StringName, mid: StringName) -> void:
		if pet_id == r.id:
			fired.append(mid)
	EventBus.milestone_unlocked.connect(cb)

	_check(GameState.unlock(r, &"first_touch"), "a milestone unlocks once")
	_check(not GameState.unlock(r, &"first_touch"), "...and not twice")
	GameState.unlock(r, &"first_stroke")
	_check(fired.size() == 2, "one signal per milestone", str(fired))
	_check(GameState.has_milestone(r, &"first_touch"), "milestones are queryable")
	_check(r.journal.size() == 2, "each milestone writes one journal entry")
	_check(String(r.journal[0].get("text", "")).length() > 8,
		"journal entries carry prose, not ids")

	GameState.rename(r, "Biscuit")
	_check(GameState.has_milestone(r, &"named"), "naming the pet is a milestone")
	_check(GameState.display_name(r) == "Biscuit", "the name is used")
	EventBus.milestone_unlocked.disconnect(cb)


func _test_mood_tracks_state() -> void:
	var r := _pet()
	r.needs[&"food"] = 0.05
	for i in 12:
		GameState.refresh_mood(r)
	_check(r.mood == &"hungry", "an empty stomach names the mood", String(r.mood))

	var happy := _pet()
	happy.affection = 0.85
	happy.trust = 0.8
	_top_up(happy)
	for i in 12:
		GameState.refresh_mood(happy)
	_check(happy.mood == &"affectionate" or happy.mood == &"happy" or happy.mood == &"playful",
		"a well-kept, well-loved pet is in a good mood", String(happy.mood))

	var moods: Array[StringName] = []
	var cb := func(pet_id: StringName, m: StringName) -> void:
		if pet_id == happy.id:
			moods.append(m)
	EventBus.mood_changed.connect(cb)
	for i in 6:
		GameState.refresh_mood(happy)
	_check(moods.is_empty(), "mood_changed does not fire when nothing changed",
		str(moods))
	EventBus.mood_changed.disconnect(cb)


func _test_absence_memory() -> void:
	var r := _pet()
	GameState.notice_absence(r, 40.0 * 60.0)
	_check(GameState.pending_greeting(r.id) > 0.0, "a 40-minute absence is noticed")
	_check(r.journal.is_empty(), "...but is not worth writing down")
	_check(GameState.take_greeting(r.id) > 0.0, "the greeting can be consumed")
	_check(GameState.pending_greeting(r.id) == 0.0, "...and only once")

	GameState.notice_absence(r, 2.5 * DAY)
	_check(r.last_absence >= 2.5 * DAY, "the pet remembers how long you were gone")
	_check(r.journal.size() == 1, "a long absence is a remembered moment")
	_check(String(r.journal[0].get("text", "")).contains("day"),
		"...and the entry says how long", String(r.journal[0].get("text", "")))

	var short := _pet()
	GameState.notice_absence(short, 60.0)
	_check(GameState.pending_greeting(short.id) == 0.0,
		"a one-minute gap is not an absence")


## The wiring, not just the maths: does a real `Clock.ticked` move a real pet?
func _test_clock_tick_path() -> void:
	var before: int = GameState.pets.size()
	var r := GameState.adopt(&"cat", "Tick")
	var stages: Array[int] = []
	var cb := func(pet_id: StringName, stage: int) -> void:
		if pet_id == r.id:
			stages.append(stage)
	EventBus.stage_advanced.connect(cb)

	for i in 72:
		_top_up(r)
		Clock.ticked.emit(HOUR)
	_check(r.growth >= 3.0, "Clock.ticked drives growth", "%.2f" % r.growth)
	_check(stages == [1, 2, 3], "and the stage signals with it", str(stages))
	EventBus.stage_advanced.disconnect(cb)
	GameState.pets.remove_at(before)


func _test_serialisation_round_trip() -> void:
	var r := GS.PetRecord.new()
	r.id = &"round_trip"
	r.species = &"cat"
	r.nickname = "Pomegranate"
	r.growth = 1.734
	r.affection = 0.61
	r.affection_peak = 0.72
	r.affection_spent = 0.08
	r.trust = 0.55
	r.stage_seen = 1
	r.last_absence = 3.0 * DAY
	r.mood = &"playful"
	r.mood_valence = 0.62
	r.mood_arousal = 0.71
	r.needs[&"food"] = 0.42
	r.needs[&"clean"] = 0.31
	r.milestones["first_stroke"] = 1234.0
	r.journal.append({"id": "first_stroke", "text": "You found the spot.", "at": 1234.0})
	r.known_ledges.append("Recycle Bin")
	r.stats[&"strokes"] = 91
	r.stats[&"knocks"] = 4

	# Exactly what SaveSystem does: through JSON and back.
	var payload := {"pets": [r.to_dict()]}
	var text := JSON.stringify(payload)
	var parsed: Variant = JSON.parse_string(text)
	_check(typeof(parsed) == TYPE_DICTIONARY, "the save payload is valid JSON")
	var back := GS.PetRecord.from_dict((parsed as Dictionary)["pets"][0])

	_check(back.id == r.id and back.nickname == r.nickname, "identity survives")
	_near(back.growth, r.growth, 1e-4, "growth survives")
	_near(back.affection, r.affection, 1e-4, "affection survives")
	_near(back.affection_peak, r.affection_peak, 1e-4, "the bond high-water survives")
	_near(back.affection_spent, r.affection_spent, 1e-4, "today's budget survives")
	_near(back.trust, r.trust, 1e-4, "trust survives")
	_check(back.stage_seen == 1, "the announced stage survives")
	_near(back.last_absence, r.last_absence, 1.0, "the remembered absence survives")
	_check(back.mood == &"playful", "mood survives")
	_near(back.need(&"food"), 0.42, 1e-4, "needs survive as StringName keys")
	_near(back.need(&"clean"), 0.31, 1e-4, "...all of them")
	_check(back.milestones.has("first_stroke"), "milestones survive")
	_check(back.journal.size() == 1, "the journal survives")
	_check(String(back.journal[0].get("text", "")) == "You found the spot.",
		"...with its prose intact")
	_check(back.known_ledges.has("Recycle Bin"), "remembered icons survive")
	_check(back.stat(&"strokes") == 91 and back.stat(&"knocks") == 4,
		"stats survive as StringName keys")

	# And the whole-state path, which is what actually ships.
	var kept: Array = GameState.pets.duplicate()
	GameState.pets.clear()
	GameState.pets.append(r)
	var round_trip: Variant = JSON.parse_string(JSON.stringify(GameState.serialise()))
	GameState.deserialise(round_trip as Dictionary)
	_check(GameState.pets.size() == 1, "GameState round-trips its pets")
	_near(GameState.pets[0].growth, 1.734, 1e-4, "...with their growth")
	GameState.pets.clear()
	for p in kept:
		GameState.pets.append(p)


# --- Touch -------------------------------------------------------------------

func _test_gesture_classification() -> void:
	# A long, steady drag across the fur.
	var stroke := PetGesture.new()
	stroke.begin(Vector2(100, 100), 0.0)
	for i in range(1, 25):
		stroke.feed(Vector2(100 + i * 9, 100), i * 0.016)
	_check(stroke.classify() == PetGesture.Kind.STROKE,
		"a long steady drag is a stroke", PetGesture.name_of(stroke.classify()))

	# Fingers working one spot: small, fast, constantly reversing.
	var scratch := PetGesture.new()
	scratch.begin(Vector2(200, 200), 0.0)
	for i in range(1, 33):
		var x: float = 200.0 + (14.0 if i % 2 == 0 else -14.0)
		scratch.feed(Vector2(x, 200), i * 0.016)
	var sk: PetGesture.Kind = scratch.classify()
	_check(sk == PetGesture.Kind.SCRATCH or sk == PetGesture.Kind.TICKLE,
		"tight fast reversals read as scratch or tickle", PetGesture.name_of(sk))
	_check(scratch.reversal_rate > 4.0, "reversals are actually counted",
		"%.1f" % scratch.reversal_rate)

	# Barely-there wiggling with no button down.
	var tickle := PetGesture.new()
	for i in range(0, 40):
		var x: float = 300.0 + (5.0 if i % 2 == 0 else -5.0)
		tickle.feed(Vector2(x, 300), i * 0.016)
	_check(tickle.classify() == PetGesture.Kind.TICKLE,
		"a hovering wiggle is a tickle", PetGesture.name_of(tickle.classify()))

	# Down and up, going nowhere.
	var tap := PetGesture.new()
	tap.begin(Vector2(400, 400), 0.0)
	tap.feed(Vector2(401, 400), 0.05)
	_check(tap.end(Vector2(401, 400), 0.09) == PetGesture.Kind.TAP,
		"a quick dab is a tap")

	var second := PetGesture.new()
	second.begin(Vector2(400, 400), 0.0)
	_check(second.end(Vector2(400, 400), 0.08) == PetGesture.Kind.TAP,
		"a fresh recogniser has no double-tap history")


func _test_touch_response() -> void:
	var cat: CreatureSpec = GameState.spec_for(&"cat")
	_check(cat != null, "the cat spec is loaded")

	var chin := TouchResponse.evaluate(cat, &"cat", &"chin",
		PetGesture.Kind.SCRATCH, 0.1, 0.1, 0.0)
	_check(chin.valence > 0.8, "a chin scratch is welcome from anyone",
		"%.2f" % chin.valence)
	_check(chin.affection_rate > 0.0, "and it builds the bond")

	var tail := TouchResponse.evaluate(cat, &"cat", &"tail",
		PetGesture.Kind.STROKE, 1.0, 1.0, 0.0)
	_check(tail.is_bad(), "the tail is never welcome, at any trust",
		"%.2f" % tail.valence)
	_check(tail.trust_impulse < 0.0, "and it costs trust")
	_check(tail.affection_impulse > -0.02,
		"but barely any affection — the pet is cross with what you did")

	var shy_belly := TouchResponse.evaluate(cat, &"cat", &"belly",
		PetGesture.Kind.STROKE, 0.2, 0.4, 0.0)
	_check(shy_belly.is_bad(), "an untrusting cat defends its belly",
		"%.2f" % shy_belly.valence)
	_check(shy_belly.response == &"swipe", "...by swiping", String(shy_belly.response))

	var trusted_belly := TouchResponse.evaluate(cat, &"cat", &"belly",
		PetGesture.Kind.STROKE, 0.8, 0.6, 0.0)
	_check(trusted_belly.valence > 0.6, "a trusting cat offers it",
		"%.2f" % trusted_belly.valence)
	_check(trusted_belly.response == &"roll_over", "...and rolls over",
		String(trusted_belly.response))

	var overdone := TouchResponse.evaluate(cat, &"cat", &"chin",
		PetGesture.Kind.SCRATCH, 0.9, 0.9, 30.0)
	_check(overdone.valence < 0.0, "the same spot for too long overstimulates",
		"%.2f" % overdone.valence)

	# Species matter, and not just as a multiplier.
	var bird_back := TouchResponse.evaluate(null, &"bird", &"back",
		PetGesture.Kind.STROKE, 1.0, 1.0, 0.0)
	_check(bird_back.is_bad(), "stroking a bird's back is wrong however close you are",
		"%.2f" % bird_back.valence)
	var dog_belly := TouchResponse.evaluate(null, &"dog", &"belly",
		PetGesture.Kind.SCRATCH, 0.3, 0.3, 0.0)
	_check(dog_belly.valence > 0.7, "a dog's belly is the point of a dog",
		"%.2f" % dog_belly.valence)


func _test_drag_physics() -> void:
	var cat: CreatureSpec = GameState.spec_for(&"cat")
	var map := BodyMap.new()
	map.configure(cat)
	var com: Vector2 = map.centre_of_mass(3.0)
	var px: float = map.pixels_per_unit(3.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7

	# Give the simulation a floor it can land on regardless of the headless
	# display server's opinion about screen size.
	var floor_ledge = DB.Ledge.new()
	floor_ledge.id = 9001
	floor_ledge.rect = Rect2(-4000.0, 900.0, 8000.0, 4.0)
	floor_ledge.kind = &"screen_floor"
	floor_ledge.label = "TestFloor"
	DesktopBridge.ledges.append(floor_ledge)

	# A trusting pet held by the scruff hangs quietly under the hand.
	var calm := DragBody.new()
	calm.configure(cat, 3.0, 0.95, {&"energy": 0.2, &"skittishness": 0.1}, com, px)
	calm.grab(Vector2(0.30, -0.71), Vector2(600, 200))
	var max_struggle := 0.0
	for i in 180:
		calm.update(1.0 / 60.0, Vector2(600, 200), Vector2.ZERO, rng)
		max_struggle = maxf(max_struggle, calm.struggle)
	_check(calm.position.y > 200.0, "a held pet hangs below the hand",
		"%.1f" % calm.position.y)
	_check(absf(calm.swing) < 0.35, "and settles rather than swinging forever",
		"%.2f" % calm.swing)
	_check(max_struggle < 0.9, "a pet that trusts you barely struggles",
		"%.2f" % max_struggle)

	# One that does not trust you fights.
	var cross := DragBody.new()
	cross.configure(cat, 3.0, 0.02, {&"energy": 0.9, &"skittishness": 0.9}, com, px)
	cross.grab(Vector2(0.30, -0.71), Vector2(600, 200))
	var cross_struggle := 0.0
	for i in 180:
		cross.update(1.0 / 60.0, Vector2(600, 200), Vector2.ZERO, rng)
		cross_struggle = maxf(cross_struggle, cross.struggle)
	_check(cross_struggle > max_struggle, "a pet that does not, struggles",
		"%.2f vs %.2f" % [cross_struggle, max_struggle])
	_check(cross.distress > 0.3, "and being held wears on it",
		"%.2f" % cross.distress)

	# Dropped from a height, a cat lands on its feet.
	var dropped := DragBody.new()
	dropped.configure(cat, 3.0, 0.9, {&"energy": 0.4, &"skittishness": 0.2}, com, px)
	dropped.grab(Vector2(0.30, -0.71), Vector2(600, 200))
	dropped.update(1.0 / 60.0, Vector2(600, 200), Vector2.ZERO, rng)
	dropped.rotation = 2.4
	dropped.release(Vector2(120.0, 0.0))
	var frames := 0
	while dropped.phase == DragBody.Phase.FALLING and frames < 900:
		dropped.update(1.0 / 60.0, Vector2(600, 200), Vector2.ZERO, rng)
		frames += 1
	_check(dropped.phase == DragBody.Phase.LANDED, "a dropped pet lands", str(frames))
	_check(dropped.upright, "a cat lands on its feet")
	_near(dropped.position.y, 900.0, 1.0, "and lands on the ground it fell toward")

	# A clumsy animal does not.
	var clumsy := DragBody.new()
	clumsy.configure(cat, 3.0, 0.9, {&"energy": 0.4, &"skittishness": 0.2}, com, px)
	clumsy.grab(Vector2(0.30, -0.71), Vector2(600, 860))
	clumsy.update(1.0 / 60.0, Vector2(600, 860), Vector2.ZERO, rng)
	clumsy.agility = 0.05
	clumsy.rotation = 2.6
	clumsy.release(Vector2.ZERO)
	frames = 0
	while clumsy.phase == DragBody.Phase.FALLING and frames < 900:
		clumsy.update(1.0 / 60.0, Vector2(600, 860), Vector2.ZERO, rng)
		frames += 1
	_check(not clumsy.upright,
		"an animal that cannot right itself, and a short drop, lands badly")

	DesktopBridge.ledges.erase(floor_ledge)


# --- Brain -------------------------------------------------------------------

func _make_brain(r: GS.PetRecord) -> PetBrain:
	var b := PetBrain.new()
	b.autonomous_senses = false
	b.setup(r)
	b.ctx.hour = 14.0
	b.ctx.cursor = b.ctx.position + Vector2(60.0, -40.0)
	b.ctx.cursor_idle = 0.2
	b.ctx.cursor_speed = 40.0
	b.ctx.player_present = true
	return b


func _run(b: PetBrain, seconds: float, step: float = 1.0 / 30.0) -> void:
	var n: int = int(seconds / step)
	for i in n:
		b._process(step)


func _test_brain_selection() -> void:
	# Starving, with someone at the machine: beg.
	var hungry := _pet()
	hungry.needs[&"food"] = 0.04
	hungry.needs[&"rest"] = 0.9
	hungry.needs[&"play"] = 0.9
	var b1 := _make_brain(hungry)
	_run(b1, 3.0)
	_check(b1.current != null and b1.current.id == &"beg",
		"a starving pet with an audience begs",
		String(b1.current.id) if b1.current != null else "none")

	# Exhausted, small hours, nobody about: sleep.
	var tired := _pet()
	tired.needs[&"rest"] = 0.02
	tired.needs[&"food"] = 0.9
	var b2 := _make_brain(tired)
	b2.ctx.hour = 2.0
	b2.ctx.player_present = false
	b2.ctx.cursor_idle = 900.0
	_run(b2, 3.0)
	_check(b2.current != null and b2.current.id == &"nap",
		"an exhausted pet sleeps",
		String(b2.current.id) if b2.current != null else "none")
	_run(b2, 60.0)
	_check(tired.need(&"rest") > 0.02, "and sleeping actually restores rest",
		"%.3f" % tired.need(&"rest"))

	# Bored, energetic, a cursor being waved: play.
	var bored := _pet()
	bored.needs[&"play"] = 0.05
	bored.needs[&"food"] = 0.9
	bored.needs[&"rest"] = 0.9
	var b3 := _make_brain(bored)
	b3.ctx.cursor_speed = 1200.0
	b3.ctx.toy_id = &"cursor"
	b3.ctx.toy_position = b3.ctx.position + Vector2(50.0, -30.0)
	b3.ctx.toy_at = b3.ctx.now
	_run(b3, 3.0)
	_check(b3.current != null and b3.current.id == &"play_with_toy",
		"a waved cursor is a toy",
		String(b3.current.id) if b3.current != null else "none")

	b1.free()
	b2.free()
	b3.free()


func _test_brain_interrupt_model() -> void:
	# A startle must cut a nap.
	var r := _pet()
	r.needs[&"rest"] = 0.02
	var b := _make_brain(r)
	b.ctx.hour = 3.0
	b.ctx.player_present = false
	_run(b, 3.0)
	_check(b.current != null and b.current.id == &"nap", "asleep to begin with",
		String(b.current.id) if b.current != null else "none")
	b.add_startle(1.0)
	_run(b, 0.5)
	_check(b.current != null and b.current.id == &"startle",
		"a startle cuts a nap mid-sleep",
		String(b.current.id) if b.current != null else "none")
	_check(r.stat(&"startles") > 0, "and it is remembered")

	# A nap must not cut a greeting.
	var g := _pet()
	g.affection = 0.8
	g.needs[&"rest"] = 0.01
	var gb := _make_brain(g)
	gb.ctx.hour = 3.0
	GameState.notice_absence(g, 2.0 * DAY)
	_run(gb, 1.0)
	_check(gb.current != null and gb.current.id == &"greet_on_return",
		"a returning player is greeted before anything else",
		String(gb.current.id) if gb.current != null else "none")
	_run(gb, 3.0)
	_check(gb.current != null and gb.current.id == &"greet_on_return",
		"and an exhausted pet does not fall asleep mid-hello",
		String(gb.current.id) if gb.current != null else "none")
	_run(gb, 12.0)
	_check(g.stat(&"greetings") > 0, "the greeting is paid out")
	_check(GameState.pending_greeting(g.id) == 0.0, "and only owed once")

	b.free()
	gb.free()


func _test_brain_does_not_flip_flop() -> void:
	var r := _pet()
	r.needs[&"food"] = 0.6
	r.needs[&"play"] = 0.55
	r.needs[&"rest"] = 0.6
	r.needs[&"clean"] = 0.55
	var b := _make_brain(r)
	# One-element arrays, because GDScript lambdas capture locals by value and an
	# int counter would be incremented on a copy.
	var switches := [0]
	var cb := func(pet_id: StringName, _bid: StringName, _prev: StringName) -> void:
		if pet_id == r.id:
			switches[0] += 1
	EventBus.behaviour_changed.connect(cb)
	# Five minutes of deliberately ambiguous state — every need half met, which
	# is exactly where a naive "highest score wins" AI twitches.
	_run(b, 300.0)
	EventBus.behaviour_changed.disconnect(cb)
	_check(switches[0] > 2, "the pet does change its mind sometimes", str(switches[0]))
	_check(switches[0] < 60, "but hysteresis keeps dwell above five seconds",
		"%d switches in 300 s" % switches[0])
	b.free()


# --- Router ------------------------------------------------------------------

func _test_touch_router_end_to_end() -> void:
	var r := _pet()
	r.growth = 3.0
	r.trust = 0.5
	var brain := _make_brain(r)
	var router := TouchRouter.new()
	add_child(router)
	router.set_process(false)          # stepped by hand, for determinism
	router.read_display_pointer = false
	router.setup(r, null, brain)

	var origin: Vector2 = brain.ctx.position
	var px: float = router.body.pixels_per_unit(r.growth)
	# Rig-space landmarks straight out of the cat spec.
	var chin: Vector2 = origin + Vector2(0.46, -0.655) * px
	var tail: Vector2 = origin + Vector2(-0.55, -0.80) * px

	router.pointer = chin
	router.press()
	_check(router.current_region() == &"chin" or router.current_region() == &"muzzle",
		"the hit test finds the chin", String(router.current_region()))

	var strokes := [0]
	var cb := func(pet_id: StringName, _region: StringName, _speed: float) -> void:
		if pet_id == r.id:
			strokes[0] += 1
	EventBus.pet_stroked.connect(cb)

	# Work the chin for a couple of seconds, back and forth over the spot.
	var before_affection: float = r.affection
	var before_trust: float = r.trust
	for i in 120:
		router.pointer = chin + Vector2(sin(i * 0.6) * 16.0, cos(i * 0.6) * 5.0)
		router._process(1.0 / 60.0)
	router.release()
	EventBus.pet_stroked.disconnect(cb)

	_check(strokes[0] > 5, "a sustained stroke emits pet_stroked", str(strokes[0]))
	_check(r.affection > before_affection, "and builds affection",
		"%.4f -> %.4f" % [before_affection, r.affection])
	_check(r.trust > before_trust, "and trust")
	_check(GameState.has_milestone(r, &"first_touch"), "first touch is remembered")

	# The tail is a different story.
	var reactions: Array[StringName] = []
	var rcb := func(pet_id: StringName, response: StringName, _i: float) -> void:
		if pet_id == r.id:
			reactions.append(response)
	EventBus.pet_reacted.connect(rcb)
	var trust_before_tail: float = r.trust
	router.pointer = tail
	router.press()
	for i in 30:
		router.pointer = tail + Vector2(sin(i * 0.7) * 20.0, 0.0)
		router._process(1.0 / 60.0)
	router.release()
	EventBus.pet_reacted.disconnect(rcb)
	_check(r.trust < trust_before_tail, "pulling the tail costs trust",
		"%.3f -> %.3f" % [trust_before_tail, r.trust])
	_check(reactions.has(&"swipe") or reactions.has(&"pull_away"),
		"and the cat says so", str(reactions))
	_check(r.trust > 0.0, "but never all of it")

	# Pick the pet up and put it down.
	var grabbed := [0]
	var landed := [0]
	var gcb := func(pet_id: StringName) -> void:
		if pet_id == r.id:
			grabbed[0] += 1
	var lcb := func(pet_id: StringName, _impact: float, _up: bool) -> void:
		if pet_id == r.id:
			landed[0] += 1
	EventBus.pet_grabbed.connect(gcb)
	EventBus.pet_landed.connect(lcb)

	var floor_ledge = DB.Ledge.new()
	floor_ledge.id = 9002
	floor_ledge.rect = Rect2(-4000.0, origin.y + 300.0, 8000.0, 4.0)
	floor_ledge.kind = &"screen_floor"
	floor_ledge.label = "TestFloor2"
	DesktopBridge.ledges.append(floor_ledge)

	router.pointer = origin + Vector2(0.30, -0.71) * px
	router.press()
	for i in 40:
		router._process(1.0 / 60.0)
	_check(grabbed[0] == 1, "holding still on the body picks the pet up", str(grabbed[0]))
	_check(router.is_carrying(), "and it is now being carried")
	_check(brain.ctx.held, "the brain knows it has no say")

	for i in 60:
		router.pointer = origin + Vector2(0.30, -0.71) * px + Vector2(0.0, -200.0 * i / 60.0)
		router._process(1.0 / 60.0)
	router.release()
	var frames := 0
	while router.is_carrying() and frames < 600:
		router._process(1.0 / 60.0)
		frames += 1
	_check(landed[0] == 1, "and letting go drops it exactly once", str(landed[0]))
	_check(not brain.ctx.held, "after which the brain has its body back")

	EventBus.pet_grabbed.disconnect(gcb)
	EventBus.pet_landed.disconnect(lcb)
	DesktopBridge.ledges.erase(floor_ledge)
	router.queue_free()
	brain.free()
