class_name VfxDirector
extends Node2D

## Owns every effect in the game: what may spawn, where, how many, and at what
## fidelity.
##
## Individual effects are deliberately naive — each one knows how to look right
## and nothing else. All the judgement lives here, because the failure mode of a
## VFX layer is never one bad effect, it is fifteen individually reasonable
## effects arriving at the same moment. Four mechanisms prevent that:
##
##   POOLING      Every effect is built once and recycled forever. After the
##                first minute of play this node allocates nothing.
##   BUDGET       One global particle ceiling per quality tier. An effect
##                declares its cost before it is allowed to exist; over budget,
##                the director culls the oldest lower-priority effect, and if
##                there is nothing cheaper to cull it refuses the spawn.
##   RATE LIMITS  Per-effect cooldowns and concurrency caps. `pet_stroked` fires
##                every frame the cursor moves; without a cooldown that is sixty
##                ripples a second.
##   QUALITY      `Settings.quality` picks the tier, `reduced_motion` picks
##                whether effects lunge or drift. Effects thin out rather than
##                vanish, except where the cost is structural.
##
## Everything the creature and brain layers need is exposed twice: as EventBus
## subscriptions for signals that exist today, and as direct methods for the
## motion events the bus has not grown yet. Signal connections are guarded with
## `has_signal`, so this file keeps working while the bus is being edited.

## Registry of every spawnable effect.
##   script  — implementation, loaded lazily on first use
##   cost    — worst-case particle count, used for admission control
##   max     — concurrent instances allowed
##   cool    — minimum seconds between spawns
##   z       — z_index offset relative to the director
const EFFECTS := {
	&"stroke_ripple": {
		"script": "res://vfx/touch/stroke_ripple.gd",
		"cost": 4, "max": 2, "cool": 0.09, "z": 2,
	},
	&"touch_dust": {
		"script": "res://vfx/touch/touch_dust.gd",
		"cost": 16, "max": 3, "cool": 0.14, "z": 3,
	},
	&"emotion": {
		"script": "res://vfx/emotion/emotion_bubble.gd",
		"cost": 3, "max": 2, "cool": 0.30, "z": 6,
	},
	&"landing_dust": {
		"script": "res://vfx/impact/landing_dust.gd",
		"cost": 20, "max": 2, "cool": 0.08, "z": 1,
	},
	&"footfall": {
		"script": "res://vfx/impact/footfall_puff.gd",
		"cost": 4, "max": 5, "cool": 0.06, "z": 1,
	},
	&"jump_smear": {
		"script": "res://vfx/impact/jump_smear.gd",
		"cost": 2, "max": 1, "cool": 0.25, "z": -1,
	},
	&"droplet_shed": {
		"script": "res://vfx/impact/droplet_shed.gd",
		"cost": 4, "max": 2, "cool": 0.45, "z": 3,
	},
	&"shake_spray": {
		"script": "res://vfx/impact/shake_spray.gd",
		"cost": 33, "max": 1, "cool": 0.90, "z": 3,
	},
	&"breath": {
		"script": "res://vfx/ambient/breath_vapour.gd",
		"cost": 6, "max": 1, "cool": 1.20, "z": 2,
	},
	&"shed_fur": {
		"script": "res://vfx/ambient/shed_fur.gd",
		"cost": 2, "max": 2, "cool": 3.00, "z": 3,
	},
	# The two ambient effects are re-requested every frame until they take, so
	# they carry a cooldown purely to damp the retry.
	&"motes": {
		"script": "res://vfx/ambient/light_motes.gd",
		"cost": 14, "max": 2, "cool": 0.75, "z": 4,
	},
	&"god_ray": {
		"script": "res://vfx/ambient/god_ray.gd",
		"cost": 1, "max": 2, "cool": 0.75, "z": -2,
	},
}

## Hard ceiling on simultaneous particles, indexed by `Settings.quality`.
## Chosen so that the worst plausible pile-up — a wet dog shaking off as it
## lands from a jump — still fits at High without culling anything the player
## caused.
const BUDGET := [42, 96, 190, 320]

## Which mood maps to which glyph. Moods with no entry emote nothing, which is
## most of them: a pet that comments on every internal state is exhausting.
const MOOD_GLYPHS := {
	&"sleepy": VfxEmotionBubble.Glyph.SLEEP,
	&"asleep": VfxEmotionBubble.Glyph.SLEEP,
	&"drowsy": VfxEmotionBubble.Glyph.SLEEP,
	&"curious": VfxEmotionBubble.Glyph.QUESTION,
	&"confused": VfxEmotionBubble.Glyph.QUESTION,
	&"alert": VfxEmotionBubble.Glyph.EXCLAIM,
	&"startled": VfxEmotionBubble.Glyph.EXCLAIM,
	&"scared": VfxEmotionBubble.Glyph.SWEAT,
	&"anxious": VfxEmotionBubble.Glyph.SWEAT,
	&"hot": VfxEmotionBubble.Glyph.SWEAT,
	&"playful": VfxEmotionBubble.Glyph.NOTE,
	&"happy": VfxEmotionBubble.Glyph.NOTE,
	&"affectionate": VfxEmotionBubble.Glyph.HEART,
}

## Vocalisations that are musical rather than conversational.
const SINGING_CALLS := [&"song", &"warble", &"trill", &"purr"]

## What the director knows about one pet. Everything is optional; a caller that
## only supplies a node still gets working effects, just with default sizes.
class Anchor:
	var node: Node2D = null
	var renderer: Node = null
	## Pixels per rig unit, for converting the rig-space hit points the bus
	## sends into screen positions.
	var px_per_unit: float = 180.0
	## Half-width and radius of the body in pixels, for sizing effects.
	var radius: float = 70.0
	var width: float = 90.0
	## Dominant coat colour, so shed hairs and touch dust match the animal.
	var coat := Color(0.44, 0.35, 0.29)
	var ground := Color(0.46, 0.42, 0.38)
	var facing: float = 1.0
	## 0..1, drives the shed-water timer.
	var wetness: float = 0.0
	## Caller's claim about how brightly lit this spot is, 0..1.
	var exposure: float = 1.0
	## Last screen position the player touched, so a stroke signal that carries
	## no position still lands on the right patch of fur.
	var last_touch := Vector2.ZERO
	var stroke_dir := Vector2(-1.0, 0.0)
	# Ambient bookkeeping.
	var motes: VfxEffect = null
	var ray: VfxEffect = null
	var next_shed: float = 0.0
	var next_breath: float = 0.0
	var next_drip: float = 0.0
	## While the clock is under this, the ambient motes run bright. Used for
	## celebration rather than spawning a second, louder particle system.
	var motes_boost_until: float = 0.0

## Fields `register_pet` and `update_pet` will copy out of their options
## dictionary. Spelled out rather than reflected so a typo in a caller is
## ignored instead of silently writing a property that does not exist.
const ANCHOR_FIELDS := [
	"node", "renderer", "px_per_unit", "radius", "width", "coat", "ground",
	"facing", "wetness", "exposure",
]

## Shared lighting. Created here so a scene only has to add the director.
var light: VfxTimeOfDay

var _tier: int = 2
var _calm: bool = false
var _scripts := {}
var _pool := {}
var _live: Array[VfxEffect] = []
var _live_cost: int = 0
var _last_spawn := {}
var _anchors := {}
var _clock: float = 0.0
## Peak concurrent cost seen this session, for the diagnostics overlay.
var _peak_cost: int = 0


func _ready() -> void:
	light = VfxTimeOfDay.new()
	light.name = "VfxTimeOfDay"
	add_child(light)
	_read_settings()
	_connect_bus()


func _read_settings() -> void:
	_tier = clampi(int(Settings.get_value(&"quality", 2)), 0, BUDGET.size() - 1)
	_calm = bool(Settings.get_value(&"reduced_motion", false))
	# Live effects keep the tier they were spawned with; changing fidelity
	# mid-flight looks worse than letting the current burst finish.
	for e in _live:
		e.calm = _calm


## Signals the bus may or may not have yet. Connecting through a table keeps
## this file from breaking while `event_bus.gd` is being extended by someone
## else, and makes the set of things VFX reacts to readable in one place.
func _connect_bus() -> void:
	var wiring := {
		&"pet_touched": _on_pet_touched,
		&"pet_stroked": _on_pet_stroked,
		&"pet_grabbed": _on_pet_grabbed,
		&"pet_released": _on_pet_released,
		&"pet_fed": _on_pet_fed,
		&"pet_played_with": _on_pet_played_with,
		&"affection_changed": _on_affection_changed,
		&"mood_changed": _on_mood_changed,
		&"need_critical": _on_need_critical,
		&"stage_advanced": _on_stage_advanced,
		&"milestone_unlocked": _on_milestone_unlocked,
		&"pet_vocalised": _on_pet_vocalised,
		&"pet_reached_ledge": _on_pet_reached_ledge,
		&"settings_changed": _on_settings_changed,
	}
	for sig in wiring:
		if EventBus.has_signal(sig):
			EventBus.connect(sig, wiring[sig])
		else:
			Log.debug("VfxDirector", "no signal '%s' on the bus; skipping" % sig)


# --- pet registration --------------------------------------------------------

## Attach the director to a pet. `opts` may carry any field of `Anchor`.
func register_pet(pet_id: StringName, node: Node2D, opts: Dictionary = {}) -> void:
	var a := Anchor.new()
	a.node = node
	_apply_opts(a, opts)
	if a.renderer != null:
		light.register_renderer(a.renderer)
	_anchors[pet_id] = a
	a.next_shed = _clock + randf_range(12.0, 30.0)
	a.next_breath = _clock + randf_range(2.0, 5.0)
	a.next_drip = _clock + randf_range(0.4, 1.2)


func unregister_pet(pet_id: StringName) -> void:
	var a: Anchor = _anchors.get(pet_id)
	if a == null:
		return
	if a.renderer != null:
		light.unregister_renderer(a.renderer)
	if a.motes != null:
		a.motes.stop()
	if a.ray != null:
		a.ray.stop()
	_anchors.erase(pet_id)


## Update anything the brain owns and VFX only reads.
func update_pet(pet_id: StringName, opts: Dictionary) -> void:
	var a: Anchor = _anchors.get(pet_id)
	if a == null:
		return
	_apply_opts(a, opts)


func _apply_opts(a: Anchor, opts: Dictionary) -> void:
	for k in opts:
		var key := String(k)
		if ANCHOR_FIELDS.has(key):
			a.set(key, opts[k])
		else:
			Log.warn("VfxDirector", "unknown anchor field '%s'" % key)


func anchor_position(pet_id: StringName) -> Vector2:
	var a: Anchor = _anchors.get(pet_id)
	if a == null or not is_instance_valid(a.node):
		return global_position
	return a.node.global_position


# --- spawning ----------------------------------------------------------------

## The one way an effect comes into existence. Returns null when the spawn was
## refused, which callers are expected to ignore — a refused effect is a
## successful budget, not an error.
func spawn(id: StringName, at: Vector2, cfg: Dictionary = {}) -> VfxEffect:
	var reg: Dictionary = EFFECTS.get(id, {})
	if reg.is_empty():
		Log.warn("VfxDirector", "unknown effect '%s'" % id)
		return null

	var cool: float = float(reg.get("cool", 0.0))
	if cool > 0.0 and _clock - float(_last_spawn.get(id, -999.0)) < cool:
		return null
	if _count_live(id) >= int(reg.get("max", 1)):
		return null

	var declared: int = int(reg.get("cost", 0))
	# An instance pulled from the pool and then refused simply stays parked, so
	# the early returns below leak nothing.
	var eff: VfxEffect = _acquire(id, reg)
	if eff == null or eff.min_tier > _tier:
		return null
	if not _make_room(declared, eff.priority):
		return null

	eff.tier = _tier
	eff.calm = _calm
	eff.light = light
	eff.global_position = at
	eff.z_index = int(reg.get("z", 0))
	eff.play(cfg)
	_live.append(eff)
	# Charged and refunded with the same call, so the running total cannot drift.
	_live_cost += eff.cost()
	_peak_cost = maxi(_peak_cost, _live_cost)
	_last_spawn[id] = _clock
	return eff


## Free enough budget for `want`, by culling the oldest effect strictly less
## important than the one being spawned. Never culls something the player just
## caused to make room for ambience.
func _make_room(want: int, priority: int) -> bool:
	var cap: int = BUDGET[_tier]
	if _live_cost + want <= cap:
		return true
	var guard: int = 0
	while _live_cost + want > cap and guard < 16:
		guard += 1
		var victim: VfxEffect = null
		for e in _live:
			if e.looping or e.priority >= priority:
				continue
			if victim == null or e.age > victim.age:
				victim = e
		if victim == null:
			return false
		victim.stop()
	return _live_cost + want <= cap


func _count_live(id: StringName) -> int:
	var n: int = 0
	var arr: Array = _pool.get(id, [])
	for e in arr:
		if e.is_playing():
			n += 1
	return n


func _acquire(id: StringName, reg: Dictionary) -> VfxEffect:
	# `_pool.get(id)` returns Nil for a missing key, and assigning Nil to a typed
	# Array is a hard error — so the null check below never got the chance to
	# run, the pool stayed empty, and every spawn leaked a fresh node.
	if not _pool.has(id):
		_pool[id] = []
	var arr: Array = _pool[id]
	for e in arr:
		if not e.is_playing():
			return e
	var script: Script = _scripts.get(id)
	if script == null:
		var path: String = reg.get("script", "")
		if not ResourceLoader.exists(path):
			Log.error("VfxDirector", "effect script missing: %s" % path)
			return null
		script = load(path)
		_scripts[id] = script
	var inst: VfxEffect = script.new()
	inst.name = String(id)
	inst.finished.connect(_on_effect_finished)
	add_child(inst)
	inst.visible = false
	arr.append(inst)
	return inst


func _on_effect_finished(eff: VfxEffect) -> void:
	_live.erase(eff)
	_live_cost = maxi(0, _live_cost - eff.cost())


# --- ambience ----------------------------------------------------------------

func _process(delta: float) -> void:
	_clock += delta
	for pet_id in _anchors:
		_tend(pet_id, _anchors[pet_id])


## Ambient effects are held open per pet rather than spawned per event, so they
## can breathe with the time of day instead of restarting.
func _tend(pet_id: StringName, a: Anchor) -> void:
	if not is_instance_valid(a.node):
		return
	var at: Vector2 = a.node.global_position

	if _tier >= 1:
		if a.motes == null or not a.motes.is_playing():
			a.motes = spawn(&"motes", at, {
				"area": Vector2(a.width * 2.4, a.radius * 2.6),
				"count": 12,
			})
		else:
			a.motes.global_position = at
			a.motes.params["gain"] = 2.6 if _clock < a.motes_boost_until else 1.0
	if _tier >= 2 and a.exposure > 0.05:
		if a.ray == null or not a.ray.is_playing():
			a.ray = spawn(&"god_ray", at, {"radius": a.radius, "exposure": a.exposure})
		else:
			a.ray.global_position = at
			a.ray.params["exposure"] = a.exposure

	# Shed fur: rare, irregular, and never on a round number of seconds.
	if _clock >= a.next_shed:
		a.next_shed = _clock + randf_range(14.0, 38.0)
		spawn(&"shed_fur", at + Vector2(0.0, -a.radius * 0.35),
			{"coat": a.coat, "width": a.width})

	# Breath is only visible when it is cold enough to condense.
	if light.chill > 0.25 and _clock >= a.next_breath:
		a.next_breath = _clock + randf_range(2.6, 4.4)
		spawn(&"breath", at + Vector2(a.facing * a.radius * 0.8, -a.radius * 0.9),
			{"facing": a.facing, "strength": 0.6 + light.chill * 0.6})

	# A wet coat drips on its own until it dries.
	if a.wetness > 0.12 and _clock >= a.next_drip:
		a.next_drip = _clock + randf_range(0.5, 1.4) / maxf(a.wetness, 0.2)
		spawn(&"droplet_shed", at + Vector2(0.0, -a.radius * 0.15),
			{"wetness": a.wetness, "width": a.width})


# --- direct API for the creature and brain layers ----------------------------
#
# These exist because the motion moments that matter most to this layer —
# footfalls, landings, takeoffs, shaking off water — have no signal on the bus
# yet. Calling them directly is the supported path; if the bus grows matching
# signals later, `_connect_bus` picks them up and these stay as the manual
# entry points.

## A paw hit the ground. `speed` is normalised against the species' run speed.
func footfall(pet_id: StringName, at: Vector2, speed: float, facing: float = 1.0) -> void:
	if not VfxFootfallPuff.wanted(speed):
		return
	var a: Anchor = _anchors.get(pet_id)
	spawn(&"footfall", at, {
		"speed": speed, "facing": facing,
		"ground": a.ground if a != null else Color(0.46, 0.42, 0.38),
	})


## The whole body hit the ground. `velocity` is in pixels per second.
func landed(pet_id: StringName, at: Vector2, velocity: Vector2) -> void:
	var a: Anchor = _anchors.get(pet_id)
	var impact: float = clampf(absf(velocity.y) / 620.0, 0.1, 2.0)
	spawn(&"landing_dust", at, {
		"impact": impact, "velocity": velocity,
		"width": a.width if a != null else 90.0,
		"ground": a.ground if a != null else Color(0.46, 0.42, 0.38),
	})
	if a != null and a.wetness > 0.3:
		spawn(&"droplet_shed", at + Vector2(0.0, -a.radius * 0.4),
			{"wetness": a.wetness, "width": a.width})


func took_off(pet_id: StringName, at: Vector2, velocity: Vector2) -> void:
	var a: Anchor = _anchors.get(pet_id)
	spawn(&"jump_smear", at, {
		"velocity": velocity,
		"radius": a.radius if a != null else 70.0,
	})
	spawn(&"landing_dust", at, {
		"impact": clampf(velocity.length() / 900.0, 0.15, 1.0),
		"velocity": -velocity * 0.4,
		"width": a.width if a != null else 90.0,
		"ground": a.ground if a != null else Color(0.46, 0.42, 0.38),
	})


func shake_off(pet_id: StringName, at: Vector2, power: float = 1.0) -> void:
	var a: Anchor = _anchors.get(pet_id)
	spawn(&"shake_spray", at, {
		"power": power,
		"radius": a.radius if a != null else 40.0,
		"facing": a.facing if a != null else 1.0,
	})
	if a != null:
		# Shaking is how an animal gets dry. Spending most of the wetness here
		# is what makes the action feel like it accomplished something.
		a.wetness = maxf(0.0, a.wetness - 0.55 * power)


## Ask for an emotion directly. `glyph` is a `VfxEmotionBubble.Glyph`.
func emote(pet_id: StringName, glyph: int, count: int = -1) -> VfxEffect:
	var a: Anchor = _anchors.get(pet_id)
	var at: Vector2 = anchor_position(pet_id)
	var head: float = (a.radius if a != null else 70.0) * 1.15
	var cfg := {"glyph": glyph}
	if count > 0:
		cfg["count"] = count
	return spawn(&"emotion", at + Vector2(0.0, -head), cfg)


## The player is touching the pet. `at` is a screen position, `dir` the cursor's
## travel this frame, `strength` how firm the contact is.
func touch(pet_id: StringName, at: Vector2, dir: Vector2 = Vector2.ZERO,
		strength: float = 1.0) -> void:
	var a: Anchor = _anchors.get(pet_id)
	if a != null:
		a.last_touch = at
		if dir.length_squared() > 1e-4:
			a.stroke_dir = dir.normalized()
	spawn(&"stroke_ripple", at, {"strength": strength, "dir": dir})
	spawn(&"touch_dust", at, {
		"strength": strength, "dir": dir,
		"coat": a.coat if a != null else Color(0.44, 0.35, 0.29),
	})


# --- bus handlers ------------------------------------------------------------

func _on_settings_changed(_key: StringName) -> void:
	_read_settings()


## `local` arrives in rig units; the anchor knows the scale that turns those
## into pixels. Falls back to treating them as pixels when no anchor is
## registered, which is wrong but visible rather than silent.
func _on_pet_touched(pet_id: StringName, _region: StringName, local: Vector2) -> void:
	var a: Anchor = _anchors.get(pet_id)
	var at: Vector2 = anchor_position(pet_id)
	if a != null and is_instance_valid(a.node):
		at = a.node.to_global(local * a.px_per_unit)
	touch(pet_id, at, Vector2.ZERO, 1.0)


func _on_pet_stroked(pet_id: StringName, _region: StringName, speed: float) -> void:
	var a: Anchor = _anchors.get(pet_id)
	var at: Vector2 = a.last_touch if a != null else anchor_position(pet_id)
	var dir: Vector2 = a.stroke_dir if a != null else Vector2(-1.0, 0.0)
	# Cooldowns in `EFFECTS` do the rate limiting; a stroke signal can arrive
	# every frame and most of them are supposed to be dropped.
	spawn(&"stroke_ripple", at, {
		"strength": clampf(0.45 + speed * 0.5, 0.3, 1.3), "dir": dir,
	})
	if speed > 0.35:
		spawn(&"touch_dust", at, {
			"strength": clampf(speed, 0.3, 1.2), "dir": dir,
			"coat": a.coat if a != null else Color(0.44, 0.35, 0.29),
		})


func _on_pet_grabbed(pet_id: StringName) -> void:
	emote(pet_id, VfxEmotionBubble.Glyph.EXCLAIM, 1)


func _on_pet_released(pet_id: StringName, velocity: Vector2) -> void:
	if velocity.length() > 140.0:
		took_off(pet_id, anchor_position(pet_id), velocity)


func _on_pet_fed(pet_id: StringName, _food_id: StringName) -> void:
	emote(pet_id, VfxEmotionBubble.Glyph.HEART, 2)


func _on_pet_played_with(pet_id: StringName, _toy_id: StringName) -> void:
	emote(pet_id, VfxEmotionBubble.Glyph.NOTE)


## Only a real gain emotes. Affection drifts constantly, and a heart every time
## it ticks up by a thousandth is the fastest way to make the number meaningless.
func _on_affection_changed(pet_id: StringName, _value: float, delta: float) -> void:
	if delta >= 0.03:
		emote(pet_id, VfxEmotionBubble.Glyph.HEART, 2 if delta < 0.08 else 3)


func _on_mood_changed(pet_id: StringName, mood: StringName) -> void:
	if MOOD_GLYPHS.has(mood):
		emote(pet_id, MOOD_GLYPHS[mood])


func _on_need_critical(pet_id: StringName, _need: StringName) -> void:
	emote(pet_id, VfxEmotionBubble.Glyph.EXCLAIM, 1)


func _on_stage_advanced(pet_id: StringName, _stage: int) -> void:
	_celebrate(pet_id)


func _on_milestone_unlocked(pet_id: StringName, _milestone_id: StringName) -> void:
	_celebrate(pet_id)


func _celebrate(pet_id: StringName) -> void:
	emote(pet_id, VfxEmotionBubble.Glyph.HEART, 3)
	var a: Anchor = _anchors.get(pet_id)
	if a != null:
		# Borrow the ambient motes for a few seconds rather than spawning a
		# confetti system. The room brightens; that is enough, and it costs
		# nothing that was not already on screen.
		a.motes_boost_until = _clock + 2.5


func _on_pet_vocalised(pet_id: StringName, call_id: StringName, intensity: float) -> void:
	if intensity > 0.35 and SINGING_CALLS.has(call_id):
		emote(pet_id, VfxEmotionBubble.Glyph.NOTE)


func _on_pet_reached_ledge(pet_id: StringName, _ledge_id: int) -> void:
	landed(pet_id, anchor_position(pet_id), Vector2(0.0, 320.0))


# --- diagnostics -------------------------------------------------------------

## One line for the debug overlay: what the layer is currently spending.
func stats() -> Dictionary:
	return {
		"tier": _tier,
		"calm": _calm,
		"live": _live.size(),
		"cost": _live_cost,
		"peak": _peak_cost,
		"budget": BUDGET[_tier],
		"pooled": _pool.size(),
	}
