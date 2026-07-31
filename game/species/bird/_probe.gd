extends Node2D

## Temporary proportion probe for the bird. Deleted before hand-off.
##
## Two jobs. It prints the proportions per growth stage so they can be checked
## against the reference figures in `bird_spec.gd`, and it reports the *effective*
## `px_per_unit` a capture will actually shade with.
##
## The second one is not obvious and it matters more. `CreatureRenderer` hands the
## shader `spec.pixels_per_unit * view_scale`, and the capture harness sets that
## view scale by fitting the posed animal to the frame — so a 560 px shot of a
## small species shades at roughly twice the species' nominal density. Every coat
## level-of-detail gate keys off that number, `pet_feather`'s barb fade included,
## so tuning `coat_density` against the nominal 158 gives an answer that is out by
## a factor of two and a bird whose vanes are either invisible on the desktop or a
## fingerprint in review.

const CELL_INSET := 8.0
const POSE_MARGIN := 0.05


func _ready() -> void:
	var spec: CreatureSpec = GameState.spec_for(&"bird")
	print("parts=%d palette=%d  ppu_nominal=%.0f  coat_density=%.2f"
		% [spec.parts.size(), spec.palette.size(), spec.pixels_per_unit, spec.coat_density])

	for g in [0.0, 1.0, 2.0, 3.0]:
		var c := Creature.new()
		add_child(c)
		c.set_process(false)
		c.setup_preview(spec, g, 0x5EED)
		for i in 240:
			c.tick(1.0 / 120.0)

		# Same bound the capture harness fits to: capsule radius plus the blend,
		# because the smooth union pushes the surface out past the capsule.
		var mn := Vector2(INF, INF)
		var mx := Vector2(-INF, -INF)
		var lowest := -1e9
		for p in c.renderer.live_parts:
			var r: float = maxf(p.radius_a, p.radius_b) + p.blend
			mn = mn.min((p.a - Vector2(r, r)).min(p.b - Vector2(r, r)))
			mx = mx.max((p.a + Vector2(r, r)).max(p.b + Vector2(r, r)))
			lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
		mn -= Vector2(POSE_MARGIN, POSE_MARGIN)
		mx += Vector2(POSE_MARGIN, POSE_MARGIN)
		mn.y = minf(mn.y, 0.0)
		mx.y = maxf(mx.y, 0.0)
		var extent: Vector2 = mx - mn

		var h: float = -mn.y
		var l: float = extent.x
		print("growth=%.0f  H=%.3f  L=%.3f  L/H=%.2f  lowest_y=%+.4f  front=%+.3f rear=%+.3f"
			% [g, h, l, l / h, lowest, mx.x, mn.x])

		for size in [300.0, 560.0, 900.0]:
			var box: float = size - CELL_INSET * 2.0
			var fit: float = minf(box / (extent.x * spec.pixels_per_unit),
				box / (extent.y * spec.pixels_per_unit))
			var ppu: float = spec.pixels_per_unit * fit
			var pitch: float = 150.0 * spec.coat_density
			var gate: float = smoothstep(1.8, 4.2, ppu / pitch)
			var plate: float = 0.030 / spec.coat_density
			print("    shot %4.0fpx  fit=%.2f  ppu_eff=%6.1f  px/barb=%.2f  barb_gate=%.2f  scale_plate_px=%.1f"
				% [size, fit, ppu, ppu / pitch, gate, plate * ppu])
		c.queue_free()
	get_tree().quit()
