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
	## Height the hip above this foot is geometrically allowed to sit at.
	var support := 0.0
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

## Body outputs, read by the rig once per frame.
var bob := 0.0
var pitch := 0.0
var roll := 0.0
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

var _spec: CreatureSpec
var _family: int = CreatureSpec.Locomotion.QUADRUPED
var _stride_ref := 0.4
var _bob_gain := 1.0
var _body_len := 0.5
## Mean support height over the reference cycle; bob oscillates around it.
var _support_ref := 0.5
## Mean leg reach, i.e. the highest the body could ever ride. Stands in for the
## support mean during a suspension, when no foot is carrying anything.
var _reach_ref := 0.5
## Constant downward offset that buys the legs their flexion reserve.
var _crouch := 0.0
## Extra flexion carried once the animal is actually moving, faded in with speed.
var _move_crouch := 0.0


func setup(spec: CreatureSpec, chains: Array) -> void:
	_spec = spec
	_family = spec.locomotion
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

	# `spec.stride` is the ground distance covered by one full cycle at the
	# comfortable walking speed — the reference point the frequency law below
	# scales from. A foot's stance sweep is that times the duty factor.
	_stride_ref = maxf(spec.stride, 0.05)
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
			# against a curve the runtime never produces: stance feet only, and
			# the gathered height whenever the reference cycle has none down.
			if not stance:
				continue
			w_sum += 1.0
			# Stance sweeps the contact back linearly under the body.
			var dx: float = f.contact_bind.x + sweep * (0.5 - ph / d) - f.root_bind.x
			var support: float = sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))
			h_sum += support
			ceil_max = maxf(ceil_max, (f.bind.y - f.root_bind.y) - support)
		var mean: float = (h_sum / w_sum) if w_sum > 0.0 else _reach_ref
		lo = minf(lo, mean)
		hi = maxf(hi, mean)
	var span: float = hi - lo
	if not is_finite(span) or span < 1e-5:
		return 1.0
	_support_ref = (lo + hi) * 0.5
	# A foot planted ahead of the hip needs more leg than one straight under it.
	# If the body does not lower to pay for that, the reach constraint in
	# `_solve_body` shears the top off every bob and the authored amplitude never
	# appears — the animal walks with a nearly rigid trunk. So buy exactly the
	# headroom this cycle asks for, plus room for the authored swing, and fade it
	# in with speed: a cat stands tall and walks low, which is the same thing.
	_move_crouch = maxf(ceil_max - _crouch, 0.0) + spec.bob * spec.adult_height
	return clampf((spec.bob * spec.adult_height * 2.0) / span, 0.1, 12.0)


## Snap every foot back to its bind position and zero the cycle.
func settle() -> void:
	cycle = 0.0
	travel = 0.0
	bob = 0.0
	pitch = 0.0
	roll = 0.0
	surge = 0.0
	undulation = 0.0
	for f in feet:
		f.phase = 0.0
		f.stance = true
		f.target = f.bind
		f.pitch = 0.0
		f.support = absf(f.root_bind.y - f.bind.y)
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
			# Roll from heel to toe across stance: flat early, up onto the toe as
			# the leg trails behind. This is what stops the paw looking welded on.
			var st: float = f.phase / maxf(duty, 1e-3)
			f.pitch = -0.10 * smoothstep(0.0, 0.22, st) + 0.42 * smoothstep(0.62, 1.0, st)
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


## How high this leg permits the body to ride, measured from the ground.
##
## For a foot on the ground that is the inverted pendulum: the hip can be at most
## sqrt(reach² − dx²) above a contact dx away. A foot in the *air* constrains
## nothing at all — it can be folded and set down anywhere — so the height it
## permits is its whole reach. Running the swing foot through the stance formula
## instead is what made the body sink through a gallop's suspension: mid-swing
## the target is projected almost a full stride ahead of the hip, which the
## pendulum reads as a leg with no height left in it.
func _support_height(f: Foot) -> float:
	if not f.stance:
		return f.reach
	var dx: float = f.target.x - f.root_bind.x
	return sqrt(maxf(f.reach * f.reach - dx * dx, 0.0))


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
	for i in FOOT_COUNT:
		var f: Foot = feet[i]
		if not f.present:
			continue
		var w: float = 1.0 if f.stance else 0.16
		w_sum += w
		if f.stance:
			stance_w += 1.0
			stance_h += f.support
			ceiling = maxf(ceiling, (f.target.y - f.root_bind.y) - f.support)
		if i == FORE_NEAR or i == FORE_FAR:
			fore_h += f.support * w
			fore_w += w
		else:
			hind_h += f.support * w
			hind_w += w
		if i == FORE_NEAR or i == HIND_NEAR:
			near_h += f.support * w
			near_w += w
		else:
			far_h += f.support * w
			far_w += w
	if w_sum <= 0.0:
		return

	var mean: float = (stance_h / stance_w) if stance_w > 0.0 else _reach_ref
	# `lift` finally does what the pattern table says it does. The pendulum's
	# geometry is nearly the same at every speed — a cat's legs are long next to
	# its stride, so the support height only ever varies by a couple of
	# hundredths — but a galloping animal's trunk travels far more than a walking
	# one's, because most of that travel is ballistic and no static geometry can
	# see it. `spec.bob` is authored for the walk; each faster pattern declares
	# how much further the body goes.
	var ride: float = _crouch + _move_crouch \
		* clampf(speed / maxf(_spec.walk_speed, 1e-3), 0.0, 1.0)
	var target_bob: float = ride \
		+ (_support_ref - mean) * _bob_gain * float(_pattern()["lift"])
	if is_finite(ceiling):
		target_bob = maxf(target_bob, ceiling)
	# One pole of smoothing: the body has mass and cannot follow a discontinuity
	# in support the instant a foot lands.
	bob = lerpf(bob, target_bob, clampf(dt * 26.0, 0.0, 1.0))

	if fore_w > 0.0 and hind_w > 0.0:
		var delta: float = (hind_h / hind_w) - (fore_h / fore_w)
		pitch = lerpf(pitch, atan2(delta, _body_len) * 0.55, clampf(dt * 18.0, 0.0, 1.0))
	if near_w > 0.0 and far_w > 0.0:
		var d2: float = (near_h / near_w) - (far_h / far_w)
		roll = lerpf(roll, clampf(d2 * 1.4, -0.5, 0.5), clampf(dt * 16.0, 0.0, 1.0))

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
