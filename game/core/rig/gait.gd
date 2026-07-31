class_name Gait
extends RefCounted

## Procedural footfall timing, foot trajectories and body weight shift.
##
## Everything here is derived from one number — how fast the creature is
## actually moving — so the gait can never skate. Step frequency comes out of
## speed and stride length; a foot in stance is pinned to the ground it landed
## on and swept backwards by exactly the distance the body travelled.
##
## Timing is expressed as a phase offset per foot within a normalised cycle,
## plus a duty factor (fraction of the cycle a foot spends on the ground).
## That pair is the whole vocabulary of quadruped gait analysis and it is enough
## to describe every pattern we ship:
##
##   walk   4-beat lateral sequence, diagonal couplets. Footfall order is
##          hind-near, fore-near, hind-far, fore-far — each forefoot follows the
##          hindfoot on its own side, which is what "lateral sequence" means.
##          The couplets are the other half of it: a foot and its *diagonal*
##          partner land about an eighth of a cycle apart (fore-near at 0.38,
##          hind-far at 0.50). Duty 0.62, so at least two feet are always down.
##   trot   2-beat. True diagonal pairs, exactly in antiphase. Duty 0.45, which
##          buys two short suspensions.
##   run    rotary gallop, which is what a cat actually uses. The hind pair lands
##          in quick succession, then the fore pair, and the fore lead is the
##          mirror of the hind lead rather than a repeat of it. Duty 0.32, with a
##          long gathered suspension.
##   hop    both legs together, the ground gait of a perching bird.
##
## Body vertical motion is *not* a sine wave laid on top. It falls out of the
## legs: each supporting foot constrains the hip above it to sit at
## sqrt(reach² − dx²), so the body rises over a vertical leg and sinks at
## footfall. Bob is therefore in phase with the footfalls by construction, and
## stays in phase when the gait, speed or leg proportions change.

const RigBones := preload("res://core/rig/bone_map.gd")

enum Kind { IDLE, WALK, TROT, RUN, HOP }

## Foot slots, matching the order `LegIK.gather` returns.
const FORE_NEAR := 0
const FORE_FAR := 1
const HIND_NEAR := 2
const HIND_FAR := 3
const FOOT_COUNT := 4

## Footfall phase per slot, then duty factor, then `lift` — how much further the
## body travels, up and down and through the feet, than it does at a walk.
## Phase order: fore-near, fore-far, hind-near, hind-far.
const PATTERNS := {
	Kind.WALK: {"phase": [0.62, 0.12, 0.00, 0.50], "duty": 0.62, "lift": 1.00},
	Kind.TROT: {"phase": [0.50, 0.00, 0.00, 0.50], "duty": 0.45, "lift": 1.35},
	Kind.RUN: {"phase": [0.40, 0.49, 0.09, 0.00], "duty": 0.32, "lift": 1.75},
	Kind.HOP: {"phase": [0.00, 0.00, 0.00, 0.00], "duty": 0.42, "lift": 2.10},
}
## A biped walks its two legs in antiphase; the fore slots stay unused.
const BIPED_WALK := {"phase": [0.0, 0.0, 0.00, 0.50], "duty": 0.60, "lift": 1.15}


class Foot:
	var slot := 0
	var present := false
	var phase := 0.0
	var stance := true
	## Rig-space IK target for the ankle.
	var target := Vector2.ZERO
	var pitch := 0.0
	## Height above the ground this leg permits its own limb root to ride at.
	var support := 0.0
	## The same height in the bind pose. Pitch and roll are differentials against
	## it, because a cat's hind legs are simply longer than its forelegs and the
	## raw difference would tilt the animal permanently nose-down.
	var support_ref := 0.0
	## Where in *ground* space the **contact patch** is pinned. Ground space is rig
	## space plus distance travelled, so a pinned foot is exactly stationary.
	var plant_ground := 0.0
	var lift_ground := 0.0
	var bind := Vector2.ZERO
	## Bind-pose offset from the ankle out to the contact patch, and where that
	## patch sits along the floor at rest. Stance solves the contact first and
	## derives the ankle from it, so rolling the foot cannot drag the paw.
	var contact_arm := Vector2.ZERO
	var contact_bind := Vector2.ZERO
	var root_bind := Vector2.ZERO
	var reach := 0.0
	## True on the frame the foot touched down — drives impact squash and audio.
	var just_landed := false
	var landing_force := 0.0


var kind: int = Kind.IDLE
var speed := 0.0
## Distance covered, rig units. Feet are pinned against this, never against time.
var travel := 0.0
var cycle := 0.0
var frequency := 0.0
var duty := 0.62
var feet: Array[Foot] = []

## Body outputs, read by the rig once per frame. All three attitude channels are
## in radians of picture-plane rotation, so the rig applies them directly.
var bob := 0.0
var pitch := 0.0
var roll := 0.0
## Counter-rotation between the pectoral and pelvic girdles: the *total* twist
## across the trunk, which the rig splits half backwards into the croup and half
## forwards into the withers. Positive lifts the withers.
var girdle_twist := 0.0
## Sagittal curvature of the back: total radians of bend shared across the lumbar
## run, positive rounding the topline *up*. Distinct from `pitch`, which rotates
## the trunk rigidly — this is the only channel that changes the trunk's shape,
## and until it existed the torso could only ever translate and tilt, which is
## precisely what a blind reviewer called "furniture being carried".
var flex := 0.0
## Vertical slide of the pectoral girdle over the ribcage, rig units, positive up.
##
## A cat has no clavicle: the shoulder blade is slung in muscle and rides up the
## side of the ribcage every time the limb takes load. From the side that is the
## most conspicuous thing a walking cat's topline does, and it runs at twice the
## stride rate, so it is also the only body channel that is not in lockstep with
## the bob — which is what stops the whole animal reading as one oscillator.
var withers := 0.0
var surge := 0.0
## Lateral body wave for sprawling locomotion, sampled per spine bone.
var undulation := 0.0
var turn := 0.0
## 0 at rest → 1 at full sprint. Drives breathing, coat fluff and audio.
var exertion := 0.0

## Fraction of full leg extension the body rides at when standing. Species author
## bind poses with straight legs because that is how a reference drawing looks,
## but a real animal always stands with the joints slightly flexed — and without
## that reserve the body has nowhere to bob up into, so the feet lift off the
## ground the moment the gait raises it. 5% of leg length is enough.
const STANCE_COMPRESSION := 0.95

## Trunk attitude gains, radians per unit of load asymmetry.
##
## Static geometry cannot produce these and it was a mistake to ask it to. A
## cat's legs are long next to its stride, so the fore and hind support heights
## differ by a couple of hundredths over a whole cycle; the trunk pitch that
## fell out of them measured 0.005 rad peak-to-peak, which is a fifth of a pixel
## at the size this pet actually ships at. An independent reviewer, shown the
## build cold, called the body "furniture being carried along", and that number
## is why.
##
## What pitches a trunk is the *load* handing over between the girdles, and load
## is a phase quantity: already normalised to [0, 1], identical for a kitten and
## an adult, and correct for every pattern in the table without a per-species
## calibration. It also self-checks — at a trot the diagonal pairs make the two
## girdles' loads identical, the imbalance is exactly zero, and a trotting animal
## really does hold its trunk still. That is the gait a rider posts to precisely
## because it does not pitch.
const PITCH_GAIN := 0.72
## Ceiling on trunk pitch. A gallop is often on a single leg and the raw
## imbalance goes past 0.4; 0.13 rad is about 7°, which is a hard-running cat.
const PITCH_MAX := 0.13
## Radians of counter-rotation between the girdles at full asymmetry. Small in
## absolute terms — it is the *opposition* that reads, not the amount.
##
## Sized against the picture rather than against the number. The rig splits the
## twist half backwards into the croup and all of it forwards along the lumbar,
## so the two ends of the trunk end up 1.5x this apart; at 0.064 that measured
## 0.10 rad of opposition, which over the cat's 0.45-unit half-trunk is 2.6 px at
## ship size — right at the floor of what a 260 px frame can show. The channel
## was doing its job and arriving as almost nothing.
const TWIST_GAIN := 0.090
## Whole-body lean from the near/far load split. A strict side view can barely
## show a roll at all, so this stays a hint rather than a statement.
const ROLL_GAIN := 0.022
## Radians of lumbar bend per unit of girdle gather, where one unit is the two
## girdles' feet closing by a whole trunk length.
##
## Driven off the actual gap between the fore and hind contact patches rather
## than off a phase table, which makes it self-scaling in the way that matters:
## at a walk the two feet of a pair are half a cycle apart so the gap barely
## moves and the back stays nearly rigid, while a gallop gathers both pairs under
## the body at once and the back rounds hard. That is the real difference between
## the two gaits and no per-gait constant has to encode it.
const FLEX_GAIN := 1.75
## Ceiling on that bend. A galloping cat's spine really does work through 30°+,
## but the trunk here is three capsules and pushing past this folds them into
## each other instead of arching.
const FLEX_MAX := 0.42
## Scapula travel at full load swing, as a fraction of leg reach.
##
## The most valuable body channel there is at ship size, and the reason is the
## frequency rather than the amplitude: it runs at twice the stride rate, so it
## is the only thing on the trunk that is not in lockstep with the bob, and a
## body whose every channel shares one phase is a body being carried. Measured on
## the cat at 0.30 it delivered 5.0 px of scapula travel against 7.6 px of bob;
## at 0.52 it delivers 8.6 px, which is a shoulder that visibly rides up the
## ribcage twice a stride instead of a topline that only translates.
const WITHERS_GAIN := 0.52

var _spec: CreatureSpec
var _family: int = CreatureSpec.Locomotion.QUADRUPED
## Body height of *this* creature, not of the adult of its species. Every bob
## number in the spec is authored as a fraction of body height, and the rig it is
## applied to has already been scaled by growth — so reading `adult_height`
## straight gave a kitten the adult's absolute bob on a body 0.42 the size, which
## drove a walking kitten nearly four hundredths of a unit into the floor.
var _body_height := 1.0
var _stride_ref := 0.4
var _bob_gain := 1.0
var _body_len := 0.5
## Mean support height over the reference cycle; bob oscillates around it.
var _support_ref := 0.5
## The highest that mean ever gets over the reference cycle. Stands in for it
## during a suspension, when no foot is carrying anything: the trunk is ballistic
## and the honest statement is "as high as this animal's legs ever put it", scaled
## by the pattern's `lift`. Leg reach used to stand in here, which is a length
## rather than a height above the floor — the two agreed closely enough by
## accident to look right, until the support height started counting the ankle,
## and then a galloping cat buried a quarter of a unit of itself in the floor
## every suspension.
var _support_hi := 0.5
## Mean leg reach. Sets the flexion reserve the body bobs into.
var _reach_ref := 0.5
## Constant downward offset that buys the legs their flexion reserve.
var _crouch := 0.0
## Gap between the fore and hind feet in the bind pose. `flex` is a differential
## against it, the same way `pitch` is a differential against `support_ref`: a
## species whose girdles sit unusually close together must not walk permanently
## hunched.
var _span_ref := 0.5
## Slow-followed mean of the fore girdle's load. Subtracting it makes `withers` a
## deviation by construction, so a gait whose duty factor gives the pair a high
## average load does not park the shoulder permanently raised.
var _fore_load_mean := 0.0
## Extra flexion carried once the animal is actually moving, faded in with speed.
var _move_crouch := 0.0


func setup(spec: CreatureSpec, chains: Array, body_scale: float = 1.0) -> void:
	_spec = spec
	_family = spec.locomotion
	_body_height = maxf(spec.adult_height * body_scale, 1e-3)
	feet.clear()
	for i in FOOT_COUNT:
		var f := Foot.new()
		f.slot = i
		if i < chains.size():
			var c: LegIK.Chain = chains[i]
			f.present = c.valid
			f.bind = c.ankle_bind
			f.contact_arm = c.contact_arm
			f.contact_bind = c.contact_bind
			f.root_bind = c.root_bind
			f.reach = maxf(c.reach, 1e-3)
		f.target = f.bind
		var bind_dx: float = f.bind.x - f.root_bind.x
		f.support_ref = -f.bind.y \
			+ sqrt(maxf(f.reach * f.reach - bind_dx * bind_dx, 0.0))
		feet.append(f)

	# A biped has only the hind pair; a quadruped that authored no forelimbs is
	# treated the same way rather than falling over.
	if _family == CreatureSpec.Locomotion.BIPED_HOP:
		feet[FORE_NEAR].present = false
		feet[FORE_FAR].present = false

	var reach_sum := 0.0
	var support_n := 0
	var min_x := INF
	var max_x := -INF
	for f in feet:
		if not f.present:
			continue
		reach_sum += f.reach
		support_n += 1
		min_x = minf(min_x, f.root_bind.x)
		max_x = maxf(max_x, f.root_bind.x)
	_reach_ref = reach_sum / float(maxi(support_n, 1))
	_crouch = _reach_ref * (1.0 - STANCE_COMPRESSION)
	_body_len = maxf(max_x - min_x, 0.2) if support_n > 1 else 0.5
	_span_ref = maxf(_girdle_span(), 0.05)

	# `spec.stride` is the ground distance covered by one full cycle at the
	# comfortable walking speed — the reference point the frequency law below
	# scales from. A foot's stance sweep is that times the duty factor.
	#
	# Scaled by growth, like every other length in this file. Authored at adult
	# size and read literally, a kitten reached an adult's step on legs 0.42 as
	# long: the sweep came to nearly a whole leg length fore and aft, which the
	# body could only pay for by crouching a third of its leg length, and it still
	# drove the paws through the floor.
	_stride_ref = maxf(spec.stride * body_scale, 0.02)
	_bob_gain = 1.0
	_bob_gain = _calibrate_bob(spec)
	settle()


## Find the gain that makes the geometric bob match the authored `spec.bob`.
##
## The raw inverted-pendulum drop is always an overestimate — legs flex under
## load — and averaging four out-of-phase legs damps it much further, by an
## amount that depends entirely on the gait pattern and the animal's
## proportions. Rather than guess a constant, sample one reference walk cycle
## and measure the peak-to-peak directly. Cheap (it runs once per rebuild) and
## it means a long-legged dog and a squat lizard both land on their authored bob.
func _calibrate_bob(spec: CreatureSpec) -> float:
	const SAMPLES := 96
	var pat: Dictionary = BIPED_WALK if _family == CreatureSpec.Locomotion.BIPED_HOP \
		else PATTERNS[Kind.WALK]
	var d := float(pat["duty"])
	var sweep: float = _stride_ref * d
	var lo := INF
	var hi := -INF
	## Deepest the reach constraint will ever push the body during this cycle.
	var ceil_max := -INF
	for s in SAMPLES:
		var c := float(s) / float(SAMPLES)
		var w_sum := 0.0
		var h_sum := 0.0
		for i in FOOT_COUNT:
			var f: Foot = feet[i]
			if not f.present:
				continue
			var ph: float = fposmod(c + float(pat["phase"][i]), 1.0)
			var stance: bool = ph < d
			# Must mirror `_solve_body` exactly, or the gain ends up calibrated
			# against a curve the runtime never produces: stance feet only, the
			# same rolled ankle, and the gathered height whenever the reference
			# cycle has none down.
			if not stance:
				continue
			w_sum += 1.0
			# Stance sweeps the contact back linearly under the body; the ankle is
			# then read off it through the roll, exactly as `_ankle_for` does.
			var st: float = ph / d
			var contact := Vector2(f.contact_bind.x + sweep * (0.5 - st), 0.0)
			var ankle: Vector2 = contact - f.contact_arm.rotated(_stance_pitch(st))
			var dx: float = ankle.x - f.root_bind.x
			var support: float = -ankle.y + sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))
			h_sum += support
			ceil_max = maxf(ceil_max, -f.root_bind.y - support)
		var mean: float = (h_sum / w_sum) if w_sum > 0.0 else _reach_ref
		lo = minf(lo, mean)
		hi = maxf(hi, mean)
	var span: float = hi - lo
	if not is_finite(span) or span < 1e-5:
		return 1.0
	_support_ref = (lo + hi) * 0.5
	_support_hi = hi
	# A foot planted ahead of the hip needs more leg than one straight under it.
	# If the body does not lower to pay for that, the reach constraint in
	# `_solve_body` shears the top off every bob and the authored amplitude never
	# appears — the animal walks with a nearly rigid trunk. So buy exactly the
	# headroom this cycle asks for, plus room for the authored swing, and fade it
	# in with speed: a cat stands tall and walks low, which is the same thing.
	_move_crouch = maxf(ceil_max - _crouch, 0.0) + spec.bob * _body_height
	return clampf((spec.bob * _body_height * 2.0) / span, 0.1, 12.0)


## Snap every foot back to its bind position and zero the cycle.
func settle() -> void:
	cycle = 0.0
	travel = 0.0
	bob = 0.0
	pitch = 0.0
	roll = 0.0
	girdle_twist = 0.0
	flex = 0.0
	withers = 0.0
	_fore_load_mean = 0.0
	surge = 0.0
	undulation = 0.0
	for f in feet:
		f.phase = 0.0
		f.stance = true
		f.target = f.bind
		f.pitch = 0.0
		f.support = -f.root_bind.y
		f.plant_ground = f.contact_bind.x
		f.lift_ground = f.contact_bind.x
		f.just_landed = false


## Pick a gait. Passing `Kind.IDLE` parks the feet; the caller normally lets
## `Creature` choose from speed instead.
func set_kind(k: int) -> void:
	if k == kind:
		return
	kind = k
	duty = float(_pattern()["duty"])


func pattern_name() -> StringName:
	match kind:
		Kind.WALK: return &"walk"
		Kind.TROT: return &"trot"
		Kind.RUN: return &"run"
		Kind.HOP: return &"hop"
	return &"idle"


func _pattern() -> Dictionary:
	if _family == CreatureSpec.Locomotion.BIPED_HOP and kind == Kind.WALK:
		return BIPED_WALK
	return PATTERNS.get(kind, PATTERNS[Kind.WALK])


## Stride length grows sublinearly with speed — animals lengthen the step *and*
## step faster, roughly as v^0.55 / v^0.45. Anchored at the walk so a species
## only has to author one stride number.
func _stride_length(v: float) -> float:
	var ratio: float = clampf(v / maxf(_spec.walk_speed, 1e-3), 0.05, 6.0)
	return _stride_ref * pow(ratio, 0.55)


## Step frequency at a given speed, without advancing anything. The capture
## harness needs the cycle length before the first frame so it can space a
## contact sheet evenly across exactly one stride.
func frequency_for(v: float) -> float:
	if _spec == null or v < 0.02:
		return 0.0
	return clampf(v / maxf(_stride_length(v), 1e-3), 0.25, 6.0)


func advance(dt: float) -> void:
	if _spec == null or dt <= 0.0:
		return
	var v: float = maxf(speed, 0.0)
	exertion = clampf(v / maxf(_spec.run_speed, 1e-3), 0.0, 1.0)

	if kind == Kind.IDLE or v < 0.02:
		_idle_step(dt)
		return

	var stride: float = _stride_length(v)
	frequency = frequency_for(v)
	var pat := _pattern()
	duty = float(pat["duty"])
	travel += v * dt
	cycle = fposmod(cycle + frequency * dt, 1.0)

	var sweep: float = stride * duty
	var step_h: float = 0.0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		f.just_landed = false
		if not f.present:
			continue
		var was_stance := f.stance
		f.phase = fposmod(cycle + float(pat["phase"][i]), 1.0)
		f.stance = f.phase < duty
		step_h = f.reach * (0.09 + 0.16 * exertion) * float(pat["lift"])

		if f.stance:
			if not was_stance:
				# Touchdown. Pin the contact patch in ground space, ahead of where
				# it rests by half a sweep, and never move it again.
				f.plant_ground = travel + f.contact_bind.x + sweep * 0.5
				f.just_landed = true
				f.landing_force = clampf(0.35 + exertion, 0.0, 1.6)
			f.pitch = _stance_pitch(f.phase / maxf(duty, 1e-3))
			f.target = _ankle_for(f, Vector2(f.plant_ground - travel, 0.0))
			f.lift_ground = f.plant_ground
		else:
			var u: float = (f.phase - duty) / maxf(1.0 - duty, 1e-3)
			# Where this foot will land, in ground space: the body will have
			# moved on by the time the swing finishes.
			var swing_left: float = (1.0 - f.phase) / frequency
			var next_plant: float = travel + swing_left * v + f.contact_bind.x + sweep * 0.5
			var from_x: float = f.lift_ground - travel
			var to_x: float = next_plant - travel
			# Ease out hard at the end: a real foot is nearly stationary relative
			# to the ground when it touches down, and any residual velocity here
			# is exactly what reads as a skate.
			var e: float = _swing_ease(u)
			f.pitch = lerpf(0.42, -0.14, smoothstep(0.0, 0.55, u))
			f.target = _ankle_for(f, Vector2(lerpf(from_x, to_x, e),
				-step_h * _lift_curve(u)))
		f.support = _support_height(f)

	_solve_body(dt)


func _idle_step(dt: float) -> void:
	frequency = 0.0
	for f in feet:
		f.just_landed = false
		if not f.present:
			continue
		f.stance = true
		f.target = f.target.lerp(f.bind, clampf(dt * 9.0, 0.0, 1.0))
		f.pitch = lerpf(f.pitch, 0.0, clampf(dt * 9.0, 0.0, 1.0))
		f.support = _support_height(f)
	_solve_body(dt)


## Foot roll through stance, `st` running 0 → 1 from touchdown to lift-off: flat
## early, up onto the toe as the leg trails behind. This is what stops the paw
## looking welded on — and it is a named function rather than three inline lines
## because `_calibrate_bob` has to reproduce the same pose, and a roll that the
## calibration cannot see is a roll the bob gain is wrong about.
static func _stance_pitch(st: float) -> float:
	var a: float = clampf(st, 0.0, 1.0)
	return -0.10 * smoothstep(0.0, 0.22, a) + 0.42 * smoothstep(0.62, 1.0, a)


## Swing timing. Recovery is quick, placement is slow — the classic asymmetric
## step. A symmetric curve here is the single most common cause of "floaty".
static func _swing_ease(u: float) -> float:
	var a: float = clampf(u, 0.0, 1.0)
	return 1.0 - pow(1.0 - a, 2.4)


## Foot lift over the swing, peaking early so the leg is already reaching by the
## time it comes down.
static func _lift_curve(u: float) -> float:
	var a: float = clampf(u, 0.0, 1.0)
	return sin(PI * pow(a, 0.78))


## Ankle position that puts this foot's contact patch at `contact`, given the
## roll already chosen for this frame.
##
## The foot is rigid and rotates about the ankle, so a stance that pins the
## ankle necessarily sweeps the paw across the floor by the arm length times the
## roll — around a tenth of a unit for a cat's hind leg, which is a full ruler
## tick of skate on a contact sheet. Solving the contact first and reading the
## ankle back off it makes the pinned foot genuinely pinned, and the ankle rises
## and carries forward over the toe for free, which is what heel-off looks like.
func _ankle_for(f: Foot, contact: Vector2) -> Vector2:
	return contact - f.contact_arm.rotated(f.pitch)


## How high this leg permits the limb root to ride **above the ground**.
##
## For a foot on the ground that is the inverted pendulum: the ankle can be at
## most sqrt(reach² − dx²) below the hip, so the hip clears the floor by that
## much plus however high the ankle itself is. A foot in the *air* constrains
## nothing at all — it can be folded and set down anywhere — so the height it
## permits is its whole reach. Running the swing foot through the stance formula
## instead is what made the body sink through a gallop's suspension: mid-swing
## the target is projected almost a full stride ahead of the hip, which the
## pendulum reads as a leg with no height left in it.
##
## The ankle term is not a detail. The foot rolls onto the toe through the back
## half of stance, which lifts the ankle and carries it forward over the contact
## patch — that rise *is* the push-off, and dropping it (measuring the hip from
## the ankle alone) both loses the lift and makes the pendulum think the leg has
## height in reserve exactly when the body should be sinking. Between them those
## two errors sheared more than half of the authored bob away.
func _support_height(f: Foot) -> float:
	if not f.stance:
		# Gathered under the body: dx is zero because a folded leg can be set down
		# anywhere, so the whole reach is available from wherever the ankle is.
		return -f.target.y + f.reach
	var dx: float = f.target.x - f.root_bind.x
	return -f.target.y + sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))


## Turn the per-foot support heights into body bob, pitch and roll.
##
## Bob comes from the feet that are actually carrying weight, and from nothing
## else: a leg in the air holds up no part of the animal. When *no* foot is down
## the body is in a suspension, and the only height still meaningful is the one
## a gathered leg could reach — the top of the range — so the trunk floats up
## through the flight phase and drops again the instant a foot lands. Pitch and
## roll do still hear the swing legs, quietly, because they are about where the
## mass is leaning rather than about what is holding it up.
func _solve_body(dt: float) -> void:
	var w_sum := 0.0
	var stance_w := 0.0
	var stance_h := 0.0
	## Highest the body may ride before a supporting leg would have to stretch
	## past full extension. Without this, any bob amplitude the species asks for
	## that the legs cannot absorb comes out as feet hovering above the ground —
	## which no amount of tuning elsewhere can hide.
	var ceiling := -INF
	var fore_h := 0.0
	var fore_w := 0.0
	var hind_h := 0.0
	var hind_w := 0.0
	var near_h := 0.0
	var near_w := 0.0
	var far_h := 0.0
	var far_w := 0.0
	## Vertical load per foot: 0 at touchdown and at lift-off, 1 at mid-stance.
	## Deliberately normalised — the attitude channels are about *when* weight
	## hands over, not about how tall the animal is.
	var load := [0.0, 0.0, 0.0, 0.0]
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present:
			continue
		if f.stance:
			load[i] = sin(PI * clampf(f.phase / maxf(duty, 1e-3), 0.0, 1.0))
		var w: float = 1.0 if f.stance else 0.16
		w_sum += w
		if f.stance:
			stance_w += 1.0
			stance_h += f.support
			# The hip rides −root_bind.y − bob above the floor and may not out-climb
			# what this leg permits, so bob has a hard lower bound.
			ceiling = maxf(ceiling, -f.root_bind.y - f.support)
		# Attitude is a differential: how much higher than its *resting* height this
		# leg is currently letting its girdle sit. Feeding in the raw heights makes
		# an animal with unequal fore and hind legs — which is every quadruped we
		# ship — walk permanently nose-down.
		var lift_h: float = f.support - f.support_ref
		if i == FORE_NEAR or i == FORE_FAR:
			fore_h += lift_h * w
			fore_w += w
		else:
			hind_h += lift_h * w
			hind_w += w
		if i == FORE_NEAR or i == HIND_NEAR:
			near_h += lift_h * w
			near_w += w
		else:
			far_h += lift_h * w
			far_w += w
	if w_sum <= 0.0:
		return

	var mean: float = (stance_h / stance_w) if stance_w > 0.0 else _support_hi
	# `lift` finally does what the pattern table says it does. The pendulum's
	# geometry is nearly the same at every speed — a cat's legs are long next to
	# its stride, so the support height only ever varies by a couple of
	# hundredths — but a galloping animal's trunk travels far more than a walking
	# one's, because most of that travel is ballistic and no static geometry can
	# see it. `spec.bob` is authored for the walk; each faster pattern declares
	# how much further the body goes.
	var ride: float = _crouch + _move_crouch \
		* clampf(speed / maxf(_spec.walk_speed, 1e-3), 0.0, 1.0)
	var lift: float = float(_pattern()["lift"])
	var target_bob: float = ride + (_support_ref - mean) * _bob_gain * lift
	# `lift` is a budget as well as a gain. At a gallop the animal is often on a
	# single leg, and one pendulum swings far wider than the average of four does,
	# so the raw geometry overshot the declared amplitude by well over double — a
	# quarter of the cat's own height of vertical travel per stride.
	#
	# Compressed rather than clipped, and only above budget. A hard clip engaged
	# for two thirds of a gallop cycle and turned the curve into two flat plateaux,
	# which reads more mechanical than the overshoot it was fixing; this leaves an
	# ordinary stride untouched and only reins in the single-leg outliers.
	var budget: float = _spec.bob * _body_height * lift
	var excess: float = target_bob - ride
	var over: float = absf(excess) / maxf(budget, 1e-5)
	if over > 1.0:
		target_bob = ride + signf(excess) * budget * (2.0 - 1.0 / over)
	if is_finite(ceiling):
		target_bob = maxf(target_bob, ceiling)
	# One pole of smoothing: the body has mass and cannot follow a discontinuity in
	# support the instant a foot lands. The rate scales with cadence, because the
	# discontinuity *is* a footfall and footfalls arrive faster as the animal speeds
	# up. Held fixed, the corner sits below the stride at anything past a stroll,
	# which quietly halves the bob and drags what is left a sixth of a stride behind
	# the feet that are meant to be causing it — which is what "the bob is out of
	# phase with the footfalls" looks like from the outside.
	bob = lerpf(bob, target_bob, clampf(dt * maxf(26.0, frequency * 40.0), 0.0, 1.0))

	# Phase-driven trunk attitude, gated on the animal actually walking. At rest
	# the foot phases are frozen wherever the gait stopped, and reading them then
	# would park the trunk at a permanent tilt; the idle layer owns the resting
	# attitude instead, and these decay to zero through the followers below.
	var pitch_to := 0.0
	var roll_to := 0.0
	var twist_to := 0.0
	if frequency > 0.0:
		var has_fore: bool = feet[FORE_NEAR].present and feet[FORE_FAR].present
		var has_hind: bool = feet[HIND_NEAR].present and feet[HIND_FAR].present
		var roll_fore: float = load[FORE_NEAR] - load[FORE_FAR] if has_fore else 0.0
		var roll_hind: float = load[HIND_NEAR] - load[HIND_FAR] if has_hind else 0.0
		if (feet[FORE_NEAR].present or feet[FORE_FAR].present) \
				and (feet[HIND_NEAR].present or feet[HIND_FAR].present):
			# The hind girdle carrying more than the fore means the croup is being
			# driven up while the forehand falls away underneath it: nose down.
			pitch_to = _soft_clip((_pair_load(load, HIND_NEAR, HIND_FAR)
				- _pair_load(load, FORE_NEAR, FORE_FAR)) * PITCH_GAIN, PITCH_MAX)
		# Each girdle's own near/far split, kept apart rather than averaged. The
		# two are close to antiphase in every pattern we ship — at a trot they are
		# exact negatives — and that opposition *is* the counter-rotation.
		# Averaging the four feet together, which is what this used to do, cancels
		# it to nothing, and cancelling it is most of why the trunk read as one
		# rigid plank.
		#
		# Both girdles have to be complete for a twist between them to mean
		# anything. A biped has no forehand at all, and reading the absent pair as
		# a permanently unloaded one twisted its trunk against a girdle that does
		# not exist — which, because the legs hang off the pelvis this rotates,
		# walked the bird's feet a tenth of a unit off the spots they were pinned
		# to. Measured: slip 0.1071 with the phantom girdle, 0.0000 without it.
		if has_fore and has_hind:
			twist_to = (roll_fore - roll_hind) * 0.5 * TWIST_GAIN
		roll_to = (roll_fore + roll_hind) * 0.5 * ROLL_GAIN
		# A sprawling animal's trunk motion is lateral, not sagittal — the spine
		# writhes side to side and `undulation` already carries all of it. Pitching
		# a lizard's long trunk on top of that only drives the far end of a metre
		# of tail through the floor, which is exactly what it measured.
		if _family == CreatureSpec.Locomotion.SPRAWLING:
			pitch_to *= 0.35
			twist_to *= 0.35
	# The geometric differentials stay in the sum. They are a rounding error on a
	# level floor, but they are the only term that hears a species whose hind legs
	# are longer than its fore ones, or a foot that landed somewhere unexpected.
	if fore_w > 0.0 and hind_w > 0.0:
		pitch_to += atan2((hind_h / hind_w) - (fore_h / fore_w), _body_len) * 0.55
	if near_w > 0.0 and far_w > 0.0:
		roll_to += clampf(((near_h / near_w) - (far_h / far_w)) * 1.4, -0.5, 0.5) * 0.22
	pitch = lerpf(pitch, pitch_to, clampf(dt * 18.0, 0.0, 1.0))
	roll = lerpf(roll, roll_to, clampf(dt * 16.0, 0.0, 1.0))
	girdle_twist = lerpf(girdle_twist, twist_to, clampf(dt * 20.0, 0.0, 1.0))

	# Trunk *shape*, as opposed to trunk attitude. Both channels are differentials
	# against a rest value and both are gated on the animal actually moving, for
	# the same reason the attitude channels are: at a standstill the phases are
	# frozen wherever the gait stopped, and a frozen phase read as a pose is a
	# permanent deformity.
	var flex_to := 0.0
	var withers_to := 0.0
	if frequency > 0.0:
		# The two girdles' feet closing toward each other is the animal gathering,
		# and a gathering quadruped rounds its back — that coupling is the whole of
		# a bound and most of a gallop. Normalised by the trunk so it means the same
		# thing on a lizard and a whippet.
		flex_to = _soft_clip((_span_ref - _girdle_span()) / maxf(_body_len, 1e-3)
			* FLEX_GAIN, FLEX_MAX)
		# A sprawling animal's trunk already carries all its motion laterally
		# through `undulation`; adding a sagittal arch on top only lifts the middle
		# of a lizard off the floor.
		if _family == CreatureSpec.Locomotion.SPRAWLING:
			flex_to *= 0.25
		var fore_load: float = _pair_load(load, FORE_NEAR, FORE_FAR)
		_fore_load_mean = lerpf(_fore_load_mean, fore_load, clampf(dt * 1.4, 0.0, 1.0))
		withers_to = (fore_load - _fore_load_mean) * WITHERS_GAIN * _reach_ref
	else:
		_fore_load_mean = lerpf(_fore_load_mean, 0.0, clampf(dt * 1.4, 0.0, 1.0))
	# Faster followers than the attitude channels above. Both of these are shape
	# changes driven by a limb taking load, and a limb takes load in about a tenth
	# of a second; smoothed at the trunk's rate they arrive after the footfall that
	# caused them, which reads as the body sagging rather than bracing.
	flex = lerpf(flex, flex_to, clampf(dt * 22.0, 0.0, 1.0))
	withers = lerpf(withers, withers_to, clampf(dt * 26.0, 0.0, 1.0))

	# Fore-aft surge: the body decelerates against each braking forelimb and is
	# pushed on by each hind. Small, but its absence is why naive walk cycles
	# look like a puppet sliding along a rail.
	var s := 0.0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present or not f.stance:
			continue
		var st: float = f.phase / maxf(duty, 1e-3)
		var push: float = sin(PI * st)
		s += push * (-1.0 if (i == FORE_NEAR or i == FORE_FAR) else 1.0)
	surge = lerpf(surge, s * _stride_ref * 0.035 * exertion, clampf(dt * 20.0, 0.0, 1.0))

	# Sprawling locomotion: a travelling lateral wave along the trunk. In a side
	# view its most visible component is the trunk shortening and swinging as the
	# animal writhes, so the rig maps it onto the spine as an in-plane S-bend.
	if _family == CreatureSpec.Locomotion.SPRAWLING:
		undulation = sin(TAU * cycle) * (0.10 + 0.16 * exertion)
	else:
		undulation = 0.0


## Fore-aft gap between the two girdles' feet, right now. Measured off the live
## targets rather than off the cycle phase, so it stays honest through a
## suspension, a turn, or a foot placed somewhere the pattern did not predict.
func _girdle_span() -> float:
	var fore := 0.0
	var fore_n := 0
	var hind := 0.0
	var hind_n := 0
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present:
			continue
		if i == FORE_NEAR or i == FORE_FAR:
			fore += f.target.x
			fore_n += 1
		else:
			hind += f.target.x
			hind_n += 1
	if fore_n == 0 or hind_n == 0:
		return _span_ref
	return fore / float(fore_n) - hind / float(hind_n)


## Mean vertical load across one girdle's pair, ignoring limbs the species never
## authored — a biped must not read a missing forehand as a permanently
## unloaded one and walk around nose-up.
func _pair_load(load: Array, near: int, far: int) -> float:
	var sum := 0.0
	var n := 0
	if feet[near].present:
		sum += float(load[near])
		n += 1
	if feet[far].present:
		sum += float(load[far])
		n += 1
	return sum / float(maxi(n, 1))


## Soft saturation: linear near zero, asymptotic at `cap`. A hard clamp on an
## attitude channel flattens the top of every stride into a plateau, which reads
## more mechanical than the overshoot it was fixing — the same lesson the bob
## budget above already learned the expensive way.
static func _soft_clip(v: float, cap: float) -> float:
	return v / (1.0 + absf(v) / maxf(cap, 1e-4))


## The single strongest foot impact this frame, for squash and audio. Zero when
## nothing landed.
func landing_impulse() -> float:
	var best := 0.0
	for f in feet:
		if f.just_landed:
			best = maxf(best, f.landing_force)
	return best


## Gait a given speed should be using. Kept here so the brain can ask without
## reimplementing the thresholds.
func kind_for_speed(v: float) -> int:
	if _spec == null:
		return Kind.IDLE
	if v < 0.02:
		return Kind.IDLE
	if _family == CreatureSpec.Locomotion.BIPED_HOP:
		return Kind.WALK if v < _spec.walk_speed * 1.25 else Kind.HOP
	if v < _spec.walk_speed * 1.35:
		return Kind.WALK
	if v < _spec.run_speed * 0.72:
		return Kind.TROT
	return Kind.RUN
