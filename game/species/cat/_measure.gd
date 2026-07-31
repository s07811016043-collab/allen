extends Node2D

## Proportion probe for the domestic cat.
##
## Written because the cat was rebuilt twice by eye and drifted both times: once
## too short, then — over-correcting — into a dachshund. Eyeballing a silhouette
## at review zoom cannot tell 1.9 from 2.6, so the ratios get printed instead.
##
## Reference animal, adult domestic shorthair, standing square:
##
##   withers height          24 cm      → the rig's 1.0 unit
##   nose to tail base       46 cm      → L/H ≈ 1.90
##   chest depth             11 cm      → 46% of H, so the elbow sits just under
##                                        the sternum and there is real daylight
##                                        between belly and floor
##   elbow (scapula bottom)  17 cm from the nose → 37% of L
##   fore paw to hind paw    22 cm      → 0.92 H; a cat stands nearly square, and
##                                        this is the number a dachshund fails
##   flank tuck              the belly line rises ~25% of chest depth from the
##                                        sternum back to the stifle
##
## The two derived numbers at the bottom are the ones that were actually wrong:
## `cantilever` is how much of the body hangs forward of the front paw with
## nothing under it, and `lumbar` is the unsupported run between the girdles.

const FORE_IDS := [&"leg_fl_upper", &"leg_fl_lower", &"paw_fl"]
const HIND_IDS := [&"leg_bl_upper", &"leg_bl_lower", &"leg_bl_hock", &"paw_bl"]
const TRUNK_IDS := [&"hip", &"torso", &"chest", &"belly", &"brisket"]

## Distal part of each limb, near then far. Neither far limb has a paw or a
## cannon of its own — each is two capsules and the second runs to the floor —
## so "where does this leg touch down" cannot be asked by part name alone.
const FEET := [&"paw_fl", &"leg_fl_far_lower", &"paw_bl", &"leg_bl_far_lower"]
const FEET_LABELS := ["FN", "FF", "HN", "HF"]

## The ratio the height field digs a groove at, and the ceiling found by capture
## on the dog: a thin capsule unioned along a fat one has its radius biased
## toward the fat one with a strength running on `(R_fat − R_thin)/(R_fat +
## R_thin)`, and past about 0.36 the bias carves a channel whose two walls light
## as the white streak and the black stipple the review reported on all four
## species. Printed per stage because `Growth` scales the two radii by different
## per-part curves and the ratio is not stage-invariant.
const RATIO_CEILING := 0.36

## Pixels per rig unit on the shipped 260 px frame. Measured, not assumed: the
## harness fits the settled pose to the frame, so an adult cat's 1.391 units of
## vertical extent land on 157 px. Every gap below is quoted in these as well as
## in rig units, because a 0.03 gap is a fix at one size and nothing at the other.
const SHIP_PX := 112.9

## Pixels of gap the coat closes before anything is drawn.
##
## The capsules are not the silhouette: the fur fringe stands outside them, and
## an alpha threshold across the shipped frame catches it. Calibrated by holding
## the geometry still and comparing this probe against a 260 px alpha capture at
## matching scanlines — a 0.038 gap between the shins measured as *zero* rendered
## pixels, and 0.082 measured as seven. So a pair separated by less than about
## 0.035 is not separated at all, and every gap below is worth roughly this much
## less on screen than it is here. Subtracted rather than left to the reader,
## because three rounds of leg staggering were signed off on the geometric number.
const COAT_PX := 3.6


func _ready() -> void:
	var spec: CreatureSpec = GameState.spec_for(&"cat")
	print("parts=%d/%d  palette=%d  ppu=%.0f" % [spec.parts.size(),
		CreatureRenderer.MAX_PARTS, spec.palette.size(), spec.pixels_per_unit])
	for g in [0.0, 1.0, 2.0, 3.0]:
		_report(spec, g)
	# Posed as well as authored: the bind pose can be perfect and the rig can
	# still stand the animal somewhere else, which is the failure mode the ground
	# probe caught last time.
	for anim in [&"idle", &"walk"]:
		var c := Creature.new()
		add_child(c)
		c.set_process(false)
		c.setup_preview(spec, 3.0, 0x5EED)
		if anim == &"walk":
			c.set_gait(&"walk")
		for _i in 400:
			c.tick(1.0 / 120.0)
		_report_posed(anim, c.renderer.live_parts)
		c.queue_free()
	get_tree().quit()


func _report(spec: CreatureSpec, g: float) -> void:
	var live: Array[SDFPart] = []
	for p in spec.parts:
		live.append(p.duplicate_part())
	Growth.apply(spec, live, g)
	var by := {}
	for p in live:
		by[p.id] = p

	var head_x := -INF
	var rump_x := INF
	var withers := 0.0
	var trunk_top := INF
	var trunk_bottom := -INF
	for p in live:
		var id := String(p.id)
		if id.begins_with("tail"):
			continue
		head_x = maxf(head_x, maxf(p.a.x + p.radius_a, p.b.x + p.radius_b))
		rump_x = minf(rump_x, minf(p.a.x - p.radius_a, p.b.x - p.radius_b))
		if p.id in TRUNK_IDS:
			trunk_top = minf(trunk_top, minf(p.a.y - p.radius_a, p.b.y - p.radius_b))
			trunk_bottom = maxf(trunk_bottom, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
	withers = -trunk_top

	var l: float = head_x - rump_x
	var fore_x: float = _paw_x(by, FEET[0])
	var hind_x: float = _paw_x(by, FEET[2])
	var blade: SDFPart = by.get(&"brisket", by.get(&"chest"))
	var blade_x: float = (blade.a.x + blade.b.x) * 0.5

	print("g=%.0f  H=%.3f L=%.3f  L/H=%.2f | chest_depth=%.0f%%H  stance=%.2fH" % [
		g, withers, l, l / withers,
		(trunk_bottom - trunk_top) / withers * 100.0, (fore_x - hind_x) / withers])
	print("       shoulder=%.0f%% of L from nose | cantilever=%.0f%% of L ahead of the fore paw"
		% [(head_x - blade_x) / l * 100.0, (head_x - fore_x) / l * 100.0])
	# Girdle to girdle: the shoulder joint to the hip joint, which is the run of
	# spine with nothing under it. ~0.80H on a cat, ~1.5H on a dachshund.
	var girdles: float = (by[FORE_IDS[0]].a.x - by[HIND_IDS[0]].a.x) / withers
	print("       girdles=%.2fH apart | far/near fore split=%.3f hind=%.3f" % [
		girdles,
		_paw_x(by, FEET[0]) - _paw_x(by, FEET[1]),
		_paw_x(by, FEET[2]) - _paw_x(by, FEET[3])])
	_report_gaps(live, withers)
	_report_front(live, withers)
	_report_belly(by)


## The belly capsule against the trunk it hangs from, at both of its ends. The
## number that has to stay under `RATIO_CEILING` at every stage.
func _report_belly(by: Dictionary) -> void:
	var belly: SDFPart = by.get(&"belly")
	if belly == null:
		return
	var line := "       belly ratio:"
	var worst := 0.0
	for end_a in [true, false]:
		var pt: Vector2 = belly.a if end_a else belly.b
		var thin: float = belly.radius_a if end_a else belly.radius_b
		# The trunk capsule directly above this end, found by sampling rather than
		# named, so the probe keeps working when the trunk is re-cut.
		var fat := 0.0
		for id in [&"hip", &"torso", &"chest"]:
			var t: SDFPart = by.get(id)
			if t == null:
				continue
			for i in 17:
				var u: float = float(i) / 16.0
				var c: Vector2 = t.a.lerp(t.b, u)
				if absf(c.x - pt.x) > 0.02:
					continue
				fat = maxf(fat, lerpf(t.radius_a, t.radius_b, u))
		if fat <= 0.0:
			continue
		var ratio: float = (fat - thin) / (fat + thin)
		worst = maxf(worst, ratio)
		line += "  %s r=%.3f vs trunk %.3f -> %.2f" % ["a" if end_a else "b", thin, fat, ratio]
	print("%s | %s" % [line, "OK" if worst <= RATIO_CEILING else "GROOVES"])


## Daylight inside each leg pair, which is the whole of review item 1.
##
## Split measured at the paw is not the question the eye asks — two legs can be
## 0.15 apart at the floor and still share one silhouette run all the way up, and
## a silhouette run is what the reviewer counts. So this walks the free length of
## the limb and reports the *narrowest* separation between the near group's
## trailing edge and the far group's leading edge at each height, which is the
## number that has to stay positive.
func _report_gaps(live: Array[SDFPart], withers: float) -> void:
	var near_fore: Array[SDFPart] = _group(live, ["leg_fl_lower", "paw_fl"])
	var far_fore: Array[SDFPart] = _group(live, ["leg_fl_far_lower"])
	var near_hind: Array[SDFPart] = _group(live, ["leg_bl_lower", "leg_bl_hock", "paw_bl"])
	var far_hind: Array[SDFPart] = _group(live, ["leg_bl_far_lower"])
	# The far fore sits behind the near fore and the far hind ahead of the near
	# hind, so each pair is asked the question that way round.
	_print_gap("fore", near_fore, far_fore, true, withers)
	_print_gap("hind", far_hind, near_hind, true, withers)


func _print_gap(label: String, front: Array[SDFPart], back: Array[SDFPart],
		_unused: bool, withers: float) -> void:
	var line := "       %s gap:" % label
	var worst := INF
	for i in 9:
		# From the floor up to 45% of withers height — above that the limbs
		# converge into the girdle and are *supposed* to share a run.
		var y: float = -withers * (0.05 + 0.05 * float(i))
		var f := _span_at(front, y)
		var b := _span_at(back, y)
		if not is_finite(f.x) or not is_finite(b.x):
			continue
		var gap: float = f.x - b.y  # front group's rear edge minus back group's front edge
		worst = minf(worst, gap)
		if i % 2 == 0:
			line += "  y%.2f=%+.3f" % [y, gap]
	print("%s | worst=%+.3f (%.1f px geometric, %.1f rendered)"
		% [line, worst, worst * SHIP_PX, worst * SHIP_PX - COAT_PX])


## Leading edge of the body from throat to elbow, which is review item 2. A cat
## is deepest at the chest; a column of identical numbers is the flat wall.
func _report_front(live: Array[SDFPart], withers: float) -> void:
	var trunk: Array[SDFPart] = _group(live,
		["brisket", "chest", "neck", "belly", "leg_fl_upper", "leg_fl_lower"])
	var line := "       front:"
	var lead := -INF
	var leg := -INF
	for i in 8:
		var y: float = -withers * (0.85 - 0.05 * float(i))
		var s := _span_at(trunk, y)
		if not is_finite(s.y):
			continue
		lead = maxf(lead, s.y)
		line += " %+.3f" % s.y
	var legs: Array[SDFPart] = _group(live, ["leg_fl_upper", "leg_fl_lower"])
	for i in 8:
		var s := _span_at(legs, -withers * (0.85 - 0.05 * float(i)))
		if is_finite(s.y):
			leg = maxf(leg, s.y)
	print("%s | chest leads the foreleg by %+.3f (%.1f px)" % [line, lead - leg,
		(lead - leg) * SHIP_PX])


func _group(live: Array[SDFPart], ids: Array) -> Array[SDFPart]:
	var out: Array[SDFPart] = []
	for p in live:
		if String(p.id) in ids:
			out.append(p)
	return out


## Horizontal span of a group of capsules on the scanline `y`, as (min_x, max_x).
## Sampled along each spine rather than solved, because a tapered capsule's
## outline is a pair of tangent lines and the closed form is not worth the risk
## of getting it subtly wrong in a probe whose whole job is to be trusted.
func _span_at(group: Array[SDFPart], y: float) -> Vector2:
	var lo := INF
	var hi := -INF
	for p in group:
		for i in 33:
			var t: float = float(i) / 32.0
			var c: Vector2 = p.a.lerp(p.b, t)
			var r: float = lerpf(p.radius_a, p.radius_b, t)
			var dy: float = absf(y - c.y)
			if dy > r:
				continue
			var half: float = sqrt(r * r - dy * dy)
			lo = minf(lo, c.x - half)
			hi = maxf(hi, c.x + half)
	return Vector2(lo, hi)


## Lowest posed point, per leg, so a rig-introduced float shows up per limb
## rather than as one body-wide number that a single planted paw can hide.
func _report_posed(anim: StringName, live: Array[SDFPart]) -> void:
	var line := "posed %s:" % anim
	for i in FEET.size():
		for p in live:
			if p.id == FEET[i]:
				line += "  %s y=%+.4f x=%+.3f" % [FEET_LABELS[i], maxf(p.a.y + p.radius_a,
					p.b.y + p.radius_b), p.b.x]
	print(line)


func _paw_x(by: Dictionary, id: StringName) -> float:
	var p: SDFPart = by.get(id)
	return 0.0 if p == null else (p.a.x + p.b.x) * 0.5
