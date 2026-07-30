extends Node

## The authoritative model of every pet the player owns.
##
## Deliberately holds no nodes and no rendering concerns: it is the thing that
## gets serialised, and the thing that survives when the pet's scene is freed
## because the player minimised the app.
##
## It is also the *simulation*: needs, affection, trust, growth, mood and the
## journal all advance here, driven by `Clock.ticked` while the app is open and
## by a single catch-up step when it reopens. Keeping the whole model in one
## place is what makes offline progress honest — there is exactly one function
## that moves a pet forward in time, and it does not care whether the seconds
## were watched or not.
##
## Tuning philosophy: a desktop pet is a companion, not a chore. Needs sag on a
## timescale of most of a day, affection is slow to earn and much slower to
## lose, and neglect slows growth rather than undoing it. Nothing here is
## allowed to punish someone for having a job.

## Per-pet persistent record.
class PetRecord:
	var id: StringName = &""
	var species: StringName = &"cat"
	var nickname: String = ""
	## Continuous growth in [0, 3]: 0 = newborn, 3 = fully adult.
	var growth: float = 0.0
	## Bond with the player in [0, 1]. Slow to earn, slow to lose.
	var affection: float = 0.1
	## High-water mark of `affection`. The bond floor is derived from it, so a
	## pet you were once close to never regresses into a stranger.
	var affection_peak: float = 0.1
	## How much of today's affection budget has been spent. Grinding strokes for
	## an hour should not buy a bond; this decays back to zero over a day.
	var affection_spent: float = 0.0
	## Willingness to be handled, in [0, 1]. Distinct from affection: it gates
	## which body regions are welcome. A cat can adore you and still not offer
	## its belly.
	var trust: float = 0.2
	## Needs in [0, 1] where 1 = fully satisfied.
	var needs := {&"food": 0.8, &"play": 0.8, &"rest": 0.9, &"clean": 0.9}
	var mood: StringName = &"content"
	## Cached mood axes so a reloaded pet does not snap to a fresh evaluation.
	var mood_valence: float = 0.5
	var mood_arousal: float = 0.5
	## Short-lived agitation from startles, bad touches and hard landings.
	var stress: float = 0.0
	## Unix timestamp of creation and of the last time the player interacted.
	var born_at: float = 0.0
	var last_seen_at: float = 0.0
	## Longest absence the pet has noticed, in seconds. Read by the greeting
	## behaviour so a two-day trip reads differently from a lunch break.
	var last_absence: float = 0.0
	## Highest life stage already announced. Guards `stage_advanced` so a
	## catch-up that spans two stages fires once per stage and never twice for
	## the same one.
	var stage_seen: int = 0
	## Colour/pattern variation seed, so two cats are visibly different pets.
	var variant_seed: int = 0
	## Milestones already awarded, keyed by id (String keys so JSON round-trips).
	var milestones := {}
	## Remembered moments, oldest first: {"id", "text", "at"}.
	var journal: Array = []
	## Labels of desktop ledges this pet has already investigated. Persisted so
	## a brand new icon is still novel after a restart.
	var known_ledges: Array = []
	## Lifetime counters that feed the journal.
	var stats := {
		&"strokes": 0, &"meals": 0, &"naps": 0, &"steps": 0,
		&"plays": 0, &"grooms": 0, &"knocks": 0, &"startles": 0,
		&"drops": 0, &"greetings": 0, &"swipes": 0,
	}

	func stage() -> int:
		return clampi(int(floor(growth)), 0, 3)

	func need(key: StringName) -> float:
		return clampf(float(needs.get(key, 0.8)), 0.0, 1.0)

	## How far a need has fallen, in [0, 1]. Behaviour scoring wants deficits far
	## more often than it wants satisfactions.
	func deficit(key: StringName) -> float:
		return 1.0 - need(key)

	func stat(key: StringName) -> int:
		return int(stats.get(key, 0))

	func to_dict() -> Dictionary:
		return {
			"id": String(id), "species": String(species), "nickname": nickname,
			"growth": growth, "affection": affection,
			"affection_peak": affection_peak, "affection_spent": affection_spent,
			"trust": trust, "needs": needs,
			"mood": String(mood), "mood_valence": mood_valence,
			"mood_arousal": mood_arousal, "stress": stress,
			"born_at": born_at, "last_seen_at": last_seen_at,
			"last_absence": last_absence, "stage_seen": stage_seen,
			"variant_seed": variant_seed, "milestones": milestones,
			"journal": journal, "known_ledges": known_ledges, "stats": stats,
		}

	static func from_dict(d: Dictionary) -> PetRecord:
		var r := PetRecord.new()
		r.id = StringName(d.get("id", "pet"))
		r.species = StringName(d.get("species", "cat"))
		r.nickname = d.get("nickname", "")
		r.growth = float(d.get("growth", 0.0))
		r.affection = float(d.get("affection", 0.1))
		# Older saves predate the peak; seeding it from the current value keeps
		# their bond floor correct instead of resetting it to newborn.
		r.affection_peak = maxf(r.affection, float(d.get("affection_peak", 0.0)))
		r.affection_spent = float(d.get("affection_spent", 0.0))
		r.trust = float(d.get("trust", 0.2))
		var n: Variant = d.get("needs")
		if typeof(n) == TYPE_DICTIONARY:
			for k in n.keys():
				r.needs[StringName(k)] = float(n[k])
		r.mood = StringName(d.get("mood", "content"))
		r.mood_valence = float(d.get("mood_valence", 0.5))
		r.mood_arousal = float(d.get("mood_arousal", 0.5))
		r.stress = float(d.get("stress", 0.0))
		r.born_at = float(d.get("born_at", 0.0))
		r.last_seen_at = float(d.get("last_seen_at", 0.0))
		r.last_absence = float(d.get("last_absence", 0.0))
		r.stage_seen = int(d.get("stage_seen", r.stage()))
		r.variant_seed = int(d.get("variant_seed", 0))
		var m: Variant = d.get("milestones")
		if typeof(m) == TYPE_DICTIONARY:
			r.milestones = m
		var j: Variant = d.get("journal")
		if typeof(j) == TYPE_ARRAY:
			r.journal = j
		var kl: Variant = d.get("known_ledges")
		if typeof(kl) == TYPE_ARRAY:
			r.known_ledges = kl
		var s: Variant = d.get("stats")
		if typeof(s) == TYPE_DICTIONARY:
			for k in s.keys():
				r.stats[StringName(k)] = int(s[k])
		return r


var pets: Array[PetRecord] = []
## Loaded species specs, keyed by species id.
var specs := {}

const SPEC_PATHS := {
	&"cat": "res://species/cat/cat_spec.gd",
	&"dog": "res://species/dog/dog_spec.gd",
	&"bird": "res://species/bird/bird_spec.gd",
	&"reptile": "res://species/reptile/reptile_spec.gd",
}

# --- Simulation tuning -------------------------------------------------------

const NEED_KEYS: Array[StringName] = [&"food", &"play", &"rest", &"clean"]
## Fall per hour of attended time. Food is the loudest clock; grooming is the
## quietest, because a pet that nags about being dirty is a chore.
const NEED_DECAY := {&"food": 0.055, &"play": 0.042, &"rest": 0.034, &"clean": 0.017}
## Away from the machine the pet is mostly asleep, so its day costs less.
const OFFLINE_NEED_SCALE := 0.62
## ...and sleeping is exactly how rest comes back.
const OFFLINE_REST_RECOVERY := 0.075
## Below this a need is worth interrupting the player over.
const NEED_CRITICAL := 0.18

## Wellbeing under this counts as neglect and starts costing affection.
const NEGLECT_THRESHOLD := 0.55
## Peak affection loss per hour of total neglect. Deliberately tiny: a week
## away costs about a fifth of the bond, and the floor catches the rest.
const AFFECTION_DECAY_PER_HOUR := 0.005
## Fraction of the high-water bond that can never be lost.
const BOND_FLOOR_RATIO := 0.32
## Most affection one day of doting can buy.
const DAILY_AFFECTION_BUDGET := 0.22
## Trust drifts toward the bond when the pet is well: forgiveness, on a timer.
const TRUST_RECOVERY_PER_HOUR := 0.006

## Slowest a neglected pet grows, as a fraction of full pace. Never zero —
## withholding a birthday is not a mechanic we want.
const MIN_GROWTH_RATE := 0.35
## Fallback when a species spec has not been written yet.
const DEFAULT_HOURS_PER_STAGE := 24.0

## An absence longer than this earns a greeting when the player comes back.
const ABSENCE_NOTICE := 25.0 * 60.0
## ...and one longer than this earns a journal entry about it.
const ABSENCE_JOURNAL := 20.0 * 3600.0

## Stress bleeds off with roughly a two-minute half-life.
const STRESS_HALFLIFE := 120.0

const JOURNAL_CAP := 64
const KNOWN_LEDGE_CAP := 48

## Milestone copy lives here rather than in the UI so the journal reads the same
## everywhere and a designer can retune the whole voice in one file.
const MILESTONES := {
	"first_touch": "The first time you reached out.",
	"first_stroke": "You found the spot behind the ears.",
	"first_purr": "It purred. You did that.",
	"named": "You gave it a name.",
	"first_meal": "Its first meal from your hand.",
	"first_play": "The first game you played together.",
	"first_nap_nearby": "It fell asleep where it could still see you.",
	"first_taskbar_nap": "Asleep on the taskbar, in everyone's way.",
	"first_knock": "It pushed something off a ledge, holding eye contact.",
	"first_belly": "It rolled over. That took a while.",
	"friends": "Somewhere in here, it decided you were alright.",
	"bonded": "It waits by the cursor now.",
	"stage_1": "No longer a baby.",
	"stage_2": "All legs and opinions.",
	"stage_3": "Fully grown, and still yours.",
	"week_together": "A week of mornings together.",
}

const STAGE_MILESTONES := ["", "stage_1", "stage_2", "stage_3"]

## Per-pet runtime state that is cheap to rebuild and pointless to save.
var _critical: Dictionary = {}          ## pet id -> {need: bool}
var _personality: Dictionary = {}       ## pet id -> jittered personality
var _pending_greeting: Dictionary = {}  ## pet id -> true away seconds
var _sim_present := true


func _ready() -> void:
	_load_specs()
	var payload := SaveSystem.load_save()
	if payload.is_empty():
		Log.info("GameState", "no save found; starting fresh")
	else:
		deserialise(payload)
	# Everything between the last autosave and now happened while the app was
	# shut. Fold it in before anyone can observe a stale pet.
	_catch_up_from_records()
	Clock.ticked.connect(_on_tick)
	Clock.caught_up.connect(_on_caught_up)


## Specs are built by code rather than stored as .tres so that a species is a
## readable, diffable, reviewable file rather than an opaque blob.
func _load_specs() -> void:
	for id in SPEC_PATHS:
		var path: String = SPEC_PATHS[id]
		if not ResourceLoader.exists(path):
			continue
		var script: Script = load(path)
		if script == null or not script.has_method("build"):
			# `build` is a static factory; check via the script's own class.
			pass
		var spec: CreatureSpec = script.call("build")
		if spec != null:
			specs[id] = spec
	Log.info("GameState", "loaded %d species specs" % specs.size())


func spec_for(species: StringName) -> CreatureSpec:
	return specs.get(species)


func adopt(species: StringName, nickname: String = "") -> PetRecord:
	var r := PetRecord.new()
	r.id = StringName("pet_%d_%d" % [pets.size(), int(Clock.now()) % 100000])
	r.species = species
	r.nickname = nickname
	r.born_at = Clock.now()
	r.last_seen_at = r.born_at
	r.variant_seed = randi()
	pets.append(r)
	SaveSystem.mark_dirty()
	return r


func pet_by_id(id: StringName) -> PetRecord:
	for p in pets:
		if p.id == id:
			return p
	return null


# --- Personality -------------------------------------------------------------

## Species personality, jittered per pet so two cats from the same spec are not
## the same animal. The jitter is derived from `variant_seed`, so it costs
## nothing to save and is stable for the pet's whole life.
func personality(r: PetRecord) -> Dictionary:
	var cached: Variant = _personality.get(r.id)
	if typeof(cached) == TYPE_DICTIONARY:
		return cached
	var s: CreatureSpec = spec_for(r.species)
	var rng := RandomNumberGenerator.new()
	rng.seed = r.variant_seed
	var base := {
		&"energy": 0.5, &"affection_drive": 0.5,
		&"curiosity": 0.5, &"skittishness": 0.4,
	}
	if s != null:
		base[&"energy"] = s.energy
		base[&"affection_drive"] = s.affection_drive
		base[&"curiosity"] = s.curiosity
		base[&"skittishness"] = s.skittishness
	var out := {}
	for k in base:
		out[k] = clampf(float(base[k]) + rng.randf_range(-0.13, 0.13), 0.0, 1.0)
	_personality[r.id] = out
	return out


# --- Time --------------------------------------------------------------------

func _on_tick(delta: float) -> void:
	for r in pets:
		advance(r, delta, true)
		r.last_seen_at = Clock.now()


## The app was asleep or the laptop lid was shut. Clock has already clamped the
## gap to something sane; we only decide what it means.
func _on_caught_up(away_seconds: float) -> void:
	for r in pets:
		advance(r, away_seconds, false)
		notice_absence(r, away_seconds)
	SaveSystem.mark_dirty()


## Offline progress across an actual app restart. `last_seen_at` is the honest
## record of when the pet was last watched; Clock cannot know about it because
## the process did not exist.
func _catch_up_from_records() -> void:
	var now := Clock.now()
	for r in pets:
		if r.last_seen_at <= 0.0:
			r.last_seen_at = now
			continue
		var away: float = now - r.last_seen_at
		if away <= 1.0:
			continue
		advance(r, minf(away, Clock.MAX_AWAY_SECONDS), false)
		notice_absence(r, away)
		r.last_seen_at = now
	if not pets.is_empty():
		SaveSystem.mark_dirty()


## Memory. The pet does not just resume — it registers that you were gone, and
## the brain reads that back as a greeting worth making. Public because a window
## regaining focus is also a return, and the shell layer knows about that before
## the clock does.
func notice_absence(r: PetRecord, away: float) -> void:
	if away < ABSENCE_NOTICE:
		return
	r.last_absence = maxf(r.last_absence, away)
	_pending_greeting[r.id] = away
	if away >= ABSENCE_JOURNAL:
		var days: float = away / 86400.0
		var who := display_name(r)
		var text: String = "%s was alone for %s. It was waiting by the cursor." \
			% [who, _duration_text(away)]
		if days >= 3.0:
			text = "%s was alone for %s, and still came running." % [who, _duration_text(away)]
		note(r, StringName("absence_%d" % int(Clock.now())), text)


static func _duration_text(seconds: float) -> String:
	if seconds >= 86400.0:
		var d := int(round(seconds / 86400.0))
		return "%d day%s" % [d, "" if d == 1 else "s"]
	var h := int(round(seconds / 3600.0))
	return "%d hour%s" % [maxi(h, 1), "" if h == 1 else "s"]


## True absence in seconds if this pet is owed a greeting, else 0.
func pending_greeting(id: StringName) -> float:
	return float(_pending_greeting.get(id, 0.0))


## Consume the greeting. The brain calls this when it actually starts greeting,
## so a pet that was mid-nap still owes you the hello when it wakes.
func take_greeting(id: StringName) -> float:
	var v: float = float(_pending_greeting.get(id, 0.0))
	_pending_greeting.erase(id)
	return v


func hours_since_seen(r: PetRecord) -> float:
	if r.last_seen_at <= 0.0:
		return 0.0
	return maxf(0.0, (Clock.now() - r.last_seen_at) / 3600.0)


# --- Simulation --------------------------------------------------------------

## Move one pet forward by `seconds`. `present` distinguishes seconds the player
## was around for from seconds the app was closed; it is the only difference
## between live play and offline catch-up, which is why there is one function.
func advance(r: PetRecord, seconds: float, present: bool = true) -> void:
	if seconds <= 0.0:
		return
	var hours: float = seconds / 3600.0

	for k in NEED_KEYS:
		var rate: float = float(NEED_DECAY.get(k, 0.03))
		if not present:
			rate *= OFFLINE_NEED_SCALE
		r.needs[k] = clampf(r.need(k) - rate * hours, 0.0, 1.0)
	if not present:
		r.needs[&"rest"] = clampf(r.need(&"rest") + OFFLINE_REST_RECOVERY * hours, 0.0, 1.0)

	# Today's affection budget refills over a day, which is what stops a single
	# marathon petting session from buying a lifetime bond.
	r.affection_spent = maxf(0.0, r.affection_spent - DAILY_AFFECTION_BUDGET * hours / 24.0)
	r.stress = r.stress * pow(0.5, seconds / STRESS_HALFLIFE)

	var well: float = wellbeing(r)

	# Neglect costs affection, gently, and only down to the bond floor.
	if well < NEGLECT_THRESHOLD:
		var severity: float = (NEGLECT_THRESHOLD - well) / NEGLECT_THRESHOLD
		var floor_v: float = bond_floor(r)
		if r.affection > floor_v:
			var loss: float = AFFECTION_DECAY_PER_HOUR * severity * hours
			_set_affection(r, maxf(floor_v, r.affection - loss), false)
	elif r.trust < r.affection * 0.9:
		# Well-kept pets soften toward being handled again.
		add_trust(r, TRUST_RECOVERY_PER_HOUR * hours)

	_advance_growth(r, hours, well)
	_check_critical(r)
	refresh_mood(r)
	_check_time_milestones(r)


## Growth is gated on care, not blocked by it: a neglected pet still grows, at
## roughly a third of the pace. Stage crossings are announced exactly once,
## even when a three-day catch-up jumps two of them.
func _advance_growth(r: PetRecord, hours: float, well: float) -> void:
	if r.growth >= 3.0:
		return
	var s: CreatureSpec = spec_for(r.species)
	var per_stage: float = DEFAULT_HOURS_PER_STAGE
	if s != null:
		per_stage = maxf(0.5, s.hours_per_stage)
	var care: float = clampf(MIN_GROWTH_RATE + (1.0 - MIN_GROWTH_RATE) * well, MIN_GROWTH_RATE, 1.0)
	r.growth = clampf(r.growth + (hours / per_stage) * care, 0.0, 3.0)

	var st: int = r.stage()
	while r.stage_seen < st:
		r.stage_seen += 1
		EventBus.stage_advanced.emit(r.id, r.stage_seen)
		unlock(r, StringName(String(STAGE_MILESTONES[r.stage_seen])))
		SaveSystem.mark_dirty()


## One number for "is this pet alright", used by growth gating, mood and the
## affection decay. Needs dominate; the bond softens a bad day.
func wellbeing(r: PetRecord) -> float:
	var mean := 0.0
	for k in NEED_KEYS:
		mean += r.need(k)
	mean /= float(NEED_KEYS.size())
	return clampf(0.75 * mean + 0.25 * clampf(r.affection * 1.4, 0.0, 1.0), 0.0, 1.0)


func bond_floor(r: PetRecord) -> float:
	return clampf(BOND_FLOOR_RATIO * r.affection_peak, 0.02, 0.55)


func _check_critical(r: PetRecord) -> void:
	var flags: Dictionary = _critical.get(r.id, {})
	for k in NEED_KEYS:
		var low: bool = r.need(k) < NEED_CRITICAL
		if low and not bool(flags.get(k, false)):
			EventBus.need_critical.emit(r.id, k)
		flags[k] = low
	_critical[r.id] = flags


func _check_time_milestones(r: PetRecord) -> void:
	if r.born_at > 0.0 and Clock.now() - r.born_at >= 7.0 * 86400.0:
		unlock(r, &"week_together")
	if r.affection >= 0.45:
		unlock(r, &"friends")
	if r.affection >= 0.8:
		unlock(r, &"bonded")


# --- Mood --------------------------------------------------------------------

## Mood is derived, never authored: it is a readout of needs, bond and how the
## last few minutes went. Two axes (how good, how awake) collapse into a name
## that the rig, the voice and the UI can all branch on.
func refresh_mood(r: PetRecord) -> void:
	var mean := 0.0
	for k in NEED_KEYS:
		mean += r.need(k)
	mean /= float(NEED_KEYS.size())
	var p: Dictionary = personality(r)

	var valence: float = clampf(
		0.46 * mean + 0.30 * r.affection + 0.24 * (1.0 - r.stress), 0.0, 1.0)
	var arousal: float = clampf(
		0.22 + 0.42 * float(p[&"energy"]) + 0.34 * r.deficit(&"play")
		- 0.50 * r.deficit(&"rest") + 0.45 * r.stress, 0.0, 1.0)
	# Smooth the axes: mood should read as a drift, not as a switch flipping on
	# a tick boundary.
	r.mood_valence = lerpf(r.mood_valence, valence, 0.25)
	r.mood_arousal = lerpf(r.mood_arousal, arousal, 0.25)

	var next := &"content"
	if r.stress > 0.55:
		next = &"anxious"
	elif r.need(&"food") < NEED_CRITICAL:
		next = &"hungry"
	elif r.need(&"rest") < NEED_CRITICAL or r.mood_arousal < 0.2:
		next = &"sleepy"
	elif r.need(&"clean") < NEED_CRITICAL:
		next = &"itchy"
	elif r.mood_valence < 0.34:
		next = &"lonely"
	elif r.affection > 0.66 and r.mood_valence > 0.62:
		next = &"affectionate"
	elif r.deficit(&"play") > 0.55 and r.mood_arousal > 0.58:
		next = &"playful"
	elif r.mood_valence > 0.66:
		next = &"happy"

	if next != r.mood:
		r.mood = next
		EventBus.mood_changed.emit(r.id, next)
		SaveSystem.mark_dirty()


# --- Mutation API ------------------------------------------------------------

## Affection gains are damped twice: by how much bond already exists, and by how
## much of today's budget is left. Both are there to make the number mean
## something — a pet that adores you should have taken days to get there.
func add_affection(r: PetRecord, amount: float, reason: StringName = &"") -> float:
	if amount == 0.0:
		return 0.0
	if amount < 0.0:
		# Losses skip the budget entirely and are capped by the bond floor, so
		# one bad moment can never undo a week.
		var target: float = maxf(bond_floor(r), r.affection + amount * 0.5)
		return _set_affection(r, target, true)
	var headroom: float = clampf(
		1.0 - r.affection_spent / DAILY_AFFECTION_BUDGET, 0.06, 1.0)
	var taper: float = pow(clampf(1.0 - r.affection, 0.0, 1.0), 0.65)
	var gain: float = amount * headroom * taper
	r.affection_spent += gain
	if reason != &"":
		Log.debug("GameState", "affection +%.4f (%s)" % [gain, reason])
	return _set_affection(r, r.affection + gain, true)


func _set_affection(r: PetRecord, value: float, notify: bool) -> float:
	var before: float = r.affection
	r.affection = clampf(value, 0.0, 1.0)
	r.affection_peak = maxf(r.affection_peak, r.affection)
	var delta: float = r.affection - before
	if delta == 0.0:
		return 0.0
	if notify:
		EventBus.affection_changed.emit(r.id, r.affection, delta)
	SaveSystem.mark_dirty()
	return delta


func add_trust(r: PetRecord, amount: float) -> float:
	var before: float = r.trust
	# Trust is easier to lose than to gain, which is the whole point of it
	# being separate from affection — but it is floored well above zero once the
	# pet knows you, so a single mistake is never fatal.
	var scaled: float = amount if amount >= 0.0 else amount * 1.6
	var low: float = clampf(0.25 * r.affection_peak, 0.0, 0.4)
	r.trust = clampf(r.trust + scaled, low, 1.0)
	var delta: float = r.trust - before
	if delta == 0.0:
		return 0.0
	EventBus.trust_changed.emit(r.id, r.trust, delta)
	if r.trust >= 0.7:
		unlock(r, &"first_belly")
	SaveSystem.mark_dirty()
	return delta


func add_stress(r: PetRecord, amount: float) -> void:
	r.stress = clampf(r.stress + amount, 0.0, 1.0)


func satisfy(r: PetRecord, key: StringName, amount: float) -> void:
	r.needs[key] = clampf(r.need(key) + amount, 0.0, 1.0)
	SaveSystem.mark_dirty()


func bump_stat(r: PetRecord, key: StringName, n: int = 1) -> int:
	var v: int = r.stat(key) + n
	r.stats[key] = v
	return v


func mark_seen(r: PetRecord) -> void:
	r.last_seen_at = Clock.now()


func display_name(r: PetRecord) -> String:
	if r.nickname != "":
		return r.nickname
	var s: CreatureSpec = spec_for(r.species)
	return s.display_name if s != null else String(r.species).capitalize()


func rename(r: PetRecord, nickname: String) -> void:
	var first: bool = r.nickname == ""
	r.nickname = nickname
	if first and nickname != "":
		unlock(r, &"named")
	SaveSystem.mark_dirty()


func feed(r: PetRecord, food_id: StringName = &"kibble") -> void:
	satisfy(r, &"food", 0.55)
	satisfy(r, &"clean", -0.03)
	add_affection(r, 0.014, &"fed")
	add_trust(r, 0.010)
	bump_stat(r, &"meals")
	unlock(r, &"first_meal")
	EventBus.pet_fed.emit(r.id, food_id)


func play(r: PetRecord, toy_id: StringName = &"feather", intensity: float = 1.0) -> void:
	satisfy(r, &"play", 0.38 * intensity)
	satisfy(r, &"rest", -0.05 * intensity)
	add_affection(r, 0.011 * intensity, &"played")
	add_trust(r, 0.008 * intensity)
	bump_stat(r, &"plays")
	unlock(r, &"first_play")
	EventBus.pet_played_with.emit(r.id, toy_id)


## Called by the greeting behaviour once the pet has actually said hello.
func greeted(r: PetRecord, away_seconds: float) -> void:
	# A longer absence is worth more, but with a hard ceiling: going away is not
	# a strategy for building a bond.
	var scale: float = clampf(away_seconds / (12.0 * 3600.0), 0.25, 1.0)
	add_affection(r, 0.020 * scale, &"greeted")
	add_trust(r, 0.006)
	bump_stat(r, &"greetings")
	r.stress = maxf(0.0, r.stress - 0.2)
	EventBus.pet_greeted.emit(r.id, away_seconds)
	SaveSystem.mark_dirty()


# --- Milestones and journal --------------------------------------------------

func has_milestone(r: PetRecord, id: StringName) -> bool:
	return r.milestones.has(String(id))


## Award a milestone once. Returns true only on the crossing, so callers can
## fire a one-time celebration without tracking it themselves.
func unlock(r: PetRecord, id: StringName) -> bool:
	var key := String(id)
	if key == "" or r.milestones.has(key):
		return false
	r.milestones[key] = Clock.now()
	EventBus.milestone_unlocked.emit(r.id, id)
	var text: String = MILESTONES.get(key, "")
	if text != "":
		note(r, id, text)
	SaveSystem.mark_dirty()
	return true


## Write a remembered moment. The journal is the reason a returning player cares
## about *this* pet rather than about a pet: it is the only part of the save
## that is prose.
func note(r: PetRecord, id: StringName, text: String) -> bool:
	if text == "":
		return false
	for e in r.journal:
		if typeof(e) == TYPE_DICTIONARY and String(e.get("id", "")) == String(id):
			return false
	var entry := {"id": String(id), "text": text, "at": Clock.now()}
	r.journal.append(entry)
	while r.journal.size() > JOURNAL_CAP:
		# Keep the oldest entries; the first week is the part worth re-reading.
		r.journal.remove_at(JOURNAL_CAP / 2)
	EventBus.journal_entry.emit(r.id, id, text, float(entry["at"]))
	SaveSystem.mark_dirty()
	return true


## Has this pet met the desktop object behind `label` before? Novelty is what
## drives investigation, and it has to survive a restart or every launch would
## look like the pet had amnesia.
func is_ledge_known(r: PetRecord, label: String) -> bool:
	return r.known_ledges.has(label)


func remember_ledge(r: PetRecord, label: String) -> void:
	if label == "" or r.known_ledges.has(label):
		return
	r.known_ledges.append(label)
	while r.known_ledges.size() > KNOWN_LEDGE_CAP:
		r.known_ledges.remove_at(0)
	SaveSystem.mark_dirty()


# --- Persistence -------------------------------------------------------------

func serialise() -> Dictionary:
	var arr: Array = []
	for p in pets:
		arr.append(p.to_dict())
	return {"pets": arr}


func deserialise(payload: Dictionary) -> void:
	pets.clear()
	_critical.clear()
	_personality.clear()
	var arr: Variant = payload.get("pets", [])
	if typeof(arr) != TYPE_ARRAY:
		return
	for d in arr:
		if typeof(d) == TYPE_DICTIONARY:
			pets.append(PetRecord.from_dict(d))
	Log.info("GameState", "restored %d pets" % pets.size())
