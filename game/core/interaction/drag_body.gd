class_name DragBody
extends RefCounted

## Picking the pet up, and putting it down.
##
## Dangling an animal from a cursor is the interaction most likely to break the
## illusion, because everyone knows exactly what a held cat looks like. So this
## is a real pendulum rather than a lerp: the body hangs from wherever it was
## grabbed, swings with the hand's acceleration, struggles at a rate set by how
## much it trusts you, and — for anything agile enough — rights itself on the
## way down and lands on its feet.
##
## The simulation is pure: it owns no nodes and reads only `DesktopBridge` for
## the ground. The router feeds it a cursor and reads back a position and a
## rotation, which means it can be tested headlessly and reused by whatever ends
## up owning the body.

const DB := preload("res://autoload/desktop_bridge.gd")

enum Phase { IDLE, HELD, FALLING, LANDED }

## Screen pixels per second squared. Tuned against the pet's own scale rather
## than reality: real gravity on a 120px animal looks like it is falling through
## treacle.
const GRAVITY := 2400.0
## Velocity lost per second in the air.
const AIR_DRAG := 1.1
## Pendulum damping, and how hard the hand's acceleration swings the body.
const SWING_DAMPING := 2.2
const HAND_COUPLING := 0.9
## Fastest a throw can be; beyond this the player is flinging, not placing.
const MAX_THROW := 2000.0
## Vertical speed at which a landing is as bad as it gets.
const IMPACT_SPEED := 1500.0
## Rotation within this many radians of upright counts as landing on its feet.
const UPRIGHT_TOLERANCE := 0.45

var phase: Phase = Phase.IDLE

## Screen-space position of the rig origin (between the paws).
var position := Vector2.ZERO
var velocity := Vector2.ZERO
## Body rotation in radians; 0 is standing upright.
var rotation := 0.0
var angular_velocity := 0.0

## Pendulum angle from straight-down, and its rate.
var swing := 0.0
var swing_velocity := 0.0

## 0 = limp, 1 = fighting. Drives the rig's thrash and the audio.
var struggle := 0.0
## Builds while held; a distressed animal rights itself worse and costs trust.
var distress := 0.0
## Set on landing.
var impact := 0.0
var upright := true

## Rig-space point the hand has hold of, and the body's centre of mass.
var grab_rig := Vector2.ZERO
var com_rig := Vector2(0.0, -0.5)
var pixels_per_unit := 180.0
## Species righting ability; see `configure`.
var agility := 1.0
## Wing-assisted descent: birds do not fall, they land.
var can_fly := false

var _trust := 0.5
var _energy := 0.5
var _skittish := 0.4
var _next_struggle := 0.0
var _held_for := 0.0
var _cursor_velocity := Vector2.ZERO
var _fall_time := 0.0


## Bind to a species and a particular pet. `com` and `px` come from `BodyMap`,
## which already knows the grown body.
func configure(spec: CreatureSpec, growth: float, trust: float,
		personality: Dictionary, com: Vector2, px: float) -> void:
	com_rig = com
	pixels_per_unit = maxf(px, 1.0)
	_trust = clampf(trust, 0.0, 1.0)
	_energy = float(personality.get(&"energy", 0.5))
	_skittish = float(personality.get(&"skittishness", 0.4))
	can_fly = spec != null and spec.can_fly

	# How well this animal turns in the air. A cat is the benchmark; a lizard
	# essentially cannot, and a baby of any species is hopeless at it.
	agility = 0.85
	if spec != null:
		if spec.can_fly:
			agility = 1.7
		elif spec.locomotion == CreatureSpec.Locomotion.SPRAWLING:
			agility = 0.45
		elif spec.can_climb:
			agility = 1.35
		elif spec.locomotion == CreatureSpec.Locomotion.BIPED_HOP:
			agility = 1.0
	agility *= lerpf(0.55, 1.0, clampf(growth / 3.0, 0.0, 1.0))


func grab(at_rig: Vector2, cursor: Vector2) -> void:
	phase = Phase.HELD
	grab_rig = at_rig
	swing = 0.0
	swing_velocity = 0.0
	struggle = 0.0
	distress = 0.0
	impact = 0.0
	_held_for = 0.0
	_fall_time = 0.0
	_next_struggle = _struggle_interval()
	_apply_hang(cursor)


func update(delta: float, cursor: Vector2, cursor_velocity: Vector2, rng: RandomNumberGenerator) -> void:
	match phase:
		Phase.HELD:
			_update_held(delta, cursor, cursor_velocity, rng)
		Phase.FALLING:
			_update_falling(delta)
		_:
			pass


func release(cursor_velocity: Vector2) -> void:
	if phase != Phase.HELD:
		return
	phase = Phase.FALLING
	_fall_time = 0.0
	velocity = cursor_velocity.limit_length(MAX_THROW)
	# Carry the swing into a real tumble, so a pet let go mid-arc spins.
	var lever: float = maxf((com_rig - grab_rig).length() * pixels_per_unit, 1.0)
	angular_velocity = clampf(swing_velocity, -14.0, 14.0)
	velocity += Vector2(cos(swing + PI * 0.5), sin(swing + PI * 0.5)) \
		* swing_velocity * lever * 0.25


# --- Held --------------------------------------------------------------------

func _update_held(delta: float, cursor: Vector2, cursor_velocity: Vector2,
		rng: RandomNumberGenerator) -> void:
	_held_for += delta

	# Pendulum about the grab point. L is the distance from the hand to the
	# centre of mass, so being held by the scruff swings slowly and being held
	# by the tail swings fast and badly — which is correct.
	var lever: float = maxf((com_rig - grab_rig).length() * pixels_per_unit, 8.0)
	var hand_accel: Vector2 = (cursor_velocity - _cursor_velocity) / maxf(delta, 0.0001)
	_cursor_velocity = cursor_velocity

	var accel: float = -(GRAVITY / lever) * sin(swing)
	accel -= SWING_DAMPING * swing_velocity
	# Moving the hand sideways throws the body the other way.
	accel -= HAND_COUPLING * (hand_accel.x / lever) * cos(swing)

	# Struggling. A pet that trusts you goes limp — the scruff reflex — and one
	# that does not fights, harder the more wound up it is.
	_next_struggle -= delta
	if _next_struggle <= 0.0:
		_next_struggle = _struggle_interval()
		var power: float = (0.35 + 0.9 * (1.0 - _trust)) * (0.5 + 0.7 * _energy)
		power *= 0.6 + 0.8 * distress
		swing_velocity += rng.randf_range(-1.0, 1.0) * power * 5.0
		struggle = clampf(struggle + power, 0.0, 1.0)
	struggle = maxf(0.0, struggle - delta * 1.4)

	swing_velocity += accel * delta
	swing = clampf(swing + swing_velocity * delta, -PI * 0.85, PI * 0.85)

	# Being held is stressful in proportion to how little it was wanted.
	distress = clampf(distress + delta * (0.03 + 0.22 * (1.0 - _trust)
		+ 0.10 * _skittish), 0.0, 1.0)

	_apply_hang(cursor)


## Place the body so that the grab point sits under the hand and the centre of
## mass hangs below it at the current swing angle.
func _apply_hang(cursor: Vector2) -> void:
	var d: Vector2 = com_rig - grab_rig
	if d.length_squared() < 1e-8:
		d = Vector2(0.0, -0.4)
	# The rig direction from hand to centre of mass must end up pointing down,
	# plus whatever the pendulum is doing.
	rotation = (PI * 0.5 + swing) - d.angle()
	position = cursor + (-grab_rig * pixels_per_unit).rotated(rotation)


func _struggle_interval() -> float:
	# A trusting, calm animal may never struggle at all; a frightened one
	# thrashes about twice a second.
	var rate: float = 0.15 + 2.0 * (1.0 - _trust) * (0.4 + 0.6 * _energy)
	return 1.0 / maxf(rate, 0.05)


# --- Falling -----------------------------------------------------------------

func _update_falling(delta: float) -> void:
	_fall_time += delta
	velocity.y += GRAVITY * delta
	velocity = velocity.lerp(Vector2.ZERO, clampf(AIR_DRAG * delta, 0.0, 1.0))

	if can_fly and _fall_time > 0.18:
		# Wings. A dropped bird does not fall, it objects and then glides down.
		velocity.y = minf(velocity.y, 110.0)
		velocity.x = lerpf(velocity.x, 0.0, clampf(3.0 * delta, 0.0, 1.0))

	# The righting reflex: rotate toward upright at a rate set by agility, and
	# damp the tumble as it goes. A distressed animal rights itself worse, which
	# is why dropping a pet that already hates being held goes badly.
	var righting: float = 7.0 * agility * (1.0 - 0.55 * distress)
	angular_velocity = lerpf(angular_velocity, 0.0, clampf(righting * delta * 0.5, 0.0, 1.0))
	rotation += angular_velocity * delta
	rotation = lerp_angle(rotation, 0.0, clampf(righting * delta, 0.0, 1.0))

	var next: Vector2 = position + velocity * delta
	# Probe from where the body *is*, not from where it is about to be: a fast
	# fall covers 30 px a frame, and a ledge one pixel above the predicted point
	# has already stopped being "below" it. Probing ahead makes a falling pet
	# tunnel straight through the floor.
	var ground: float = _ground_y(Vector2(next.x, position.y))
	if next.y >= ground:
		position = Vector2(next.x, ground)
		_land()
		return
	position = next


func _ground_y(at: Vector2) -> float:
	var l: DB.Ledge = DesktopBridge.ground_below(at)
	if l != null:
		return l.top_y()
	return DesktopBridge.work_area.end.y


func _land() -> void:
	phase = Phase.LANDED
	impact = clampf(absf(velocity.y) / IMPACT_SPEED, 0.0, 1.0)
	upright = absf(wrapf(rotation, -PI, PI)) <= UPRIGHT_TOLERANCE
	if not upright:
		# A bad landing hurts more than a fast one.
		impact = clampf(impact + 0.25, 0.0, 1.0)
	velocity = Vector2.ZERO
	angular_velocity = 0.0
	rotation = 0.0
	swing = 0.0
	swing_velocity = 0.0
	struggle = 0.0


func is_active() -> bool:
	return phase == Phase.HELD or phase == Phase.FALLING


func reset() -> void:
	phase = Phase.IDLE
	velocity = Vector2.ZERO
	angular_velocity = 0.0
	rotation = 0.0
	struggle = 0.0
	distress = 0.0
