class_name BrainContext
extends RefCounted

## The blackboard every behaviour scores against, and the only thing they are
## allowed to write to.
##
## Two halves. The top half is *senses*: everything the brain knows about the
## pet, the player and the desktop this frame. The bottom half is *intent*: what
## the pet would like its body to do. Behaviours read the first and write the
## second; they never touch the creature, the rig or the renderer directly.
##
## That split is what keeps the AI testable — a headless test can drive several
## simulated days through this object with no scene at all — and what keeps it
## decoupled from the rig, which is being built in parallel.

const GS := preload("res://autoload/game_state.gd")

## What the pet wants its body to be doing. The creature (or, until it exists,
## anything else that cares) reads this every frame and is free to interpret it:
## the brain expresses desire, the rig expresses motion.
class Intent:
	## Id of the behaviour that produced this intent, e.g. &"nap".
	var behaviour: StringName = &"idle"
	## Requested body pose: &"stand", &"sit", &"crouch", &"curl", &"stretch",
	## &"pounce", &"groom", &"beg", &"dangle", &"loaf".
	var pose: StringName = &"stand"
	## Free-form sub-state for the pose, when one pose has variants worth
	## distinguishing: which body part is being groomed, which phase of a
	## startle, how deep a nap is. The rig may ignore it entirely.
	var detail: StringName = &""
	## Screen-space point the pet is walking toward.
	var move_target: Vector2 = Vector2.ZERO
	var has_move_target: bool = false
	## Multiplier on `spec.walk_speed`. Above ~1.8 the gait solver should run.
	var speed_scale: float = 1.0
	## Screen-space point the head and eyes track.
	var look_at: Vector2 = Vector2.ZERO
	var has_look_at: bool = false
	## 0 = drowsy, ears down; 1 = fully alert, pupils wide, ears forward.
	var alertness: float = 0.5
	## -1 tucked under, 0 neutral, +1 up and waving.
	var tail: float = 0.0
	## Whole-body rotation in radians, 0 = standing upright. Only ever non-zero
	## while `behaviour` is &"held": the drag simulation owns the body then, and
	## the rig should follow rather than solve.
	var body_rotation: float = 0.0
	## Facial channels, matching `CreatureRenderer`'s expression uniforms.
	var expression := {
		&"brow_raise": 0.0, &"brow_furrow": 0.0,
		&"mouth_open": 0.0, &"cheek_puff": 0.0, &"eye_open": 1.0,
	}

	func reset_frame() -> void:
		# Movement and gaze are re-asserted every frame by whichever behaviour is
		# running; everything else persists so a behaviour can set a pose once.
		has_move_target = false
		has_look_at = false


# --- Senses ------------------------------------------------------------------

## The pet this brain drives. Never null once the brain is set up.
var record: GS.PetRecord = null
var spec: CreatureSpec = null
## The body, when there is one. Behaviours only ever reach it through `react`;
## everything else goes out as intent.
var creature: Node = null
## Jittered per-pet personality; see `GameState.personality`.
var personality := {
	&"energy": 0.5, &"affection_drive": 0.5, &"curiosity": 0.5, &"skittishness": 0.4,
}

var now: float = 0.0
var dt: float = 0.0
## Local hour of day as a float in [0, 24). Behaviour scoring leans on it hard:
## a cat that naps at 3pm and goes mad at 6am is doing most of the work of
## feeling like a cat.
var hour: float = 12.0

## Screen-space position of the pet's feet.
var position: Vector2 = Vector2.ZERO
## Facing: -1 left, +1 right.
var facing: float = 1.0
## Ledge the pet is currently standing on, or -1.
var ledge_id: int = -1
## &"icon", &"taskbar", &"screen_floor", ... or &"" when airborne/unknown.
var ledge_kind: StringName = &""

var cursor: Vector2 = Vector2.ZERO
var cursor_velocity: Vector2 = Vector2.ZERO
var cursor_speed: float = 0.0
## Seconds since the cursor last moved meaningfully.
var cursor_idle: float = 999.0
## Is anyone actually at the machine right now?
var player_present: bool = false

## Reflex charge, raised by fast movement nearby, bad touches and hard landings.
## Decays fast; the startle behaviour consumes it.
var startle_charge: float = 0.0
## Interest charge, raised when the desktop topology changes.
var novelty: float = 0.0
## Ledge the pet has not investigated yet, or -1.
var novel_ledge: int = -1
## Ledge worth pushing something off, or -1.
var mischief_ledge: int = -1

## True absence in seconds the pet still owes the player a hello for.
var greet_pending: float = 0.0

var held: bool = false
var last_touch_at: float = -999.0
var last_touch_region: StringName = &""
## How much the pet liked the last touch, in [-1, 1].
var last_touch_valence: float = 0.0
## Set when the player waves a toy (or wiggles the cursor like one).
var toy_id: StringName = &""
var toy_at: float = -999.0
var toy_position: Vector2 = Vector2.ZERO

## Shared, seeded per pet so two cats do not idle in lockstep.
var rng := RandomNumberGenerator.new()

# --- Intent ------------------------------------------------------------------

var intent := Intent.new()


# --- Convenience -------------------------------------------------------------

func need(key: StringName) -> float:
	return record.need(key) if record != null else 0.8


func deficit(key: StringName) -> float:
	return record.deficit(key) if record != null else 0.2


func affection() -> float:
	return record.affection if record != null else 0.0


func trust() -> float:
	return record.trust if record != null else 0.0


func stress() -> float:
	return record.stress if record != null else 0.0


func trait_of(key: StringName) -> float:
	return float(personality.get(key, 0.5))


func seconds_since_touch() -> float:
	return now - last_touch_at


## Growth-scaled body height in screen pixels. Behaviours use it for distances
## so a kitten keeps proportionally the same personal space as an adult.
func body_pixels() -> float:
	if spec == null:
		return 120.0
	return spec.adult_height * spec.scale_at(record.growth if record != null else 3.0) \
		* spec.pixels_per_unit


func distance_to(p: Vector2) -> float:
	return position.distance_to(p)


# --- Intent writers ----------------------------------------------------------

func move_to(target: Vector2, speed_scale: float = 1.0) -> void:
	intent.move_target = target
	intent.has_move_target = true
	intent.speed_scale = speed_scale


func stop() -> void:
	intent.has_move_target = false
	intent.speed_scale = 0.0


func look_at_point(p: Vector2) -> void:
	intent.look_at = p
	intent.has_look_at = true


func set_pose(p: StringName, detail: StringName = &"") -> void:
	intent.pose = p
	intent.detail = detail


func set_face(alertness: float, tail: float, brow_raise: float = 0.0,
		brow_furrow: float = 0.0, mouth_open: float = 0.0, eye_open: float = 1.0) -> void:
	intent.alertness = clampf(alertness, 0.0, 1.0)
	intent.tail = clampf(tail, -1.0, 1.0)
	intent.expression[&"brow_raise"] = clampf(brow_raise, 0.0, 1.0)
	intent.expression[&"brow_furrow"] = clampf(brow_furrow, 0.0, 1.0)
	intent.expression[&"mouth_open"] = clampf(mouth_open, 0.0, 1.0)
	intent.expression[&"eye_open"] = clampf(eye_open, 0.0, 1.0)


func arrived(radius: float = 18.0) -> bool:
	if not intent.has_move_target:
		return true
	return position.distance_to(intent.move_target) <= radius


## Fire a one-shot body reaction on the rig: &"startle", &"land", &"jump",
## &"perk", &"blink", &"shake". Guarded, because the creature is built by a
## different agent and may not be present at all.
func react(reaction: StringName, intensity: float = 1.0) -> void:
	if creature != null and creature.has_method("play_reaction"):
		creature.call("play_reaction", reaction, intensity)


## Point the ears at something. Same guard, same reason.
func hear(point: Vector2, strength: float = 1.0) -> void:
	if creature != null and creature.has_method("hear"):
		creature.call("hear", point - Vector2(DisplayServer.window_get_position()), strength)


## Speak. Pitch comes from the spec and the pet's age, so the same call is a
## squeak from a kitten and a proper meow from an adult.
func say(call_id: StringName, intensity: float = 0.6) -> void:
	if record == null:
		return
	var hz := 320.0
	if spec != null:
		var baby: float = spec.babyness_at(record.growth)
		hz = spec.voice_hz * lerpf(1.0, spec.baby_voice_scale, baby)
	AudioDirector.vocalise(record.id, call_id, hz, intensity)
