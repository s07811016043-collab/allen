extends Node2D

## Measures secondary motion as numbers instead of as a vibe.
##
## Every claim in the animation review — "the torso is furniture being carried",
## "the tail does not lag", "the idle is frozen" — is a statement about an
## amplitude, and amplitudes are cheap to measure and impossible to argue with.
## The capture harness's `--probe` prints one instant; this walks a whole cycle
## and reduces it to peak-to-peak travel, phase lag and frame-to-frame change.
##
## Everything is reported twice: in rig units, and in pixels at the size the pet
## actually ships at. A 0.01-unit wobble is a fine number and an invisible one,
## and only the second column can tell the difference.

const RigBones := preload("res://core/rig/bone_map.gd")
const STEP := 1.0 / 120.0
## Pixels per rig unit at ship size. The pet stands about 160 px tall on a
## desktop, and 1.0 rig unit is adult shoulder height, so this is the conversion
## that decides whether a term is animation or rounding.
const SHIP_PPU := 160.0
## Warm-up before any measurement, seconds. Springs settle, the bob follower
## reaches steady state, and the crouch has faded in — measure before that and
## the transient dwarfs the signal.
const WARMUP := 4.0


class Track:
	var lo := INF
	var hi := -INF
	var samples := PackedFloat32Array()

	func add(v: float) -> void:
		lo = minf(lo, v)
		hi = maxf(hi, v)
		samples.append(v)

	func span() -> float:
		return (hi - lo) if is_finite(lo) else 0.0

	func mean() -> float:
		var m := 0.0
		for v in samples:
			m += v
		return m / maxf(float(samples.size()), 1.0)

	## Zero-mean copy, so a lag correlation measures shape rather than offset.
	func centred() -> PackedFloat32Array:
		var m := 0.0
		for v in samples:
			m += v
		m /= maxf(float(samples.size()), 1.0)
		var out := PackedFloat32Array()
		for v in samples:
			out.append(v - m)
		return out


func _ready() -> void:
	_check_wing_fit()
	for anim in [&"walk", &"trot", &"run"]:
		_measure_gait(anim)
	_measure_stop()
	_measure_idle()
	get_tree().quit()


## `Slot.WING` parts used to be fitted once per girdle, and `limb_base` puts no
## girdle in a wing's bone name, so every wing bone was added twice. No shipping
## spec exercises the path — the bird works around it by naming its wings so they
## classify as spine — so the fix is proved against a synthetic spec instead of
## against a species that has already been bent around the bug.
func _check_wing_fit() -> void:
	var spec := CreatureSpec.new()
	var parts: Array[SDFPart] = []
	parts.append(_part(&"torso", Vector2(-0.3, -0.6), Vector2(0.3, -0.6), 1))
	parts.append(_part(&"head", Vector2(0.45, -0.75), Vector2(0.6, -0.78), 1))
	# One wing per side, two segments each, near in front of the body and far behind.
	for far in [false, true]:
		var layer: int = 0 if far else 2
		var side := "far" if far else "near"
		parts.append(_part(StringName("wing_%s_upper" % side),
			Vector2(0.2, -0.65), Vector2(-0.05, -0.6), layer))
		parts.append(_part(StringName("wing_%s_primary" % side),
			Vector2(-0.05, -0.6), Vector2(-0.35, -0.5), layer))
	var sk := RigSkeleton.build(spec, parts, [])
	var seen := {}
	var dupes: Array[String] = []
	var wings := 0
	for b in sk.bones:
		var n := String(b.name)
		if seen.has(n):
			dupes.append(n)
		seen[n] = true
		if n.begins_with("wing_"):
			wings += 1
	# Every wing part must be skinned to a bone that lookup-by-name also finds,
	# which is exactly what the duplicate broke.
	var orphans := 0
	for pb in sk.part_binds:
		var n := String(sk.bones[pb.bone_a].name)
		if n.begins_with("wing_") and sk.index_of(sk.bones[pb.bone_a].name) != pb.bone_a:
			orphans += 1
	print("== wing fit ==")
	print("   %d wing bones, %d duplicate names %s, %d parts bound to a shadow bone"
		% [wings, dupes.size(), dupes, orphans])


func _part(id: StringName, a: Vector2, b: Vector2, layer: int) -> SDFPart:
	var p := SDFPart.new()
	p.id = id
	p.a = a
	p.b = b
	p.radius_a = 0.09
	p.radius_b = 0.07
	p.layer = layer
	return p


func _spawn(growth: float = 3.0) -> Creature:
	var c := Creature.new()
	add_child(c)
	c.set_process(false)
	c.setup_preview(GameState.spec_for(&"cat"), growth, 0x5EED)
	return c


## One gait, sampled over two full cycles at the simulation step.
func _measure_gait(anim: StringName) -> void:
	var c := _spawn()
	c.set_gait(anim)
	for i in int(WARMUP / STEP):
		c.tick(STEP)
	var g: Gait = c.rig.gait
	var sk: RigSkeleton = c.rig.skeleton
	var cycles := 2.0
	var dur: float = cycles / maxf(g.frequency, 0.5)
	var n := int(dur / STEP)

	var bob := Track.new()
	var pitch := Track.new()
	var twist := Track.new()
	var flex := Track.new()
	var withers := Track.new()
	var head := Track.new()
	var chest := Track.new()
	var pelvis := Track.new()
	var diff := Track.new()      ## chest − pelvis height: the pitch made visible
	var nose := Track.new()
	## The head stabiliser's own output. Tracked because "the neck cancels the
	## ripple" is a claim about a number that either shows up on the skull or does
	## not, and derivation has been wrong about it before.
	var fix := Track.new()
	## Sag of the mid-back below the straight line from croup to withers. This is
	## the number that separates a torso that changes shape from one that only
	## translates and tilts — both of which leave every point on the topline in the
	## same place relative to every other, which is the definition of furniture.
	var arc := Track.new()
	## Where the skull would be if the neck did nothing. The stabiliser's whole
	## claim is the gap between this and `head`, and a ratio against the chest
	## cannot report it — cut the lever the trunk swings the head through and the
	## chest's own travel falls too, so that ratio gets *worse* while the head gets
	## better. Measure the correction against what it is correcting.
	var head_raw := Track.new()
	var tail_x := Track.new()
	var tail_y := Track.new()
	var hip_ang := Track.new()
	var tail_ang := Track.new()
	var tail_path := 0.0
	var prev_tail := Vector2.INF

	var tail_tip := RigBones.chain_tip("tail", RigBones.SIDE_NONE)
	var muzzle := RigBones.MUZZLE
	for i in n:
		c.tick(STEP)
		bob.add(g.bob)
		pitch.add(g.pitch)
		twist.add(g.girdle_twist)
		flex.add(g.flex)
		withers.add(g.withers)
		var h := sk.bone_position(RigBones.HEAD)
		var ch := sk.bone_position(RigBones.CHEST)
		var pv := sk.bone_position(RigBones.PELVIS)
		head.add(h.y)
		chest.add(ch.y)
		pelvis.add(pv.y)
		diff.add(ch.y - pv.y)
		nose.add(sk.bone_position(muzzle).y)
		fix.add(c.rig.head_fix())
		head_raw.add(h.y - c.rig.head_fix())
		arc.add(sk.bone_position(RigBones.spine_bone(1)).y - pv.lerp(ch, 0.5).y)
		var t := sk.bone_position(tail_tip)
		tail_x.add(t.x)
		tail_y.add(t.y)
		if prev_tail != Vector2.INF:
			tail_path += prev_tail.distance_to(t)
		prev_tail = t
		var pi_ := sk.index_of(RigBones.PELVIS)
		var ti := sk.index_of(tail_tip)
		hip_ang.add(sk.bones[pi_].xform.get_rotation() if pi_ >= 0 else 0.0)
		tail_ang.add((t - sk.bone_position(RigBones.chain_bone("tail",
			RigBones.SIDE_NONE, 0))).angle() if ti >= 0 else 0.0)

	print("== %s  freq=%.2f Hz  cycle=%.2f s ==" % [anim, g.frequency, 1.0 / maxf(g.frequency, 0.01)])
	_row("bob", bob)
	_row_rad("pitch", pitch)
	_row_rad("twist", twist)
	_row_rad("flex", flex)
	_row("withers", withers)
	_row("back_arc", arc)
	_row("chest_y", chest)
	_row("pelvis_y", pelvis)
	_row("chest-pelvis", diff)
	_row("head_y", head)
	_row("nose_y", nose)
	_row("head_fix", fix)
	_row("tail_tip_x", tail_x)
	_row("tail_tip_y", tail_y)
	print("   tail_path/cycle %7.4f u  %6.1f px" % [tail_path / cycles, tail_path / cycles * SHIP_PPU])
	# The head-stabilisation ratio is the whole point of a neck. Below 1 means the
	# skull travels less than the shoulders under it; at or above 1 the animal is
	# one rigid piece from hip to nose, which is the "carried furniture" read.
	_row("head_raw", head_raw)
	print("   head_y mean %+.5f   fix mean %+.5f" % [head.mean(), fix.mean()])
	print("   head travel %.1f px  (want < 8 at a walk)   stabilised to %.0f%% of raw"
		% [head.span() * SHIP_PPU, 100.0 * head.span() / maxf(head_raw.span(), 1e-6)])
	print("   tail lag %+.0f ms  (want ~ +120)" % (_lag_ms(hip_ang, tail_ang, g.frequency) * 1000.0))
	c.queue_free()


## Peak-to-peak of a length channel, in rig units and in ship pixels.
func _row(name: String, t: Track) -> void:
	print("   %-14s %7.4f u  %6.1f px" % [name, t.span(), t.span() * SHIP_PPU])


## Peak-to-peak of an angle channel. Degrees, plus the arc a point one third of a
## body length from the joint sweeps — an angle alone cannot say whether it is
## visible and the arc can.
func _row_rad(name: String, t: Track) -> void:
	print("   %-14s %7.4f rad  %5.2f deg  %5.1f px @0.35u" % [
		name, t.span(), rad_to_deg(t.span()), t.span() * 0.35 * SHIP_PPU])


## Lag of `b` behind `a`, in seconds, by peak cross-correlation over up to half a
## cycle. Positive means `b` happens later, which is what a trailing tail does.
func _lag_ms(a: Track, b: Track, freq: float) -> float:
	var ca := a.centred()
	var cb := b.centred()
	var max_shift := int(0.5 / maxf(freq, 0.5) / STEP)
	var best := 0
	var best_score := -INF
	for s in range(0, max_shift):
		var acc := 0.0
		for i in range(0, ca.size() - s):
			acc += ca[i] * cb[i + s]
		if acc > best_score:
			best_score = acc
			best = s
	return float(best) * STEP


## Braking from a trot to a standstill.
##
## The one event that can prove a tail has mass. At a constant speed everything
## in the rig is periodic and a lagging tail is indistinguishable from a stiff one
## that happens to be pointing somewhere; only a deceleration asks the question,
## because only then does the body stop and the tail have to decide whether to
## stop with it. Reported as how far the tip keeps travelling *after* the hips are
## already still, and how far past its own final resting place it swings.
func _measure_stop() -> void:
	var c := _spawn()
	c.set_gait(&"trot")
	for i in int(WARMUP / STEP):
		c.tick(STEP)
	var sk: RigSkeleton = c.rig.skeleton
	var tip := RigBones.chain_tip("tail", RigBones.SIDE_NONE)
	c.set_gait(&"idle")
	# Where everything ends up, so "overshoot" has something to be past.
	var probe_at := PackedFloat32Array([0.15, 0.3, 0.5, 0.8, 1.2])
	var hip_path := 0.0
	var tail_path := 0.0
	var prev_hip := sk.bone_position(RigBones.PELVIS)
	var prev_tail := sk.bone_position(tip)
	var t := 0.0
	var k := 0
	print("== stop (trot to standstill) ==")
	while t < 1.2:
		c.tick(STEP)
		t += STEP
		var hip := sk.bone_position(RigBones.PELVIS)
		var tl := sk.bone_position(tip)
		hip_path += prev_hip.distance_to(hip)
		tail_path += prev_tail.distance_to(tl)
		prev_hip = hip
		prev_tail = tl
		if k < probe_at.size() and t >= probe_at[k]:
			print("   +%.2fs  hips have moved %6.3f u   tail tip %6.3f u   ratio %.1fx"
				% [t, hip_path, tail_path, tail_path / maxf(hip_path, 1e-4)])
			k += 1
	# Settle out, then ask how far past the resting pose the tip had swung.
	var during := prev_tail
	for i in int(3.0 / STEP):
		c.tick(STEP)
	print("   tail tip is %.3f u from where it settled, 1.2 s after the stop"
		% during.distance_to(sk.bone_position(tip)))
	c.queue_free()


## Idle liveness. The failure mode the review named was two frames two seconds
## apart being pose-identical, so measure exactly that: the largest distance any
## rendered capsule endpoint has moved between one sample and the next.
func _measure_idle() -> void:
	var c := _spawn()
	c.set_gait(&"idle")
	for i in int(WARMUP / STEP):
		c.tick(STEP)
	print("== idle ==")
	# Whole-body maxima hide the failure this is looking for. An ear flick or a
	# tail sway alone will carry the max while the trunk sits frozen, and a frozen
	# trunk under a twitching ear reads worse than no animation at all, because the
	# contrast points straight at the seam. So the trunk is measured on its own.
	var sk: RigSkeleton = c.rig.skeleton
	var chest := Track.new()
	var pelvis := Track.new()
	var head := Track.new()
	var arc := Track.new()
	for i in int(20.0 / STEP):
		c.tick(STEP)
		var ch := sk.bone_position(RigBones.CHEST)
		var pv := sk.bone_position(RigBones.PELVIS)
		chest.add(ch.y)
		pelvis.add(pv.y)
		head.add(sk.bone_position(RigBones.HEAD).y)
		arc.add(sk.bone_position(RigBones.spine_bone(1)).y - pv.lerp(ch, 0.5).y)
	print("   over 20 s of standing still:")
	_row("chest_y", chest)
	_row("pelvis_y", pelvis)
	_row("head_y", head)
	_row("back_arc", arc)

	var prev := _snapshot(c)
	var worst := INF
	for k in 8:
		for i in int(2.0 / STEP):
			c.tick(STEP)
		var now := _snapshot(c)
		var d := 0.0
		for i in mini(prev.size(), now.size()):
			d = maxf(d, prev[i].distance_to(now[i]))
		worst = minf(worst, d)
		print("   +%ds  max part travel %7.4f u  %6.1f px" % [(k + 1) * 2, d, d * SHIP_PPU])
		prev = now
	print("   quietest 2 s window: %.4f u  %.1f px  (want > 3 px)" % [worst, worst * SHIP_PPU])
	c.queue_free()


func _snapshot(c: Creature) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for p in c.renderer.live_parts:
		out.append(p.a)
		out.append(p.b)
	return out
