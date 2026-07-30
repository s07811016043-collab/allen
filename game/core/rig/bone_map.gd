class_name RigBoneMap
extends RefCounted

## The canonical bone vocabulary, and the classifier that maps a species' parts
## onto it.
##
## `BONES.md`, next to this file, is the authored contract that species agents
## write against. This file is its executable half: it owns the exact bone-name
## grammar, and it recovers the intended bone from a part id when the species
## has not named one explicitly. Part ids in Petalia already read like anatomy
## (`leg_bl_far_upper`, `ear_near_inner`, `tail_1`), so inference is reliable and
## keeps species files free of rig bookkeeping. `SDFPart.bone_a` / `bone_b`
## always win when they are set.
##
## Everything here is pure string/enum work — no geometry. `RigSkeleton.build`
## does the fitting.

## What anatomical role a part plays. One slot per bone family in BONES.md.
enum Slot {
	NONE, PELVIS, SPINE, CHEST, NECK, HEAD, JAW, MUZZLE,
	EAR, TAIL, CREST, WATTLE, JOWL, BELLY, LIMB, WING,
}

## Limb segments, proximal → distal. A plantigrade limb uses UPPER/LOWER/FOOT; a
## digitigrade hind leg adds CANNON, which is what makes the hock read correctly.
enum Seg { UPPER, LOWER, CANNON, FOOT, TOE }

const SEG_NAMES := ["upper", "lower", "cannon", "foot", "toe"]
## Terminal leaf of every chain. Carries the tip so the last real segment still
## has a joint of its own to rotate about.
const TIP := "tip"

## Fixed counts, so a species author can predict the tree without reading code.
const SPINE_BONES := 3
const NECK_BONES := 2
const EAR_JOINTS := 2
const MAX_TAIL_JOINTS := 8

const ROOT := &"root"
const PELVIS := &"pelvis"
const CHEST := &"chest"
const HEAD := &"head"
const JAW := &"jaw"
const MUZZLE := &"muzzle"

## Side markers used inside chain and limb names.
const SIDE_NONE := -1
const SIDE_NEAR := 0
const SIDE_FAR := 1


## Result of classifying one part id.
class Tag:
	var slot: int = Slot.NONE
	## Side away from the viewer. Resolved from an explicit token, else from the
	## part's render layer (BEHIND ⇒ far), which every species already sets.
	var far := false
	## Limbs only: pectoral (fore) versus pelvic (hind) girdle.
	var fore := true
	## Limb/wing segment, or -1 when the id did not say and order must decide.
	var seg := -1
	## Trailing index parsed off the id (`tail_1` → 1), or -1.
	var index := -1


const _WORDS := {
	# --- body axis ---
	"hip": Slot.PELVIS, "hips": Slot.PELVIS, "pelvis": Slot.PELVIS, "rump": Slot.PELVIS,
	"croup": Slot.PELVIS, "haunch": Slot.PELVIS, "cloaca": Slot.PELVIS,
	"torso": Slot.SPINE, "body": Slot.SPINE, "barrel": Slot.SPINE, "spine": Slot.SPINE,
	"trunk": Slot.SPINE, "abdomen": Slot.SPINE, "flank": Slot.SPINE, "saddle": Slot.SPINE,
	"dorsal": Slot.SPINE, "midsection": Slot.SPINE, "waist": Slot.SPINE,
	"chest": Slot.CHEST, "breast": Slot.CHEST, "ribcage": Slot.CHEST, "keel": Slot.CHEST,
	"crop": Slot.CHEST, "brisket": Slot.CHEST, "withers": Slot.CHEST, "scapula": Slot.CHEST,
	"neck": Slot.NECK, "throat": Slot.NECK, "mane": Slot.NECK, "ruff": Slot.NECK,
	"hackle": Slot.NECK, "nape": Slot.NECK,
	"head": Slot.HEAD, "skull": Slot.HEAD, "cheek": Slot.HEAD, "crown": Slot.HEAD,
	"brow": Slot.HEAD, "forehead": Slot.HEAD, "temple": Slot.HEAD, "eye": Slot.HEAD,
	"jaw": Slot.JAW, "chin": Slot.JAW, "mandible": Slot.JAW, "lowerbeak": Slot.JAW,
	"muzzle": Slot.MUZZLE, "snout": Slot.MUZZLE, "nose": Slot.MUZZLE, "nostril": Slot.MUZZLE,
	"beak": Slot.MUZZLE, "bill": Slot.MUZZLE, "whisker": Slot.MUZZLE, "lip": Slot.MUZZLE,
	"rostrum": Slot.MUZZLE, "cere": Slot.MUZZLE,
	# --- secondary-motion chains ---
	"ear": Slot.EAR, "pinna": Slot.EAR,
	"tail": Slot.TAIL, "rectrix": Slot.TAIL, "brush": Slot.TAIL,
	"crest": Slot.CREST, "comb": Slot.CREST, "frill": Slot.CREST, "sail": Slot.CREST,
	"plume": Slot.CREST, "spike": Slot.CREST, "horn": Slot.CREST, "antler": Slot.CREST,
	"wattle": Slot.WATTLE, "dewlap": Slot.WATTLE, "gular": Slot.WATTLE, "snood": Slot.WATTLE,
	"jowl": Slot.JOWL, "flew": Slot.JOWL, "pouch": Slot.JOWL,
	"belly": Slot.BELLY, "paunch": Slot.BELLY, "gut": Slot.BELLY, "udder": Slot.BELLY,
	# --- appendages ---
	"wing": Slot.WING, "primary": Slot.WING, "secondary": Slot.WING,
	"covert": Slot.WING, "alula": Slot.WING,
	"leg": Slot.LIMB, "arm": Slot.LIMB, "paw": Slot.LIMB, "foot": Slot.LIMB,
	"hand": Slot.LIMB, "hoof": Slot.LIMB, "talon": Slot.LIMB, "toe": Slot.LIMB,
	"claw": Slot.LIMB, "digit": Slot.LIMB, "thigh": Slot.LIMB, "shin": Slot.LIMB,
	"femur": Slot.LIMB, "tibia": Slot.LIMB, "humerus": Slot.LIMB, "radius": Slot.LIMB,
	"cannon": Slot.LIMB, "shank": Slot.LIMB, "elbow": Slot.LIMB, "knee": Slot.LIMB,
	"hock": Slot.LIMB, "ankle": Slot.LIMB, "wrist": Slot.LIMB, "pastern": Slot.LIMB,
	"forearm": Slot.LIMB, "upperarm": Slot.LIMB, "stifle": Slot.LIMB, "shoulder": Slot.LIMB,
	"metatarsus": Slot.LIMB, "metacarpus": Slot.LIMB,
}

const _SEG_WORDS := {
	"upper": Seg.UPPER, "humerus": Seg.UPPER, "femur": Seg.UPPER, "thigh": Seg.UPPER,
	"upperarm": Seg.UPPER, "shoulder": Seg.UPPER,
	"lower": Seg.LOWER, "tibia": Seg.LOWER, "shin": Seg.LOWER, "radius": Seg.LOWER,
	"forearm": Seg.LOWER, "shank": Seg.LOWER, "knee": Seg.LOWER, "elbow": Seg.LOWER,
	"stifle": Seg.LOWER,
	"cannon": Seg.CANNON, "metatarsus": Seg.CANNON, "metacarpus": Seg.CANNON,
	"pastern": Seg.CANNON, "hock": Seg.CANNON, "ankle": Seg.CANNON, "wrist": Seg.CANNON,
	"foot": Seg.FOOT, "paw": Seg.FOOT, "hand": Seg.FOOT, "hoof": Seg.FOOT, "talon": Seg.FOOT,
	"toe": Seg.TOE, "digit": Seg.TOE, "claw": Seg.TOE, "nail": Seg.TOE,
}

## Tokens that put a limb on the pectoral girdle. `fl`/`fr` are the shorthand
## older specs use for front-left / front-right.
const _FORE_WORDS := ["fore", "front", "f", "fl", "fr", "pectoral", "arm", "hand",
	"wrist", "elbow", "humerus", "radius", "forearm", "upperarm", "shoulder"]
const _HIND_WORDS := ["hind", "rear", "back", "b", "h", "bl", "br", "hl", "hr",
	"pelvic", "thigh", "femur", "tibia", "shin", "hock", "knee", "stifle", "haunch"]
const _FAR_WORDS := ["far", "off", "opposite"]
const _NEAR_WORDS := ["near", "close"]


## Classify one part. `layer` is `SDFPart.Layer`; BEHIND is the fallback signal
## for "this is the far side of the animal", which is exactly how species use it.
static func classify(part_id: StringName, layer: int) -> Tag:
	var t := Tag.new()
	t.far = layer == 0
	var tokens := String(part_id).to_lower().split("_", false)
	var saw_side := false
	for tok in tokens:
		if tok.is_valid_int():
			t.index = int(tok)
			continue
		if tok in _FAR_WORDS:
			t.far = true
			saw_side = true
		elif tok in _NEAR_WORDS:
			t.far = false
			saw_side = true
		if t.slot == Slot.NONE and _WORDS.has(tok):
			t.slot = _WORDS[tok]
	if not saw_side:
		t.far = layer == 0

	if t.slot != Slot.LIMB and t.slot != Slot.WING:
		return t

	# Girdle and segment only mean anything on a limb, and `back`/`f` would
	# otherwise collide with the axis vocabulary.
	var girdled := false
	for tok in tokens:
		if not girdled and tok in _FORE_WORDS:
			t.fore = true
			girdled = true
		elif not girdled and tok in _HIND_WORDS:
			t.fore = false
			girdled = true
		if t.seg < 0 and _SEG_WORDS.has(tok):
			t.seg = _SEG_WORDS[tok]
	if not girdled:
		# Left unstated; `RigSkeleton.build` decides from the part's position
		# relative to the body's midpoint.
		t.fore = true
	return t


## True when the id carried no girdle token, so geometry must break the tie.
static func girdle_stated(part_id: StringName) -> bool:
	for tok in String(part_id).to_lower().split("_", false):
		if tok in _FORE_WORDS or tok in _HIND_WORDS:
			return true
	return false


static func spine_bone(i: int) -> StringName:
	return StringName("spine_%02d" % (i + 1))


static func neck_bone(i: int) -> StringName:
	return StringName("neck_%02d" % (i + 1))


## `base` is the chain family (`tail`, `ear`, `crest`, …); `side` is one of the
## SIDE_* constants; `i` is zero-based and prints one-based.
static func chain_bone(base: String, side: int, i: int) -> StringName:
	if side == SIDE_NONE:
		return StringName("%s_%02d" % [base, i + 1])
	return StringName("%s_%s_%02d" % [base, "far" if side == SIDE_FAR else "near", i + 1])


static func chain_tip(base: String, side: int) -> StringName:
	if side == SIDE_NONE:
		return StringName("%s_%s" % [base, TIP])
	return StringName("%s_%s_%s" % [base, "far" if side == SIDE_FAR else "near", TIP])


static func chain_prefix(base: String, side: int) -> String:
	if side == SIDE_NONE:
		return base + "_"
	return "%s_%s_" % [base, "far" if side == SIDE_FAR else "near"]


static func limb_base(fore: bool, far: bool, wing: bool) -> String:
	if wing:
		return "wing_%s" % ("far" if far else "near")
	return "leg_%s_%s" % ["fore" if fore else "hind", "far" if far else "near"]


static func limb_bone(fore: bool, far: bool, wing: bool, seg: int) -> StringName:
	var suffix: String = TIP if seg < 0 or seg >= SEG_NAMES.size() else SEG_NAMES[seg]
	return StringName("%s_%s" % [limb_base(fore, far, wing), suffix])


## Coarse touch region for a part, used by `Creature.region_at`. Deliberately
## fewer buckets than there are slots: a player pets "the head", not "the jaw".
static func region_for(slot: int, seg: int) -> StringName:
	match slot:
		Slot.PELVIS: return &"rump"
		Slot.SPINE: return &"back"
		Slot.CHEST: return &"chest"
		Slot.NECK: return &"neck"
		Slot.HEAD: return &"head"
		Slot.JAW, Slot.MUZZLE: return &"muzzle"
		Slot.EAR: return &"ear"
		Slot.TAIL: return &"tail"
		Slot.CREST: return &"crest"
		Slot.WATTLE, Slot.JOWL: return &"throat"
		Slot.BELLY: return &"belly"
		Slot.WING: return &"wing"
		Slot.LIMB:
			return &"paw" if seg >= Seg.FOOT else &"leg"
	return &"body"
