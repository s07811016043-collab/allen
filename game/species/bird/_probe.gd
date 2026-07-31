extends Node2D

## Temporary proportion probe for the bird. Deleted before hand-off.

func _ready() -> void:
	var spec: CreatureSpec = GameState.spec_for(&"bird")
	print("parts=%d palette=%d" % [spec.parts.size(), spec.palette.size()])
	for g in [0.0, 1.0, 2.0, 3.0]:
		var live: Array[SDFPart] = []
		for p in spec.parts:
			live.append(p.duplicate_part())
		Growth.apply(spec, live, g)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		var lowest := -1e9
		for p in live:
			var r: float = maxf(p.radius_a, p.radius_b)
			lo = lo.min(p.a - Vector2(p.radius_a, p.radius_a)).min(p.b - Vector2(p.radius_b, p.radius_b))
			hi = hi.max(p.a + Vector2(p.radius_a, p.radius_a)).max(p.b + Vector2(p.radius_b, p.radius_b))
			lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
		var h: float = -lo.y
		var l: float = hi.x - lo.x
		print("growth=%.0f  H=%.3f  L=%.3f  L/H=%.2f  lowest_y=%+.4f  front=%+.3f rear=%+.3f"
			% [g, h, l, l / h, lowest, hi.x, lo.x])
		# Landmarks, in the grown frame.
		for id in [&"head", &"beak_upper", &"leg_hind_near_cannon", &"tail_2", &"belly"]:
			for p in live:
				if p.id == id:
					print("    %-24s a=(%+.3f,%+.3f) r=%.3f  b=(%+.3f,%+.3f) r=%.3f"
						% [id, p.a.x, p.a.y, p.radius_a, p.b.x, p.b.y, p.radius_b])
	get_tree().quit()
