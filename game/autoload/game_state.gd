extends Node

## The authoritative model of every pet the player owns.
##
## Deliberately holds no nodes and no rendering concerns: it is the thing that
## gets serialised, and the thing that survives when the pet's scene is freed
## because the player minimised the app.

## Per-pet persistent record.
class PetRecord:
	var id: StringName = &""
	var species: StringName = &"cat"
	var nickname: String = ""
	## Continuous growth in [0, 3]: 0 = newborn, 3 = fully adult.
	var growth: float = 0.0
	## Bond with the player in [0, 1]. Slow to earn, slow to lose.
	var affection: float = 0.1
	## Needs in [0, 1] where 1 = fully satisfied.
	var needs := {&"food": 0.8, &"play": 0.8, &"rest": 0.9, &"clean": 0.9}
	var mood: StringName = &"content"
	## Unix timestamp of creation and of the last time the player interacted.
	var born_at: float = 0.0
	var last_seen_at: float = 0.0
	## Colour/pattern variation seed, so two cats are visibly different pets.
	var variant_seed: int = 0
	## Milestones already awarded, keyed by id.
	var milestones := {}
	## Lifetime counters that feed the journal.
	var stats := {&"strokes": 0, &"meals": 0, &"naps": 0, &"steps": 0}

	func stage() -> int:
		return clampi(int(floor(growth)), 0, 3)

	func to_dict() -> Dictionary:
		return {
			"id": String(id), "species": String(species), "nickname": nickname,
			"growth": growth, "affection": affection, "needs": needs,
			"mood": String(mood), "born_at": born_at, "last_seen_at": last_seen_at,
			"variant_seed": variant_seed, "milestones": milestones, "stats": stats,
		}

	static func from_dict(d: Dictionary) -> PetRecord:
		var r := PetRecord.new()
		r.id = StringName(d.get("id", "pet"))
		r.species = StringName(d.get("species", "cat"))
		r.nickname = d.get("nickname", "")
		r.growth = float(d.get("growth", 0.0))
		r.affection = float(d.get("affection", 0.1))
		var n: Variant = d.get("needs")
		if typeof(n) == TYPE_DICTIONARY:
			for k in n.keys():
				r.needs[StringName(k)] = float(n[k])
		r.mood = StringName(d.get("mood", "content"))
		r.born_at = float(d.get("born_at", 0.0))
		r.last_seen_at = float(d.get("last_seen_at", 0.0))
		r.variant_seed = int(d.get("variant_seed", 0))
		var m: Variant = d.get("milestones")
		if typeof(m) == TYPE_DICTIONARY:
			r.milestones = m
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


func _ready() -> void:
	_load_specs()
	var payload := SaveSystem.load_save()
	if payload.is_empty():
		Log.info("GameState", "no save found; starting fresh")
	else:
		deserialise(payload)


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


func serialise() -> Dictionary:
	var arr: Array = []
	for p in pets:
		arr.append(p.to_dict())
	return {"pets": arr}


func deserialise(payload: Dictionary) -> void:
	pets.clear()
	var arr: Variant = payload.get("pets", [])
	if typeof(arr) != TYPE_ARRAY:
		return
	for d in arr:
		if typeof(d) == TYPE_DICTIONARY:
			pets.append(PetRecord.from_dict(d))
	Log.info("GameState", "restored %d pets" % pets.size())
