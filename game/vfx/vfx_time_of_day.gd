class_name VfxTimeOfDay
extends Node

## The one lighting model the whole presentation layer agrees on.
##
## The pet should feel like it is sitting in the player's room: warm and
## long-shadowed at 18:00, cold and blue at 02:00. There are two ways to get
## that, and only one of them survives contact with a real codebase.
##
## The wrong way is a second lighting system that tints the creature with an
## overlay. It would fight the body shader's own shading, wash out the coat's
## anisotropy, and drift out of sync with the VFX the moment either side is
## tweaked.
##
## The right way — this one — is to drive the shading inputs `CreatureRenderer`
## already publishes, and to publish the same numbers to the effects so a dust
## mote is lit by the same sun as the fur it came off. The renderer exposes
## exactly three: `light_dir`, `ambient_tint` and `bounce_tint`. Everything
## below is expressed in those terms.
##
## A note on what that constraint costs. In life the sunset key is orange while
## the sky dome stays blue; we can set the direction and the two fill colours
## but not a key *colour*. So golden hour is carried by warming the ambient and
## strongly warming the bounce, which is also physically defensible — near
## sunset the whole sky glows, not just the sun. Night does the reverse. If the
## renderer ever gains a key-colour uniform, every stop below already carries
## the value under `key`; wire it up in `_push_to_renderers` and nothing else
## needs to change.

## One lighting condition, sampled at an hour of the local day.
class Stop:
	var hour: float = 12.0
	## VFX-facing key colour. Not yet consumed by the body shader; particles,
	## motes and god rays are lit with it so they agree with each other.
	var key := Color.WHITE
	var ambient := Color.WHITE
	var bounce := Color.BLACK
	## Direction *towards* the light, in the body shader's space. Note that +y
	## is down, so an overhead key has a negative y.
	var dir := Vector3(0.0, -1.0, 0.0)
	## How bright the scene reads, 0..1. Gates the god ray and the motes.
	var brightness: float = 1.0

	static func make(p_hour: float, p_key: Color, p_ambient: Color,
			p_bounce: Color, p_dir: Vector3, p_brightness: float) -> Stop:
		var s := Stop.new()
		s.hour = p_hour
		s.key = p_key
		s.ambient = p_ambient
		s.bounce = p_bounce
		s.dir = p_dir.normalized()
		s.brightness = p_brightness
		return s

## Seconds for the lighting to travel most of the way to a new target. Long on
## purpose: the transition must never be something the player can catch
## happening, only something they notice has happened.
const BLEND_TAU := 6.0

## Overrides the system clock when >= 0. The preview scene and the capture
## harness set this; nothing in the shipping game does.
var force_hour: float = -1.0
## Externally driven cold, 0..1. Gates breath vapour and pulls the palette
## towards blue without disturbing the time-of-day curve underneath.
var chill: float = 0.0
## Externally driven cloud cover, 0..1. Flattens the key and kills god rays.
var overcast: float = 0.0

# Live, smoothed state. Effects read these every frame; they are never null.
var key_color := Color(1.0, 0.95, 0.88)
var ambient_tint := Color(0.60, 0.67, 0.83)
var bounce_tint := Color(0.31, 0.29, 0.26)
var light_dir := Vector3(-0.46, -0.62, 0.64)
var brightness: float = 0.85

## The day, as seven keyframes. Deliberately few: a desktop pet's lighting
## should be something a player half-notices when they look up at 19:00, not a
## simulation. Hours wrap, so 23:00 blends into 05:00 through the night stop.
var _stops: Array[Stop] = []
## Filled in place every frame so the smoothing costs no allocation.
var _scratch := Stop.new()
var _renderers: Array[Node] = []


func _ready() -> void:
	_stops = [
		# Dawn: low rose key from the left, violet fill, almost no bounce.
		Stop.make(5.5, Color(1.00, 0.74, 0.62), Color(0.46, 0.46, 0.62),
			Color(0.26, 0.21, 0.24), Vector3(-0.58, -0.40, 0.71), 0.45),
		# Mid-morning: clean neutral daylight, the reference condition.
		Stop.make(9.5, Color(1.00, 0.95, 0.88), Color(0.60, 0.67, 0.83),
			Color(0.31, 0.29, 0.26), Vector3(-0.46, -0.62, 0.64), 0.85),
		# Noon: key almost overhead, shortest contact shadow.
		Stop.make(13.0, Color(1.00, 0.99, 0.96), Color(0.63, 0.70, 0.86),
			Color(0.34, 0.32, 0.29), Vector3(-0.12, -0.84, 0.53), 1.00),
		# Golden hour: the flattering one. Warm everywhere, raking from the right.
		Stop.make(17.5, Color(1.00, 0.82, 0.58), Color(0.64, 0.55, 0.52),
			Color(0.38, 0.27, 0.20), Vector3(0.54, -0.44, 0.72), 0.78),
		# Sunset proper: deeply warm, light almost horizontal.
		Stop.make(19.5, Color(1.00, 0.62, 0.40), Color(0.58, 0.44, 0.44),
			Color(0.36, 0.21, 0.17), Vector3(0.68, -0.28, 0.68), 0.50),
		# Dusk: the warmth has gone, the blue has not arrived. Lowest contrast.
		Stop.make(21.5, Color(0.66, 0.60, 0.74), Color(0.31, 0.34, 0.52),
			Color(0.17, 0.17, 0.24), Vector3(0.22, -0.66, 0.72), 0.26),
		# Night: moon key, cold and dim, everything reads by rim light.
		Stop.make(1.5, Color(0.56, 0.66, 0.94), Color(0.19, 0.24, 0.42),
			Color(0.10, 0.11, 0.17), Vector3(-0.34, -0.72, 0.60), 0.14),
	]
	# Snap on the first frame; a fade-in from the default palette would read as
	# a bug on startup.
	_blend(1.0)


## Register a `CreatureRenderer`, or anything exposing the same three fields.
## Typed as `Node` on purpose: this layer must not hard-depend on a class that
## lives in a directory another agent is editing.
func register_renderer(r: Node) -> void:
	if r != null and not _renderers.has(r):
		_renderers.append(r)


func unregister_renderer(r: Node) -> void:
	_renderers.erase(r)


func _process(delta: float) -> void:
	# One-pole smoothing rather than a tween, because the target itself moves
	# continuously with the clock and there is never a moment to tween *to*.
	_blend(1.0 - exp(-delta / BLEND_TAU))
	_push_to_renderers()


func current_hour() -> float:
	if force_hour >= 0.0:
		return fposmod(force_hour, 24.0)
	var t := Time.get_time_dict_from_system()
	return float(t.get("hour", 12)) + float(t.get("minute", 0)) / 60.0


func _blend(k: float) -> void:
	_sample_into(current_hour(), _scratch)
	var kc: Color = _scratch.key
	var am: Color = _scratch.ambient
	var bo: Color = _scratch.bounce
	var br: float = _scratch.brightness
	if chill > 0.0:
		# Cold does not move the sun. It changes colour temperature and how much
		# of the shadow is filled by a pale sky.
		kc = kc.lerp(Color(0.78, 0.86, 1.00), chill * 0.55)
		am = am.lerp(Color(0.42, 0.52, 0.74), chill * 0.50)
		bo = bo.lerp(Color(0.14, 0.17, 0.23), chill * 0.50)
	if overcast > 0.0:
		# Cloud turns the sky itself into the key: fill rises, contrast dies.
		kc = kc.lerp(am, overcast * 0.60)
		am = am.lerp(Color(0.60, 0.63, 0.70), overcast * 0.60)
		br *= lerpf(1.0, 0.45, overcast)
	key_color = key_color.lerp(kc, k)
	ambient_tint = ambient_tint.lerp(am, k)
	bounce_tint = bounce_tint.lerp(bo, k)
	light_dir = light_dir.lerp(_scratch.dir, k).normalized()
	brightness = lerpf(brightness, br, k)


## Circular interpolation across the keyframe ring, written into `out`.
func _sample_into(hour: float, out: Stop) -> void:
	var n: int = _stops.size()
	if n == 0:
		return
	var lo: int = n - 1
	var hi: int = 0
	for i in n:
		var span: float = fposmod(_stops[(i + 1) % n].hour - _stops[i].hour, 24.0)
		if fposmod(hour - _stops[i].hour, 24.0) <= span:
			lo = i
			hi = (i + 1) % n
			break
	var a: Stop = _stops[lo]
	var b: Stop = _stops[hi]
	var span2: float = maxf(fposmod(b.hour - a.hour, 24.0), 1e-3)
	var f: float = clampf(fposmod(hour - a.hour, 24.0) / span2, 0.0, 1.0)
	# Smoothstep between stops so the day has no corners in it. A linear ramp
	# through golden hour reads as a slider being dragged.
	f = f * f * (3.0 - 2.0 * f)
	out.hour = hour
	out.key = a.key.lerp(b.key, f)
	out.ambient = a.ambient.lerp(b.ambient, f)
	out.bounce = a.bounce.lerp(b.bounce, f)
	out.dir = a.dir.lerp(b.dir, f)
	out.brightness = lerpf(a.brightness, b.brightness, f)


## Written by property name rather than through a setter so this file never has
## to be edited when the renderer grows new shading inputs, and never breaks
## when a field it expects is temporarily absent mid-refactor.
func _push_to_renderers() -> void:
	for i in range(_renderers.size() - 1, -1, -1):
		var r: Node = _renderers[i]
		if not is_instance_valid(r):
			_renderers.remove_at(i)
			continue
		if r.get("light_dir") != null:
			r.set("light_dir", light_dir)
		if r.get("ambient_tint") != null:
			r.set("ambient_tint", ambient_tint)
		if r.get("bounce_tint") != null:
			r.set("bounce_tint", bounce_tint)


# --- convenience for effects -------------------------------------------------

## Screen-space unit vector pointing *towards* the light. Effects use it to
## place highlights and to decide which way a god ray or a shed hair falls.
func light_dir_2d() -> Vector2:
	var v := Vector2(light_dir.x, light_dir.y)
	return v.normalized() if v.length_squared() > 1e-6 else Vector2(0.0, -1.0)


## 0 at midday, 1 in the dead of night. Effects dim themselves at night rather
## than glowing through it, which is the difference between atmosphere and a
## screensaver.
func night() -> float:
	return clampf(1.0 - brightness / 0.85, 0.0, 1.0)


## Colour a lit airborne particle should be: the key, filled by however much
## sky is bouncing into it.
func particle_color(sky_mix: float = 0.35) -> Color:
	return key_color.lerp(ambient_tint, clampf(sky_mix, 0.0, 1.0))
