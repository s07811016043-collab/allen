extends Node2D

## Proportion probe for the bearded dragon.
##
## The one number this file exists to print is L/H. A domestic cat is 1.75; a
## Pogona standing on all fours is about 6.7 with the tail held straight, and
## anything under about 4 stops reading as a lizard and starts reading as a
## dachshund. The second number that matters is the ventral clearance: the
## sprawl only reads if the elbow can clear the flank, and the elbow can only
## clear the flank if there is air under the belly.

func _ready() -> void:
	var spec: CreatureSpec = GameState.spec_for(&"reptile")
	print("parts=%d/28  palette=%d  ppu=%.0f" % [spec.parts.size(), spec.palette.size(),
		spec.pixels_per_unit])
	for g in [0.0, 1.0, 2.0, 3.0]:
		var live: Array[SDFPart] = []
		for p in spec.parts:
			live.append(p.duplicate_part())
		Growth.apply(spec, live, g)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var lowest := -1e9
		# Lowest point of the trunk: the belly clearance the limbs have to live in.
		var gut := -1e9
		for p in live:
			lo = lo.min(p.a - Vector2(p.radius_a, p.radius_a)).min(p.b - Vector2(p.radius_b, p.radius_b))
			hi = hi.max(p.a + Vector2(p.radius_a, p.radius_a)).max(p.b + Vector2(p.radius_b, p.radius_b))
			lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
			if String(p.id) in ["hip", "torso", "chest", "belly"]:
				gut = maxf(gut, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
		var h: float = -lo.y
		var l: float = hi.x - lo.x
		print("growth=%.0f  H=%.3f  L=%.3f  L/H=%.2f  clearance=%.3f (%.0f%% of H)  lowest_y=%+.4f  snout=%+.3f tail=%+.3f  px=%.0fx%.0f"
			% [g, h, l, l / h, -gut, -gut / h * 100.0, lowest, hi.x, lo.x,
				l * spec.pixels_per_unit * spec.scale_at(g) / spec.scale_at(3.0),
				h * spec.pixels_per_unit * spec.scale_at(g) / spec.scale_at(3.0)])
		for id in [&"head", &"chin", &"leg_fore_near_lower", &"leg_hind_near_lower", &"tail_2"]:
			for p in live:
				if p.id == id:
					print("    %-22s a=(%+.3f,%+.3f) r=%.3f  b=(%+.3f,%+.3f) r=%.3f"
						% [id, p.a.x, p.a.y, p.radius_a, p.b.x, p.b.y, p.radius_b])
	get_tree().quit()
