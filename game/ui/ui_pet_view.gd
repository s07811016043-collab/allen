class_name UIPetView
extends RefCounted

## A read-only view of one pet, shaped for the interface rather than for the
## save file.
##
## The panels deliberately do not reach into `GameState.PetRecord`. Two reasons,
## and only one of them is architectural: the model is owned by another part of
## the codebase and changes under us, and — more importantly — the UI needs
## derived facts the model has no business computing ("four days together",
## "62% of the way to teen", "adopted on a Tuesday in June"). Putting those here
## keeps the same phrasing in the care panel, the journal and a toast.
##
## Every field is read defensively. A desktop pet that cannot draw its own
## interface because a save file was written by a newer build is not shippable.

var id: StringName = &"pet"
var species: StringName = &"cat"
var nickname: String = ""
var growth: float = 0.0
var affection: float = 0.0
var needs := {&"food": 1.0, &"play": 1.0, &"rest": 1.0, &"clean": 1.0}
var mood: StringName = &"content"
var born_at: float = 0.0
var stats := {&"strokes": 0, &"meals": 0, &"naps": 0, &"steps": 0}
## milestone id -> unix timestamp it was awarded.
var milestones := {}
var variant_seed: int = 0

const NEED_ORDER: Array[StringName] = [&"food", &"play", &"rest", &"clean"]
const STAGE_NAMES := ["Baby", "Child", "Teen", "Adult"]
## Species-specific baby words. "Your baby cat" is what a spreadsheet would
## write; "your kitten" is what a person would.
const BABY_WORDS := {
	&"cat": "Kitten", &"dog": "Puppy", &"bird": "Chick", &"reptile": "Hatchling",
}


## Build from a `GameState.PetRecord` (or anything shaped like one).
static func from_record(rec: Object) -> UIPetView:
	var v := UIPetView.new()
	if rec == null:
		return v
	v.id = StringName(_field(rec, "id", "pet"))
	v.species = StringName(_field(rec, "species", "cat"))
	v.nickname = String(_field(rec, "nickname", ""))
	v.growth = float(_field(rec, "growth", 0.0))
	v.affection = float(_field(rec, "affection", 0.0))
	v.mood = StringName(_field(rec, "mood", "content"))
	v.born_at = float(_field(rec, "born_at", 0.0))
	v.variant_seed = int(_field(rec, "variant_seed", 0))
	var n: Variant = _field(rec, "needs", null)
	if typeof(n) == TYPE_DICTIONARY:
		for k in n:
			v.needs[StringName(k)] = float(n[k])
	var s: Variant = _field(rec, "stats", null)
	if typeof(s) == TYPE_DICTIONARY:
		for k in s:
			v.stats[StringName(k)] = int(s[k])
	var m: Variant = _field(rec, "milestones", null)
	if typeof(m) == TYPE_DICTIONARY:
		v.milestones = m
	return v


static func _field(obj: Object, prop: String, fallback: Variant) -> Variant:
	if obj == null:
		return fallback
	var value: Variant = obj.get(prop)
	if value == null:
		return fallback
	return value


func display_name() -> String:
	if not nickname.is_empty():
		return nickname
	return species_name()


func species_name() -> String:
	return String(species).capitalize()


func stage() -> int:
	return clampi(int(floor(growth)), 0, 3)


## Stage name with the species' own word for a baby.
func stage_name(st: int = -1) -> String:
	var idx: int = stage() if st < 0 else clampi(st, 0, 3)
	if idx == 0:
		return String(BABY_WORDS.get(species, "Baby"))
	if idx == 3:
		return species_name()
	return STAGE_NAMES[idx]


func is_fully_grown() -> bool:
	return growth >= 2.999


## Fraction of the way from the current stage to the next, in [0, 1].
func stage_progress() -> float:
	if is_fully_grown():
		return 1.0
	return clampf(growth - floor(growth), 0.0, 1.0)


## Real hours left before the next stage, given the species' pacing. Returns a
## negative number when unknown, so callers can hide the estimate rather than
## print a confident lie.
func hours_to_next_stage(hours_per_stage: float) -> float:
	if is_fully_grown() or hours_per_stage <= 0.0:
		return -1.0
	return (1.0 - stage_progress()) * hours_per_stage


func days_together(now: float) -> int:
	if born_at <= 0.0:
		return 0
	return int(floor(maxf(0.0, now - born_at) / 86400.0))


## "12 June 2026". Written out rather than 12/06/2026 because the journal is
## meant to read like a diary, and because the numeric form is ambiguous across
## exactly the two regions most players are in.
func adopted_on() -> String:
	if born_at <= 0.0:
		return "today"
	var d := Time.get_datetime_dict_from_unix_time(int(born_at))
	const MONTHS := ["January", "February", "March", "April", "May", "June",
		"July", "August", "September", "October", "November", "December"]
	var m: int = clampi(int(d.get("month", 1)) - 1, 0, 11)
	return "%d %s %d" % [int(d.get("day", 1)), MONTHS[m], int(d.get("year", 2026))]


## A phrase for how long you have known each other, for the journal header.
func togetherness(now: float) -> String:
	var days := days_together(now)
	if days <= 0:
		return "Adopted today"
	if days == 1:
		return "One day together"
	if days < 14:
		return "%d days together" % days
	if days < 60:
		return "%d weeks together" % int(round(float(days) / 7.0))
	return "%d months together" % maxi(2, int(round(float(days) / 30.4)))


func need(key: StringName) -> float:
	return clampf(float(needs.get(key, 1.0)), 0.0, 1.0)


## The need most in want of attention, or an empty name when all are fine. The
## care panel uses this to say one useful sentence instead of four numbers.
func most_pressing_need() -> StringName:
	var worst: StringName = &""
	var worst_v := 0.45
	for k in NEED_ORDER:
		var v := need(k)
		if v < worst_v:
			worst_v = v
			worst = k
	return worst


## Mood as something a person would say. The model stores a token; this is the
## only place it becomes English, so the toast and the panel never disagree.
func mood_phrase() -> String:
	match mood:
		&"content": return "content"
		&"happy": return "delighted"
		&"playful": return "in a playful mood"
		&"sleepy": return "getting sleepy"
		&"hungry": return "hungry"
		&"lonely": return "missing you"
		&"grumpy": return "a little grumpy"
		&"curious": return "curious about something"
		&"scared": return "startled"
	return String(mood).replace("_", " ")


## Bond, worded rather than numbered. A percentage invites optimisation; a word
## invites affection, which is the entire point of the meter.
func bond_word() -> String:
	if affection >= 0.92:
		return "Inseparable"
	if affection >= 0.72:
		return "Devoted"
	if affection >= 0.48:
		return "Fond of you"
	if affection >= 0.24:
		return "Warming up"
	if affection >= 0.08:
		return "Curious about you"
	return "Just met"


## Demo data for the preview harness, so a shot can be reviewed before any of
## the gameplay systems that produce real data exist.
static func demo(sp: StringName = &"cat", name: String = "Mochi") -> UIPetView:
	var v := UIPetView.new()
	v.id = &"demo"
	v.species = sp
	v.nickname = name
	v.growth = 1.62
	v.affection = 0.68
	v.needs = {&"food": 0.34, &"play": 0.78, &"rest": 0.55, &"clean": 0.91}
	v.mood = &"playful"
	v.born_at = 1748000000.0
	v.stats = {&"strokes": 412, &"meals": 37, &"naps": 64, &"steps": 18930}
	v.milestones = {
		"first_touch": 1748003600.0,
		"named": 1748004000.0,
		"first_meal": 1748090000.0,
		"stage_child": 1748200000.0,
		"week_together": 1748604800.0,
		"bond_half": 1748700000.0,
	}
	return v
