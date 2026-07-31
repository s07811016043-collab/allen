extends Node2D

## Measures the numbers behind the *render* pass, the way `_ground_probe.gd`
## measures the numbers behind the rig.
##
## Three questions this round, all of which a picture can only make you guess at:
##
##   1. Does every paw actually reach `ContactShadow` in the *standing* pose? The
##      capability was written last round and the standing capture still shows one
##      ellipse, so the interesting number is how many patches get a non-zero
##      opacity, not how they look.
##   2. Where does each limb enter the body? That is what the belly occlusion and
##      the shoulder whorl both have to be anchored to, and it is uploaded by
##      `CreatureRenderer`, so it can be read straight off the packed uniform.
##   3. Which species run the mammal marking code at all. `marking_strength` was
##      never set, so a bird was wearing a tabby.

const ContactShadowScript := preload("res://core/render/contact_shadow.gd")
const RigBones := preload("res://core/rig/bone_map.gd")


func _ready() -> void:
	for id in [&"cat", &"dog", &"bird", &"reptile"]:
		_probe(id)
	get_tree().quit()


func _probe(id: StringName) -> void:
	var c := Creature.new()
	add_child(c)
	c.set_process(false)
	c.setup_preview(GameState.spec_for(id), 3.0, 0x5EED)
	# The same settle the capture harness uses, so the numbers describe the frame
	# a reviewer is looking at rather than the bind pose.
	for i in 400:
		c.tick(1.0 / 120.0)
	c.renderer._process(0.0)

	print("=== %s ===" % id)
	print("  coat_surface=%d marking_strength=%s"
		% [int(c.spec.coat_surface),
			str(c.renderer._mat.get_shader_parameter("marking_strength"))])

	var shadow: ContactShadow = ContactShadowScript.make_for(c)
	add_child(shadow)
	shadow._refresh()
	var planted := 0
	for i in ContactShadow.MAX_PAWS:
		var q: Vector4 = shadow._mat.get_shader_parameter("paw_%d" % i)
		if q.w > 0.0:
			planted += 1
		print("  paw_%d x=%+.3f r=%.3f opacity=%.3f" % [i, q.x, q.z, q.w])
	print("  paw_parts=%d patches_lit=%d" % [shadow._paw_parts.size(), planted])
	if shadow._paw_parts.is_empty():
		var seen: Array[String] = []
		for p in c.renderer.live_parts:
			var tag = RigBones.classify(p.id, int(p.layer))
			if tag.slot == RigBones.Slot.LIMB:
				seen.append("%s(seg=%d)" % [p.id, tag.seg])
		print("  limb parts seen: %s" % ", ".join(seen))

	for i in c.renderer._landmark_count:
		var lm: Vector4 = c.renderer._packed_landmarks[i]
		var lr: Vector4 = c.renderer._packed_limb_roots[i]
		print("  landmark %d crest=(%+.3f,%+.3f) r=%.3f | root=(%+.3f,%+.3f) r=%.3f"
			% [i, lm.x, lm.y, lm.z, lr.x, lr.y, lr.z])

	shadow.queue_free()
	c.queue_free()
