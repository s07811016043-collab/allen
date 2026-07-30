class_name BodyMap
extends RefCounted

## Turns a point on screen into a body region.
##
## `Creature.region_at()` is the authority when a creature exists: it owns the
## live, posed parts and classifies them through the rig's own bone map. This
## falls back to testing the point against the species bind pose run through
## `Growth` — the same implicit body the shader draws, just unposed — so the
## touch layer works before a creature node has been built, in headless tests,
## and in the adoption preview.
##
## Both paths answer in the vocabulary `region_name` normalises to, so
## `TouchResponse` never has to care which one replied.
##
## Everything here is in **rig space** (`+x` forward, `+y` down, origin between
## the paws, 1.0 ≈ adult shoulder height) except the conversion helpers.

## Rig-space slack around a capsule that still counts as touching it. Fur is
## soft and cursors are imprecise; being strict here makes the pet feel slippery.
const TOUCH_SLOP := 0.05
## Extra rig-space margin on the bounds test, so a stroke that starts just off
## the silhouette still reads as a stroke.
const BOUNDS_SLOP := 0.12

var spec: CreatureSpec = null

var _live: Array[SDFPart] = []
var _live_growth := -1.0
var _bounds := Rect2()
var _com := Vector2(0.0, -0.5)


func configure(p_spec: CreatureSpec) -> void:
	spec = p_spec
	_live.clear()
	_live_growth = -1.0
	if spec == null:
		return
	for p in spec.parts:
		if p != null:
			_live.append(p.duplicate_part())


## Rebuild the grown body, but only when growth has moved enough to matter —
## this runs inside pointer handling and must stay cheap.
func _ensure(growth: float) -> void:
	if spec == null or _live.is_empty():
		return
	if absf(growth - _live_growth) < 0.02:
		return
	_live_growth = growth
	Growth.apply(spec, _live, growth)

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var wsum := 0.0
	var csum := Vector2.ZERO
	for p in _live:
		var r: float = maxf(p.radius_a, p.radius_b)
		lo = lo.min(p.a.min(p.b) - Vector2(r, r))
		hi = hi.max(p.a.max(p.b) + Vector2(r, r))
		# Radius-weighted midpoints are a good enough centre of mass for a
		# dangling body: the torso dominates, which is what you want.
		var w: float = (p.radius_a + p.radius_b) * 0.5
		wsum += w
		csum += (p.a + p.b) * 0.5 * w
	_bounds = Rect2(lo, hi - lo)
	if wsum > 0.0:
		_com = csum / wsum


# --- Space conversion --------------------------------------------------------

## Screen pixels per rig unit for this creature right now.
##
## Deliberately computed from the spec rather than from the creature node's
## transform: `Creature` uses `scale.x` as its *facing* flip, so reading the
## node scale here would make the pet's touch target collapse every time it
## turned around.
func pixels_per_unit(growth: float) -> float:
	var px: float = spec.pixels_per_unit if spec != null else 180.0
	px *= float(Settings.get_value(&"pet_scale", 1.0))
	if spec != null:
		px *= spec.scale_at(growth)
	return maxf(px, 1.0)


## Offset between the game window and the screen. The brain, the ledge graph and
## the pointer all live in screen space; nodes live in the window's viewport.
static func window_origin() -> Vector2:
	return Vector2(DisplayServer.window_get_position())


## The creature's rig origin (between the paws) in screen space. Falls back to
## `fallback` — normally the brain's own idea of where the pet is — when there is
## no creature node yet.
func origin(creature: Node, fallback: Vector2) -> Vector2:
	if creature is Node2D:
		return (creature as Node2D).global_position + window_origin()
	return fallback


func to_rig(creature: Node, fallback: Vector2, point: Vector2, growth: float) -> Vector2:
	return (point - origin(creature, fallback)) / pixels_per_unit(growth)


func to_screen(creature: Node, fallback: Vector2, rig_point: Vector2, growth: float) -> Vector2:
	return origin(creature, fallback) + rig_point * pixels_per_unit(growth)


# --- Queries -----------------------------------------------------------------

## Rig-space bounding box of the whole body, with slop.
func bounds_rig(growth: float) -> Rect2:
	_ensure(growth)
	if _bounds.size == Vector2.ZERO:
		# No spec: a plausible box around a standing animal, so the bounds test
		# still does something sane.
		return Rect2(-0.7, -1.1, 1.4, 1.15)
	return _bounds.grow(BOUNDS_SLOP)


func screen_bounds(creature: Node, fallback: Vector2, growth: float) -> Rect2:
	var b: Rect2 = bounds_rig(growth)
	var px: float = pixels_per_unit(growth)
	var o: Vector2 = origin(creature, fallback)
	return Rect2(o + b.position * px, b.size * px)


## Radius-weighted centre of mass, in rig space. The drag simulation hangs the
## body from the grab point through this.
func centre_of_mass(growth: float) -> Vector2:
	_ensure(growth)
	return _com


## Region under a screen point, or &"" for a miss.
func region_at(creature: Node, fallback: Vector2, point: Vector2, growth: float) -> StringName:
	if creature != null and creature.has_method("region_at"):
		# `Creature.region_at` works in the node's own global (viewport) space.
		var r: Variant = creature.call("region_at", point - window_origin())
		return region_name(StringName(String(r)))
	return region_at_rig(to_rig(creature, fallback, point, growth), growth)


func region_at_rig(rig_point: Vector2, growth: float) -> StringName:
	_ensure(growth)
	if _live.is_empty():
		# Without a spec all we can offer is inside-or-out, and the back is the
		# safest thing to assume a hand has landed on.
		return &"back" if bounds_rig(growth).has_point(rig_point) else &""
	var best: float = INF
	var best_id: StringName = &""
	for p in _live:
		var d: float = _capsule_distance(rig_point, p.a, p.b, p.radius_a, p.radius_b)
		if d < best:
			best = d
			best_id = p.id
	if best > TOUCH_SLOP:
		return &""
	return region_for_part(best_id)


## Signed distance from a point to a tapered capsule, in rig units. The exact
## round-cone form is not worth it here; the linear-radius approximation is well
## inside the fur.
static func _capsule_distance(p: Vector2, a: Vector2, b: Vector2,
		ra: float, rb: float) -> float:
	var ab: Vector2 = b - a
	var denom: float = ab.length_squared()
	var t := 0.0
	if denom > 1e-9:
		t = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t) - lerpf(ra, rb, t)


## Collapse a part id into a touch region. Parts are authored per species with
## names like `leg_bl_far_upper`; the touch layer only cares about the handful of
## places a hand can land, and they are the same handful for every animal.
##
## Finer than the rig's classifier on the face — a chin scratch and a nose boop
## are different interactions even though they are the same bone — and identical
## everywhere else, so the two agree once `region_name` has normalised them.
static func region_for_part(part_id: StringName) -> StringName:
	var s := String(part_id)
	if s.begins_with("ear"):
		return &"ear"
	if s.begins_with("crest"):
		return &"crest"
	if s.begins_with("beak"):
		return &"beak"
	if s.begins_with("nose"):
		return &"nose"
	if s.begins_with("muzzle") or s.begins_with("jaw"):
		return &"muzzle"
	if s.begins_with("chin") or s.begins_with("throat") or s.begins_with("jowl"):
		return &"chin"
	if s.begins_with("cheek"):
		return &"cheek"
	if s.begins_with("head") or s.begins_with("skull"):
		return &"head"
	if s.begins_with("neck"):
		return &"neck"
	if s.begins_with("tail"):
		return &"tail"
	if s.begins_with("wing"):
		return &"wing"
	if s.begins_with("paw") or s.begins_with("toe") or s.begins_with("claw"):
		return &"paw"
	if s.begins_with("leg"):
		return &"leg"
	if s.begins_with("belly"):
		return &"belly"
	if s.begins_with("chest"):
		return &"chest"
	if s.begins_with("hip") or s.begins_with("rump"):
		return &"rump"
	return &"back"


## Fold either vocabulary — the rig's (`RigBoneMap.region_for`) or this file's —
## onto one canonical set, so `TouchResponse` has exactly one table to key on.
static func region_name(raw: StringName) -> StringName:
	match raw:
		&"", &"none":
			return &""
		&"ears":
			return &"ear"
		&"paws":
			return &"paw"
		&"legs":
			return &"leg"
		&"scruff":
			return &"neck"
		&"throat":
			return &"chin"
		&"body":
			return &"back"
	return raw
