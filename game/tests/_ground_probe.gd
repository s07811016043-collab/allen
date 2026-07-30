extends Node2D

## Measures where the *posed* creature's lowest point ends up.
##
## The bind pose is grounded by construction, so any gap between the paws and
## y = 0 after the rig runs is introduced by the rig, and that gap is exactly
## what makes the pet look like it is hovering over its own shadow.

func _ready() -> void:
	for anim in [&"idle", &"walk"]:
		for g in [0.0, 3.0]:
			var c := Creature.new()
			add_child(c)
			c.set_process(false)
			c.setup_preview(GameState.spec_for(&"cat"), g, 0x5EED)
			if anim == &"walk":
				c.set_gait(&"walk")
			for i in 400:
				c.tick(1.0 / 120.0)
			var lowest := -1e9
			for p in c.renderer.live_parts:
				lowest = maxf(lowest, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
			print("anim=%s growth=%.0f lowest_y=%+.4f  (0 = paws on ground; negative = floating)"
				% [anim, g, lowest])
			c.queue_free()
	get_tree().quit()
