class_name VfxEffect
extends Node2D

## Base class for every effect in the VFX layer.
##
## Two constraints shape this contract, and neither is negotiable for a program
## that sits on someone's desktop for eight hours:
##
## 1. **Nothing allocates during play.** An effect is built once, then recycled
##    by `VfxDirector` forever. `play()` must be able to restart an instance
##    that has already run without touching the scene tree. That is why the
##    animation state lives in plain floats and why appearance is driven by
##    shader uniforms rather than by Tweens, Curves or new nodes.
## 2. **Every effect declares what it costs** before it is allowed to exist, so
##    the director can enforce one global particle ceiling instead of hoping
##    that ten independently reasonable systems add up to something reasonable.
##
## Subclasses override `_build()` (once), `_restart()` (per play) and
## `_tick(t, delta)` where `t` is normalised life in [0, 1].

## Emitted when the effect has finished and may be recycled. The director is the
## only intended listener.
signal finished(effect: VfxEffect)

## Culling order when the budget is exhausted. A footfall puff can be dropped
## without anyone noticing; the glyph that tells the player their pet is hungry
## cannot.
enum Priority {
	CHATTER = 0,   ## Ambient garnish: motes, shed fur, footfall dust.
	NORMAL = 1,    ## Reactions the player caused and expects to see.
	MESSAGE = 2,   ## Communication: emotion glyphs, need warnings.
}

## Lowest `Settings.quality` tier at which this effect is allowed to spawn.
## Effects that carry meaning stay at 0; garnish opts itself out on low.
var min_tier: int = 0
var priority: int = Priority.NORMAL
## Seconds from `play()` to `finished`. Subclasses set this in `_build()` and
## may re-derive it per play in `_restart()`.
var duration: float = 1.0
## Ambient effects run until they are stopped rather than expiring. They are
## held open by the director for as long as their pet exists, and they are the
## only effects allowed to emit continuously.
var looping: bool = false
## Live quality tier, pushed down by the director before `play()`.
var tier: int = 2
## Set when the player has asked for reduced motion. Effects must still read,
## they just must not lunge, snap or strobe.
var calm: bool = false
## Per-play parameters from the director. Subclasses read this in `_restart()`.
var params: Dictionary = {}
## Shared lighting state, injected by the director. Effects must work without
## it — an effect that only lights correctly when the whole game is running is
## an effect nobody can iterate on.
var light: VfxTimeOfDay = null

var age: float = 0.0
var _built := false
var _playing := false


func _ready() -> void:
	# Effects spend most of their life parked in a pool; process only while
	# actually playing, so an idle desktop pet costs nothing per effect.
	set_process(false)
	_ensure_built()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build()


## One-time construction: create child nodes, materials and shaders here.
func _build() -> void:
	pass


## Called at the start of every play, after `params` and `tier` are set.
func _restart() -> void:
	pass


## Per-frame update. `t` is normalised life in [0, 1].
func _tick(_t: float, _delta: float) -> void:
	pass


## Called when the effect is parked back in the pool. Stop emitters here.
func _sleep() -> void:
	pass


## Peak simultaneous particles this effect will put on screen. The director sums
## these against a hard global cap. Effects that draw with a shader quad and no
## emitter honestly report 0 — a single quad is not what makes a machine hot.
func cost() -> int:
	return 0


func is_playing() -> bool:
	return _playing


func play(p_params: Dictionary = {}) -> void:
	_ensure_built()
	params = p_params
	age = 0.0
	_playing = true
	visible = true
	_restart()
	# Run one tick immediately so the effect is correctly posed on the very
	# first frame it is visible. Without this, every spawn shows one frame of
	# whatever pose the previous user of this pooled instance left behind.
	_tick(0.0, 0.0)
	set_process(true)


func stop() -> void:
	if not _playing:
		return
	_playing = false
	set_process(false)
	visible = false
	_sleep()
	finished.emit(self)


func _process(delta: float) -> void:
	if not _playing:
		return
	age += delta
	var t: float = clampf(age / maxf(duration, 1e-4), 0.0, 1.0)
	_tick(t, delta)
	if age >= duration and not looping:
		stop()


# --- lighting, with standalone fallbacks -------------------------------------

## Colour an airborne particle should be under the current key. `sky` is how
## much of the ambient fill bleeds into it: 0 for something bright and close to
## the light, 1 for something deep in shadow.
func lit_color(sky: float = 0.35) -> Color:
	return light.particle_color(sky) if light != null else Color(1.0, 0.95, 0.88).lerp(
		Color(0.60, 0.67, 0.83), clampf(sky, 0.0, 1.0))


func shadow_color() -> Color:
	return light.bounce_tint if light != null else Color(0.31, 0.29, 0.26)


## Screen-space unit vector pointing towards the key light.
func key_dir() -> Vector2:
	return light.light_dir_2d() if light != null else Vector2(-0.55, -0.83).normalized()


## 0 in daylight, 1 at night. Effects use it to pull their own brightness down
## instead of glowing through a dark desktop.
func night() -> float:
	return light.night() if light != null else 0.0


# --- helpers shared by subclasses --------------------------------------------

## Scale factor applied to particle counts. Low tiers thin effects out rather
## than removing them, so the pet still reacts on a weak machine — it just
## reacts more quietly.
func count_scale() -> float:
	match tier:
		0: return 0.35
		1: return 0.6
		2: return 1.0
		_: return 1.35


func scaled_count(base: int) -> int:
	return maxi(1, int(round(float(base) * count_scale())))


## Overshoot-and-settle curve for anything that pops into existence: rises past
## 1, crosses back, and rings down. `k` is the overshoot amount, `damp` how
## quickly the ringing dies. Hand-rolled rather than a Tween because pooled
## effects must not allocate, and because a designer wants one number to turn.
static func spring(t: float, k: float = 0.35, damp: float = 4.2) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	return 1.0 - exp(-damp * t) * (cos(t * TAU * 0.75) - k * sin(t * TAU * 0.75))


static func ease_out_cubic(t: float) -> float:
	var u: float = 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


static func ease_in_cubic(t: float) -> float:
	var u: float = clampf(t, 0.0, 1.0)
	return u * u * u


## `t` remapped from [a, b] to [0, 1], clamped. Used constantly to carve a
## normalised life into named beats.
static func beat(t: float, a: float, b: float) -> float:
	return clampf((t - a) / maxf(b - a, 1e-4), 0.0, 1.0)


## Build a CPUParticles2D wired for this layer's conventions: untextured quads
## shaped entirely by `shader`, a per-particle seed smuggled through
## `anim_offset`, and no colour ramp (the shader owns the whole envelope, which
## keeps every effect tunable from one place instead of two).
static func make_emitter(shader: Shader, amount: int, lifetime: float,
		size_px: float) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = maxi(1, amount)
	p.lifetime = lifetime
	p.one_shot = true
	p.explosiveness = 1.0
	p.emitting = false
	p.local_coords = false
	p.gravity = Vector2.ZERO
	p.scale_amount_min = size_px
	p.scale_amount_max = size_px
	# The shader's only source of per-particle variation. See vfx_common.
	p.anim_offset_min = 0.0
	p.anim_offset_max = 1.0
	p.lifetime_randomness = 0.35
	var m := ShaderMaterial.new()
	m.shader = shader
	p.material = m
	return p
