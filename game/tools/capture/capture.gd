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
##   --anim=<name>       walk | trot | run | hop | idle | startle. Drives the rig
##                       at the speed that gait is actually meant for, so foot
##                       planting in the shot is the real thing.
##   --t=<seconds>       advance the rig deterministically to this time before
##                       capturing. With --strip it is the start of the sheet.
##   --strip=<n>         contact sheet: n evenly spaced frames of one gait cycle
##                       side by side, with a scrolling ground ruler and a stance
##                       chart per frame. This is how motion gets judged from a
##                       still: a planted foot must stay on the same ruler tick
##                       across every frame it is down.
##
## Motion is advanced at a fixed step from a settled rig, never from wall time,
## so two runs of the same command are pixel-identical.

## Rig step used to advance to `--t`. Matches `CreatureRig.STEP`, so each call
## consumes exactly one simulation step and nothing is ever interpolated.
const TICK := 1.0 / 120.0
## Cycles of warm-up before a contact sheet starts, so springs are in steady
## state and the sheet shows the gait rather than the settle.
const WARMUP_CYCLES := 2.0
## Ground ruler spacing in rig units. A planted foot must not move between ticks.
const RULER_STEP := 0.1

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

	var vp := get_viewport_rect().size
	var count: int = maxi(strip, 1)
	var natural_h: float = _spec.adult_height * _spec.scale_at(growth) * _spec.pixels_per_unit
	var cells := _layout(count, vp, natural_h)
	var fit: float = _cell_fit(cells[0].size, natural_h) * zoom

	var times := _frame_times()
	for i in count:
		var c := Creature.new()
		add_child(c)
		# Driven by hand below; automatic processing would make the shot depend
		# on how many frames the renderer happened to take to warm up.
		c.set_process(false)
		c.setup_preview(_spec, growth, 0x5EED)
		c.scale = Vector2(fit, fit)
		var cell: Rect2 = cells[i]
		var origin := Vector2(cell.position.x + cell.size.x * 0.5,
			cell.position.y + cell.size.y * (0.80 if strip > 0 else 0.80))
		_drive(c, times[i])
		c.position = origin
		if focus != "":
			c.position = cell.position + cell.size * 0.5 \
				- _focus_point() * _spec.pixels_per_unit * fit
		_cells.append(c)

		if draw_contact and focus == "":
			var shadow := _make_contact_shadow()
			add_child(shadow)
			move_child(shadow, 1)
			shadow.position = origin
			shadow.scale = Vector2(fit, fit)

	if strip > 0:
		_overlay = _StripOverlay.new()
		(_overlay as _StripOverlay).setup(_cells, times, cells, fit, _spec)
		add_child(_overlay)


## Scale that fits one creature into a cell. The height budget is the usual
## constraint, but a walking quadruped is about twice as long as it is tall, so
## on a contact sheet the width budget frequently wins.
func _cell_fit(cell: Vector2, natural_h: float) -> float:
	var by_h: float = (cell.y * (0.56 if strip > 0 else 0.62)) / maxf(natural_h, 1.0)
	# A standing cat is about twice as long as it is tall, so fitting by height
	# alone runs the rump and tail off the side of the frame. Measure the actual
	# body length rather than assuming an aspect ratio: species differ, and a
	# reviewer looking at a cropped animal reports the crop, not the animal.
	var span: float = _body_span() * _spec.pixels_per_unit
	var by_w: float = (cell.x * (0.88 if strip > 0 else 0.92)) / maxf(span, 1.0)
	return minf(by_h, by_w)


## Widest horizontal extent of the bind pose, in rig units.
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
func _layout(count: int, vp: Vector2, natural_h: float) -> Array[Rect2]:
	var best_cols := count
	var best_fit := -1.0
	for cols in range(1, count + 1):
		var rows: int = int(ceil(float(count) / float(cols)))
		var f := _cell_fit(Vector2(vp.x / float(cols), vp.y / float(rows)), natural_h)
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
	var begin: float = start_t if start_t >= 0.0 else cycle * WARMUP_CYCLES
	for i in count:
		out.append(begin + cycle * float(i) / float(count))
	return out


func _cycle_seconds() -> float:
	# Reactions and idles have no stride, so they get a fixed window chosen to
	# show the whole event: a startle resolves in about a second.
	match anim:
		&"startle": return 1.2
		&"", &"idle": return 4.0
	var probe := Gait.new()
	probe.setup(_spec, [])
	var v := _speed_for(anim)
	var f := probe.frequency_for(v)
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
	if anim != &"" and anim != &"startle":
		c.set_gait(anim)
	elif anim == &"startle":
		c.set_gait(&"idle")
		c.play_reaction(&"startle", 1.0)
	if pose == &"look" :
		c.look_at_point(c.position + Vector2(240.0, -80.0))
	var steps: int = clampi(int(round(maxf(t, 0.0) / TICK)), 0, 6000)
	for _i in steps:
		c.tick(TICK)


## Soft elliptical contact shadow with a penumbra that tightens near the paws.
## Grounding is the single cheapest way to stop a 2D character looking pasted on.
func _make_contact_shadow() -> Node2D:
	var holder := Node2D.new()
	var rect := ColorRect.new()
	var w: float = _spec.adult_height * _spec.pixels_per_unit * 1.6
	rect.size = Vector2(w, w * 0.34)
	rect.position = Vector2(-w * 0.5, -w * 0.13)
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

	func setup(p_cells: Array[Creature], p_times: PackedFloat32Array,
			p_rects: Array[Rect2], p_fit: float, p_spec: CreatureSpec) -> void:
		cells = p_cells
		times = p_times
		rects = p_rects
		fit = p_fit
		spec = p_spec
		z_index = 50

	func _draw() -> void:
		var font := ThemeDB.fallback_font
		for i in cells.size():
			var c: Creature = cells[i]
			var r: Rect2 = rects[i]
			var ground_y: float = r.position.y + r.size.y * 0.80
			var mid: float = r.position.x + r.size.x * 0.5
			draw_rect(r, Color(1, 1, 1, 0.09), false, 1.0)

			# Ground line plus a ruler fixed to the *ground*, not to the frame:
			# tick n always marks the same patch of floor, so a planted foot sits
			# over the same tick in every frame it is down and any drift is a
			# slide. Every fifth tick is drawn long as a counting aid.
			draw_line(Vector2(r.position.x + 4.0, ground_y),
				Vector2(r.end.x - 4.0, ground_y), Color(1, 1, 1, 0.26), 1.0)
			var gait: Gait = c.rig.gait
			var px: float = spec.pixels_per_unit * fit
			var span: float = r.size.x * 0.5 / maxf(px, 1e-3)
			var first: int = int(floor((gait.travel - span) / RULER_STEP))
			for n in range(first, first + int(2.0 * span / RULER_STEP) + 2):
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
				if not f.stance:
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
