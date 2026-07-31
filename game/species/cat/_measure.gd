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
const HIND_IDS := [&"leg_bl_upper", &"leg_bl_lower", &"paw_bl"]
const TRUNK_IDS := [&"hip", &"torso", &"chest", &"belly", &"scapula"]


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
	var fore_x: float = _paw_x(by, FORE_IDS[2])
	var hind_x: float = _paw_x(by, HIND_IDS[2])
	var scapula: SDFPart = by.get(&"scapula", by.get(&"chest"))
	var scapula_x: float = (scapula.a.x + scapula.b.x) * 0.5

	print("g=%.0f  H=%.3f L=%.3f  L/H=%.2f | chest_depth=%.0f%%H  stance=%.2fH" % [
		g, withers, l, l / withers,
		(trunk_bottom - trunk_top) / withers * 100.0, (fore_x - hind_x) / withers])
	print("       scapula=%.0f%% of L from nose | cantilever=%.0f%% of L ahead of the fore paw"
		% [(head_x - scapula_x) / l * 100.0, (head_x - fore_x) / l * 100.0])
	# Girdle to girdle: the shoulder joint to the hip joint, which is the run of
	# spine with nothing under it. ~0.80H on a cat, ~1.5H on a dachshund.
	var girdles: float = (by[FORE_IDS[0]].a.x - by[HIND_IDS[0]].a.x) / withers
	print("       girdles=%.2fH apart | far/near fore split=%.3f hind=%.3f" % [
		girdles,
		_paw_x(by, &"paw_fl") - _paw_x(by, &"paw_fl_far"),
		_paw_x(by, &"paw_bl") - _paw_x(by, &"paw_bl_far")])


## Lowest posed point, per leg, so a rig-introduced float shows up per limb
## rather than as one body-wide number that a single planted paw can hide.
func _report_posed(anim: StringName, live: Array[SDFPart]) -> void:
	var line := "posed %s:" % anim
	for id in [&"paw_fl", &"paw_fl_far", &"paw_bl", &"paw_bl_far"]:
		for p in live:
			if p.id == id:
				line += "  %s y=%+.4f x=%+.3f" % [id, maxf(p.a.y + p.radius_a,
					p.b.y + p.radius_b), p.b.x]
	print(line)


func _paw_x(by: Dictionary, id: StringName) -> float:
	var p: SDFPart = by.get(id)
	return 0.0 if p == null else (p.a.x + p.b.x) * 0.5
