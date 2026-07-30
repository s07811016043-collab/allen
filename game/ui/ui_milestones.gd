class_name UIMilestones
extends RefCounted

## The catalogue of moments worth remembering.
##
## Milestones are the journal's spine, and the journal is the screen that makes
## somebody keep the app. So they are written as memories, not as achievements:
## no points, no completion percentage, no "3/12 unlocked" badge. Each one is a
## sentence about something that actually happened between two of you.
##
## The list lives here because nothing else needs it yet — the gameplay side
## only emits ids through `EventBus.milestone_unlocked`. If a canonical
## catalogue later appears in `core/`, `_external()` picks it up and this
## becomes a fallback rather than a fork.

const EXTERNAL_PATH := "res://core/creature/milestones.gd"


class Entry:
	var id: StringName
	var title: String
	var story: String
	var glyph: StringName
	## Ordering weight; roughly the order a player will meet them.
	var order: int

	func _init(p_id: StringName, p_title: String, p_story: String,
			p_glyph: StringName, p_order: int) -> void:
		id = p_id
		title = p_title
		story = p_story
		glyph = p_glyph
		order = p_order


static var _cache: Array = []


static func all() -> Array:
	if not _cache.is_empty():
		return _cache
	var ext := _external()
	if not ext.is_empty():
		_cache = ext
		return _cache
	_cache = [
		Entry.new(&"first_touch", "First contact",
			"You reached out. They leaned in.", &"paw", 0),
		Entry.new(&"named", "A name of their own",
			"The moment they stopped being \"the pet\".", &"sparkle", 1),
		Entry.new(&"first_meal", "First meal",
			"Eaten far too quickly, as is traditional.", &"food", 2),
		Entry.new(&"first_nap", "Asleep on your work",
			"Directly on top of whatever you were doing.", &"rest", 3),
		Entry.new(&"stage_child", "Growing up",
			"Legs caught up with the head. Mostly.", &"star", 4),
		Entry.new(&"week_together", "One week together",
			"Seven days of being followed around a desktop.", &"clock", 5),
		Entry.new(&"bond_half", "Trusted",
			"They come to you now without being called.", &"heart", 6),
		Entry.new(&"stage_teen", "The awkward phase",
			"All limbs and opinions.", &"star", 7),
		Entry.new(&"explorer", "Desktop explorer",
			"Ten thousand steps across your icons.", &"paw", 8),
		Entry.new(&"night_owl", "Kept you company",
			"Still awake at 3am, right beside you.", &"sleep", 9),
		Entry.new(&"stage_adult", "All grown up",
			"The pet you will have from here on.", &"star", 10),
		Entry.new(&"month_together", "One month together",
			"Long enough to be a habit. Long enough to matter.", &"clock", 11),
		Entry.new(&"bond_full", "Inseparable",
			"There is no version of your desktop without them.", &"affection", 12),
	]
	return _cache


## Load a catalogue from `core/` if the gameplay side has published one. Kept
## duck-typed so a change to its shape degrades to the built-in list rather than
## taking the whole interface down with it.
static func _external() -> Array:
	if not ResourceLoader.exists(EXTERNAL_PATH):
		return []
	var script: Script = load(EXTERNAL_PATH)
	if script == null or not script.has_method("ui_entries"):
		return []
	var raw: Variant = script.call("ui_entries")
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for e in raw:
		if e is Entry:
			out.append(e)
	return out


static func by_id(id: StringName) -> Entry:
	for e in all():
		if e.id == id:
			return e
	return null


## Everything, in journal order, paired with the timestamp it was unlocked
## (0 when still locked). Locked entries are shown deliberately: a journal with
## visible blank pages is an invitation, where a list that only grows is a log.
static func timeline(pet: UIPetView) -> Array:
	var out: Array = []
	for e in all():
		var when: float = float(pet.milestones.get(String(e.id), 0.0))
		out.append({&"entry": e, &"at": when})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var aa: float = a[&"at"]
		var bb: float = b[&"at"]
		# Unlocked first, most recent at the top; locked ones keep catalogue
		# order underneath so the next one to earn is always the one on top.
		if (aa > 0.0) != (bb > 0.0):
			return aa > 0.0
		if aa > 0.0:
			return aa > bb
		return (a[&"entry"] as Entry).order < (b[&"entry"] as Entry).order)
	return out


static func unlocked_count(pet: UIPetView) -> int:
	var n := 0
	for e in all():
		if float(pet.milestones.get(String(e.id), 0.0)) > 0.0:
			n += 1
	return n


## "3 days ago" / "12 June". Recent memories want relative phrasing, old ones
## want a date — that is how people actually talk about their own past.
static func when_phrase(at: float, now: float) -> String:
	if at <= 0.0:
		return ""
	var days: int = int(floor(maxf(0.0, now - at) / 86400.0))
	if days <= 0:
		return "today"
	if days == 1:
		return "yesterday"
	if days < 8:
		return "%d days ago" % days
	var d := Time.get_datetime_dict_from_unix_time(int(at))
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
		"Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%d %s" % [int(d.get("day", 1)),
		MONTHS[clampi(int(d.get("month", 1)) - 1, 0, 11)]]
