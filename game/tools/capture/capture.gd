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

var species := &"cat"
var growth := 3.0
var out_path := "user://shot.png"
var settle_frames := 8
var bg := "checker"
var zoom := 1.0
var draw_contact := true
var pose := &"idle"
var focus := ""

var _frames := 0
var _done := false
var _renderer: CreatureRenderer
var _spec: CreatureSpec


func _ready() -> void:
	_parse_args()
	_build_backdrop()
	_build_creature()
	Log.info("Capture", "shot species=%s growth=%.2f -> %s" % [species, growth, out_path])


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

	_renderer = CreatureRenderer.new()
	add_child(_renderer)
	_renderer.setup(_spec)
	Growth.apply(_spec, _renderer.live_parts, growth)
	_renderer.set_shading_state(growth, 0.0, 1.0, 0.0)

	var vp := get_viewport_rect().size
	# Frame the creature: its feet sit on the lower third, and it fills roughly
	# 70% of the frame height regardless of life stage, so a baby and an adult
	# are judged at comparable pixel counts.
	var target_h: float = vp.y * 0.62
	var natural_h: float = _spec.adult_height * _spec.scale_at(growth) * _spec.pixels_per_unit
	var fit: float = (target_h / maxf(natural_h, 1.0)) * zoom
	_renderer.scale = Vector2(fit, fit)
	_renderer.position = Vector2(vp.x * 0.5, vp.y * 0.80)

	# A focus point re-frames the shot around a rig-space location, so a
	# reviewer can ask for a head close-up without recomputing the transform by
	# hand. Zoomed shots are how face detail actually gets judged.
	if focus != "":
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
		_renderer.position = Vector2(vp.x * 0.5, vp.y * 0.5) - target * _spec.pixels_per_unit * fit

	if draw_contact and focus == "":
		var shadow := _make_contact_shadow()
		add_child(shadow)
		move_child(shadow, 1)
		shadow.position = _renderer.position
		shadow.scale = Vector2(fit, fit)


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
