extends Node2D
func _ready() -> void:
	for g in [0.0, 1.0, 2.0, 3.0]:
		var spec: CreatureSpec = GameState.spec_for(&"cat")
		var live: Array[SDFPart] = []
		for p in spec.parts:
			live.append(p.duplicate_part())
		Growth.apply(spec, live, g)
		var lowest := -1e9
		var top := 1e9
		var back := 1e9
		var front := -1e9
		for p in live:
			lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
			top = minf(top, minf(p.a.y - p.radius_a, p.b.y - p.radius_b))
			back = minf(back, minf(p.a.x - p.radius_a, p.b.x - p.radius_b))
			front = maxf(front, maxf(p.a.x + p.radius_a, p.b.x + p.radius_b))
		print("growth=%.1f  lowest_y=%+.4f  height=%.3f  length=%.3f  L/H=%.2f"
			% [g, lowest, lowest - top, front - back, (front - back) / maxf(lowest - top, 1e-3)])
	get_tree().quit()
