extends Node2D

## Deterministic UI screenshot harness.
##
## The creature capture scene renders a creature; this renders the interface. It
## exists for the same reason: a reviewer has to look at the actual composite,
## and on a desktop overlay the composite includes the wallpaper underneath. A
## panel judged against a flat grey is not judged at all.
##
##   xvfb-run -a -s "-screen 0 1920x1200x24" \
##     Godot --path game res://ui/ui_preview.tscn --rendering-driver opengl3 \
##     --resolution 1600x1000 --single-window -- --shot=board --out=/abs/x.png
##
## Flags (after the bare `--`):
##   --shot=<id>     board | care | journal | adopt | settings | radial | toasts
##   --out=<path>    absolute PNG path
##   --light=<0|1>   render the light scheme over a pale wallpaper
##   --frames=<n>    frames to settle springs before capturing (default 90)
##   --scale=<f>     UI scale, to check the layout at 125% / 150%
##   --reduced=<0|1> reduced-motion pass, to prove nothing depends on animation

const WALLPAPER := "res://ui/preview/wallpaper.gdshader"

var shot := "board"
var out_path := "user://ui_shot.png"
var light := false
var settle_frames := 90
var ui_scale := 1.0
var reduced := false

var _frames := 0
var _done := false
var _stage: UIStage


func _ready() -> void:
	_parse_args()
	UITokens.refresh(ui_scale, not light, reduced)
	_build_desktop()
	_build_ui()
	Log.info("UIPreview", "shot=%s light=%s scale=%.2f" % [shot, light, ui_scale])


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"shot": shot = kv[1]
			"out": out_path = kv[1]
			"light": light = kv[1] != "0"
			"frames": settle_frames = int(kv[1])
			"scale": ui_scale = float(kv[1])
			"reduced": reduced = kv[1] != "0"


## Wallpaper plus two worst-case blocks: a blown-out white document and a black
## terminal. Any panel that stays legible across that seam is safe anywhere.
func _build_desktop() -> void:
	get_viewport().transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.08, 0.08, 0.10, 1.0))
	var vp := get_viewport_rect().size

	var paper := ColorRect.new()
	paper.position = Vector2.ZERO
	paper.size = vp
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load(WALLPAPER) as Shader
	mat.set_shader_parameter("dark", 0.0 if light else 1.0)
	paper.material = mat
	add_child(paper)

	var white := ColorRect.new()
	white.color = Color(1, 1, 1, 1)
	white.position = Vector2(vp.x * 0.52, 0.0)
	white.size = Vector2(vp.x * 0.48, vp.y * 0.5)
	white.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(white)

	var black := ColorRect.new()
	black.color = Color(0.02, 0.02, 0.025, 1)
	black.position = Vector2(vp.x * 0.52, vp.y * 0.5)
	black.size = Vector2(vp.x * 0.48, vp.y * 0.5)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(black)

	# The scrim shader reads the screen texture, which in 2D is only populated
	# by an explicit back-buffer copy. Placed after the desktop and before the
	# UI so panels blur the wallpaper but not each other.
	var bbc := BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	add_child(bbc)


func _build_ui() -> void:
	_stage = UIStage.new()
	_stage.shot = shot
	_stage.viewport_size = get_viewport_rect().size
	add_child(_stage)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < settle_frames or _done:
		return
	_done = true
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	if err != OK:
		Log.error("UIPreview", "save_png failed: %s" % error_string(err))
		get_tree().quit(3)
		return
	print("CAPTURE_OK %s %dx%d" % [out_path, img.get_width(), img.get_height()])
	get_tree().quit(0)
