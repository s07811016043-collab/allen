extends Node2D

## Deterministic screenshot harness.
##
## The visual-review agents need to look at the game, not at the code, and they
## need the exact same frame every run so a diff means a real change. This scene
## renders one requested shot to a PNG and exits.
##
##   godot --path game res://tools/capture/capture.tscn --rendering-driver opengl3 \
##       --resolution 720x720 -- --species=cat --growth=0 --out=/tmp/kitten.png
##
## Flags (all after the bare `--`):
##   --species=<id>      cat | dog | bird | reptile
##   --growth=<0..3>     life stage, continuous
##   --out=<path>        absolute PNG path
##   --frames=<n>        frames to settle before capturing (default 8)
##   --bg=<hex|alpha>    backdrop: `alpha`, `checker`, or an RRGGBB colour
##   --zoom=<f>          extra scale on top of the spec's pixels_per_unit
##   --contact=<0|1>     draw the contact shadow and ground plane
##   --pose=<name>       named pose from the rig, when one is available
##   --focus=<x,y>       rig-space point to centre in frame, e.g. `0.40,-0.78`
##                       for a head close-up. Combine with --zoom.
##   --focus=head        shorthand: centres on the first eye
##   --anim=<name>       walk | trot | run | hop | idle | startle | stop. Drives
##                       the rig at the speed that gait is actually meant for, so
##                       foot planting in the shot is the real thing. `stop` trots
##                       and then brakes to a standstill part-way through, which is
##                       the only way to see whether the tail lags the hips and
##                       overshoots — at a constant speed nothing decelerates and
##                       the question cannot be asked.
##   --t=<seconds>       advance the rig deterministically to this time before
##                       capturing. With --strip it is the start of the sheet.
##   --strip=<n>         contact sheet: n evenly spaced frames of one gait cycle
##                       side by side, with a scrolling ground ruler and a stance
##                       chart per frame. This is how motion gets judged from a
##                       still: a planted foot must stay on the same ruler tick
##                       across every frame it is down.
##   --window=<seconds>  span the strip covers, instead of one gait cycle. The
##                       events worth inspecting are not all stride-length: a
##                       blink is 180 ms and is invisible on a sheet that steps
##                       half a second at a time.
##   --probe=<0|1>       also print the numbers behind the picture. A sheet shows
##                       *that* a foot slides or a paw hovers; at review zoom two
##                       pixels and twenty look the same, and a fix has to move a
##                       number rather than a vibe.
##
## Motion is advanced at a fixed step from a settled rig, never from wall time,
## so two runs of the same command are pixel-identical.

const RigBones := preload("res://core/rig/bone_map.gd")

## Rig step used to advance to `--t`. Matches `CreatureRig.STEP`, so each call
## consumes exactly one simulation step and nothing is ever interpolated.
const TICK := 1.0 / 120.0
## Cycles of warm-up before a contact sheet starts, so springs are in steady
## state and the sheet shows the gait rather than the settle.
const WARMUP_CYCLES := 2.0
## Ground ruler spacing in rig units. A planted foot must not move between ticks.
const RULER_STEP := 0.1
## When `--anim=stop` cuts the drive. Fixed rather than a fraction of the window,
## so every cell of a sheet brakes at the same instant and the frames line up as
## one continuous event.
const STOP_AT := 0.5

## Rig-space padding added around the measured pose before fitting. Coat fringe
## and rim light live just outside the capsule surface, and a silhouette that
## ends exactly on the frame edge reads as a crop even when nothing was cut.
const POSE_MARGIN := 0.05
## Frame furniture reserved inside every cell. On a contact sheet the top holds
## two header lines, the bottom holds the stance chart, and the ruler ticks hang
## below the ground line; the animal is fitted into what is left, so a raised
## tail can never end up behind the caption.
const CELL_INSET := 8.0
const STRIP_PAD_TOP := 44.0
const STRIP_PAD_BOTTOM := 30.0
const RULER_DEPTH := 16.0

var species := &"cat"
var growth := 3.0
var out_path := "user://shot.png"
var settle_frames := 8
var bg := "checker"
var zoom := 1.0
var draw_contact := true
var pose := &"idle"
var focus := ""
var anim := &""
var start_t := -1.0
var strip := 0
var window := -1.0
var probe := false

var _frames := 0
var _done := false
var _spec: CreatureSpec
var _cells: Array[Creature] = []
var _overlay: Node2D


func _ready() -> void:
	_parse_args()
	_build_backdrop()
	_build_creature()
	Log.info("Capture", "shot species=%s growth=%.2f anim=%s strip=%d -> %s"
		% [species, growth, anim, strip, out_path])


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"species": species = StringName(kv[1])
			"growth": growth = float(kv[1])
			"out": out_path = kv[1]
			"frames": settle_frames = int(kv[1])
			"bg": bg = kv[1]
			"zoom": zoom = float(kv[1])
			"contact": draw_contact = kv[1] != "0"
			"pose": pose = StringName(kv[1])
			"focus": focus = kv[1]
			"anim": anim = StringName(kv[1])
			"t": start_t = float(kv[1])
			"strip": strip = int(kv[1])
			"window": window = float(kv[1])
			"probe": probe = kv[1] != "0"


func _build_backdrop() -> void:
	if bg == "alpha":
		RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))
		return
	# The project renders with a transparent background for the desktop overlay;
	# captures need an opaque frame so a reviewer sees the composite, not a
	# checkerboard supplied by their image viewer.
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.12, 0.13, 0.15, 1.0))
	var rect := ColorRect.new()
	# Anchors do nothing under a Node2D parent, so size the backdrop explicitly.
	rect.position = Vector2.ZERO
	rect.size = get_viewport_rect().size
	rect.z_index = -100
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if bg == "checker":
		# A neutral mid-grey checker is the honest backdrop for judging a
		# silhouette: it exposes both halo on light ground and hard edges on
		# dark, which a flat colour hides.
		var sh := Shader.new()
		sh.code = """
shader_type canvas_item;
render_mode unshaded;
uniform float cell = 32.0;
void fragment() {
	vec2 g = floor(FRAGCOORD.xy / cell);
	float c = mod(g.x + g.y, 2.0);
	vec3 a = vec3(0.30, 0.31, 0.33);
	vec3 b = vec3(0.38, 0.39, 0.41);
	// A soft vertical gradient stands in for a desktop wallpaper so the
	// creature is never judged against a perfectly uniform field.
	vec3 col = mix(a, b, c) * mix(1.15, 0.80, UV.y);
	COLOR = vec4(col, 1.0);
}
"""
		var m := ShaderMaterial.new()
		m.shader = sh
		rect.material = m
		rect.color = Color.WHITE
	else:
		rect.color = Color.html(bg if bg.begins_with("#") else "#" + bg)
	add_child(rect)
	move_child(rect, 0)


func _build_creature() -> void:
	_spec = GameState.spec_for(species)
	if _spec == null:
		Log.error("Capture", "unknown species '%s'" % species)
		get_tree().quit(2)
		return

	var count: int = maxi(strip, 1)
	var times := _frame_times()
	# Every cell is built and driven *before* anything is measured or placed. The
	# frame can only be fitted honestly to the pose the rig actually settles
	# into: the tail spring hangs well outside the bind pose, a swing foot
	# reaches past the paws, and across a contact sheet the union of all that is
	# wider still.
	for i in count:
		var c := Creature.new()
		add_child(c)
		# Driven by hand below; automatic processing would make the shot depend
		# on how many frames the renderer happened to take to warm up.
		c.set_process(false)
		c.setup_preview(_spec, growth, 0x5EED)
		_drive(c, times[i])
		if probe:
			_probe_cell(i, c, times[i])
		_cells.append(c)

	var vp := get_viewport_rect().size
	var extent := _posed_extent()
	var cells := _layout(count, vp, extent)
	var fit: float = _cell_fit(cells[0], extent) * zoom

	for i in count:
		var c: Creature = _cells[i]
		c.scale = Vector2(fit, fit)
		var origin := _cell_origin(cells[i], extent, fit)
		c.position = origin
		if focus != "":
			c.position = cells[i].position + cells[i].size * 0.5 \
				- _focus_point() * _spec.pixels_per_unit * fit
			# Every cell of a close-up sheet still draws the whole animal, just
			# framed elsewhere, so without a clip cell 3's rump lands across cell
			# 2's face. Give each one its own window onto the creature.
			if strip > 0:
				var clip := _CellClip.new()
				clip.rect = cells[i]
				remove_child(c)
				clip.add_child(c)
				add_child(clip)
		elif draw_contact:
			var shadow := _make_contact_shadow()
			add_child(shadow)
			# Behind every creature by depth rather than by sibling index: with
			# `--bg=alpha` there is no backdrop node to sit in front of, and an
			# index-based insert would then bury one cell's creature.
			shadow.z_index = -1
			shadow.position = origin
			shadow.scale = Vector2(fit, fit)

	if strip > 0:
		_overlay = _StripOverlay.new()
		(_overlay as _StripOverlay).setup(_cells, times, cells, fit, _spec, focus == "")
		add_child(_overlay)


## Bounding box of every cell's posed geometry, in rig units, y down.
##
## Measured off the live parts after `_drive`, never off the bind pose. A tail
## that has settled 0.3 units wider than it was authored is exactly the thing
## that used to run off the side of a review shot, and a reviewer who sees a
## cropped animal reports the crop instead of the animal.
func _posed_extent() -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for c in _cells:
		for p in c.renderer.live_parts:
			# The smooth-union blend pushes the surface out past the capsule, so
			# it is part of the silhouette and has to be part of the bound.
			var r: float = maxf(p.radius_a, p.radius_b) + p.blend
			mn = mn.min((p.a - Vector2(r, r)).min(p.b - Vector2(r, r)))
			mx = mx.max((p.a + Vector2(r, r)).max(p.b + Vector2(r, r)))
	if not is_finite(mn.x):
		return Rect2(-0.5, -1.0, 1.0, 1.0)
	mn -= Vector2(POSE_MARGIN, POSE_MARGIN)
	mx += Vector2(POSE_MARGIN, POSE_MARGIN)
	# The ground plane is y = 0 by convention and the contact shadow spreads out
	# below it, so the frame has to hold both even when no part reaches there.
	mn.y = minf(mn.y, 0.0)
	mx.y = maxf(mx.y, 0.0)
	if draw_contact and focus == "":
		mx.y = maxf(mx.y, _shadow_depth())
	return Rect2(mn, mx - mn)


## How far the contact shadow reaches below the ground line, in rig units. Sized
## from `_make_contact_shadow`, which centres its ellipse at UV y = 0.62.
func _shadow_depth() -> float:
	return _body_span() * 1.05 * 0.34 * 0.38


## The part of a cell the animal may occupy, once frame furniture is subtracted.
func _content_rect(cell: Rect2) -> Rect2:
	var top: float = STRIP_PAD_TOP if strip > 0 else CELL_INSET
	var bottom: float = STRIP_PAD_BOTTOM if strip > 0 else CELL_INSET
	return Rect2(cell.position + Vector2(CELL_INSET, top),
		cell.size - Vector2(CELL_INSET * 2.0, top + bottom))


## Scale that fits the measured pose into a cell. A walking quadruped is about
## twice as long as it is tall, so the width budget usually wins — but a raised
## tail can flip that, which is why both are measured rather than assumed.
func _cell_fit(cell: Rect2, extent: Rect2) -> float:
	if focus != "":
		# A `--focus` shot is a deliberate crop, so it keeps the older bind-pose
		# rule unchanged: close-ups stay comparable between captures instead of
		# rescaling every time the tail settles somewhere new.
		var natural_h: float = _spec.adult_height * _spec.scale_at(growth) * _spec.pixels_per_unit
		var by_h: float = (cell.size.y * (0.56 if strip > 0 else 0.62)) / maxf(natural_h, 1.0)
		var by_w: float = (cell.size.x * (0.84 if strip > 0 else 0.88)) \
			/ maxf(_body_span() * _spec.pixels_per_unit, 1.0)
		return minf(by_h, by_w)
	var box := _content_rect(cell)
	var ppu: float = _spec.pixels_per_unit
	var ruler: float = RULER_DEPTH if strip > 0 else 0.0
	var by_w: float = box.size.x / maxf(extent.size.x * ppu, 1.0)
	var by_h: float = maxf(box.size.y - ruler, 1.0) / maxf(extent.size.y * ppu, 1.0)
	return maxf(minf(by_w, by_h), 0.01)


## Where this cell's rig origin lands on screen — which is also where the ground
## line and the ruler are drawn, since the origin sits on the ground plane.
func _cell_origin(cell: Rect2, extent: Rect2, fit: float) -> Vector2:
	var box := _content_rect(cell)
	var ppu: float = _spec.pixels_per_unit * fit
	var above: float = -extent.position.y * ppu
	var below: float = extent.end.y * ppu + (RULER_DEPTH if strip > 0 else 0.0)
	# Centre the measured content in whatever is left over, then place the origin
	# inside it. Centring the *content* rather than the origin is the whole fix:
	# a cat's origin sits between its paws, nowhere near the middle of a body
	# that runs from tail tip to nose.
	return Vector2(
		box.position.x + (box.size.x - extent.size.x * ppu) * 0.5 - extent.position.x * ppu,
		box.position.y + (box.size.y - above - below) * 0.5 + above)


## Widest horizontal extent of the bind pose, in rig units. Used to size the
## contact shadow, which should track the body's footprint and stay the same in
## every cell of a sheet rather than swelling with a raised tail.
func _body_span() -> float:
	var lo := INF
	var hi := -INF
	var live: Array[SDFPart] = []
	for p in _spec.parts:
		live.append(p.duplicate_part())
	Growth.apply(_spec, live, growth)
	for p in live:
		lo = minf(lo, minf(p.a.x - p.radius_a, p.b.x - p.radius_b))
		hi = maxf(hi, maxf(p.a.x + p.radius_a, p.b.x + p.radius_b))
	return maxf(hi - lo, 0.1) if is_finite(lo) else 1.0


## Choose the grid that makes the creature largest. A single long row wastes
## most of the frame on empty sky; picking the column count by measuring is
## simpler than guessing an aspect ratio and always beats it.
func _layout(count: int, vp: Vector2, extent: Rect2) -> Array[Rect2]:
	var best_cols := count
	var best_fit := -1.0
	for cols in range(1, count + 1):
		var rows: int = int(ceil(float(count) / float(cols)))
		var f := _cell_fit(Rect2(Vector2.ZERO,
			Vector2(vp.x / float(cols), vp.y / float(rows))), extent)
		if f > best_fit:
			best_fit = f
			best_cols = cols
	var rows: int = int(ceil(float(count) / float(best_cols)))
	var size := Vector2(vp.x / float(best_cols), vp.y / float(rows))
	var out: Array[Rect2] = []
	for i in count:
		out.append(Rect2(Vector2(float(i % best_cols) * size.x,
			float(i / best_cols) * size.y), size))
	return out


func _focus_point() -> Vector2:
	var target := Vector2.ZERO
	if focus == "head":
		if not _spec.eyes.is_empty():
			target = _spec.eyes[_spec.eyes.size() - 1].center
		else:
			target = Vector2(0.4, -0.75)
		target *= _spec.scale_at(growth)
	else:
		var xy := focus.split(",")
		if xy.size() == 2:
			target = Vector2(float(xy[0]), float(xy[1]))
	return target


## Times to advance each cell to. A contact sheet samples exactly one cycle so
## the first and last frames are the same instant of the gait — if they do not
## match, the cycle does not close and the animation will pop.
func _frame_times() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var count: int = maxi(strip, 1)
	if strip <= 0:
		out.append(maxf(start_t, 0.0) if start_t >= 0.0 else (0.0 if anim == &"" else 1.0))
		return out
	var cycle := _cycle_seconds()
	var begin: float = start_t
	if begin < 0.0:
		# Warming up only means anything for motion that repeats. A reaction is a
		# one-shot, and two "cycles" of settling put the sheet two and a half
		# seconds past the startle it exists to show — six identical frames of a
		# cat standing still, which is exactly what it produced.
		begin = 0.0 if anim in [&"startle", &"stop"] else cycle * WARMUP_CYCLES
	for i in count:
		out.append(begin + cycle * float(i) / float(count))
	return out


func _cycle_seconds() -> float:
	if window > 0.0:
		return window
	# Reactions and idles have no stride, so they get a fixed window chosen to
	# show the whole event: a startle resolves in about a second.
	match anim:
		&"startle": return 1.2
		# Long enough to cover the approach, the brake and the settle after it.
		&"stop": return 1.5
		&"", &"idle": return 4.0
	var g := Gait.new()
	g.setup(_spec, [], _spec.scale_at(growth))
	var v := _speed_for(anim)
	var f := g.frequency_for(v)
	return 1.0 / maxf(f, 0.2)


func _speed_for(a: StringName) -> float:
	match a:
		&"walk": return _spec.walk_speed
		&"trot": return lerpf(_spec.walk_speed, _spec.run_speed, 0.42)
		&"run": return _spec.run_speed
		&"hop": return lerpf(_spec.walk_speed, _spec.run_speed, 0.55)
	return 0.0


## Advance one creature's rig to `t` at a fixed step, then re-centre it. The rig
## plants feet against distance travelled, so the body staying put while the
## ground scrolls under it is exactly the walking-on-a-treadmill view a reviewer
## wants: a planted foot slides backwards at precisely the body's speed.
func _drive(c: Creature, t: float) -> void:
	match anim:
		&"startle":
			c.set_gait(&"idle")
			c.play_reaction(&"startle", 1.0)
		&"stop":
			c.set_gait(&"trot")
		&"":
			pass
		_:
			c.set_gait(anim)
	if pose == &"look" :
		c.look_at_point(c.position + Vector2(240.0, -80.0))
	var steps: int = clampi(int(round(maxf(t, 0.0) / TICK)), 0, 6000)
	var brake_step: int = int(round(STOP_AT / TICK)) if anim == &"stop" else -1
	for i in steps:
		if i == brake_step:
			c.set_gait(&"idle")
		c.tick(TICK)


## Print one cell's measurements, in rig units so readings are comparable across
## species and growth stages.
##
## Three numbers carry most of the weight. `floor` is the bottom of the
## silhouette: 0 means the animal is standing on the ground plane, negative means
## it hovers. `sink` is the same question asked of one paw's contact patch. `slip`
## is the distance that patch has drifted, in *ground* space, from the spot the
## gait pinned it to — the definition of a skate, and the one thing a reviewer
## cannot measure by eye.
func _probe_cell(index: int, c: Creature, t: float) -> void:
	var floor_y := -INF
	for p in c.renderer.live_parts:
		floor_y = maxf(floor_y, maxf(p.a.y + p.radius_a, p.b.y + p.radius_b))
	var sk: RigSkeleton = c.rig.skeleton
	var g: Gait = c.rig.gait
	var tail: Vector2 = sk.bone_position(RigBones.chain_tip("tail", RigBones.SIDE_NONE))
	var idle: IdleRig = c.rig.idle
	# Head *and* chest, because "does the head ride the bob" is a question about the
	# gap between them. The head alone cannot answer it: breathing lifts the whole
	# front of the animal, and a head faithfully riding a breath looks identical in
	# one number to a head welded to the stride.
	var line := ("PROBE %d t=%.3f cyc=%.3f bob=%+.4f floor=%+.4f head=%+.4f chest=%+.4f"
		+ " tail=%+.3f,%+.3f"
		+ " breath=%+.3f blink=%.2f gaze=%+.2f,%+.2f ear=%+.3f shift=%+.4f,%+.4f") \
		% [index, t, g.cycle, g.bob, floor_y,
			sk.bone_position(RigBones.HEAD).y, sk.bone_position(RigBones.CHEST).y,
			tail.x, tail.y,
			idle.breath_swell(), idle.blink, idle.gaze.x, idle.gaze.y, idle.ear_near,
			idle.weight_shift.x, idle.weight_shift.y]
	for s in mini(g.feet.size(), c.rig.legs.size()):
		var f: Gait.Foot = g.feet[s]
		var ch: LegIK.Chain = c.rig.legs[s]
		if not f.present or not ch.valid:
			continue
		# The contact patch is rigidly attached to the toe bone, so ask that bone
		# where it ended up rather than re-deriving it from the target the gait
		# asked for. The gap between the two is precisely what a slide is.
		var ti := sk.index_of(RigBones.limb_bone(ch.fore, ch.far, false, -1))
		var contact := Vector2.INF
		if ti >= 0:
			var tb: RigSkeleton.Bone = sk.bones[ti]
			contact = tb.xform * (tb.rest_inv * Vector2(ch.contact_bind.x, 0.0))
		var ik: float = sk.bones[ch.ankle_bone].xform.origin.distance_to(f.target)
		line += "  %s%s ik=%.4f sink=%+.4f" % [
			["FN", "FF", "HN", "HF"][s], "*" if f.stance else ".", ik, contact.y]
		if f.stance:
			line += " slip=%+.4f" % (contact.x + g.travel - f.plant_ground)
	print(line)


## Soft elliptical contact shadow with a penumbra that tightens near the paws.
## Grounding is the single cheapest way to stop a 2D character looking pasted on.
func _make_contact_shadow() -> Node2D:
	var holder := Node2D.new()
	var rect := ColorRect.new()
	# Sized to the animal actually in frame, not to a guess: a long cat casts a
	# long shadow, and a kitten a small one.
	var w: float = _body_span() * _spec.pixels_per_unit * 1.05
	rect.size = Vector2(w, w * 0.34)
	# The ellipse inside the shader is centred at UV y = 0.62, so the rect has to
	# be offset by exactly that fraction of its own height for the shadow to land
	# on the ground line rather than below it. Getting this wrong is what made
	# the pet look like it was hovering over its own shadow.
	rect.position = Vector2(-w * 0.5, -rect.size.y * 0.62)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode blend_mix, unshaded;
uniform float softness : hint_range(0.05, 1.0) = 0.55;
uniform float strength : hint_range(0.0, 1.0) = 0.55;
void fragment() {
	vec2 q = (UV - vec2(0.5, 0.62)) * vec2(2.0, 3.1);
	float d = length(q);
	// Two stacked falloffs: a tight dark core where the body meets the ground,
	// and a wide soft ambient occlusion halo around it.
	float core = smoothstep(0.55, 0.05, d);
	float halo = smoothstep(1.15, 0.15, d);
	float a = (core * 0.72 + halo * 0.35) * strength;
	COLOR = vec4(vec3(0.03, 0.03, 0.05), clamp(a, 0.0, 1.0));
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	rect.material = m
	rect.color = Color.WHITE
	holder.add_child(rect)
	return holder


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < settle_frames or _done:
		return
	# `await` yields, so _process runs again before the capture completes unless
	# we latch first.
	_done = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	if err != OK:
		Log.error("Capture", "save_png failed: %s" % error_string(err))
		get_tree().quit(3)
		return
	print("CAPTURE_OK %s %dx%d" % [out_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


## A window onto one cell of a close-up sheet. Draws its own rectangle and clips
## its child to it; `CLIP_CHILDREN_ONLY` means the rectangle itself never shows.
class _CellClip:
	extends Node2D

	var rect := Rect2()

	func _ready() -> void:
		clip_children = CanvasItem.CLIP_CHILDREN_ONLY

	func _draw() -> void:
		draw_rect(rect, Color.WHITE, true)


## Contact-sheet furniture: cell dividers, a ground ruler that scrolls with the
## distance travelled, and a stance chart per frame.
##
## The ruler is the load-bearing part. Each cell's ticks are offset by that
## frame's travel, so a foot that is genuinely planted sits on the same tick in
## every frame it is down. Any drift between the paw and the tick is a slide,
## and slides are invisible in a normal side-by-side but obvious here.
class _StripOverlay:
	extends Node2D

	const LABELS := ["FN", "FF", "HN", "HF"]
	## One hue per foot, shared between the stance chart and the plant markers so
	## a marker on the ground can be traced back to the leg that owns it.
	const FOOT_COLORS := [
		Color(0.42, 0.86, 1.00, 0.90),  # fore near
		Color(0.30, 0.52, 0.90, 0.75),  # fore far
		Color(1.00, 0.78, 0.32, 0.90),  # hind near
		Color(0.86, 0.46, 0.24, 0.75),  # hind far
	]

	var cells: Array[Creature] = []
	var times := PackedFloat32Array()
	var rects: Array[Rect2] = []
	var fit := 1.0
	var spec: CreatureSpec
	## A close-up is framed on a body part, so the ground plane is off-frame and
	## every piece of ground furniture would be a lie. Caption those cells and
	## draw nothing else.
	var grounded := true

	func setup(p_cells: Array[Creature], p_times: PackedFloat32Array,
			p_rects: Array[Rect2], p_fit: float, p_spec: CreatureSpec,
			p_grounded: bool) -> void:
		cells = p_cells
		times = p_times
		rects = p_rects
		fit = p_fit
		spec = p_spec
		grounded = p_grounded
		z_index = 50

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		for i in cells.size():
			var c: Creature = cells[i]
			var r: Rect2 = rects[i]
			if not grounded:
				draw_rect(r, Color(1, 1, 1, 0.09), false, 1.0)
				draw_string(font, r.position + Vector2(8.0, 18.0),
					"%d  t=%.3fs" % [i, times[i]],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.78))
				continue
			# The creature's own origin *is* the ground plane in rig space, so the
			# furniture reads it off the node rather than re-deriving the layout.
			# Any disagreement between the two would show up as a permanent fake
			# slide on every foot in the sheet.
			var ground_y: float = c.position.y
			var mid: float = c.position.x
			draw_rect(r, Color(1, 1, 1, 0.09), false, 1.0)

			# Ground line plus a ruler fixed to the *ground*, not to the frame:
			# tick n always marks the same patch of floor, so a planted foot sits
			# over the same tick in every frame it is down and any drift is a
			# slide. Every fifth tick is drawn long as a counting aid.
			draw_line(Vector2(r.position.x + 4.0, ground_y),
				Vector2(r.end.x - 4.0, ground_y), Color(1, 1, 1, 0.26), 1.0)
			var gait: Gait = c.rig.gait
			var px: float = spec.pixels_per_unit * fit
			var left: float = gait.travel + (r.position.x - mid) / maxf(px, 1e-3)
			var right: float = gait.travel + (r.end.x - mid) / maxf(px, 1e-3)
			var first: int = int(floor(left / RULER_STEP))
			for n in range(first, int(ceil(right / RULER_STEP)) + 1):
				var tx: float = mid + (float(n) * RULER_STEP - gait.travel) * px
				if tx <= r.position.x + 3.0 or tx >= r.end.x - 3.0:
					continue
				var tall: bool = n % 5 == 0
				draw_line(Vector2(tx, ground_y), Vector2(tx, ground_y + (13.0 if tall else 6.0)),
					Color(1, 1, 1, 0.45 if tall else 0.24), 1.0)

			# Plant markers: where each supporting foot is pinned in ground space,
			# and a cross on the ankle the IK actually solved to. The paw above a
			# marker must not move relative to it, and the cross must sit on the
			# marker — the two together separate a gait bug from a geometry one.
			for s in 4:
				var f: Gait.Foot = gait.feet[s]
				if not f.present:
					continue
				var col: Color = FOOT_COLORS[s]
				var chain: LegIK.Chain = c.rig.legs[s]
				if chain.valid:
					var ankle: Vector2 = c.position + c.rig.skeleton.bones[chain.ankle_bone].xform.origin * px
					draw_line(ankle - Vector2(5, 0), ankle + Vector2(5, 0), col, 1.0)
					draw_line(ankle - Vector2(0, 5), ankle + Vector2(0, 5), col, 1.0)
				# `plant_ground` is only meaningful while a gait is running. At idle it
				# holds wherever the foot last landed, which on a `stop` sheet drew
				# markers metres from the paws standing over them and read as a slide
				# that is not happening.
				if not f.stance or gait.frequency <= 0.0:
					continue
				var fx: float = mid + (f.plant_ground - gait.travel) * px
				draw_line(Vector2(fx, ground_y - 8.0), Vector2(fx, ground_y + 8.0), col, 1.5)
				draw_circle(Vector2(fx, ground_y), 2.5, col)

			# Stance chart: a filled dot means that foot is carrying weight.
			for s in 4:
				var f: Gait.Foot = gait.feet[s]
				var dot := Vector2(r.position.x + 16.0 + float(s) * 26.0, r.end.y - 16.0)
				if not f.present:
					draw_arc(dot, 4.0, 0.0, TAU, 12, Color(1, 1, 1, 0.15), 1.0)
				elif f.stance:
					draw_circle(dot, 6.0, FOOT_COLORS[s])
				else:
					draw_arc(dot, 6.0, 0.0, TAU, 16, Color(1, 1, 1, 0.35), 1.2)
				draw_string(font, dot + Vector2(-8.0, -10.0), LABELS[s],
					HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 1, 1, 0.6))

			draw_string(font, r.position + Vector2(8.0, 18.0),
				"%d  t=%.2fs  %s" % [i, times[i], gait.pattern_name()],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.78))
			draw_string(font, r.position + Vector2(8.0, 34.0),
				"phase %.2f  bob %+.3f  pitch %+.2f" % [gait.cycle, gait.bob, gait.pitch],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.48))
