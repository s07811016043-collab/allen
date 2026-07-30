class_name VfxEmotionBubble
extends VfxEffect

## The emotion set: hearts, sleep, question, exclamation, sweat, music.
##
## One effect instance owns the whole burst — three hearts are one pooled
## object, not three — because the choreography *between* the glyphs is most of
## what makes it read as an animal thinking rather than as icons appearing.
##
## Every glyph runs the same five beats, which is the shape of any well-animated
## pop. The values differ per emotion; the structure never does:
##
##   ANTICIPATION  gathers small and wide, and dips slightly, for ~70 ms. The
##                 dip is the important half: a pop that only goes up has no
##                 weight behind it.
##   OVERSHOOT     springs past full size while stretching vertically, and
##                 covers half its total rise in this beat.
##   SETTLE        the spring rings down, with a counter-rotation so the glyph
##                 arrives at a slight angle rather than snapping to upright.
##   HOLD          the readable beat. Slow rise, slow sway, a 2% breath. This is
##                 the only part the player consciously reads, so it is the
##                 longest and the calmest.
##   EXIT          per emotion, and never a linear fade. A heart lifts and pops,
##                 a Z expands and dissolves like breath, an exclamation snaps
##                 back down, a sweat drop slides off sideways under gravity.
##
## Timing is integrated by hand instead of by Tween. Pooled effects must not
## allocate, and an artist tuning "how much overshoot" wants one number in one
## table, not a tween chain rebuilt on every spawn.

enum Glyph { HEART, SLEEP, QUESTION, EXCLAIM, SWEAT, NOTE, NOTE_PAIR }

const SHADER_PATH := "res://vfx/emotion/emotion_glyph.gdshader"
## More than three of anything is a cartoon, not a pet.
const MAX_SLOTS := 3

## Per-emotion design values. Reads as a table on purpose: this is the file a
## designer edits, and everything they would want to change is in one place.
class Kit:
	var fill_top := Color.WHITE
	var fill_bottom := Color.GRAY
	var edge := Color.BLACK
	var count: int = 1
	## Seconds between successive glyphs in the burst.
	var stagger: float = 0.18
	var life: float = 1.5
	## Pixels the glyph climbs over its life.
	var rise: float = 46.0
	## Peak lateral sway in pixels.
	var sway: float = 7.0
	## Horizontal fan across the burst, in pixels.
	var fan: float = 20.0
	## Spring overshoot, 0 = none.
	var pop: float = 0.36
	## Exit style, see `_exit_pose`.
	var exit_kind: int = 0
	var size: float = 46.0

	static func make(ft: Color, fb: Color, e: Color, count_: int, stagger_: float,
			life_: float, rise_: float, sway_: float, fan_: float, pop_: float,
			exit_: int, size_: float) -> Kit:
		var k := Kit.new()
		k.fill_top = ft
		k.fill_bottom = fb
		k.edge = e
		k.count = count_
		k.stagger = stagger_
		k.life = life_
		k.rise = rise_
		k.sway = sway_
		k.fan = fan_
		k.pop = pop_
		k.exit_kind = exit_
		k.size = size_
		return k

## Exit styles.
const EXIT_LIFT := 0     ## Rises, shrinks, gone. The default.
const EXIT_POP := 1      ## Swells then vanishes fast — affection, celebration.
const EXIT_DISSOLVE := 2 ## Expands and thins, like breath. Sleep.
const EXIT_SNAP := 3     ## Recoils down and squashes out. Alarm, realisation.
const EXIT_SLIDE := 4    ## Falls away sideways under gravity. Sweat.

var _slots: Array[ColorRect] = []
var _mats: Array[ShaderMaterial] = []
var _kits: Array[Kit] = []
var _kit: Kit
var _glyphs := PackedInt32Array()
var _count: int = 1
var _size: float = 46.0
var _seed: float = 0.0


func _build() -> void:
	priority = Priority.MESSAGE
	# Emotion is the layer's only literal channel; it survives every quality
	# tier, because a pet that stops telling you it is hungry is broken, not
	# optimised.
	min_tier = 0

	_kits.resize(Glyph.size())
	#                       fill top             fill bottom          keyline              n  stag  life  rise sway  fan  pop  exit          size
	_kits[Glyph.HEART] = Kit.make(
		Color(1.00, 0.52, 0.58), Color(0.80, 0.16, 0.30), Color(0.26, 0.05, 0.11),
		3, 0.17, 1.55, 62.0, 8.0, 22.0, 0.42, EXIT_POP, 44.0)
	_kits[Glyph.SLEEP] = Kit.make(
		Color(0.92, 0.95, 1.00), Color(0.58, 0.66, 0.88), Color(0.15, 0.18, 0.30),
		3, 0.52, 2.30, 74.0, 11.0, 26.0, 0.24, EXIT_DISSOLVE, 40.0)
	_kits[Glyph.QUESTION] = Kit.make(
		Color(1.00, 0.93, 0.68), Color(0.94, 0.68, 0.24), Color(0.30, 0.17, 0.05),
		1, 0.0, 1.45, 26.0, 5.0, 0.0, 0.44, EXIT_LIFT, 48.0)
	_kits[Glyph.EXCLAIM] = Kit.make(
		Color(1.00, 0.86, 0.54), Color(0.96, 0.42, 0.18), Color(0.32, 0.09, 0.04),
		1, 0.0, 1.05, 18.0, 0.0, 0.0, 0.62, EXIT_SNAP, 50.0)
	_kits[Glyph.SWEAT] = Kit.make(
		Color(0.86, 0.96, 1.00), Color(0.40, 0.68, 0.92), Color(0.09, 0.23, 0.36),
		1, 0.0, 1.25, 10.0, 3.0, 0.0, 0.30, EXIT_SLIDE, 38.0)
	_kits[Glyph.NOTE] = Kit.make(
		Color(0.84, 0.90, 1.00), Color(0.44, 0.52, 0.82), Color(0.11, 0.13, 0.26),
		3, 0.24, 1.80, 70.0, 14.0, 30.0, 0.38, EXIT_LIFT, 42.0)
	_kits[Glyph.NOTE_PAIR] = Kit.make(
		Color(0.84, 0.90, 1.00), Color(0.44, 0.52, 0.82), Color(0.11, 0.13, 0.26),
		2, 0.30, 1.80, 70.0, 14.0, 30.0, 0.38, EXIT_LIFT, 46.0)

	var shader := load(SHADER_PATH) as Shader
	_glyphs.resize(MAX_SLOTS)
	for i in MAX_SLOTS:
		var r := ColorRect.new()
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.color = Color.WHITE
		var m := ShaderMaterial.new()
		m.shader = shader
		r.material = m
		r.visible = false
		add_child(r)
		_slots.append(r)
		_mats.append(m)
	_kit = _kits[Glyph.HEART]


func _restart() -> void:
	var g: int = clampi(int(params.get("glyph", Glyph.HEART)), 0, Glyph.size() - 1)
	_kit = _kits[g]
	_seed = randf()
	_size = float(params.get("size", _kit.size)) * float(params.get("scale", 1.0))
	_count = clampi(int(params.get("count", _kit.count)), 1, MAX_SLOTS)
	# Low tiers show fewer glyphs but never zero — the message is the point.
	if tier <= 0:
		_count = mini(_count, 1)
	elif tier == 1:
		_count = mini(_count, 2)

	# Musical phrases alternate a single quaver with a beamed pair, which is the
	# difference between "notes" and "the same note three times".
	for i in MAX_SLOTS:
		var gi: int = g
		if g == Glyph.NOTE and i == 1:
			gi = Glyph.NOTE_PAIR
		_glyphs[i] = gi

	# Stroke weight is defined in *pixels*, then converted to glyph units, so a
	# 24 px heart and a 96 px heart have the same keyline.
	var px_to_unit: float = 2.0 / maxf(_size, 8.0)
	var outline: float = clampf(1.7 * px_to_unit, 0.028, 0.115)
	var shadow: float = clampf(2.6 * px_to_unit, 0.035, 0.140)

	var k := key_dir()
	# Emotions keep their identity but pick up the room: a heart at sunset is
	# warmer than a heart at noon, by about a sixth.
	var warm: Color = lit_color(0.3)
	for i in MAX_SLOTS:
		var m: ShaderMaterial = _mats[i]
		m.set_shader_parameter("glyph", _glyphs[i])
		m.set_shader_parameter("fill_top", _kit.fill_top.lerp(warm, 0.16))
		m.set_shader_parameter("fill_bottom", _kit.fill_bottom.lerp(warm, 0.10))
		m.set_shader_parameter("edge_color", _kit.edge)
		m.set_shader_parameter("spec_color", lit_color(0.05))
		m.set_shader_parameter("key_dir", k)
		m.set_shader_parameter("outline", outline)
		m.set_shader_parameter("shadow_dist", shadow)
		m.set_shader_parameter("shadow_alpha", 0.24)
		var r: ColorRect = _slots[i]
		r.size = Vector2(_size, _size)
		r.pivot_offset = r.size * 0.5
		r.visible = i < _count

	var stagger: float = _kit.stagger * (1.25 if calm else 1.0)
	duration = _kit.life * (1.15 if calm else 1.0) + stagger * float(_count - 1)


func _tick(_t: float, _delta: float) -> void:
	var stagger: float = _kit.stagger * (1.25 if calm else 1.0)
	var life: float = _kit.life * (1.15 if calm else 1.0)
	for i in _count:
		_pose_slot(i, (age - stagger * float(i)) / maxf(life, 1e-4))


func _pose_slot(i: int, u: float) -> void:
	var r: ColorRect = _slots[i]
	if u < 0.0 or u > 1.0:
		r.visible = false
		return
	r.visible = true

	# Deterministic per-glyph variation so a burst is not three clones.
	var jitter: float = fposmod(_seed * 7.31 + float(i) * 0.417, 1.0) - 0.5
	var lean: float = signf(jitter + 0.001)
	var side: float = (float(i) - float(_count - 1) * 0.5)
	var motion: float = 0.45 if calm else 1.0

	# End of the gather, as a fraction of life. About 130 ms at default timings,
	# which is the shortest anticipation the eye still registers as one.
	const ANTI_END := 0.085
	## Size the glyph reaches while gathering, before the launch.
	const GATHER := 0.40

	var gather: float = VfxEffect.beat(u, 0.0, ANTI_END)
	var launch: float = VfxEffect.beat(u, ANTI_END, 0.42)

	# --- ANTICIPATION -> OVERSHOOT -> SETTLE ---------------------------------
	var scale_amt: float = VfxEffect.ease_out_cubic(gather) * GATHER
	if u >= ANTI_END:
		scale_amt = lerpf(GATHER, 1.0, VfxEffect.spring(launch, _kit.pop * motion, 4.0))

	# One signed squash channel: +1 is wide and flat (gathering), -1 is tall and
	# thin (launching), 0 is settled. Blending between them across the first
	# sixth of the launch keeps the flip from being a one-frame snap.
	var squash: float = 1.0
	if u >= ANTI_END:
		squash = lerpf(1.0, -1.0, smoothstep(0.0, 0.18, launch)) * (1.0 - launch)
	squash *= motion
	var sx: float = scale_amt * (1.0 + squash * 0.34)
	var sy: float = scale_amt * (1.0 - squash * 0.30)

	# --- HOLD: rise, sway, breathe. ------------------------------------------
	var climb: float = VfxEffect.ease_out_cubic(VfxEffect.beat(u, ANTI_END, 0.85))
	var y: float = -_kit.rise * climb
	# The gather dips before the launch. That dip is what gives the pop weight;
	# without it the glyph reads as appearing rather than as being expelled.
	y += (1.0 - gather) * 9.0 * motion
	var sway_t: float = u * TAU * 0.85 + _seed * TAU + float(i) * 1.9
	var x: float = side * _kit.fan + sin(sway_t) * _kit.sway * motion \
		* VfxEffect.beat(u, 0.12, 0.45)
	var rot: float = sin(sway_t * 0.8) * 0.10 * motion + jitter * 0.16
	# Counter-rotation on arrival: the glyph swings past upright and back.
	rot += (1.0 - VfxEffect.beat(u, ANTI_END, 0.5)) * -0.34 * motion * lean
	var alpha: float = 1.0

	# --- EXIT ----------------------------------------------------------------
	var e: float = VfxEffect.beat(u, 0.80, 1.0)
	if e > 0.0:
		var pose := _exit_pose(e, motion)
		sx *= pose.x
		sy *= pose.y
		y += pose.z
		alpha = pose.w
		rot += (e * e) * 0.30 * motion * lean
		if _kit.exit_kind == EXIT_SLIDE:
			x += e * e * 34.0 * lean

	var m: ShaderMaterial = _mats[i]
	# The arrival flash rides the front of the spring: two or three frames of a
	# brighter keyline, which is what makes the pop feel like it has an impact
	# instead of just a size curve.
	m.set_shader_parameter("flash", (1.0 - VfxEffect.beat(u, 0.02, 0.16)) * 0.9
		* VfxEffect.beat(u, 0.0, 0.05))
	m.set_shader_parameter("master_alpha", clampf(alpha, 0.0, 1.0))
	r.scale = Vector2(maxf(sx, 0.0001), maxf(sy, 0.0001))
	r.rotation = rot
	r.position = Vector2(x, y) - r.size * 0.5


## Returns (scale_x, scale_y, extra_y, alpha) for the exit beat, `e` in [0, 1].
func _exit_pose(e: float, motion: float) -> Vector4:
	var ec: float = VfxEffect.ease_in_cubic(e)
	match _kit.exit_kind:
		EXIT_POP:
			# Swell, then leave quickly. Alpha holds almost to the end so the
			# glyph is legible right up to the moment it is not there.
			var sw: float = 1.0 + sin(e * PI) * 0.22 * motion
			return Vector4(sw, sw, -e * 16.0, 1.0 - ec * ec)
		EXIT_DISSOLVE:
			# Breath: expands as it thins, so it reads as dispersing rather than
			# as being switched off.
			var g: float = 1.0 + e * 0.55 * motion
			return Vector4(g, g, -e * 20.0, pow(1.0 - e, 1.6))
		EXIT_SNAP:
			# Alarm recoils: drops back towards the pet, squashing as it goes.
			return Vector4(1.0 + ec * 0.30 * motion, 1.0 - ec * 0.55 * motion,
				ec * 22.0, 1.0 - ec)
		EXIT_SLIDE:
			# A drop is heavy. It accelerates downward and flicks away.
			return Vector4(1.0 - e * 0.15, 1.0 + e * 0.20, e * e * 46.0, 1.0 - ec)
		_:
			# Lift: the default. Keeps rising, narrows slightly, fades late.
			return Vector4(1.0 - e * 0.24, 1.0 - e * 0.18, -e * 26.0,
				1.0 - VfxEffect.ease_in_cubic(e))


func _sleep() -> void:
	for r in _slots:
		r.visible = false
