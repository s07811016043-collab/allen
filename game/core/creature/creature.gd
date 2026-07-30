class_name Creature
extends Node2D

## One living pet in the world.
##
## Owns the four things that make a creature: the persistent record, the species
## spec, the renderer that draws its implicit body, and the rig that moves it.
## Its whole job is to tick those in the right order and to expose a surface the
## other systems can drive without knowing any of it.
##
## Deliberately decoupled. The brain decides *where* and *what*; this node
## decides *how the body does it*. Nav supplies a path and reads
## `arrived_at_target`; audio listens for `footfall`; the input layer asks
## `region_at`. None of them touch the rig, the skeleton or the parts.
##
## Rig space is the local space of this node: +x forward, +y down, origin between
## the paws on the ground plane, 1.0 ≈ adult shoulder height. Facing is a scale
## flip on x, so a creature walking left is the same rig mirrored.

## A foot hit the ground. `slot` indexes `Gait`'s feet, `force` is in [0, 1.6].
signal footfall(slot: int, force: float)
## `move_to` finished, either by arriving or by being cancelled.
signal arrived_at_target()
## A reaction animation finished, so the brain can resume what it was doing.
signal reaction_finished(reaction: StringName)

const Rig := preload("res://core/rig/rig.gd")
const RigBones := preload("res://core/rig/bone_map.gd")

## How close counts as arrived, in rig units.
const ARRIVE_EPS := 0.05
## Steering: how fast the creature can change speed and heading. A pet that
## snaps to full speed reads as weightless.
const ACCEL := 5.5
const BRAKE := 8.5
const TURN_RATE := 7.0

var record: GameState.PetRecord
var spec: CreatureSpec
var renderer: CreatureRenderer
var rig: CreatureRig

## Continuous growth actually being rendered. Changing it re-fits the skeleton,
## because a kitten and an adult are different skeletons, not different scales.
var growth_value := 3.0
## Desired ground speed in rig units/s; the rig derives its gait from it.
var speed := 0.0
## +1 facing right, -1 facing left.
var facing := 1.0
## Shading state the brain and world write directly.
var wetness := 0.0
var fluff := 1.0
var emotion_flush := 0.0

var _bind_parts: Array[SDFPart] = []
var _bind_eyes: Array = []
var _growth_built := -1.0
var _target := Vector2.INF
var _target_speed := 0.0
var _reaction := &""
var _reaction_left := 0.0
var _facing_blend := 1.0
var _seed := 0


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

## Bind to a saved pet. The usual entry point in the shipping game.
func setup(p_record: GameState.PetRecord) -> void:
	record = p_record
	var s := GameState.spec_for(record.species)
	if s == null:
		Log.error("Creature", "no spec for species '%s'" % record.species)
		return
	setup_preview(s, record.growth, record.variant_seed)


## Bind to a spec directly, with no save record. Used by the capture harness and
## by the adoption screen, which both need a body before a pet exists.
func setup_preview(p_spec: CreatureSpec, p_growth: float, seed_value: int = 0) -> void:
	spec = p_spec
	growth_value = p_growth
	_seed = seed_value
	if not is_inside_tree():
		# The renderer only has a shader material once it has entered the tree,
		# so finish the moment we do.
		if not ready.is_connected(_finish_setup):
			ready.connect(_finish_setup, CONNECT_ONE_SHOT)
		return
	_finish_setup()


func _finish_setup() -> void:
	if renderer == null:
		renderer = CreatureRenderer.new()
		renderer.name = "Renderer"
		add_child(renderer)
		# CreatureRenderer packs its uniforms in _process; as our child it runs
		# after us in tree order, so it always sees this frame's pose.
		renderer.setup(spec)
	_rebuild(growth_value, _seed)


func _rebuild(p_growth: float, seed_value: int) -> void:
	_bind_parts.clear()
	for p in spec.parts:
		if p != null:
			_bind_parts.append(p.duplicate_part())
	if _bind_parts.size() > CreatureRenderer.MAX_PARTS:
		_bind_parts.resize(CreatureRenderer.MAX_PARTS)
	Growth.apply(spec, _bind_parts, p_growth)

	_bind_eyes.clear()
	for e in spec.eyes:
		if e == null:
			continue
		var live := EyeSpec.Live.new()
		live.copy_from(e)
		_bind_eyes.append(live)
	if _bind_eyes.size() > CreatureRenderer.MAX_EYES:
		_bind_eyes.resize(CreatureRenderer.MAX_EYES)
	Growth.apply_eyes(spec, _bind_eyes, p_growth, _bind_parts)

	# The renderer's live arrays start as a copy of the bind pose, so a creature
	# is drawn correctly on its very first frame, before the rig has ticked.
	for i in mini(renderer.live_parts.size(), _bind_parts.size()):
		_copy_part(_bind_parts[i], renderer.live_parts[i])
	for i in mini(renderer.live_eyes.size(), _bind_eyes.size()):
		_copy_eye(_bind_eyes[i], renderer.live_eyes[i])

	rig = Rig.new()
	rig.setup(spec, _bind_parts, _bind_eyes, seed_value)
	rig.settle()
	_growth_built = p_growth
	growth_value = p_growth


func _process(delta: float) -> void:
	tick(delta)


## One frame of body simulation. Public and separate from `_process` so the
## capture harness can drive a creature at a fixed step, and so a paused world
## can still advance a single pet.
func tick(delta: float) -> void:
	if spec == null or rig == null:
		return
	if record != null and absf(record.growth - _growth_built) > 0.004:
		_rebuild(record.growth, record.variant_seed)
	elif absf(growth_value - _growth_built) > 0.004:
		_rebuild(growth_value, record.variant_seed if record != null else 0)

	_advance_locomotion(delta)
	_advance_reaction(delta)

	rig.speed = speed
	rig.advance(delta)
	_emit_footfalls()
	rig.write(_bind_parts, renderer.live_parts, _bind_eyes, renderer.live_eyes)
	renderer.set_shading_state(_growth_built, wetness,
		fluff * lerpf(1.0, 0.88, rig.gait.exertion), emotion_flush)


# ---------------------------------------------------------------------------
# Locomotion
# ---------------------------------------------------------------------------

func _advance_locomotion(dt: float) -> void:
	var desired := _target_speed
	var heading := Vector2(facing, 0.0)
	if _target != Vector2.INF:
		var to_target: Vector2 = _target - position
		var dist: float = to_target.length() / maxf(spec.pixels_per_unit, 1.0)
		if dist <= ARRIVE_EPS:
			_target = Vector2.INF
			desired = 0.0
			arrived_at_target.emit()
		else:
			# Ease into the last stride rather than stopping dead on the mark.
			desired = _target_speed * clampf(dist / (spec.stride * 1.5), 0.15, 1.0)
			heading = to_target.normalized()
			if absf(to_target.x) > 1.0:
				facing = signf(to_target.x)

	var rate: float = ACCEL if desired > speed else BRAKE
	speed = move_toward(speed, desired, rate * dt)

	# Facing flips by easing the x scale through zero, which reads as the animal
	# turning away from camera rather than as a mirror snap. The rate of that
	# flip *is* the turn rate the rig banks and bends the spine against.
	var before := _facing_blend
	_facing_blend = move_toward(_facing_blend, facing, TURN_RATE * dt)
	rig.turn_rate = clampf((_facing_blend - before) / maxf(dt, 1e-4) * 0.25, -2.0, 2.0)
	scale.x = _facing_blend if absf(_facing_blend) > 0.06 else 0.06 * signf(facing)

	if speed > 0.02:
		# Travel along the ground. The rig plants feet against distance covered,
		# so this and the gait can never disagree about how far the body moved.
		position += heading * speed * spec.pixels_per_unit * dt


func _emit_footfalls() -> void:
	for f in rig.gait.feet:
		if f.just_landed:
			footfall.emit(f.slot, f.landing_force)


# ---------------------------------------------------------------------------
# Brain-facing API
# ---------------------------------------------------------------------------

## Walk to a point in this node's parent space. `pace` in [0, 1] picks between
## the species' walking and running speed; the rig chooses the gait.
func move_to(target: Vector2, pace: float = 0.35) -> void:
	_target = target
	_target_speed = lerpf(spec.walk_speed, spec.run_speed, clampf(pace, 0.0, 1.0))


func stop() -> void:
	if _target != Vector2.INF:
		_target = Vector2.INF
		arrived_at_target.emit()
	_target_speed = 0.0


## Force a locomotion pattern regardless of speed: `idle`, `walk`, `trot`,
## `run`, `hop`. Pass `&""` to hand control back to the speed-derived choice.
## Mostly for the capture harness and for scripted moments.
func set_gait(gait_name: StringName) -> void:
	var kind := -1
	match gait_name:
		&"idle": kind = Gait.Kind.IDLE
		&"walk": kind = Gait.Kind.WALK
		&"trot": kind = Gait.Kind.TROT
		&"run": kind = Gait.Kind.RUN
		&"hop": kind = Gait.Kind.HOP
	rig.gait_override = kind
	if kind < 0:
		return
	# Drive the body at the speed that pattern is actually meant for, so foot
	# planting stays exact instead of the feet skating under a forced cadence.
	speed = _speed_for_gait(kind)
	_target_speed = speed
	rig.speed = speed
	rig.gait.speed = speed
	rig.gait.set_kind(kind)


func _speed_for_gait(kind: int) -> float:
	match kind:
		Gait.Kind.WALK: return spec.walk_speed
		Gait.Kind.TROT: return lerpf(spec.walk_speed, spec.run_speed, 0.42)
		Gait.Kind.RUN: return spec.run_speed
		Gait.Kind.HOP: return lerpf(spec.walk_speed, spec.run_speed, 0.55)
	return 0.0


## Look at a point in this node's parent space. Named `look_at_point` rather than
## `look_at` because `Node2D.look_at` already exists and rotates the whole node,
## which is emphatically not what a creature should do.
func look_at_point(world_point: Vector2) -> void:
	rig.look_target = to_local(world_point) / maxf(spec.pixels_per_unit, 1.0)


func clear_look() -> void:
	rig.look_target = Vector2.INF


## Point the ears at a sound coming from `world_point`.
func hear(world_point: Vector2, strength: float = 1.0) -> void:
	rig.hear(to_local(world_point).normalized(), strength)


## One-shot body reactions. Short, physical, and non-blocking: the creature keeps
## walking through a `blink` but not through a `startle`.
func play_reaction(reaction: StringName, intensity: float = 1.0) -> void:
	var k: float = clampf(intensity, 0.0, 2.0)
	match reaction:
		&"startle":
			rig.squash.startle(k)
			rig.idle.trigger_blink(true)
			rig.tension = 1.0
			rig.set_tail_carry(-0.8)
			_reaction_left = 0.9
		&"land":
			rig.squash.land(k * 1.2)
			_reaction_left = 0.4
		&"jump":
			rig.squash.jump(k)
			_reaction_left = 0.4
		&"perk":
			rig.tension = clampf(k, 0.0, 1.0)
			rig.set_tail_carry(0.6)
			_reaction_left = 1.2
		&"blink":
			rig.idle.trigger_blink(k > 0.7)
			_reaction_left = 0.3
		&"shake":
			# A wet-dog shake: alternating squash with the tail thrown wide.
			rig.squash.startle(k * 0.6)
			rig.set_tail_carry(0.9)
			_reaction_left = 0.7
		_:
			Log.warn("Creature", "unknown reaction '%s'" % reaction)
			return
	_reaction = reaction


func _advance_reaction(dt: float) -> void:
	if _reaction_left <= 0.0:
		return
	_reaction_left -= dt
	if _reaction_left > 0.0:
		return
	rig.tension = 0.0
	rig.set_tail_carry(0.0)
	reaction_finished.emit(_reaction)
	_reaction = &""


# ---------------------------------------------------------------------------
# Hit testing
# ---------------------------------------------------------------------------

## Which body region a point in the parent's space lands on, or `&""` if the
## point misses the creature. Regions are coarse on purpose — a player pets "the
## head", not "the left zygomatic".
func region_at(world_point: Vector2) -> StringName:
	var local: Vector2 = to_local(world_point) / maxf(spec.pixels_per_unit, 1.0)
	var best := &""
	var best_d := INF
	for i in renderer.live_parts.size():
		var p: SDFPart = renderer.live_parts[i]
		var d: float = _capsule_distance(local, p)
		if d < best_d:
			best_d = d
			best = _region_of(i)
	# A small grace margin: fingers are imprecise and fur has no hard edge.
	return best if best_d <= 0.03 else &""


func contains_point(world_point: Vector2) -> bool:
	return region_at(world_point) != &""


func _region_of(part_index: int) -> StringName:
	var p: SDFPart = _bind_parts[part_index]
	var tag = RigBones.classify(p.id, int(p.layer))
	return RigBones.region_for(tag.slot, tag.seg)


static func _capsule_distance(p: Vector2, part: SDFPart) -> float:
	var ba: Vector2 = part.b - part.a
	var pa: Vector2 = p - part.a
	var t: float = clampf(pa.dot(ba) / maxf(ba.length_squared(), 1e-7), 0.0, 1.0)
	return (pa - ba * t).length() - lerpf(part.radius_a, part.radius_b, t)


static func _copy_part(src: SDFPart, dst: SDFPart) -> void:
	dst.a = src.a
	dst.b = src.b
	dst.radius_a = src.radius_a
	dst.radius_b = src.radius_b
	dst.blend = src.blend
	dst.height_scale = src.height_scale
	dst.surface = src.surface
	dst.palette_index = src.palette_index
	dst.groom_angle = src.groom_angle
	dst.coat_length = src.coat_length
	dst.layer = src.layer


static func _copy_eye(src: EyeSpec.Live, dst: EyeSpec.Live) -> void:
	dst.center = src.center
	dst.radius = src.radius
	dst.pupil_ratio = src.pupil_ratio
	dst.pupil_slit = src.pupil_slit
