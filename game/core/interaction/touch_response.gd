class_name TouchResponse
extends RefCounted

## What a touch means to this animal, here, right now.
##
## Three inputs decide it: **where** (region), **how** (gesture) and **whether
## the pet trusts you** (which gates the regions that are conditional rather
## than simply good or simply bad). A cat that trusts you rolls over for a belly
## rub; a cat that does not swipes. That single sentence is the design, and the
## tables below are it written down.
##
## The fourth input is time. Petting one spot without pause overstimulates —
## the classic cat that purrs, purrs, purrs and then bites your hand — so a
## per-region charge flips a good touch negative if you never let up. It decays
## the moment you move to another region or stop.

## Everything a touch does to the pet. Continuous gestures use the `_rate`
## fields (per second of contact); discrete ones and refusals use the impulses.
class Reaction:
	var region: StringName = &""
	var gesture: StringName = &"none"
	## How much the pet liked it, in [-1, 1].
	var valence: float = 0.0
	var affection_rate: float = 0.0
	var trust_rate: float = 0.0
	var affection_impulse: float = 0.0
	var trust_impulse: float = 0.0
	var stress_impulse: float = 0.0
	## Reflex charge handed to the brain; enough of it triggers a startle.
	var startle: float = 0.0
	## Visible answer: &"purr", &"lean_in", &"roll_over", &"knead", &"freeze",
	## &"tolerate", &"pull_away", &"flinch", &"swipe", &"wag".
	var response: StringName = &"tolerate"
	## Vocalisation, or &"" for silence.
	var vocal: StringName = &""

	func is_bad() -> bool:
		return valence <= -0.25


## Region tables. `base` is the valence at or above `gate` trust; `deny` is what
## happens below it. `best` names the gesture this spot is *for*.
##
## Keys are the canonical regions from `BodyMap.region_name`, which is also what
## the rig's own classifier answers in — so these tables work whether the hit
## test came from the posed creature or from the bind-pose fallback.
##
## Cats: ears, chin and cheeks are unconditionally welcome, the base of the tail
## is a surprise favourite, the belly is the famous trap, and the tail itself is
## never funny.
const CAT := {
	&"ear":    {"base": 0.86, "gate": 0.0,  "deny": 0.0,   "best": "scratch"},
	&"chin":   {"base": 0.96, "gate": 0.0,  "deny": 0.0,   "best": "scratch"},
	&"cheek":  {"base": 0.90, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"head":   {"base": 0.72, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"back":   {"base": 0.74, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"rump":   {"base": 0.82, "gate": 0.35, "deny": 0.10,  "best": "scratch"},
	&"chest":  {"base": 0.62, "gate": 0.30, "deny": 0.05,  "best": "stroke"},
	&"neck":   {"base": 0.30, "gate": 0.0,  "deny": 0.0,   "best": "stroke", "freeze": true},
	&"muzzle": {"base": 0.34, "gate": 0.25, "deny": -0.20, "best": "tap"},
	&"nose":   {"base": 0.30, "gate": 0.25, "deny": -0.25, "best": "tap"},
	&"belly":  {"base": 0.95, "gate": 0.62, "deny": -0.85, "best": "stroke"},
	&"leg":    {"base": 0.28, "gate": 0.55, "deny": -0.35, "best": "stroke"},
	&"paw":    {"base": 0.22, "gate": 0.78, "deny": -0.50, "best": "tap"},
	&"tail":   {"base": -0.30, "gate": 1.01, "deny": -0.75, "best": "none"},
}

## Dogs: almost everything is fine, the chest and belly are the *point*, and the
## tail is merely rude rather than a betrayal.
const DOG := {
	&"ear":    {"base": 0.88, "gate": 0.0,  "deny": 0.0,   "best": "scratch"},
	&"chin":   {"base": 0.80, "gate": 0.0,  "deny": 0.0,   "best": "scratch"},
	&"cheek":  {"base": 0.85, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"head":   {"base": 0.82, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"back":   {"base": 0.86, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"rump":   {"base": 0.78, "gate": 0.15, "deny": 0.20,  "best": "scratch"},
	&"chest":  {"base": 0.94, "gate": 0.0,  "deny": 0.0,   "best": "scratch"},
	&"neck":   {"base": 0.55, "gate": 0.0,  "deny": 0.0,   "best": "stroke"},
	&"muzzle": {"base": 0.45, "gate": 0.20, "deny": -0.10, "best": "tap"},
	&"nose":   {"base": 0.35, "gate": 0.20, "deny": -0.15, "best": "tap"},
	&"belly":  {"base": 1.00, "gate": 0.25, "deny": 0.10,  "best": "scratch"},
	&"leg":    {"base": 0.35, "gate": 0.35, "deny": -0.10, "best": "stroke"},
	&"paw":    {"base": 0.15, "gate": 0.60, "deny": -0.30, "best": "tap"},
	&"tail":   {"base": 0.05, "gate": 0.85, "deny": -0.35, "best": "none"},
}

## Birds: the head and crest are the only unconditionally good places. A hand
## running down a parrot's back is a mating signal, not affection, and it makes a
## real bird miserable — so it reads negative here however much it trusts you.
const BIRD := {
	&"head":   {"base": 0.92, "gate": 0.0,  "deny": 0.10,  "best": "scratch"},
	&"crest":  {"base": 0.98, "gate": 0.0,  "deny": 0.15,  "best": "scratch"},
	&"cheek":  {"base": 0.88, "gate": 0.0,  "deny": 0.10,  "best": "scratch"},
	&"ear":    {"base": 0.70, "gate": 0.20, "deny": 0.0,   "best": "scratch"},
	&"beak":   {"base": 0.45, "gate": 0.35, "deny": -0.10, "best": "tap"},
	&"chin":   {"base": 0.60, "gate": 0.25, "deny": 0.0,   "best": "scratch"},
	&"neck":   {"base": 0.35, "gate": 0.30, "deny": -0.20, "best": "stroke"},
	&"back":   {"base": -0.45, "gate": 1.01, "deny": -0.60, "best": "none"},
	&"rump":   {"base": -0.50, "gate": 1.01, "deny": -0.65, "best": "none"},
	&"chest":  {"base": 0.30, "gate": 0.55, "deny": -0.25, "best": "stroke"},
	&"wing":   {"base": -0.55, "gate": 1.01, "deny": -0.70, "best": "none"},
	&"belly":  {"base": -0.30, "gate": 0.90, "deny": -0.55, "best": "none"},
	&"leg":    {"base": 0.10, "gate": 0.70, "deny": -0.30, "best": "tap"},
	&"paw":    {"base": 0.05, "gate": 0.75, "deny": -0.35, "best": "tap"},
	&"tail":   {"base": -0.50, "gate": 1.01, "deny": -0.80, "best": "none"},
}

## Reptiles: the chin and head are where a bearded dragon wants to be touched,
## along the back is fine and warm, and the tail is as bad as it is for a cat.
const REPTILE := {
	&"head":   {"base": 0.80, "gate": 0.0,  "deny": 0.05,  "best": "stroke"},
	&"chin":   {"base": 0.94, "gate": 0.0,  "deny": 0.10,  "best": "scratch"},
	&"cheek":  {"base": 0.70, "gate": 0.15, "deny": 0.0,   "best": "stroke"},
	&"crest":  {"base": 0.60, "gate": 0.30, "deny": -0.10, "best": "stroke"},
	&"back":   {"base": 0.78, "gate": 0.0,  "deny": 0.10,  "best": "stroke"},
	&"rump":   {"base": 0.55, "gate": 0.25, "deny": 0.0,   "best": "stroke"},
	&"neck":   {"base": 0.55, "gate": 0.10, "deny": 0.0,   "best": "stroke"},
	&"chest":  {"base": 0.40, "gate": 0.40, "deny": -0.10, "best": "stroke"},
	&"muzzle": {"base": 0.25, "gate": 0.40, "deny": -0.20, "best": "tap"},
	&"nose":   {"base": 0.20, "gate": 0.40, "deny": -0.25, "best": "tap"},
	&"belly":  {"base": 0.35, "gate": 0.75, "deny": -0.60, "best": "stroke"},
	&"leg":    {"base": 0.15, "gate": 0.55, "deny": -0.25, "best": "tap"},
	&"paw":    {"base": 0.10, "gate": 0.70, "deny": -0.30, "best": "tap"},
	&"tail":   {"base": -0.35, "gate": 1.01, "deny": -0.70, "best": "none"},
}

## Seconds of unbroken attention to one region before it starts to grate.
const OVERSTIM_SECONDS := {
	&"cat": 9.0, &"dog": 40.0, &"bird": 14.0, &"reptile": 20.0,
}

## Vocabulary per family, so the audio layer never has to branch on species.
const VOICE := {
	&"cat": {"good": &"purr", "great": &"purr", "mild": &"mrrp", "bad": &"hiss", "worst": &"yowl"},
	&"dog": {"good": &"pant", "great": &"pant", "mild": &"huff", "bad": &"whine", "worst": &"growl"},
	&"bird": {"good": &"chirp", "great": &"warble", "mild": &"chirp", "bad": &"squawk", "worst": &"screech"},
	&"reptile": {"good": &"", "great": &"", "mild": &"", "bad": &"hiss", "worst": &"hiss"},
}


## Which table applies. Species id first, because that is authored intent;
## otherwise infer from the body plan, so a species added later still behaves
## sensibly before anyone writes it a table.
static func family_of(spec: CreatureSpec, species: StringName) -> StringName:
	match species:
		&"cat": return &"cat"
		&"dog": return &"dog"
		&"bird": return &"bird"
		&"reptile": return &"reptile"
	if spec != null:
		if spec.can_fly:
			return &"bird"
		if spec.locomotion == CreatureSpec.Locomotion.SPRAWLING:
			return &"reptile"
		if spec.can_climb:
			return &"cat"
	return &"dog"


static func table_for(spec: CreatureSpec, species: StringName) -> Dictionary:
	match family_of(spec, species):
		&"cat": return CAT
		&"bird": return BIRD
		&"reptile": return REPTILE
	return DOG


## Score one touch.
##
## `charge` is how many seconds this region has been worked without a break;
## `trust` and `affection` come from the record. The result is a rate for
## sustained gestures and an impulse for everything else — the router decides
## which to apply.
static func evaluate(spec: CreatureSpec, species: StringName, region: StringName,
		kind: PetGesture.Kind, trust: float, affection: float, charge: float) -> Reaction:
	var out := Reaction.new()
	out.region = region
	out.gesture = PetGesture.name_of(kind)
	if region == &"" or kind == PetGesture.Kind.NONE:
		return out

	var table: Dictionary = table_for(spec, species)
	var family: StringName = family_of(spec, species)
	var entry: Dictionary = table.get(region, {"base": 0.35, "gate": 0.4, "deny": -0.1, "best": "stroke"})

	var gate: float = float(entry.get("gate", 0.0))
	var allowed: bool = trust >= gate
	var v: float = float(entry.get("base", 0.0)) if allowed else float(entry.get("deny", -0.3))

	# Gesture fit. The right gesture in the right place is worth a lot more than
	# the same contact applied indiscriminately.
	var best := StringName(entry.get("best", "stroke"))
	if out.gesture == best:
		v *= 1.22 if v > 0.0 else 0.85
	match kind:
		PetGesture.Kind.TAP, PetGesture.Kind.DOUBLE_TAP:
			# A boop is brief and cannot carry much either way.
			v *= 0.55
		PetGesture.Kind.TICKLE:
			# Tickling is only welcome somewhere the pet is entirely relaxed
			# about; everywhere else it is an irritation.
			v = v * 0.5 if trust > 0.75 and v > 0.0 else minf(v, 0.0) - 0.15
		PetGesture.Kind.GRAB:
			v = minf(v, 0.0) - 0.25 * (1.0 - trust)
		_:
			pass

	# Overstimulation. Past the species' patience a good touch curdles, which is
	# the difference between a cat that is enjoying this and a cat that has had
	# enough of it.
	var patience: float = float(OVERSTIM_SECONDS.get(family, 20.0))
	if charge > patience and v > 0.0:
		var over: float = clampf((charge - patience) / (patience * 0.6), 0.0, 1.0)
		v = lerpf(v, -0.7, over)

	# A pet that already loves you gives more benefit of the doubt.
	if v < 0.0:
		v *= 1.0 - 0.25 * affection
	out.valence = clampf(v, -1.0, 1.0)

	_fill_effects(out, family, entry, kind, trust)
	return out


static func _fill_effects(out: Reaction, family: StringName, entry: Dictionary,
		kind: PetGesture.Kind, trust: float) -> void:
	var v: float = out.valence
	var voice: Dictionary = VOICE.get(family, VOICE[&"dog"])

	if v > 0.0:
		# Roughly: a minute of finding exactly the right spot is worth about a
		# tenth of the bond, before `GameState`'s own damping. Slow on purpose.
		out.affection_rate = 0.0021 * v
		out.trust_rate = 0.0030 * v
		out.affection_impulse = 0.0
		out.trust_impulse = 0.0
		if not PetGesture.is_continuous(kind):
			# One-off contact still counts, just much less than a real session.
			out.affection_impulse = 0.0035 * v
			out.trust_impulse = 0.0045 * v
		if v > 0.72:
			out.response = &"purr" if family == &"cat" else &"lean_in"
			out.vocal = voice["great"]
			if out.region == &"belly" and float(entry.get("base", 0.0)) >= 0.9:
				out.response = &"roll_over"
		elif v > 0.35:
			out.response = &"lean_in"
			out.vocal = voice["good"]
		else:
			out.response = &"wag" if family == &"dog" else &"blink"
			out.vocal = voice["mild"]
		if bool(entry.get("freeze", false)) and trust < 0.5:
			# Scruff hold: not unpleasant, but it does switch an animal off.
			out.response = &"freeze"
			out.vocal = &""
		return

	if v > -0.25:
		out.response = &"tolerate"
		return

	# Refusals are charged as one-off impulses: being cross about a tail pull is
	# an event, not a rate. Affection is barely touched — the pet is annoyed with
	# what you did, not with you.
	out.trust_impulse = -0.055 + 0.055 * v
	out.affection_impulse = 0.004 * v
	out.stress_impulse = 0.18 - 0.28 * v
	out.startle = 0.25 - 0.45 * v
	if v > -0.6:
		out.response = &"pull_away"
		out.vocal = voice["bad"]
	else:
		out.response = &"swipe" if family == &"cat" else &"flinch"
		out.vocal = voice["worst"]
