extends Node2D

## Deterministic contact sheet for the VFX layer.
##
## Rendering one frame of a particle system tells you almost nothing, so this
## scene fires every effect on a schedule computed backwards from the capture:
## each cell has a hand-picked age, the effect is played at `capture - age`, and
## the shot lands on the moment worth judging. `--age=` scales all of them at
## once, which is how you sweep an effect's whole life across four captures.
##
##   godot --path game res://vfx/vfx_preview.tscn --rendering-driver opengl3 \
##       --resolution 1400x1180 --fixed-fps 60 -- --mode=grid --out=/abs/path.png
##
## Modes:
##   grid    every effect in a labelled cell, on a procedural fur patch where
##           the effect needs a surface to act on
##   glyphs  the emotion set at 24, 40 and 72 px, which is the readability test
##   pet     the real creature with the director driving touch and ambience,
##           which is the only honest test of the displacement and of the
##           lighting handshake
##
## `--fixed-fps 60` matters: without it the schedule below is at the mercy of
## however long llvmpipe took to rasterise the previous frame.

const FPS := 60.0
## When the shot is taken. Long enough for the looping ambient effects to have
## reached a steady state.
const CAPTURE_T := 3.2

## One cell of the grid: a label, an effect script, its parameters, and the age
## at which that effect is worth looking at.
class Cell:
	var label: String = ""
	var script_path: String = ""
	var cfg: Dictionary = {}
	var age: float = 0.35
	## Fraction of the cell to push the effect from its centre, so ground
	## effects sit on a floor and head effects sit high.
	var anchor := Vector2(0.5, 0.5)
	## Draw a fur patch behind the effect.
	var surface: bool = false
	var effect: VfxEffect = null
	var fired: bool = false

	static func make(label_: String, path: String, cfg_: Dictionary, age_: float,
			anchor_y: float = 0.5, surface_: bool = false,
			anchor_x: float = 0.5) -> Cell:
		var c := Cell.new()
		c.label = label_
		c.script_path = path
		c.cfg = cfg_
		c.age = age_
		c.anchor = Vector2(anchor_x, anchor_y)
		c.surface = surface_
		return c

const FUR_SHADER := """
shader_type canvas_item;
render_mode unshaded;
// A stand-in animal surface. Not the real coat model — that lives in a
// directory this layer does not own — but it carries the three properties the
// touch effects have to be judged against: strands that run along a groom
// direction, per-strand brightness variation, and a silhouette that breaks up
// into hair rather than ending on a curve. Displacing a flat colour proves
// nothing; displacing this shows whether the ripple reads as fur.
uniform vec4 base_col : source_color = vec4(0.36, 0.27, 0.21, 1.0);
uniform vec4 tip_col : source_color = vec4(0.82, 0.68, 0.50, 1.0);
uniform vec2 key = vec2(-0.55, -0.83);
uniform float groom = -0.30;
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5); }
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float c = cos(groom); float s = sin(groom);
	vec2 r = mat2(vec2(c, -s), vec2(s, c)) * p;
	// Lanes across the groom direction; one strand per lane. Kept coarse
	// enough that the strand mask is several pixels wide — a one-pixel comb
	// aliases into moire and stops being a fair test of a displacement.
	float lane = r.y * 19.0;
	float id = floor(lane);
	float rnd = h(vec2(id, 3.7));
	float rnd2 = h(vec2(id, 11.3));
	// Strands wander along their length, so the coat is not a comb.
	float wob = sin(r.x * 4.0 + rnd * 6.28318) * 0.20;
	float across = lane - id - 0.5 + wob;
	float w = 0.34 + 0.14 * rnd2;
	float aa = max(fwidth(across), 1e-4);
	float strand = 1.0 - smoothstep(w - aa * 1.5, w + aa * 1.5, abs(across));
	// Roots dark, tips bright — the whole reason fur has depth.
	float depth = mix(0.55, 1.0, strand) * mix(0.72, 1.18, rnd);
	float lit = 0.55 + 0.45 * dot(normalize(p + vec2(1e-4)), -normalize(key));
	vec3 col = mix(base_col.rgb, tip_col.rgb, strand * mix(0.5, 1.0, rnd));
	col *= depth * mix(0.66, 1.15, lit);
	float body = length(p * vec2(1.0, 1.22));
	float fringe = 0.84 + rnd * 0.13 + strand * 0.05;
	float a = 1.0 - smoothstep(fringe - 0.05, fringe + 0.03, body);
	COLOR = vec4(col, a);
}
"""

var out_path := "user://vfx_preview.png"
var mode := "grid"
var age_scale := 1.0
var hour := 17.0
var tier := 2
var cols := 5
var cell := Vector2(280.0, 280.0)

var _director: VfxDirector
var _cells: Array[Cell] = []
var _frame := 0
var _done := false
var _renderer: Node = null


func _ready() -> void:
	_parse_args()
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.12, 0.13, 0.15, 1.0))
	_backdrop()

	_director = VfxDirector.new()
	add_child(_director)
	_director.light.force_hour = hour
	# Cold enough for breath to condense, so the ambient cell has something to
	# show. The shipping game drives this from weather.
	_director.light.chill = 0.7

	match mode:
		"glyphs": _build_glyphs()
		"pet": _build_pet()
		_: _build_grid()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"out": out_path = kv[1]
			"mode": mode = kv[1]
			"age": age_scale = float(kv[1])
			"hour": hour = float(kv[1])
			"tier": tier = int(kv[1])


func _backdrop() -> void:
	var rect := ColorRect.new()
	rect.position = Vector2.ZERO
	rect.size = get_viewport_rect().size
	rect.z_index = -100
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
render_mode unshaded;
uniform float cell = 40.0;
void fragment() {
	vec2 g = floor(FRAGCOORD.xy / cell);
	float c = mod(g.x + g.y, 2.0);
	vec3 a = vec3(0.135, 0.145, 0.165);
	vec3 b = vec3(0.185, 0.195, 0.215);
	COLOR = vec4(mix(a, b, c), 1.0);
}
"""
	var m := ShaderMaterial.new()
	m.shader = sh
	rect.material = m
	rect.color = Color.WHITE
	add_child(rect)


# --- grid --------------------------------------------------------------------

func _build_grid() -> void:
	var coat := Color(0.44, 0.35, 0.28)
	var ground := Color(0.48, 0.44, 0.39)
	_cells = [
		Cell.make("stroke ripple", "res://vfx/touch/stroke_ripple.gd",
			{"strength": 1.0, "dir": Vector2(-1.0, 0.12), "scale": 1.2}, 0.16, 0.5, true),
		Cell.make("touch dust + hairs", "res://vfx/touch/touch_dust.gd",
			{"strength": 1.0, "dir": Vector2(-1.0, -0.2), "coat": coat}, 0.40, 0.36, true),
		Cell.make("jump smear", "res://vfx/impact/jump_smear.gd",
			{"velocity": Vector2(340.0, -520.0), "radius": 58.0}, 0.03, 0.30, true, 0.66),
		Cell.make("shed fur", "res://vfx/ambient/shed_fur.gd",
			{"coat": coat, "width": 90.0}, 1.6, 0.28),
		Cell.make("breath vapour", "res://vfx/ambient/breath_vapour.gd",
			{"facing": 1.0, "strength": 1.0}, 0.85, 0.55, false, 0.32),

		Cell.make("heart", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.HEART}, 0.85, 0.72),
		Cell.make("sleep", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.SLEEP}, 1.45, 0.72),
		Cell.make("question", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.QUESTION}, 0.60, 0.66),
		Cell.make("exclaim", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.EXCLAIM}, 0.45, 0.66),
		Cell.make("sweat", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.SWEAT}, 0.55, 0.62),

		Cell.make("music", "res://vfx/emotion/emotion_bubble.gd",
			{"glyph": VfxEmotionBubble.Glyph.NOTE}, 1.05, 0.74),
		Cell.make("landing dust", "res://vfx/impact/landing_dust.gd",
			{"impact": 1.3, "velocity": Vector2(220.0, 480.0), "width": 70.0,
			"ground": ground}, 0.30, 0.74),
		Cell.make("footfall (fast)", "res://vfx/impact/footfall_puff.gd",
			{"speed": 0.95, "facing": 1.0, "ground": ground}, 0.26, 0.74),
		Cell.make("footfall (walk)", "res://vfx/impact/footfall_puff.gd",
			{"speed": 0.55, "facing": 1.0, "ground": ground}, 0.22, 0.74),
		Cell.make("droplet shed", "res://vfx/impact/droplet_shed.gd",
			{"wetness": 1.0, "width": 90.0}, 0.52, 0.22),

		Cell.make("shake-off spray", "res://vfx/impact/shake_spray.gd",
			{"power": 1.2, "radius": 40.0, "facing": 1.0}, 0.42, 0.54),
		Cell.make("light motes", "res://vfx/ambient/light_motes.gd",
			{"area": Vector2(210.0, 180.0), "count": 16}, 3.0, 0.5),
		Cell.make("god ray", "res://vfx/ambient/god_ray.gd",
			{"radius": 105.0, "exposure": 1.0}, 3.0, 0.5),
	]
	_lay_out(_cells)


func _lay_out(cells: Array[Cell]) -> void:
	var origin := Vector2(cell.x * 0.5, cell.y * 0.5 + 14.0)
	for i in cells.size():
		var c: Cell = cells[i]
		var centre: Vector2 = origin + Vector2(
			float(i % cols) * cell.x, float(i / cols) * cell.y)
		if c.surface:
			_fur_patch(centre)
		var lbl := Label.new()
		lbl.text = c.label
		lbl.position = centre + Vector2(-cell.x * 0.5 + 10.0, cell.y * 0.5 - 26.0)
		lbl.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
		lbl.z_index = 40
		add_child(lbl)

		var script: Script = load(c.script_path)
		var eff: VfxEffect = script.new()
		eff.light = _director.light
		eff.tier = tier
		add_child(eff)
		eff.global_position = centre + (c.anchor - Vector2(0.5, 0.5)) * cell
		eff.visible = false
		c.effect = eff


func _fur_patch(centre: Vector2) -> void:
	var r := ColorRect.new()
	var s := Vector2(196.0, 168.0)
	r.position = centre - s * 0.5
	r.size = s
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.color = Color.WHITE
	r.z_index = -10
	var m := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = FUR_SHADER
	m.shader = sh
	m.set_shader_parameter("key", _director.light.light_dir_2d())
	r.material = m
	add_child(r)


# --- glyph readability sheet -------------------------------------------------

func _build_glyphs() -> void:
	var names := ["heart", "sleep", "question", "exclaim", "sweat", "music"]
	var glyphs := [
		VfxEmotionBubble.Glyph.HEART, VfxEmotionBubble.Glyph.SLEEP,
		VfxEmotionBubble.Glyph.QUESTION, VfxEmotionBubble.Glyph.EXCLAIM,
		VfxEmotionBubble.Glyph.SWEAT, VfxEmotionBubble.Glyph.NOTE,
	]
	# 24 px is the contractual minimum; 40 is the size the pet actually uses;
	# 96 is where any sloppiness in the distance fields becomes obvious.
	var sizes := [24.0, 40.0, 96.0]
	var script: Script = load("res://vfx/emotion/emotion_bubble.gd")
	for row in sizes.size():
		var sz: float = sizes[row]
		var y: float = 150.0 + float(row) * 190.0
		var lbl := Label.new()
		lbl.text = "%d px" % int(sz)
		lbl.position = Vector2(18.0, y - 16.0)
		lbl.add_theme_color_override("font_color", Color(0.72, 0.75, 0.80))
		add_child(lbl)
		for i in glyphs.size():
			var c := Cell.make(names[i], "res://vfx/emotion/emotion_bubble.gd",
				{"glyph": glyphs[i], "size": sz, "count": 1}, 0.62)
			var eff: VfxEffect = script.new()
			eff.light = _director.light
			eff.tier = tier
			add_child(eff)
			eff.global_position = Vector2(150.0 + float(i) * 175.0, y)
			eff.visible = false
			c.effect = eff
			_cells.append(c)
			if row == 0:
				var nm := Label.new()
				nm.text = names[i]
				nm.position = Vector2(112.0 + float(i) * 175.0, 40.0)
				nm.add_theme_color_override("font_color", Color(0.60, 0.63, 0.70))
				add_child(nm)


# --- the real creature -------------------------------------------------------

## Builds the actual cat and lets the director drive it. Loaded by path rather
## than by class name, and every step guarded, because `core/render` is being
## edited by another agent right now and a preview scene that hard-fails on
## their half-finished refactor is a preview scene nobody can use.
func _build_pet() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var centre := Vector2(vp.x * 0.5, vp.y * 0.66)
	var spec: Variant = GameState.spec_for(&"cat")
	var pet := Node2D.new()
	pet.position = centre
	add_child(pet)

	var radius: float = 90.0
	if spec != null and ResourceLoader.exists("res://core/render/creature_renderer.gd"):
		var script: Script = load("res://core/render/creature_renderer.gd")
		_renderer = script.new()
		pet.add_child(_renderer)
		if _renderer.has_method("setup"):
			_renderer.call("setup", spec)
		var growth := 3.0
		var g_script := load("res://core/creature/growth.gd") if \
			ResourceLoader.exists("res://core/creature/growth.gd") else null
		if g_script != null and g_script.has_method("apply"):
			g_script.call("apply", spec, _renderer.get("live_parts"), growth)
		if _renderer.has_method("set_shading_state"):
			_renderer.call("set_shading_state", growth, 0.0, 1.0, 0.0)
		var natural: float = float(spec.adult_height) * float(spec.pixels_per_unit)
		var fit: float = (vp.y * 0.46) / maxf(natural, 1.0)
		_renderer.set("scale", Vector2(fit, fit))
		radius = natural * fit * 0.5
	else:
		Log.warn("VfxPreview", "no creature available; showing effects only")

	_director.register_pet(&"preview", pet, {
		"renderer": _renderer, "radius": radius, "width": radius * 2.0,
		"coat": Color(0.46, 0.36, 0.28), "exposure": 1.0, "wetness": 0.8,
		"facing": 1.0,
	})

	# Touch the flank, roughly where a hand would land on a sitting cat.
	var hand := centre + Vector2(-radius * 0.45, -radius * 0.55)
	_cells = [
		Cell.make("touch", "", {}, 0.22),
		Cell.make("emote", "", {}, 0.85),
	]
	_cells[0].cfg = {"kind": "touch", "at": hand, "dir": Vector2(-1.0, 0.08)}
	_cells[1].cfg = {"kind": "emote", "glyph": VfxEmotionBubble.Glyph.HEART}

	var lbl := Label.new()
	lbl.text = "director-driven: stroke ripple, touch dust, motes, god ray, hearts"
	lbl.position = Vector2(18.0, 16.0)
	lbl.add_theme_color_override("font_color", Color(0.70, 0.73, 0.78))
	add_child(lbl)


# --- schedule ----------------------------------------------------------------

func _process(_delta: float) -> void:
	_frame += 1
	var t: float = float(_frame) / FPS

	for c in _cells:
		var fire_at: float = CAPTURE_T - c.age * age_scale
		if not c.fired and t >= fire_at:
			c.fired = true
			_fire(c)

	if _frame < int(CAPTURE_T * FPS) or _done:
		return
	_done = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	if err != OK:
		Log.error("VfxPreview", "save_png failed: %s" % error_string(err))
		get_tree().quit(3)
		return
	print("CAPTURE_OK %s %dx%d" % [out_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


func _fire(c: Cell) -> void:
	if c.effect != null:
		c.effect.visible = true
		c.effect.play(c.cfg)
		return
	match String(c.cfg.get("kind", "")):
		"touch":
			_director.touch(&"preview", c.cfg["at"], c.cfg["dir"], 1.0)
		"emote":
			_director.emote(&"preview", int(c.cfg["glyph"]), 3)
